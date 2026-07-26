// 1:1 audio/video calls over WebRTC.
//
// Media flows peer-to-peer (DTLS-SRTP); this hook only exchanges signaling
// through the server, and every signaling payload (SDP, ICE) is sealed with
// nacl.box between the two participants' pinned identity keys before it
// leaves the browser. The server relays ciphertext it cannot read or alter,
// so it cannot substitute DTLS fingerprints to man-in-the-middle a call.

import {
  getSecretKey,
  sealFor,
  openFrom,
  unlockIdentity,
  cacheSecretKey,
  forgetSecretKey,
} from "./crypto.js"
import {CallYouTube} from "./call_youtube.js"

const MICROPHONE_CONSTRAINTS = {
  echoCancellation: true,
  noiseSuppression: true,
  autoGainControl: true,
}

const CAMERA_CONSTRAINTS = {
  width: {ideal: 1280, max: 1280},
  height: {ideal: 720, max: 720},
  frameRate: {ideal: 30, max: 30},
}

const CHAT_FILE_LIMIT = 25 * 1024 * 1024
const CHAT_CHUNK_SIZE = 16 * 1024
const CHAT_FILE_ID_BYTES = 36
const CHAT_URL_PATTERN = /https?:\/\/[^\s<>"']+/giu
const CALL_EXIT_MESSAGE = "Are you sure? This activity will close the conference."

let activeCallExitGuard = null
let callExitGuardInstalled = false

export function installCallExitGuard() {
  if (callExitGuardInstalled) return
  callExitGuardInstalled = true

  window.addEventListener("beforeunload", event => {
    if (!activeCallExitGuard || activeCallExitGuard.allowExit) return
    event.preventDefault()
    event.returnValue = ""
  })

  window.addEventListener("popstate", event => {
    const guard = activeCallExitGuard
    if (!guard || guard.allowExit) return
    if (guard.restoringHistory) {
      guard.restoringHistory = false
      return
    }

    if (window.confirm(CALL_EXIT_MESSAGE)) {
      guard.allowExit = true
    } else {
      event.stopImmediatePropagation()
      guard.restoringHistory = true
      window.history.forward()
    }
  })

  document.addEventListener("click", event => {
    const guard = activeCallExitGuard
    if (!guard || guard.allowExit || event.defaultPrevented || event.button !== 0) return

    const target = event.target instanceof Element ? event.target : null
    const explicitExit = target?.closest("[data-call-exit]")
    const link = target?.closest("a[href]")
    if (!explicitExit && !callClosingLink(link)) return

    if (window.confirm(CALL_EXIT_MESSAGE)) {
      guard.allowExit = true
    } else {
      event.preventDefault()
      event.stopImmediatePropagation()
    }
  }, true)
}

function callClosingLink(link) {
  if (!link || link.target === "_blank" || link.hasAttribute("download")) return false

  let destination
  try {
    destination = new URL(link.href, window.location.href)
  } catch {
    return false
  }

  return (
    destination.origin !== window.location.origin ||
    destination.pathname !== window.location.pathname ||
    destination.search !== window.location.search
  )
}

function activateCallExitGuard(callId) {
  activeCallExitGuard = {
    callId,
    allowExit: false,
    restoringHistory: false,
  }
}

function deactivateCallExitGuard(callId) {
  if (activeCallExitGuard?.callId === callId) activeCallExitGuard = null
}

function allowCallExit(callId) {
  if (activeCallExitGuard?.callId === callId) activeCallExitGuard.allowExit = true
}

function trimChatUrl(raw) {
  let url = raw.replace(/[.,!?;:]+$/u, "")
  for (const [open, close] of [
    ["(", ")"],
    ["[", "]"],
    ["{", "}"],
  ]) {
    const count = (value, character) => value.split(character).length - 1
    while (url.endsWith(close) && count(url, close) > count(url, open)) url = url.slice(0, -1)
  }
  return url
}

export function chatTextSegments(text) {
  const content = String(text)
  const segments = []
  let cursor = 0

  for (const match of content.matchAll(CHAT_URL_PATTERN)) {
    if (match.index > cursor) {
      segments.push({kind: "text", value: content.slice(cursor, match.index)})
    }

    const url = trimChatUrl(match[0])
    segments.push({kind: "url", value: url})
    if (url.length < match[0].length) {
      segments.push({kind: "text", value: match[0].slice(url.length)})
    }
    cursor = match.index + match[0].length
  }

  if (cursor < content.length) segments.push({kind: "text", value: content.slice(cursor)})
  return segments
}

export const VIDEO_PROFILES = [
  {label: "HD", maxBitrate: 1_500_000, maxFramerate: 30, scaleResolutionDownBy: 1},
  {label: "Balanced", maxBitrate: 800_000, maxFramerate: 30, scaleResolutionDownBy: 1.5},
  {label: "Data saver", maxBitrate: 350_000, maxFramerate: 30, scaleResolutionDownBy: 2},
]

export function nextVideoProfileIndex(current, quality, goodSamples, degradedSamples) {
  const downgradeAfter = quality === "poor" ? 2 : 3

  if (quality !== "good" && degradedSamples >= downgradeAfter) {
    return Math.min(current + 1, VIDEO_PROFILES.length - 1)
  }

  if (quality === "good" && goodSamples >= 10) return Math.max(current - 1, 0)
  return current
}

export function classifyCallQuality({loss = 0, rtt = 0, jitter = 0, bitrate} = {}) {
  if (loss >= 0.08 || rtt >= 0.6 || jitter >= 0.08 || (bitrate && bitrate < 150_000)) {
    return "poor"
  }

  if (loss >= 0.03 || rtt >= 0.3 || jitter >= 0.04 || (bitrate && bitrate < 400_000)) {
    return "unstable"
  }

  return "good"
}

export const CallSession = {
  mounted() {
    const {callId, role, userId, peerKey} = this.el.dataset
    activateCallExitGuard(callId)
    this.role = role
    this.isGuest = this.el.dataset.isGuest === "true"
    this.peerKey = peerKey
    this.mySecret = getSecretKey(userId)
    this.iceServers = JSON.parse(this.el.dataset.iceServers || "[]")
    this.pc = null
    this.localStream = null
    this.pendingIce = []
    this.restartAttempts = 0
    this.maxRestartAttempts = 2
    this.restartInProgress = false
    this.previousInbound = null
    this.videoProfileIndex = 0
    this.goodQualitySamples = 0
    this.degradedQualitySamples = 0
    this.remoteSharing = false
    this.remoteFitMode = "contain"
    this.popoutWindow = null
    this.popoutVideo = null
    this.chatChannel = null
    this.chatOpen = false
    this.chatUnread = 0
    this.chatSending = false
    this.chatFiles = []
    this.chatObjectUrls = []
    this.incomingChatFiles = new Map()
    this.connectedAt = null
    this.callTimer = null
    this.wakeLock = null
    this.remoteMediaState = {audio: true, video: true}
    this.peerJoined = this.el.dataset.callState === "accepted"
    this.pendingSealedSignals = []
    this.secureSessionStarted = false
    this.remoteVideo = this.el.querySelector("[data-role=remote-video]")
    this.localVideo = this.el.querySelector("[data-role=local-video]")
    this.remoteShareStatus = this.el.querySelector("[data-role=remote-share-status]")
    this.setupVideo = this.el.querySelector("[data-role=setup-video]")
    this.setupEl = this.el.querySelector("[data-role=device-setup]")
    this.statusEl = this.el.querySelector("[data-role=call-status]")
    this.durationEl = this.el.querySelector("[data-role=call-duration]")
    this.qualityEl = this.el.querySelector("[data-role=call-quality]")
    this.noticeEl = this.el.querySelector("[data-role=call-notice]")
    this.chatPanel = this.el.querySelector("[data-role=chat-panel]")
    this.chatMessages = this.el.querySelector("[data-role=chat-messages]")
    this.chatInput = this.el.querySelector("[data-role=chat-input]")
    this.chatStatus = this.el.querySelector("[data-role=chat-status]")
    this.youtube = new CallYouTube(this)
    this.mediaReady = new Promise((resolve) => {
      this.resolveMediaReady = resolve
    })

    this.handleEvent("call:peer_joined", () => {
      this.peerJoined = true
      const hangupLabel = this.el.querySelector("[data-role=hangup-label]")
      if (hangupLabel) hangupLabel.textContent = "End call"
      this.setLifecycle("connecting", "Connecting…")
      if (this.secureSessionStarted && this.role === "caller") this.startAsCaller()
    })

    this.handleEvent("call:signal", ({ciphertext, nonce}) => {
      if (this.mySecret) this.openCallSignal(ciphertext, nonce)
      else this.pendingSealedSignals.push({ciphertext, nonce})
    })

    this.handleEvent("call:peer_disconnected", () => this.showReinvite())
    this.handleEvent("call:reinvite_failed", () => {
      const button = this.el.querySelector("#call-reinvite-submit")
      if (button) {
        button.disabled = false
        button.textContent = "Re-invite"
      }
    })

    if (this.mySecret) {
      this.beginSecureSession()
    } else if (this.isGuest) {
      const error = this.el.querySelector("[data-role=media-error]")
      if (error) {
        error.textContent = "This temporary guest identity is no longer available."
        error.classList.remove("hidden")
      }
      this.pushEvent("hangup", {})
    } else {
      this.showCallUnlock()
    }
  },

  beginSecureSession() {
    if (this.secureSessionStarted || !this.mySecret) return
    this.secureSessionStarted = true
    this.el.querySelector("[data-role=call-key-unlock]")?.classList.add("hidden")
    this.setupControls()
    this.deviceChangeHandler = () => this.refreshDeviceChoices({recoverMissing: true})
    if (navigator.mediaDevices && navigator.mediaDevices.addEventListener) {
      navigator.mediaDevices.addEventListener("devicechange", this.deviceChangeHandler)
    }
    // Negotiation awaits this promise: building the peer connection before
    // the user confirms their preview would create a receive-only session or
    // send from a device they did not mean to use.
    this.acquireMedia()

    if (this.role === "caller" && this.peerJoined) this.startAsCaller()
    for (const signal of this.pendingSealedSignals.splice(0)) {
      this.openCallSignal(signal.ciphertext, signal.nonce)
    }
  },

  showCallUnlock() {
    const panel = this.el.querySelector("[data-role=call-key-unlock]")
    const input = this.el.querySelector("[data-role=call-passphrase]")
    const button = this.el.querySelector("[data-role=unlock-call]")
    const error = this.el.querySelector("[data-role=call-unlock-error]")
    if (!panel || !input || !button) return this.fail("🔒 Unlock your keys to continue the call.")

    panel.classList.remove("hidden")
    panel.classList.add("flex")
    this.setLifecycle("locked", "Passphrase required")
    window.setTimeout(() => input.focus(), 0)

    const unlock = async () => {
      if (!input.value || button.disabled) return
      button.disabled = true
      button.textContent = "Unlocking…"
      error?.classList.add("hidden")

      try {
        const secretKey = await unlockIdentity(
          input.value,
          this.el.dataset.encSecretKey,
          this.el.dataset.keySalt,
          this.el.dataset.keyNonce,
        )

        if (!secretKey) {
          if (error) {
            error.textContent = "Wrong passphrase."
            error.classList.remove("hidden")
          }
          return
        }

        cacheSecretKey(this.el.dataset.userId, secretKey)
        this.mySecret = secretKey
        input.value = ""
        panel.classList.add("hidden")
        panel.classList.remove("flex")
        this.setLifecycle("connecting", this.role === "caller" ? "Ringing…" : "Connecting…")
        this.beginSecureSession()
      } catch {
        if (error) {
          error.textContent = "Could not unlock your keys on this device."
          error.classList.remove("hidden")
        }
      } finally {
        button.disabled = false
        button.textContent = "Unlock and continue"
      }
    }

    button.addEventListener("click", unlock)
    input.addEventListener("keydown", event => {
      if (event.key === "Enter") {
        event.preventDefault()
        unlock()
      }
    })
  },

  openCallSignal(ciphertext, nonce) {
    const payload = openFrom(ciphertext, nonce, this.peerKey, this.mySecret)
    if (!payload) return // tampered or stale — never act on unauthenticated signaling
    this.onSignal(payload)
  },

  showReinvite() {
    allowCallExit(this.el.dataset.callId)
    this.clearRecoveryTimers()
    this.stopQualityMonitoring()
    clearInterval(this.callTimer)
    this.callTimer = null
    this.releaseWakeLock()
    this.youtube?.stopShare()
    if (this.screenTrack) this.screenTrack.stop()
    this.localStream?.getTracks().forEach(track => track.stop())
    if (this.chatChannel) this.chatChannel.close()
    if (this.pc) this.pc.close()
    this.pc = null
    this.localStream = null
    if (this.localVideo) this.localVideo.srcObject = null
    if (this.remoteVideo) this.remoteVideo.srcObject = null
    this.setLifecycle("disconnected", "Connection lost")

    const panel = this.el.querySelector("[data-role=call-reinvite]")
    panel?.classList.remove("hidden")
    panel?.classList.add("flex")
    const button = this.el.querySelector("#call-reinvite-submit")
    button?.addEventListener("click", () => {
      if (button.disabled) return
      button.disabled = true
      button.textContent = "Sending invitation…"
    })
  },

  destroyed() {
    deactivateCallExitGuard(this.el.dataset.callId)
    if (this.isGuest) forgetSecretKey(this.el.dataset.userId)
    this.clearRecoveryTimers()
    this.stopQualityMonitoring()
    clearTimeout(this.noticeTimer)
    clearInterval(this.callTimer)
    if (navigator.mediaDevices && navigator.mediaDevices.removeEventListener) {
      navigator.mediaDevices.removeEventListener("devicechange", this.deviceChangeHandler)
    }
    if (this.fullscreenChangeHandler) {
      document.removeEventListener("fullscreenchange", this.fullscreenChangeHandler)
      document.removeEventListener("webkitfullscreenchange", this.fullscreenChangeHandler)
    }
    if (this.keyboardHandler) document.removeEventListener("keydown", this.keyboardHandler)
    if (this.visibilityHandler) document.removeEventListener("visibilitychange", this.visibilityHandler)
    this.releaseWakeLock()
    this.closeSharePopout()
    this.chatObjectUrls.forEach((url) => URL.revokeObjectURL(url))
    this.youtube?.destroy()
    if (this.chatChannel) this.chatChannel.close()
    if (document.pictureInPictureElement === this.remoteVideo && document.exitPictureInPicture) {
      document.exitPictureInPicture().catch(() => {})
    }
    if (this.screenTrack) this.screenTrack.stop()
    if (this.localStream) this.localStream.getTracks().forEach((t) => t.stop())
    if (this.pc) this.pc.close()
  },

  async acquireMedia() {
    try {
      this.localStream = await navigator.mediaDevices.getUserMedia({
        audio: MICROPHONE_CONSTRAINTS,
        video: CAMERA_CONSTRAINTS,
      })
    } catch {
      try {
        this.localStream = await navigator.mediaDevices.getUserMedia({
          audio: MICROPHONE_CONSTRAINTS,
        })
        this.showError("No camera available — continuing with audio only.")
      } catch {
        try {
          this.localStream = await navigator.mediaDevices.getUserMedia({
            video: CAMERA_CONSTRAINTS,
          })
          this.showError("Microphone unavailable — continuing with video only.")
        } catch (err) {
          this.captureFailed(err)
          return false
        }
      }
    }

    this.setTrackContentHints(this.localStream)

    if (this.localVideo && this.localStream.getVideoTracks().length > 0) {
      this.localVideo.srcObject = this.localStream
    }
    if (this.setupVideo && this.localStream.getVideoTracks().length > 0) {
      this.setupVideo.srcObject = this.localStream
    }

    await this.refreshDeviceChoices()
    this.setSetupReady()
    return true
  },

  async refreshDeviceChoices({recoverMissing = false} = {}) {
    try {
      const devices = await navigator.mediaDevices.enumerateDevices()
      this.cameras = devices.filter((d) => d.kind === "videoinput")
      this.microphones = devices.filter((d) => d.kind === "audioinput")
      this.speakers = devices.filter((d) => d.kind === "audiooutput")
      this.populateDeviceSelect("camera-select", this.cameras, "Camera")
      this.populateDeviceSelect("microphone-select", this.microphones, "Microphone")
      this.populateSpeakerSelect()

      const btn = this.el.querySelector("[data-role=switch-cam]")
      if (btn) btn.classList.toggle("hidden", this.cameras.length < 2)

      if (recoverMissing && this.localStream) await this.recoverMissingDevices()
    } catch {
      this.cameras = []
      this.microphones = []
      this.speakers = []
    }
  },

  populateDeviceSelect(role, devices, fallbackLabel) {
    const select = this.el.querySelector(`[data-role=${role}]`)
    if (!select) return

    const kind = role === "camera-select" ? "video" : "audio"
    const track = this.localStream && this.localStream.getTracks().find((item) => item.kind === kind)
    const selectedId = track && track.getSettings().deviceId
    select.replaceChildren()

    if (devices.length === 0) {
      const option = document.createElement("option")
      option.textContent = `No ${fallbackLabel.toLowerCase()} available`
      option.value = ""
      select.appendChild(option)
      select.disabled = true
      return
    }

    devices.forEach((device, index) => {
      const option = document.createElement("option")
      option.value = device.deviceId
      option.textContent = device.label || `${fallbackLabel} ${index + 1}`
      option.selected = device.deviceId === selectedId
      select.appendChild(option)
    })
    select.disabled = false
  },

  populateSpeakerSelect() {
    const field = this.el.querySelector("[data-role=speaker-field]")
    const select = this.el.querySelector("[data-role=speaker-select]")
    const supported = this.remoteVideo && typeof this.remoteVideo.setSinkId === "function"
    if (!field || !select) return

    field.classList.toggle("hidden", !supported || this.speakers.length === 0)
    field.classList.toggle("block", supported && this.speakers.length > 0)
    if (!supported || this.speakers.length === 0) return

    const selectedId = this.remoteVideo.sinkId || ""
    select.replaceChildren()
    this.speakers.forEach((device, index) => {
      const option = document.createElement("option")
      option.value = device.deviceId
      option.textContent = device.label || (index === 0 ? "System default" : `Speaker ${index + 1}`)
      option.selected = device.deviceId === selectedId
      select.appendChild(option)
    })
  },

  async recoverMissingDevices() {
    for (const [kind, devices] of [
      ["audio", this.microphones],
      ["video", this.cameras],
    ]) {
      const track = this.localStream.getTracks().find((item) => item.kind === kind)
      const activeId = track && track.getSettings().deviceId
      const missing = track && !devices.some((device) => device.deviceId === activeId)
      if (!track || (track.readyState !== "ended" && !missing)) continue

      if (devices.length > 0) {
        await this.replaceInput(kind, devices[0].deviceId)
        this.showCallNotice(
          `${kind === "audio" ? "Microphone" : "Camera"} disconnected · switched automatically.`
        )
      } else {
        this.showError(`${kind === "audio" ? "Microphone" : "Camera"} disconnected.`)
        this.sendMediaState()
      }
    }

    const sinkId = this.remoteVideo && this.remoteVideo.sinkId
    if (
      sinkId &&
      typeof this.remoteVideo.setSinkId === "function" &&
      !this.speakers.some((device) => device.deviceId === sinkId)
    ) {
      try {
        await this.remoteVideo.setSinkId("")
        this.showCallNotice("Speaker disconnected · switched to the system default.")
      } catch {
        this.showCallNotice("Speaker disconnected. Choose another output in Devices.")
      }
    }
  },

  async selectSpeaker(deviceId) {
    if (!this.remoteVideo || typeof this.remoteVideo.setSinkId !== "function") return
    try {
      await this.remoteVideo.setSinkId(deviceId)
      this.showCallNotice("Speaker changed.")
    } catch (err) {
      this.showError(`Could not change speaker: ${err.message}`)
      await this.refreshDeviceChoices()
    }
  },

  captureFailed(err) {
    const blocked = err && ["NotAllowedError", "PermissionDeniedError"].includes(err.name)
    const message = blocked
      ? "Camera and microphone access is blocked. Allow access in your browser's site settings, then retry."
      : `Could not access a microphone or camera: ${err.message}`

    this.showError(message)
    this.setLifecycle("device", "Waiting for device access")
    const retry = this.el.querySelector("[data-role=retry-media]")
    const complete = this.el.querySelector("[data-role=complete-setup]")
    if (retry) retry.classList.remove("hidden")
    if (complete) {
      complete.disabled = true
      complete.textContent = "Devices unavailable"
    }
  },

  setSetupReady() {
    this.clearError()
    const complete = this.el.querySelector("[data-role=complete-setup]")
    const retry = this.el.querySelector("[data-role=retry-media]")
    const empty = this.el.querySelector("[data-role=setup-video-empty]")
    const help = this.el.querySelector("[data-role=setup-help]")
    const hasVideo = this.localStream && this.localStream.getVideoTracks().length > 0
    const hasAudio = this.localStream && this.localStream.getAudioTracks().length > 0

    if (complete) {
      complete.disabled = false
      complete.textContent = this.joinedCall ? "Done" : "Join call"
    }
    if (retry) retry.classList.add("hidden")
    if (help && !this.joinedCall) {
      help.textContent = hasVideo
        ? hasAudio
          ? "Your preview stays on this device. Choose what you want to use, then join."
          : "No microphone is active. You can join with video only or choose another device."
        : "No camera is active. You can join with audio only or choose another device."
    }
    if (empty) {
      empty.classList.toggle("hidden", hasVideo)
      empty.classList.toggle("flex", !hasVideo)
    }
  },

  completeDeviceSetup() {
    if (!this.localStream || this.localStream.getTracks().length === 0) return
    if (this.setupEl) this.setupEl.classList.add("hidden")

    if (!this.joinedCall) {
      this.joinedCall = true
      if (this.resolveMediaReady) this.resolveMediaReady(true)
      this.resolveMediaReady = null
      this.setLifecycle(
        this.role === "caller" ? "ringing" : "connecting",
        this.role === "caller" ? "Ringing…" : "Ready — connecting…"
      )
      this.requestWakeLock()
    }
  },

  openDeviceSetup() {
    if (!this.setupEl || !this.localStream) return
    const title = this.el.querySelector("[data-role=setup-title]")
    const help = this.el.querySelector("[data-role=setup-help]")
    if (title) title.textContent = this.joinedCall ? "Call devices" : "Check your devices"
    if (help) {
      help.textContent = this.joinedCall
        ? "Changes apply immediately and stay on this device."
        : "Your preview stays on this device. Choose what you want to use, then join."
    }
    this.setSetupReady()
    this.setupEl.classList.remove("hidden")
  },

  async retryCapture() {
    if (this.localStream) this.localStream.getTracks().forEach((track) => track.stop())
    this.localStream = null
    const retry = this.el.querySelector("[data-role=retry-media]")
    const complete = this.el.querySelector("[data-role=complete-setup]")
    if (retry) retry.classList.add("hidden")
    if (complete) {
      complete.disabled = true
      complete.textContent = "Preparing devices…"
    }
    this.clearError()
    await this.acquireMedia()
  },

  async replaceInput(kind, deviceId) {
    if (!deviceId || !this.localStream) return
    if (kind === "video" && this.screenTrack) {
      return this.showError("Stop screen sharing before changing cameras.")
    }

    const constraints =
      kind === "audio"
        ? {
            audio: {...MICROPHONE_CONSTRAINTS, deviceId: {exact: deviceId}},
            video: false,
          }
        : {
            audio: false,
            video: {...CAMERA_CONSTRAINTS, deviceId: {exact: deviceId}},
          }

    try {
      const stream = await navigator.mediaDevices.getUserMedia(constraints)
      const newTrack = stream.getTracks().find((track) => track.kind === kind)
      const oldTrack = this.localStream.getTracks().find((track) => track.kind === kind)
      if (!newTrack) throw new Error(`The selected ${kind} device did not provide a track.`)
      newTrack.contentHint = kind === "audio" ? "speech" : "motion"
      if (oldTrack) newTrack.enabled = oldTrack.enabled

      const sender =
        this.pc && this.pc.getSenders().find((item) => item.track && item.track.kind === kind)
      if (this.pc && !sender) {
        newTrack.stop()
        throw new Error(`A new ${kind} track can only be added before joining the call.`)
      }
      if (sender) await sender.replaceTrack(newTrack)

      if (oldTrack) {
        this.localStream.removeTrack(oldTrack)
        oldTrack.stop()
      }
      this.localStream.addTrack(newTrack)

      if (kind === "video") {
        await this.applyVideoProfile({announce: false})
        if (this.localVideo) this.localVideo.srcObject = this.localStream
        if (this.setupVideo) this.setupVideo.srcObject = this.localStream
      }

      this.clearError()
      await this.refreshDeviceChoices()
      this.sendMediaState()
    } catch (err) {
      this.showError(`Could not change ${kind === "audio" ? "microphone" : "camera"}: ${err.message}`)
      await this.refreshDeviceChoices()
    }
  },

  setTrackContentHints(stream) {
    for (const track of stream.getAudioTracks()) track.contentHint = "speech"
    for (const track of stream.getVideoTracks()) track.contentHint = "motion"
  },

  // Shares the whole screen or one window (the browser's picker offers the
  // choice). The screen track replaces the outgoing camera track on the
  // existing sender — no renegotiation — and the camera comes back when
  // sharing stops, including via the browser's own "Stop sharing" bar.
  async toggleScreenShare() {
    if (this.screenTrack) return this.stopScreenShare()
    if (this.youtube?.active) {
      return this.showCallNotice("Stop YouTube sharing before sharing your screen.")
    }

    const cameraTrack = this.localStream && this.localStream.getVideoTracks()[0]
    const sender =
      this.pc && this.pc.getSenders().find((s) => s.track && s.track.kind === "video")

    if (!cameraTrack || !sender) {
      return this.showError("Screen sharing needs a connected call with video.")
    }

    let stream
    try {
      stream = await navigator.mediaDevices.getDisplayMedia({video: true})
    } catch {
      return // picker dismissed — not an error
    }

    try {
      const track = stream.getVideoTracks()[0]
      track.contentHint = "detail"
      this.screenTrack = track
      track.addEventListener("ended", () => this.stopScreenShare())
      await sender.replaceTrack(track)
      await this.applyScreenShareProfile(sender)
      if (this.localVideo) this.localVideo.srcObject = stream
      this.setShareUi(true)
      this.sendSignal({kind: "share_state", sharing: true})
      this.sendMediaState()
    } catch (err) {
      this.screenTrack = null
      stream.getTracks().forEach((t) => t.stop())
      this.showError(`Could not share the screen: ${err.message}`)
    }
  },

  async stopScreenShare() {
    const track = this.screenTrack
    if (!track) return
    this.screenTrack = null
    track.stop()

    const cameraTrack = this.localStream && this.localStream.getVideoTracks()[0]
    const sender =
      this.pc && this.pc.getSenders().find((s) => s.track && s.track.kind === "video")

    try {
      if (sender && cameraTrack) {
        await sender.replaceTrack(cameraTrack)
        await this.applyVideoProfile({announce: false})
      }
    } catch (err) {
      this.showError(`Could not restore the camera: ${err.message}`)
    }

    if (this.localVideo) this.localVideo.srcObject = this.localStream
    this.setShareUi(false)
    this.sendSignal({kind: "share_state", sharing: false})
    this.sendMediaState()
  },

  // While sharing, the camera controls would silently fight the screen
  // track, so they sit disabled until sharing stops.
  setShareUi(sharing) {
    const share = this.el.querySelector("[data-role=share-screen]")
    if (share) share.textContent = sharing ? "🖥 Stop sharing" : "🖥 Share screen"

    for (const role of ["toggle-cam", "switch-cam"]) {
      const btn = this.el.querySelector(`[data-role=${role}]`)
      if (btn) btn.disabled = sharing
    }
  },

  // Swaps the outgoing video to the next camera without renegotiating: the
  // new track replaces the old one on the existing RTCRtpSender.
  async switchCamera() {
    if (this.screenTrack) return
    const oldTrack = this.localStream && this.localStream.getVideoTracks()[0]
    if (!oldTrack || !this.cameras || this.cameras.length < 2) return

    const currentId = oldTrack.getSettings().deviceId
    const index = this.cameras.findIndex((d) => d.deviceId === currentId)
    const next = this.cameras[(index + 1) % this.cameras.length]

    await this.replaceInput("video", next.deviceId)
  },

  // The caller starts negotiation only after the callee's page joined, so
  // no offer is ever sent into the void — and only after local capture has
  // settled, so the offer actually carries this side's tracks.
  async startAsCaller() {
    if (this.negotiating || this.pc) return
    this.negotiating = true
    const mediaAvailable = await this.mediaReady
    if (!mediaAvailable) {
      this.negotiating = false
      return
    }
    if (this.pc) return
    this.createPeer()
    const offer = await this.pc.createOffer()
    await this.pc.setLocalDescription(offer)
    this.sendSignal({kind: "offer", sdp: this.pc.localDescription.sdp})
  },

  createPeer() {
    this.pc = new RTCPeerConnection({iceServers: this.iceServers})
    this.pc.ondatachannel = (event) => this.setupChatChannel(event.channel)

    if (this.role === "caller") {
      this.setupChatChannel(this.pc.createDataChannel("veejr-call-chat", {ordered: true}))
    }

    for (const track of this.localStream ? this.localStream.getTracks() : []) {
      this.pc.addTrack(track, this.localStream)
    }
    this.applyVideoProfile({announce: false})

    this.pc.ontrack = (event) => {
      if (this.remoteVideo && event.streams[0]) {
        this.remoteVideo.srcObject = event.streams[0]
        if (this.popoutVideo) this.popoutVideo.srcObject = event.streams[0]
        // Nudge playback in case the browser's autoplay policy paused it.
        this.remoteVideo.play().catch(() => {})
      }
      if (event.track) {
        event.track.addEventListener("ended", () =>
          this.setRemoteMediaState({[event.track.kind]: false})
        )
      }
    }

    this.pc.onicecandidate = (event) => {
      if (event.candidate) this.sendSignal({kind: "ice", candidate: event.candidate.toJSON()})
    }

    this.pc.onconnectionstatechange = () => {
      const state = this.pc.connectionState
      if (state === "connected") {
        this.clearRecoveryTimers()
        this.restartAttempts = 0
        this.setLifecycle("connected", "Connected — end-to-end encrypted")
        this.startCallTimer()
        this.requestWakeLock()
        this.sendMediaState()
        this.startQualityMonitoring()
      } else if (state === "closed") {
        this.setLifecycle("ended", "Call ended")
      }
    }

    this.pc.oniceconnectionstatechange = () => {
      const state = this.pc.iceConnectionState

      if (state === "checking") this.setLifecycle("connecting", "Connecting…")

      if (state === "disconnected") {
        this.setLifecycle("reconnecting", "Connection interrupted — reconnecting…")
        clearTimeout(this.disconnectTimer)
        this.disconnectTimer = setTimeout(() => this.requestIceRecovery(), 5_000)
      }

      if (state === "failed") this.requestIceRecovery()
    }
  },

  async onSignal(payload) {
    try {
      if (payload.kind === "offer") {
        if (!this.pc) {
          // Wait for capture before answering — an answer built without
          // local tracks would be receive-only and the caller would never
          // see or hear this side.
          const mediaAvailable = await this.mediaReady
          if (!mediaAvailable) return
          if (!this.pc) this.createPeer()
        }

        await this.pc.setRemoteDescription({type: "offer", sdp: payload.sdp})
        const answer = await this.pc.createAnswer()
        await this.pc.setLocalDescription(answer)
        this.sendSignal({kind: "answer", sdp: this.pc.localDescription.sdp})
        await this.flushPendingIce()
      } else if (payload.kind === "answer") {
        if (!this.pc) return
        await this.pc.setRemoteDescription({type: "answer", sdp: payload.sdp})
        await this.flushPendingIce()
      } else if (payload.kind === "ice") {
        if (this.pc && this.pc.remoteDescription) {
          await this.pc.addIceCandidate(payload.candidate)
        } else {
          this.pendingIce.push(payload.candidate)
        }
      } else if (payload.kind === "restart_request" && this.role === "caller") {
        await this.restartConnection()
      } else if (payload.kind === "share_state") {
        this.setRemoteShareState(payload.sharing === true)
      } else if (payload.kind === "media_state") {
        this.setRemoteMediaState({audio: payload.audio === true, video: payload.video === true})
      }
    } catch (err) {
      this.showError(`Call negotiation failed: ${err.message}`)
    }
  },

  async flushPendingIce() {
    while (this.pendingIce.length > 0) {
      await this.pc.addIceCandidate(this.pendingIce.shift())
    }
  },

  clearRecoveryTimers() {
    clearTimeout(this.disconnectTimer)
    clearTimeout(this.restartTimer)
    this.disconnectTimer = null
    this.restartTimer = null
  },

  async requestIceRecovery() {
    if (!this.pc || this.pc.connectionState === "closed") return

    if (this.restartAttempts >= this.maxRestartAttempts) {
      this.clearRecoveryTimers()
      this.stopQualityMonitoring()
      this.setLifecycle("failed", "Connection failed")
      return this.showError(
        "The call could not reconnect after two attempts. Check your connection and try again."
      )
    }

    if (this.role === "caller") {
      await this.restartConnection()
    } else {
      this.restartAttempts += 1
      this.setLifecycle(
        "reconnecting",
        `Reconnecting (attempt ${this.restartAttempts}/${this.maxRestartAttempts})…`
      )
      this.sendSignal({kind: "restart_request"})
      clearTimeout(this.restartTimer)
      this.restartTimer = setTimeout(() => this.requestIceRecovery(), 8_000)
    }
  },

  // Only the original caller creates restart offers. That fixed ownership
  // avoids offer glare when both browsers notice the same network change.
  async restartConnection() {
    if (
      !this.pc ||
      this.restartInProgress ||
      this.restartAttempts >= this.maxRestartAttempts ||
      this.pc.signalingState !== "stable"
    ) {
      return
    }

    this.restartInProgress = true
    this.restartAttempts += 1
    this.setLifecycle(
      "reconnecting",
      `Reconnecting (attempt ${this.restartAttempts}/${this.maxRestartAttempts})…`
    )

    try {
      this.pc.restartIce()
      const offer = await this.pc.createOffer({iceRestart: true})
      await this.pc.setLocalDescription(offer)
      this.sendSignal({kind: "offer", sdp: this.pc.localDescription.sdp, restart: true})
    } catch (err) {
      this.showError(`Could not restart the connection: ${err.message}`)
    } finally {
      this.restartInProgress = false
    }

    clearTimeout(this.restartTimer)
    this.restartTimer = setTimeout(() => this.requestIceRecovery(), 8_000)
  },

  startQualityMonitoring() {
    if (!this.pc || this.qualityTimer) return
    if (this.qualityEl) this.qualityEl.classList.remove("hidden")
    this.updateCallQuality()
    this.qualityTimer = setInterval(() => this.updateCallQuality(), 2_000)
  },

  stopQualityMonitoring() {
    clearInterval(this.qualityTimer)
    this.qualityTimer = null
    this.previousInbound = null
    this.goodQualitySamples = 0
    this.degradedQualitySamples = 0
  },

  // WebRTC statistics stay in this browser. Only a coarse quality label is
  // rendered; no IP addresses, candidate details, or metrics reach Phoenix.
  async updateCallQuality() {
    if (!this.pc || !this.qualityEl || this.pc.connectionState !== "connected") return

    try {
      const stats = await this.pc.getStats()
      let pair
      let transport
      let received = 0
      let lost = 0
      let jitter = 0

      stats.forEach((report) => {
        if (report.type === "transport" && report.selectedCandidatePairId) transport = report
        if (report.type === "candidate-pair" && report.state === "succeeded" && report.nominated) {
          pair = report
        }
        if (report.type === "inbound-rtp" && !report.isRemote) {
          received += report.packetsReceived || 0
          lost += report.packetsLost || 0
          jitter = Math.max(jitter, report.jitter || 0)
        }
      })

      if (transport) pair = stats.get(transport.selectedCandidatePairId) || pair

      const previous = this.previousInbound
      const receivedDelta = previous ? Math.max(0, received - previous.received) : 0
      const lostDelta = previous ? Math.max(0, lost - previous.lost) : 0
      const packetDelta = receivedDelta + lostDelta
      const loss = packetDelta > 0 ? lostDelta / packetDelta : 0
      this.previousInbound = {received, lost}

      const localCandidate = pair && stats.get(pair.localCandidateId)
      const remoteCandidate = pair && stats.get(pair.remoteCandidateId)
      const relayed =
        (localCandidate && localCandidate.candidateType === "relay") ||
        (remoteCandidate && remoteCandidate.candidateType === "relay")
      const rtt = (pair && pair.currentRoundTripTime) || 0
      const bitrate = pair && pair.availableOutgoingBitrate
      const quality = classifyCallQuality({loss, rtt, jitter, bitrate})

      await this.observeCallQuality(quality)
      this.renderCallQuality(quality, relayed, {loss, rtt})
    } catch {
      // Stats availability differs across browsers; the call itself should
      // never be interrupted because a quality sample is unavailable.
    }
  },

  async observeCallQuality(quality) {
    if (this.screenTrack || !this.localStream || this.localStream.getVideoTracks().length === 0) {
      return
    }

    if (quality === "good") {
      this.goodQualitySamples += 1
      this.degradedQualitySamples = 0
    } else {
      this.degradedQualitySamples += 1
      this.goodQualitySamples = 0
    }

    const nextIndex = nextVideoProfileIndex(
      this.videoProfileIndex,
      quality,
      this.goodQualitySamples,
      this.degradedQualitySamples
    )
    if (nextIndex === this.videoProfileIndex) return

    const previousIndex = this.videoProfileIndex
    this.videoProfileIndex = nextIndex
    const applied = await this.applyVideoProfile({announce: true})
    if (!applied) this.videoProfileIndex = previousIndex
    this.goodQualitySamples = 0
    this.degradedQualitySamples = 0
  },

  async applyVideoProfile({announce = false} = {}) {
    const sender =
      this.pc && this.pc.getSenders().find((item) => item.track && item.track.kind === "video")
    if (!sender || !sender.getParameters || !sender.setParameters) return false

    const profile = VIDEO_PROFILES[this.videoProfileIndex]

    try {
      const parameters = sender.getParameters()
      if (!parameters.encodings || parameters.encodings.length === 0) parameters.encodings = [{}]
      parameters.encodings[0].maxBitrate = profile.maxBitrate
      parameters.encodings[0].maxFramerate = profile.maxFramerate
      parameters.encodings[0].scaleResolutionDownBy = profile.scaleResolutionDownBy
      await sender.setParameters(parameters)

      if (announce) {
        const reduced = this.videoProfileIndex > 0
        this.showCallNotice(
          reduced
            ? `Video adjusted to ${profile.label.toLowerCase()} to keep audio clear.`
            : "Connection improved — HD video restored."
        )
      }
      return true
    } catch {
      // Some browser versions expose getParameters without allowing encoding
      // changes. The call continues at the browser's own selected quality.
      return false
    }
  },

  async applyScreenShareProfile(sender) {
    if (!sender || !sender.getParameters || !sender.setParameters) return

    try {
      const parameters = sender.getParameters()
      if (!parameters.encodings || parameters.encodings.length === 0) parameters.encodings = [{}]
      parameters.encodings[0].maxBitrate = 1_500_000
      parameters.encodings[0].maxFramerate = 15
      parameters.encodings[0].scaleResolutionDownBy = 1
      await sender.setParameters(parameters)
    } catch {
      // Keep sharing with browser defaults when sender tuning is unavailable.
    }
  },

  renderCallQuality(quality, relayed, {loss, rtt}) {
    const styles = {
      good: "border-success/40 bg-success/10 text-success",
      unstable: "border-warning/50 bg-warning/10 text-warning",
      poor: "border-error/50 bg-error/10 text-error",
    }

    this.qualityEl.className =
      `rounded-full border px-2 py-0.5 text-xs font-medium ${styles[quality]}`
    this.qualityEl.textContent =
      `${quality === "good" ? "Good" : quality === "unstable" ? "Unstable" : "Poor"}` +
      ` · ${relayed ? "relayed" : "direct"}` +
      (this.videoProfileIndex > 0 ? ` · ${VIDEO_PROFILES[this.videoProfileIndex].label}` : "")
    this.qualityEl.title =
      `Round trip ${Math.round(rtt * 1000)} ms · packet loss ${Math.round(loss * 100)}%` +
      ` · video ${VIDEO_PROFILES[this.videoProfileIndex].label}`
  },

  setLifecycle(state, text) {
    this.el.dataset.lifecycle = state
    this.say(text)
  },

  startCallTimer() {
    if (!this.connectedAt) this.connectedAt = Date.now()
    if (this.callTimer) return
    if (this.durationEl) this.durationEl.classList.remove("hidden")
    this.updateCallTimer()
    this.callTimer = setInterval(() => this.updateCallTimer(), 1_000)
  },

  updateCallTimer() {
    if (!this.durationEl || !this.connectedAt) return
    const elapsed = Math.max(0, Math.floor((Date.now() - this.connectedAt) / 1_000))
    const hours = Math.floor(elapsed / 3_600)
    const minutes = Math.floor((elapsed % 3_600) / 60)
    const seconds = elapsed % 60
    this.durationEl.textContent =
      hours > 0
        ? `${hours}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`
        : `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`
  },

  sendMediaState() {
    if (!this.pc || this.pc.connectionState === "closed") return
    const audio = this.localStream?.getAudioTracks()[0]
    const video = this.localStream?.getVideoTracks()[0]
    this.sendSignal({
      kind: "media_state",
      audio: Boolean(audio && audio.enabled && audio.readyState === "live"),
      video: Boolean(this.screenTrack || (video && video.enabled && video.readyState === "live")),
    })
  },

  setRemoteMediaState(next) {
    for (const kind of ["audio", "video"]) {
      if (typeof next[kind] === "boolean") this.remoteMediaState[kind] = next[kind]
    }

    for (const [role, active] of [
      ["peer-muted", this.remoteMediaState.audio],
      ["peer-camera-off", this.remoteMediaState.video],
    ]) {
      const badge = this.el.querySelector(`[data-role=${role}]`)
      if (!badge) continue
      badge.classList.toggle("hidden", active)
      badge.classList.toggle("inline-flex", !active)
    }
  },

  async requestWakeLock() {
    if (!this.joinedCall || document.hidden || !navigator.wakeLock || this.wakeLock) return
    try {
      const lock = await navigator.wakeLock.request("screen")
      this.wakeLock = lock
      lock.addEventListener("release", () => {
        if (this.wakeLock === lock) this.wakeLock = null
      })
    } catch {
      // Wake lock is an enhancement; calls continue normally when denied.
    }
  },

  releaseWakeLock() {
    const lock = this.wakeLock
    this.wakeLock = null
    if (lock) lock.release().catch(() => {})
  },

  showCallNotice(text) {
    if (!this.noticeEl) return
    clearTimeout(this.noticeTimer)
    this.noticeEl.textContent = text
    this.noticeEl.classList.remove("hidden")
    this.noticeTimer = setTimeout(() => this.noticeEl.classList.add("hidden"), 5_000)
  },

  setupChatChannel(channel) {
    if (this.chatChannel && this.chatChannel !== channel) this.chatChannel.close()
    this.chatChannel = channel
    channel.binaryType = "arraybuffer"
    channel.bufferedAmountLowThreshold = 256 * 1024

    channel.onopen = () => {
      if (this.chatStatus) this.chatStatus.textContent = "Direct · encrypted"
      this.updateChatComposer()
      this.youtube?.channelStateChanged()
    }
    channel.onclose = () => {
      if (this.chatStatus) this.chatStatus.textContent = "Chat disconnected"
      this.updateChatComposer()
      this.youtube?.channelStateChanged()
    }
    channel.onerror = () => this.showChatError("The direct chat connection was interrupted.")
    channel.onmessage = (event) => {
      this.handleChatData(event.data).catch(() =>
        this.showChatError("A call chat item could not be received.")
      )
    }

    if (channel.readyState === "open") channel.onopen()
  },

  async handleChatData(data) {
    if (typeof data === "string") {
      let payload
      try {
        payload = JSON.parse(data)
      } catch {
        return
      }
      return this.handleChatPayload(payload)
    }

    const buffer = data instanceof Blob ? await data.arrayBuffer() : data
    if (!(buffer instanceof ArrayBuffer) || buffer.byteLength <= CHAT_FILE_ID_BYTES) return

    const bytes = new Uint8Array(buffer)
    const id = new TextDecoder().decode(bytes.slice(0, CHAT_FILE_ID_BYTES))
    const transfer = this.incomingChatFiles.get(id)
    if (!transfer) return

    const chunk = bytes.slice(CHAT_FILE_ID_BYTES)
    if (transfer.received + chunk.byteLength > transfer.size) {
      this.incomingChatFiles.delete(id)
      return this.showChatError("An incoming file exceeded its announced size.")
    }

    transfer.chunks.push(chunk)
    transfer.received += chunk.byteLength
    if (this.chatStatus) {
      const percent = transfer.size === 0 ? 100 : Math.round((transfer.received / transfer.size) * 100)
      this.chatStatus.textContent = `Receiving ${transfer.name} · ${percent}%`
    }
  },

  handleChatPayload(payload) {
    if (!payload || typeof payload !== "object") return
    if (this.youtube?.handlePayload(payload)) return

    if (payload.kind === "chat_text" && typeof payload.text === "string") {
      const text = payload.text.slice(0, 4000)
      if (!text.trim()) return
      this.renderChatText(text, false)
      this.markChatActivity()
    } else if (payload.kind === "chat_file_start") {
      const size = Number(payload.size)
      if (
        typeof payload.id !== "string" ||
        payload.id.length !== CHAT_FILE_ID_BYTES ||
        !Number.isSafeInteger(size) ||
        size < 0 ||
        size > CHAT_FILE_LIMIT
      ) {
        return this.showChatError("The other person offered an unsupported file.")
      }

      this.incomingChatFiles.set(payload.id, {
        name: this.safeChatFileName(payload.name),
        type: typeof payload.type === "string" ? payload.type.slice(0, 120) : "",
        size,
        received: 0,
        chunks: [],
      })
    } else if (payload.kind === "chat_file_end" && typeof payload.id === "string") {
      const transfer = this.incomingChatFiles.get(payload.id)
      if (!transfer) return
      this.incomingChatFiles.delete(payload.id)

      if (transfer.received !== transfer.size) {
        return this.showChatError(`Could not receive all of ${transfer.name}.`)
      }

      const blob = new Blob(transfer.chunks, {type: transfer.type || "application/octet-stream"})
      const url = URL.createObjectURL(blob)
      this.chatObjectUrls.push(url)
      this.renderChatFile(transfer.name, transfer.size, url, false)
      this.markChatActivity()
      if (this.chatStatus) this.chatStatus.textContent = "Direct · encrypted"
    }
  },

  setupChatControls() {
    const toggle = this.el.querySelector("[data-role=toggle-chat]")
    const close = this.el.querySelector("[data-role=close-chat]")
    const send = this.el.querySelector("[data-role=send-chat]")
    const fileInput = this.el.querySelector("[data-role=chat-file-input]")
    const dropzone = this.el.querySelector("[data-role=chat-dropzone]")

    if (toggle) toggle.addEventListener("click", () => this.setChatOpen(!this.chatOpen))
    if (close) close.addEventListener("click", () => this.setChatOpen(false))
    if (send) send.addEventListener("click", () => this.sendChat())

    if (this.chatInput) {
      this.chatInput.addEventListener("input", () => this.updateChatComposer())
      this.chatInput.addEventListener("keydown", (event) => {
        if (event.key === "Enter" && !event.shiftKey) {
          event.preventDefault()
          this.sendChat()
        }
      })
      this.chatInput.addEventListener("paste", (event) => {
        const files = Array.from(event.clipboardData?.files || [])
        if (files.length > 0) {
          event.preventDefault()
          this.addChatFiles(files)
        }
      })
    }

    if (fileInput) {
      fileInput.addEventListener("change", (event) => {
        this.addChatFiles(event.target.files)
        event.target.value = ""
      })
    }

    if (dropzone) {
      dropzone.addEventListener("dragover", (event) => {
        event.preventDefault()
        dropzone.classList.add("bg-primary/10", "ring-2", "ring-inset", "ring-primary")
      })
      dropzone.addEventListener("dragleave", (event) => {
        if (!dropzone.contains(event.relatedTarget)) {
          dropzone.classList.remove("bg-primary/10", "ring-2", "ring-inset", "ring-primary")
        }
      })
      dropzone.addEventListener("drop", (event) => {
        event.preventDefault()
        dropzone.classList.remove("bg-primary/10", "ring-2", "ring-inset", "ring-primary")
        this.addChatFiles(event.dataTransfer?.files || [])
      })
    }

    this.updateChatComposer()
  },

  setChatOpen(open) {
    this.chatOpen = open
    if (this.chatPanel) {
      this.chatPanel.classList.toggle("hidden", !open)
      this.chatPanel.classList.toggle("flex", open)
    }

    const toggle = this.el.querySelector("[data-role=toggle-chat]")
    if (toggle) toggle.setAttribute("aria-expanded", String(open))
    if (open) {
      this.chatUnread = 0
      this.updateChatUnread()
      this.chatInput?.focus()
    }
  },

  markChatActivity() {
    if (!this.chatOpen) {
      this.chatUnread += 1
      this.updateChatUnread()
    }
  },

  updateChatUnread() {
    const badge = this.el.querySelector("[data-role=chat-unread]")
    if (!badge) return
    badge.textContent = this.chatUnread > 99 ? "99+" : String(this.chatUnread)
    badge.classList.toggle("hidden", this.chatUnread === 0)
  },

  addChatFiles(fileList) {
    for (const file of Array.from(fileList || [])) {
      if (file.size > CHAT_FILE_LIMIT) {
        this.showChatError(`${file.name} is larger than the 25 MB call-chat limit.`)
      } else {
        this.chatFiles.push(file)
      }
    }
    this.renderPendingChatFiles()
    this.updateChatComposer()
  },

  renderPendingChatFiles() {
    const list = this.el.querySelector("[data-role=chat-files]")
    if (!list) return
    list.replaceChildren()
    list.classList.toggle("hidden", this.chatFiles.length === 0)
    list.classList.toggle("flex", this.chatFiles.length > 0)

    this.chatFiles.forEach((file, index) => {
      const chip = document.createElement("span")
      chip.className =
        "inline-flex max-w-full items-center gap-1 rounded-full bg-base-200 px-2 py-1 text-xs"

      const name = document.createElement("span")
      name.className = "truncate"
      name.textContent = this.safeChatFileName(file.name)

      const remove = document.createElement("button")
      remove.type = "button"
      remove.className = "font-bold opacity-60 hover:opacity-100"
      remove.setAttribute("aria-label", `Remove ${name.textContent}`)
      remove.textContent = "×"
      remove.addEventListener("click", () => {
        this.chatFiles.splice(index, 1)
        this.renderPendingChatFiles()
        this.updateChatComposer()
      })
      chip.append(name, remove)
      list.appendChild(chip)
    })
  },

  updateChatComposer() {
    const send = this.el.querySelector("[data-role=send-chat]")
    if (!send) return
    const hasContent = Boolean(this.chatInput?.value.trim()) || this.chatFiles.length > 0
    const connected = this.chatChannel?.readyState === "open"
    send.disabled = !hasContent || !connected || this.chatSending
  },

  async sendChat() {
    if (this.chatSending || this.chatChannel?.readyState !== "open") {
      return this.showChatError("Call chat will be ready when the peer connection is established.")
    }

    const text = (this.chatInput?.value || "").trim().slice(0, 4000)
    if (!text && this.chatFiles.length === 0) return
    this.chatSending = true
    this.clearChatError()
    this.updateChatComposer()

    try {
      if (text) {
        this.sendChatJson({kind: "chat_text", text})
        this.renderChatText(text, true)
        this.chatInput.value = ""
      }

      for (const file of [...this.chatFiles]) {
        if (this.chatStatus) this.chatStatus.textContent = `Sending ${this.safeChatFileName(file.name)}…`
        await this.sendChatFile(file)
        const url = URL.createObjectURL(file)
        this.chatObjectUrls.push(url)
        this.renderChatFile(this.safeChatFileName(file.name), file.size, url, true)
        this.chatFiles = this.chatFiles.filter((candidate) => candidate !== file)
        this.renderPendingChatFiles()
      }
      if (this.chatStatus) this.chatStatus.textContent = "Direct · encrypted"
    } catch (err) {
      this.showChatError(err.message || "Could not send that call chat item.")
    } finally {
      this.chatSending = false
      this.updateChatComposer()
    }
  },

  sendChatJson(payload) {
    if (this.chatChannel?.readyState !== "open") throw new Error("Call chat disconnected.")
    this.chatChannel.send(JSON.stringify(payload))
  },

  async sendChatFile(file) {
    if (file.size > CHAT_FILE_LIMIT) throw new Error(`${file.name} is larger than 25 MB.`)
    const id = crypto.randomUUID()
    const idBytes = new TextEncoder().encode(id)
    const bytes = new Uint8Array(await file.arrayBuffer())

    this.sendChatJson({
      kind: "chat_file_start",
      id,
      name: this.safeChatFileName(file.name),
      type: file.type,
      size: file.size,
    })

    for (let offset = 0; offset < bytes.length; offset += CHAT_CHUNK_SIZE) {
      await this.waitForChatBuffer()
      const chunk = bytes.slice(offset, offset + CHAT_CHUNK_SIZE)
      const frame = new Uint8Array(CHAT_FILE_ID_BYTES + chunk.byteLength)
      frame.set(idBytes, 0)
      frame.set(chunk, CHAT_FILE_ID_BYTES)
      this.chatChannel.send(frame.buffer)
    }
    this.sendChatJson({kind: "chat_file_end", id})
  },

  waitForChatBuffer() {
    if (this.chatChannel?.readyState !== "open") {
      return Promise.reject(new Error("Call chat disconnected during the file transfer."))
    }
    if (this.chatChannel.bufferedAmount <= 512 * 1024) return Promise.resolve()

    return new Promise((resolve, reject) => {
      const channel = this.chatChannel
      const ready = () => {
        cleanup()
        resolve()
      }
      const closed = () => {
        cleanup()
        reject(new Error("Call chat disconnected during the file transfer."))
      }
      const cleanup = () => {
        channel.removeEventListener("bufferedamountlow", ready)
        channel.removeEventListener("close", closed)
      }
      channel.addEventListener("bufferedamountlow", ready, {once: true})
      channel.addEventListener("close", closed, {once: true})
    })
  },

  renderChatText(text, own) {
    const bubble = this.chatBubble(own)
    const body = document.createElement("p")
    body.className = "whitespace-pre-wrap break-words text-sm"

    for (const segment of chatTextSegments(text)) {
      if (segment.kind === "url") {
        const link = document.createElement("a")
        link.href = segment.value
        link.target = "_blank"
        link.rel = "noopener noreferrer"
        link.className = "font-medium underline decoration-current/40 underline-offset-2"
        link.textContent = segment.value
        body.appendChild(link)
      } else {
        body.appendChild(document.createTextNode(segment.value))
      }
    }
    bubble.appendChild(body)
    this.appendChatBubble(bubble)
  },

  renderChatFile(name, size, url, own) {
    const bubble = this.chatBubble(own)
    const link = document.createElement("a")
    link.href = url
    link.download = name
    link.className = "flex items-center gap-2 text-sm font-medium underline underline-offset-2"
    link.textContent = `📎 ${name} · ${this.formatChatBytes(size)}`
    bubble.appendChild(link)
    this.appendChatBubble(bubble)
  },

  chatBubble(own) {
    const bubble = document.createElement("div")
    bubble.className = own
      ? "ml-8 self-end rounded-2xl rounded-br-md bg-primary px-3 py-2 text-primary-content shadow-sm"
      : "mr-8 self-start rounded-2xl rounded-bl-md bg-base-200 px-3 py-2 shadow-sm"
    return bubble
  },

  appendChatBubble(bubble) {
    if (!this.chatMessages) return
    const empty = this.chatMessages.querySelector("[data-role=chat-empty]")
    if (empty) empty.remove()
    this.chatMessages.appendChild(bubble)
    this.chatMessages.scrollTop = this.chatMessages.scrollHeight
  },

  safeChatFileName(name) {
    return String(name || "attachment")
      .split(/[\\/]/u)
      .pop()
      .slice(0, 160)
  },

  formatChatBytes(size) {
    if (size < 1024) return `${size} B`
    if (size < 1024 * 1024) return `${Math.ceil(size / 1024)} KB`
    return `${(size / (1024 * 1024)).toFixed(1)} MB`
  },

  showChatError(text) {
    const error = this.el.querySelector("[data-role=chat-error]")
    if (!error) return
    error.textContent = text
    error.classList.remove("hidden")
  },

  clearChatError() {
    const error = this.el.querySelector("[data-role=chat-error]")
    if (!error) return
    error.textContent = ""
    error.classList.add("hidden")
  },

  setRemoteShareState(sharing) {
    if (sharing && this.youtube?.active) this.youtube.stopShare()
    this.remoteSharing = sharing

    if (this.remoteShareStatus) {
      this.remoteShareStatus.classList.toggle("hidden", !sharing)
      this.remoteShareStatus.classList.toggle("inline-flex", sharing)
    }

    const popout = this.el.querySelector("[data-role=popout-share]")
    if (popout) popout.classList.toggle("hidden", !sharing)

    if (sharing) {
      this.setRemoteFit("contain")
      this.showCallNotice("The other person started sharing their screen.")
    } else {
      this.closeSharePopout()
      this.showCallNotice("Screen sharing stopped.")
    }
  },

  toggleRemoteFit() {
    this.setRemoteFit(this.remoteFitMode === "contain" ? "cover" : "contain")
  },

  setRemoteFit(mode) {
    this.remoteFitMode = mode
    if (this.remoteVideo) {
      this.remoteVideo.classList.toggle("object-contain", mode === "contain")
      this.remoteVideo.classList.toggle("object-cover", mode === "cover")
    }

    const label = this.el.querySelector("[data-role=fit-label]")
    if (label) label.textContent = mode === "contain" ? "Fill" : "Fit"

    const button = this.el.querySelector("[data-role=toggle-fit]")
    if (button) button.setAttribute("aria-pressed", String(mode === "cover"))
  },

  async toggleFullscreen() {
    try {
      const fullscreenElement = document.fullscreenElement || document.webkitFullscreenElement
      if (fullscreenElement) {
        if (document.exitFullscreen) await document.exitFullscreen()
        else if (document.webkitExitFullscreen) document.webkitExitFullscreen()
      } else if (this.el.requestFullscreen) {
        await this.el.requestFullscreen()
      } else if (this.el.webkitRequestFullscreen) {
        this.el.webkitRequestFullscreen()
      }
    } catch (err) {
      this.showCallNotice(`Fullscreen is unavailable: ${err.message}`)
    }
  },

  updateFullscreenUi() {
    const active =
      document.fullscreenElement === this.el || document.webkitFullscreenElement === this.el
    const label = this.el.querySelector("[data-role=fullscreen-label]")
    if (label) label.textContent = active ? "Exit fullscreen" : "Fullscreen"
  },

  async togglePictureInPicture() {
    if (!this.remoteVideo || !document.pictureInPictureEnabled) return

    try {
      if (document.pictureInPictureElement) {
        await document.exitPictureInPicture()
      } else {
        if (!this.remoteVideo.srcObject) {
          return this.showCallNotice("Picture in picture is available once the call connects.")
        }
        await this.remoteVideo.play()
        await this.remoteVideo.requestPictureInPicture()
      }
    } catch (err) {
      this.showCallNotice(`Picture in picture is unavailable: ${err.message}`)
    }
  },

  updatePictureInPictureUi() {
    const label = this.el.querySelector("[data-role=pip-label]")
    if (label) {
      label.textContent =
        document.pictureInPictureElement === this.remoteVideo
          ? "Exit picture in picture"
          : "Picture in picture"
    }
  },

  openSharePopout() {
    if (!this.remoteSharing) {
      return this.showCallNotice("The pop-out is available while the other person is sharing.")
    }

    if (this.popoutWindow && !this.popoutWindow.closed) {
      this.popoutWindow.focus()
      return
    }

    const popup = window.open(
      "",
      `veejr-share-${this.el.dataset.callId}`,
      "popup=yes,width=1100,height=760,resizable=yes"
    )
    if (!popup) return this.showCallNotice("Allow pop-ups to open the shared screen.")

    popup.document.title = "Shared screen · veejr"
    popup.document.body.replaceChildren()
    popup.document.body.style.cssText =
      "margin:0;display:grid;place-items:center;width:100vw;height:100vh;overflow:hidden;background:#050505;"

    const video = popup.document.createElement("video")
    video.autoplay = true
    video.playsInline = true
    video.muted = true
    video.style.cssText = "width:100%;height:100%;object-fit:contain;background:#050505;"
    video.srcObject = this.remoteVideo && this.remoteVideo.srcObject
    popup.document.body.appendChild(video)

    this.popoutWindow = popup
    this.popoutVideo = video
    video.play().catch(() => {})
    popup.addEventListener("beforeunload", () => {
      this.popoutWindow = null
      this.popoutVideo = null
    })
  },

  closeSharePopout() {
    const popup = this.popoutWindow
    this.popoutWindow = null
    this.popoutVideo = null
    if (popup && !popup.closed) popup.close()
  },

  sendSignal(payload) {
    const sealed = sealFor(this.peerKey, payload, this.mySecret)
    this.pushEvent("signal", sealed)
  },

  setupControls() {
    this.setupChatControls()
    const mic = this.el.querySelector("[data-role=toggle-mic]")
    const cam = this.el.querySelector("[data-role=toggle-cam]")

    if (mic) {
      mic.addEventListener("click", () => {
        const track = this.localStream && this.localStream.getAudioTracks()[0]
        if (!track) return
        track.enabled = !track.enabled
        mic.textContent = track.enabled ? "🎙 Mute" : "🎙 Unmute"
        mic.setAttribute("aria-pressed", String(!track.enabled))
        this.sendMediaState()
      })
    }

    if (cam) {
      cam.addEventListener("click", () => {
        const track = this.localStream && this.localStream.getVideoTracks()[0]
        if (!track) return
        track.enabled = !track.enabled
        cam.textContent = track.enabled ? "🎥 Camera off" : "🎥 Camera on"
        cam.setAttribute("aria-pressed", String(!track.enabled))
        this.sendMediaState()
      })
    }

    const switchCam = this.el.querySelector("[data-role=switch-cam]")
    if (switchCam) {
      switchCam.addEventListener("click", () => this.switchCamera())
    }

    // Screen capture is a desktop-browser feature; phones hide the button.
    const share = this.el.querySelector("[data-role=share-screen]")
    if (share && navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia) {
      share.classList.remove("hidden")
      share.addEventListener("click", () => this.toggleScreenShare())
    }

    const fit = this.el.querySelector("[data-role=toggle-fit]")
    if (fit) fit.addEventListener("click", () => this.toggleRemoteFit())

    const fullscreen = this.el.querySelector("[data-role=toggle-fullscreen]")
    if (fullscreen && (this.el.requestFullscreen || this.el.webkitRequestFullscreen)) {
      fullscreen.classList.remove("hidden")
      fullscreen.addEventListener("click", () => this.toggleFullscreen())
      this.remoteVideo.addEventListener("dblclick", () => this.toggleFullscreen())
      this.fullscreenChangeHandler = () => this.updateFullscreenUi()
      document.addEventListener("fullscreenchange", this.fullscreenChangeHandler)
      document.addEventListener("webkitfullscreenchange", this.fullscreenChangeHandler)
    }

    const pip = this.el.querySelector("[data-role=toggle-pip]")
    if (pip && document.pictureInPictureEnabled && this.remoteVideo.requestPictureInPicture) {
      pip.classList.remove("hidden")
      pip.addEventListener("click", () => this.togglePictureInPicture())
      this.remoteVideo.addEventListener("enterpictureinpicture", () =>
        this.updatePictureInPictureUi()
      )
      this.remoteVideo.addEventListener("leavepictureinpicture", () =>
        this.updatePictureInPictureUi()
      )
    }

    const popout = this.el.querySelector("[data-role=popout-share]")
    if (popout) popout.addEventListener("click", () => this.openSharePopout())

    const complete = this.el.querySelector("[data-role=complete-setup]")
    if (complete) complete.addEventListener("click", () => this.completeDeviceSetup())

    const retry = this.el.querySelector("[data-role=retry-media]")
    if (retry) retry.addEventListener("click", () => this.retryCapture())

    const devices = this.el.querySelector("[data-role=open-devices]")
    if (devices) devices.addEventListener("click", () => this.openDeviceSetup())

    const microphone = this.el.querySelector("[data-role=microphone-select]")
    if (microphone) {
      microphone.addEventListener("change", (event) =>
        this.replaceInput("audio", event.target.value)
      )
    }

    const camera = this.el.querySelector("[data-role=camera-select]")
    if (camera) {
      camera.addEventListener("change", (event) =>
        this.replaceInput("video", event.target.value)
      )
    }

    const speaker = this.el.querySelector("[data-role=speaker-select]")
    if (speaker) {
      speaker.addEventListener("change", (event) => this.selectSpeaker(event.target.value))
    }

    this.keyboardHandler = (event) => {
      if (event.repeat || event.ctrlKey || event.metaKey || event.altKey) return
      const target = event.target
      if (
        target instanceof HTMLInputElement ||
        target instanceof HTMLTextAreaElement ||
        target instanceof HTMLSelectElement ||
        target?.isContentEditable
      ) {
        return
      }

      const role = {m: "toggle-mic", v: "toggle-cam", c: "toggle-chat", f: "toggle-fullscreen"}[
        event.key.toLowerCase()
      ]
      if (!role) return
      const button = this.el.querySelector(`[data-role=${role}]`)
      if (!button || button.disabled || button.classList.contains("hidden")) return
      event.preventDefault()
      button.click()
    }
    document.addEventListener("keydown", this.keyboardHandler)

    this.visibilityHandler = () => {
      if (document.hidden) this.releaseWakeLock()
      else this.requestWakeLock()
    }
    document.addEventListener("visibilitychange", this.visibilityHandler)
  },

  say(text) {
    if (this.statusEl) this.statusEl.textContent = text
  },

  showError(text) {
    const el = this.el.querySelector("[data-role=media-error]")
    if (el) {
      el.textContent = text
      el.classList.remove("hidden")
    }
  },

  clearError() {
    const el = this.el.querySelector("[data-role=media-error]")
    if (el) {
      el.textContent = ""
      el.classList.add("hidden")
    }
  },

  fail(text) {
    this.showError(text)
    this.setLifecycle("failed", "Cannot start the call")
  },
}

const ringNotifications = new Map()

// Incoming-call consent: rings in every open veejr tab via the LiveNotify
// push event. The actions are plain navigations, so this works from any page
// without a dedicated reply channel.
export function installRingBanner() {
  window.addEventListener("phx:veejr:ring", ({detail}) => {
    const id = `veejr-ring-${detail.call_id}`
    if (document.getElementById(id)) return

    const banner = document.createElement("div")
    banner.id = id
    banner.setAttribute("role", "dialog")
    banner.setAttribute("aria-modal", "true")
    banner.setAttribute("aria-labelledby", `${id}-title`)
    banner.className =
      "fixed inset-0 z-[1200] flex items-center justify-center bg-base-content/45 p-4 backdrop-blur-sm"

    const card = document.createElement("div")
    card.className =
      "w-full max-w-md rounded-[32px] border border-primary/25 bg-base-100 p-6 text-center text-base-content shadow-2xl sm:p-8"

    const icon = document.createElement("div")
    icon.className =
      "mx-auto flex size-14 items-center justify-center rounded-2xl bg-primary text-2xl text-primary-content shadow-lg shadow-primary/25"
    icon.textContent = "📹"

    const title = document.createElement("h2")
    title.id = `${id}-title`
    title.className = "mt-4 text-2xl font-semibold tracking-tight"
    title.textContent = "Incoming video call"

    const label = document.createElement("p")
    label.className = "mt-2 text-sm opacity-70"
    label.textContent = `${detail.from} would like to talk.`

    const actions = document.createElement("div")
    actions.className = "mt-6 grid gap-2"

    const accept = document.createElement("a")
    accept.href = `/call/${detail.call_id}`
    accept.className = "btn btn-primary btn-lg"
    accept.textContent = "Accept"

    const busy = document.createElement("a")
    busy.href = `/call/${detail.call_id}?busy=1`
    busy.className = "btn btn-outline"
    busy.textContent = "Busy now, laters"

    const decline = document.createElement("a")
    decline.href = `/call/${detail.call_id}?reject=1`
    decline.className = "btn btn-ghost"
    decline.textContent = "Reject"

    actions.append(accept, busy, decline)
    card.append(icon, title, label, actions)
    banner.appendChild(card)
    document.body.appendChild(banner)
    setTimeout(() => banner.remove(), 60_000)

    if ("Notification" in window && Notification.permission === "granted") {
      const notification = new Notification("veejr", {
        body: `${detail.from} is calling you.`,
        tag: `veejr-call-${detail.call_id}`,
      })
      ringNotifications.set(detail.call_id, notification)
      notification.addEventListener("close", () => ringNotifications.delete(detail.call_id))
    }
  })

  window.addEventListener("phx:veejr:ring_cancelled", ({detail}) => {
    document.getElementById(`veejr-ring-${detail.call_id}`)?.remove()
    ringNotifications.get(detail.call_id)?.close()
    ringNotifications.delete(detail.call_id)
  })
}

export function installCallScheduleNotifications() {
  window.addEventListener("phx:veejr:call_schedule", ({detail}) => {
    const id = `veejr-call-schedule-${detail.schedule_id}`

    if (detail.event === "cancelled" || detail.event === "started") {
      document.getElementById(id)?.remove()
      return
    }

    const existing = document.getElementById(id)
    if (existing) existing.remove()

    const when = new Date(detail.scheduled_for)
    const time = Number.isNaN(when.getTime())
      ? "soon"
      : when.toLocaleString([], {dateStyle: "medium", timeStyle: "short"})
    const reminder = detail.event === "reminder"
    const banner = document.createElement("div")
    banner.id = id
    banner.className =
      "fixed inset-x-0 top-4 z-[1200] mx-auto flex w-fit max-w-[92vw] items-center gap-4 rounded-2xl border border-base-300 bg-base-100 py-2 pl-5 pr-2 shadow-2xl"

    const label = document.createElement("span")
    label.className = "text-sm font-medium"
    label.textContent = reminder
      ? `Scheduled call with ${detail.from} is coming up`
      : `${detail.from} scheduled a call for ${time}`

    const open = document.createElement("a")
    open.href = "/calls"
    open.className = "btn btn-primary btn-sm rounded-full"
    open.textContent = "View"

    const dismiss = document.createElement("button")
    dismiss.type = "button"
    dismiss.className = "btn btn-ghost btn-sm rounded-full"
    dismiss.textContent = "Dismiss"
    dismiss.addEventListener("click", () => banner.remove())

    banner.append(label, open, dismiss)
    document.body.appendChild(banner)

    if ("Notification" in window && Notification.permission === "granted") {
      new Notification(reminder ? "Scheduled call reminder" : "Call scheduled", {
        body: reminder
          ? `Your call with ${detail.from} is coming up.`
          : `${detail.from} scheduled a call for ${time}.`,
        tag: id,
      })
    }
  })
}

export default CallSession
