// Audio/video calls over WebRTC, for two or three people.
//
// Media flows peer-to-peer (DTLS-SRTP); this hook only exchanges signaling
// through the server, and every signaling payload (SDP, ICE) is sealed with
// nacl.box between one *pair* of participants' pinned identity keys before it
// leaves the browser. The server relays ciphertext it cannot read or alter,
// so it cannot substitute DTLS fingerprints to man-in-the-middle a call.
//
// A call is a full mesh: one `CallPeer` (call_peer.js) per other participant,
// each owning its connection, its data channel, and its video tile. A 1:1
// call is a mesh of one, so there is a single implementation rather than two.
// Everything shared across peers — local capture, device pickers, the chat
// panel, quality rendering, YouTube — lives here.
//
// Who is in the call comes from the server as a roster: `data-peers` for the
// first paint, then a `call:peers` event on every change. The hook holds a
// connection to every roster entry that has joined, which is what makes
// reloads, late arrivals, and departures all take the same path.

import {
  getSecretKey,
  sealFor,
  openFrom,
  unlockIdentity,
  cacheSecretKey,
  forgetSecretKey,
} from "./crypto.js"
import {CallPeer} from "./call_peer.js"
import {CallYouTube} from "./call_youtube.js"
import {clearFaviconActivity, setFaviconActivity} from "./favicon.js"

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

// A mesh sends one copy of the outgoing video per peer, so upload grows with
// the number of people. Past a pair, HD is not offered at all.
export const GROUP_VIDEO_PROFILE_FLOOR = 1

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

// The single worst peer decides what the call as a whole reports: a mesh is
// only as good as its weakest leg, and averaging would hide the leg that is
// actually failing.
export function worstCallQuality(qualities) {
  for (const level of ["poor", "unstable"]) {
    if (qualities.includes(level)) return level
  }
  return "good"
}

export const CallSession = {
  mounted() {
    const {callId, role, userId, localId} = this.el.dataset
    activateCallExitGuard(callId)
    this.faviconSource = `call:${callId}`
    setFaviconActivity(this.faviconSource, "call")
    this.role = role
    this.isGuest = this.el.dataset.isGuest === "true"
    // The mesh id, which is not the crypto key handle: a guest's identity is
    // keyed by a per-conference id but is "guest" to the other side.
    this.localId = String(localId || userId)
    this.mySecret = getSecretKey(userId)
    this.iceServers = JSON.parse(this.el.dataset.iceServers || "[]")
    this.peers = new Map()
    this.connecting = new Map()
    this.tiles = new Map()
    this.roster = this.parseRoster(this.el.dataset.peers)
    this.localStream = null
    this.maxRestartAttempts = 2
    this.compactTiles = false
    this.videoProfileIndex = 0
    this.goodQualitySamples = 0
    this.degradedQualitySamples = 0
    this.sharingPeerId = null
    this.remoteFitMode = "contain"
    this.speakerId = ""
    this.popoutWindow = null
    this.popoutVideo = null
    this.chatOpen = false
    this.chatUnread = 0
    this.chatSending = false
    this.chatFiles = []
    this.chatObjectUrls = []
    this.incomingChatFiles = new Map()
    this.connectedAt = null
    this.callTimer = null
    this.wakeLock = null
    this.pendingSealedSignals = []
    this.secureSessionStarted = false
    this.remoteTiles = this.el.querySelector("[data-role=remote-tiles]")
    this.remoteVideo = this.el.querySelector("[data-role=remote-video]")
    this.localVideo = this.el.querySelector("[data-role=local-video]")
    this.remoteShareStatus = this.el.querySelector("[data-role=remote-share-status]")
    this.setupVideo = this.el.querySelector("[data-role=setup-video]")
    this.setupEl = this.el.querySelector("[data-role=device-setup]")
    this.statusEl = this.el.querySelector("[data-role=call-status]")
    this.titleEl = this.el.querySelector("[data-role=call-title]")
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

    // The roster is authoritative: joining, leaving, reloading, and being
    // added late all arrive as one kind of update.
    this.handleEvent("call:peers", ({peers}) => this.setRoster(peers))

    this.handleEvent("call:peer_joined", ({peer}) => {
      const hangupLabel = this.el.querySelector("[data-role=hangup-label]")
      if (hangupLabel) hangupLabel.textContent = "End call"
      if (this.lifecycle !== "connected") this.setLifecycle("connecting", "Connecting…")
      // Guest calls have a fixed roster and never push `call:peers`, so this
      // is where their single peer becomes connectable.
      if (peer !== undefined && peer !== null) this.markRosterJoined(peer)
    })

    this.handleEvent("call:peer_left", ({peer}) => this.dropPeer(peer))

    this.handleEvent("call:signal", (payload) => {
      if (this.mySecret) this.openCallSignal(payload)
      else this.pendingSealedSignals.push(payload)
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
      this.renderTiles()
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
    // Negotiation awaits this promise: building a peer connection before the
    // user confirms their preview would create a receive-only session or send
    // from a device they did not mean to use.
    this.acquireMedia()

    this.setRoster(this.roster)
    for (const signal of this.pendingSealedSignals.splice(0)) this.openCallSignal(signal)
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

    // The submit button lives in a `method="dialog"` form, so Enter and the
    // click arrive here as one event and the browser never navigates.
    const form = this.el.querySelector("[data-role=call-unlock-form]")
    if (form) {
      form.addEventListener("submit", event => {
        event.preventDefault()
        unlock()
      })
    } else {
      button.addEventListener("click", unlock)
    }
  },

  // ---------------------------------------------------------------- roster

  parseRoster(raw) {
    try {
      const entries = JSON.parse(raw || "[]")
      return Array.isArray(entries) ? entries.map((entry) => this.normalisePeer(entry)) : []
    } catch {
      return []
    }
  },

  normalisePeer(entry) {
    return {
      id: String(entry.id),
      name: entry.name || "Someone",
      public_key: entry.public_key,
      state: entry.state || "joined",
    }
  },

  setRoster(entries) {
    this.roster = (Array.isArray(entries) ? entries : []).map((entry) => this.normalisePeer(entry))
    const known = new Set(this.roster.map((entry) => entry.id))

    for (const id of [...this.peers.keys()]) {
      if (!known.has(id)) this.dropPeer(id)
    }

    this.renderTiles()
    if (!this.secureSessionStarted) return

    for (const entry of this.roster) {
      if (entry.state === "joined") this.connectPeer(entry)
    }
  },

  // A guest call's roster never changes, so its `call:peer_joined` is the
  // only signal that the other side is actually there.
  markRosterJoined(id) {
    const entry = this.rosterEntry(id)
    if (!entry) return
    entry.state = "joined"
    this.renderTiles()
    if (this.secureSessionStarted) this.connectPeer(entry)
  },

  rosterEntry(id) {
    const key = String(id)
    return this.roster.find((entry) => entry.id === key)
  },

  // Whoever is sharing a screen leads, so pop-out, picture-in-picture, and
  // the largest tile all follow the thing people are looking at.
  orderedRoster() {
    if (!this.sharingPeerId) return this.roster
    const sharer = this.rosterEntry(this.sharingPeerId)
    if (!sharer) return this.roster
    return [sharer, ...this.roster.filter((entry) => entry !== sharer)]
  },

  meshSize() {
    return this.roster.filter((entry) => entry.state === "joined").length
  },

  // --------------------------------------------------------------- peering

  async connectPeer(entry) {
    const id = entry.id
    if (this.peers.has(id)) return this.peers.get(id)
    if (this.connecting.has(id)) return this.connecting.get(id)

    if (!entry.public_key) {
      this.showError(`${entry.name} has no encryption key set up, so this call cannot reach them.`)
      return null
    }

    const creation = (async () => {
      // An offer authored before capture settles would be receive-only, and
      // the other side would never see or hear this one.
      const mediaAvailable = await this.mediaReady
      if (!mediaAvailable || this.peers.has(id)) return this.peers.get(id) || null

      const peer = new CallPeer({
        id,
        name: entry.name,
        publicKey: entry.public_key,
        iceServers: this.iceServers,
        localId: this.localId,
        session: this,
      })
      this.peers.set(id, peer)

      // Exactly one data channel per pair: the impolite side opens it, the
      // polite side receives it through `ondatachannel`.
      if (!peer.polite) peer.createChatChannel()
      // Adding tracks raises `negotiationneeded`, which is what actually
      // starts this pairing off.
      peer.addLocalTracks(this.localStream)

      this.renderTiles()
      this.applyVideoProfile({announce: false})
      return peer
    })()

    this.connecting.set(id, creation)
    try {
      return await creation
    } finally {
      this.connecting.delete(id)
    }
  },

  dropPeer(id) {
    const key = String(id)
    const peer = this.peers.get(key)
    if (peer) {
      peer.close()
      this.peers.delete(key)
    }

    for (const transferId of [...this.incomingChatFiles.keys()]) {
      if (transferId.startsWith(`${key} `)) this.incomingChatFiles.delete(transferId)
    }

    if (this.sharingPeerId === key) this.setPeerShareState(peer || {id: key}, false)
    this.youtube?.peerLeft(key)
    this.renderTiles()
    this.updateChatComposer()
    this.youtube?.channelStateChanged()
    if (this.peers.size === 0) this.stopQualityMonitoring()
  },

  closeAllPeers() {
    for (const peer of this.peers.values()) peer.close()
    this.peers.clear()
    this.connecting.clear()
  },

  // ------------------------------------------- callbacks used by CallPeer

  sendSignal(peer, payload) {
    if (!peer?.publicKey || !this.mySecret) return
    const sealed = sealFor(peer.publicKey, payload, this.mySecret)
    this.pushEvent("signal", {target: peer.id, ...sealed})
  },

  broadcastSignal(payload) {
    for (const peer of this.peers.values()) this.sendSignal(peer, payload)
  },

  onPeerTrack(peer, event) {
    const stream = event.streams[0] || (event.track ? new MediaStream([event.track]) : null)
    if (!stream) return
    // Media can in principle beat the roster entry that would have built the
    // tile, and a stream with nowhere to go is a silent black frame.
    if (!this.tiles.has(peer.id)) this.renderTiles()
    const tile = this.tiles.get(peer.id)
    if (!tile) return

    tile.video.srcObject = stream
    if (this.popoutVideo && this.primaryPeerId() === peer.id) this.popoutVideo.srcObject = stream
    // Nudge playback in case the browser's autoplay policy paused it.
    tile.video.play().catch(() => {})
    this.applySpeaker(tile.video)
  },

  onPeerMediaState(peer, next) {
    this.setPeerMediaState(peer, next)
  },

  onPeerConnectionState(peer, state) {
    if (state === "connected") {
      clearTimeout(peer.disconnectTimer)
      peer.disconnectTimer = null
      peer.restartAttempts = 0
      this.setLifecycle("connected", this.connectedText())
      this.startCallTimer()
      this.requestWakeLock()
      this.sendMediaState()
      this.startQualityMonitoring()
    } else if (state === "closed" && this.peers.size <= 1) {
      // `dropPeer` runs after this, so the closing peer is still counted:
      // `<= 1` means it was the last one. One of three closing is not the
      // call ending.
      this.setLifecycle("ended", "Call ended")
    }

    this.updateTileConnection(peer)
  },

  onPeerIceState(peer, state) {
    if (state === "checking" && this.lifecycle !== "connected") {
      this.setLifecycle("connecting", "Connecting…")
    }

    if (state === "disconnected") {
      this.setLifecycle("reconnecting", this.reconnectingText(peer))
      clearTimeout(peer.disconnectTimer)
      peer.disconnectTimer = setTimeout(() => this.recoverPeer(peer), 5_000)
    }

    if (state === "failed") this.recoverPeer(peer)
    this.updateTileConnection(peer)
  },

  // --------------------------------------------------------- signaling in

  openCallSignal({from, ciphertext, nonce}) {
    const entry = this.rosterEntry(from)
    const peer = this.peers.get(String(from))
    const publicKey = peer?.publicKey || entry?.public_key
    if (!publicKey) return

    const payload = openFrom(ciphertext, nonce, publicKey, this.mySecret)
    if (!payload) return // tampered or stale — never act on unauthenticated signaling
    this.receiveSignal(from, payload)
  },

  async receiveSignal(from, payload) {
    const id = String(from)
    let peer = this.peers.get(id)

    if (!peer) {
      const entry = this.rosterEntry(id)
      if (!entry) return
      // An offer can arrive before the roster update that announced its
      // sender, so their first signal is also a reason to connect.
      peer = await this.connectPeer(entry)
      if (!peer) return
    }

    try {
      if (["offer", "answer", "ice"].includes(payload.kind)) {
        await peer.applySignal(payload)
      } else if (payload.kind === "share_state") {
        this.setPeerShareState(peer, payload.sharing === true)
      } else if (payload.kind === "media_state") {
        this.setPeerMediaState(peer, {
          audio: payload.audio === true,
          video: payload.video === true,
        })
      }
    } catch (err) {
      this.showError(`Call negotiation failed: ${err.message}`)
    }
  },

  // -------------------------------------------------------------- recovery

  // Perfect negotiation means either side may author the recovery offer, so
  // a peer restarts its own ICE instead of asking the caller to do it.
  async recoverPeer(peer) {
    if (peer.closed || !this.peers.has(peer.id)) return

    if (peer.restartAttempts >= this.maxRestartAttempts) {
      clearTimeout(peer.disconnectTimer)
      peer.disconnectTimer = null
      this.setLifecycle("failed", `Could not reconnect to ${peer.name}`)
      return this.showError(
        `The connection to ${peer.name} could not recover after two attempts.` +
          " Check your connection and try again."
      )
    }

    peer.restartAttempts += 1
    this.setLifecycle("reconnecting", this.reconnectingText(peer))

    try {
      await peer.restartIce()
    } catch (err) {
      this.showError(`Could not restart the connection: ${err.message}`)
    }

    clearTimeout(peer.disconnectTimer)
    peer.disconnectTimer = setTimeout(() => this.recoverPeer(peer), 8_000)
  },

  reconnectingText(peer) {
    const attempt = Math.max(1, peer.restartAttempts)
    const who = this.peers.size > 1 ? ` to ${peer.name}` : ""
    return `Reconnecting${who} (attempt ${attempt}/${this.maxRestartAttempts})…`
  },

  connectedText() {
    const connected = [...this.peers.values()].filter(
      (peer) => peer.pc.connectionState === "connected"
    ).length

    return this.peers.size > 1
      ? `Connected to ${connected} of ${this.peers.size} — end-to-end encrypted`
      : "Connected — end-to-end encrypted"
  },

  clearRecoveryTimers() {
    for (const peer of this.peers.values()) {
      clearTimeout(peer.disconnectTimer)
      clearTimeout(peer.renegotiateTimer)
      peer.disconnectTimer = null
      peer.renegotiateTimer = null
    }
  },

  // Replacing a sender's track needs no new SDP, but a receiver can keep
  // decoding the old stream and sit on a frozen frame — the swapped-in screen
  // never appears. One negotiation round per peer resets the far-side
  // decoder; perfect negotiation makes a collision with the other end safe.
  renegotiateAll() {
    for (const peer of this.peers.values()) peer.renegotiate()
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
    this.closeAllPeers()
    this.localStream = null
    if (this.localVideo) this.localVideo.srcObject = null
    for (const tile of this.tiles.values()) tile.video.srcObject = null
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
    clearFaviconActivity(this.faviconSource)
    const inPip = [...this.tiles.values()].some(
      (tile) => document.pictureInPictureElement === tile.video
    )
    if (inPip && document.exitPictureInPicture) document.exitPictureInPicture().catch(() => {})
    if (this.screenTrack) this.screenTrack.stop()
    if (this.localStream) this.localStream.getTracks().forEach((t) => t.stop())
    this.closeAllPeers()
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

    const selectedId = this.speakerId || ""
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

    if (this.speakerId && !this.speakers.some((device) => device.deviceId === this.speakerId)) {
      try {
        await this.selectSpeaker("")
        this.showCallNotice("Speaker disconnected · switched to the system default.")
      } catch {
        this.showCallNotice("Speaker disconnected. Choose another output in Devices.")
      }
    }
  },

  // Every tile plays its own audio, so an output choice has to reach all of
  // them rather than one element.
  applySpeaker(video) {
    if (!this.speakerId || typeof video.setSinkId !== "function") return
    video.setSinkId(this.speakerId).catch(() => {})
  },

  async selectSpeaker(deviceId) {
    if (!this.remoteVideo || typeof this.remoteVideo.setSinkId !== "function") return

    try {
      for (const tile of this.tiles.values()) await tile.video.setSinkId(deviceId)
      this.speakerId = deviceId
      if (deviceId) this.showCallNotice("Speaker changed.")
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

      if (oldTrack) {
        this.localStream.removeTrack(oldTrack)
        oldTrack.stop()
      }
      this.localStream.addTrack(newTrack)

      // Every leg of the mesh carries its own copy of this track.
      for (const peer of this.peers.values()) await peer.replaceTrack(kind, newTrack)

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
  // choice). The screen track replaces the outgoing camera track on every
  // peer's existing sender, and the camera comes back when sharing stops,
  // including via the browser's own "Stop sharing" bar.
  async toggleScreenShare() {
    if (this.screenTrack) return this.stopScreenShare()
    if (this.youtube?.active) {
      return this.showCallNotice("Stop YouTube sharing before sharing your screen.")
    }

    const cameraTrack = this.localStream && this.localStream.getVideoTracks()[0]
    if (!cameraTrack || this.peers.size === 0) {
      return this.showError("Screen sharing needs a connected call with video.")
    }

    let stream
    try {
      stream = await navigator.mediaDevices.getDisplayMedia({video: true})
    } catch (err) {
      // Dismissing the picker is not an error, but an operating system or
      // policy that blocks capture rejects the same way — and staying silent
      // there leaves the sharer believing their screen is on its way while
      // the others keep seeing the camera.
      if (/by system/iu.test(err.message || "")) {
        return this.showError(
          "Your system is blocking screen capture. Allow screen recording for this browser" +
            " in your system settings, restart the browser, and try again."
        )
      }
      if (err.name !== "NotAllowedError" && err.name !== "AbortError") {
        return this.showError(`Could not start screen sharing: ${err.message}`)
      }
      return // picker dismissed — not an error
    }

    try {
      const track = stream.getVideoTracks()[0]
      if (!track) throw new Error("the browser returned no screen video track")
      track.contentHint = "detail"
      this.screenTrack = track
      track.addEventListener("ended", () => this.stopScreenShare())

      for (const peer of this.peers.values()) {
        await peer.replaceTrack("video", track)
        // A sender that silently kept the camera track would leave the sharer
        // looking at their own screen while a peer sees no change at all.
        if (peer.sender("video")?.track !== track) {
          throw new Error("the outgoing video track did not switch")
        }
        await this.applyScreenShareProfile(peer.sender("video"))
      }

      if (this.localVideo) this.localVideo.srcObject = stream
      this.setShareUi(true)
      this.broadcastSignal({kind: "share_state", sharing: true})
      this.sendMediaState()
      this.renegotiateAll()
    } catch (err) {
      this.screenTrack = null
      stream.getTracks().forEach((t) => t.stop())
      // The loop may have switched some peers before failing, which would
      // leave them receiving a stopped track. Put everyone back on camera.
      const cameraTrack = this.localStream && this.localStream.getVideoTracks()[0]
      if (cameraTrack) {
        for (const peer of this.peers.values()) {
          await peer.replaceTrack("video", cameraTrack).catch(() => {})
        }
        if (this.localVideo) this.localVideo.srcObject = this.localStream
        this.renegotiateAll()
      }
      this.showError(`Could not share the screen: ${err.message}`)
    }
  },

  async stopScreenShare() {
    const track = this.screenTrack
    if (!track) return
    this.screenTrack = null
    track.stop()

    const cameraTrack = this.localStream && this.localStream.getVideoTracks()[0]

    try {
      if (cameraTrack) {
        for (const peer of this.peers.values()) await peer.replaceTrack("video", cameraTrack)
        await this.applyVideoProfile({announce: false})
      }
    } catch (err) {
      this.showError(`Could not restore the camera: ${err.message}`)
    }

    if (this.localVideo) this.localVideo.srcObject = this.localStream
    this.setShareUi(false)
    this.broadcastSignal({kind: "share_state", sharing: false})
    this.sendMediaState()
    this.renegotiateAll()
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
  // new track replaces the old one on each peer's existing RTCRtpSender.
  async switchCamera() {
    if (this.screenTrack) return
    const oldTrack = this.localStream && this.localStream.getVideoTracks()[0]
    if (!oldTrack || !this.cameras || this.cameras.length < 2) return

    const currentId = oldTrack.getSettings().deviceId
    const index = this.cameras.findIndex((d) => d.deviceId === currentId)
    const next = this.cameras[(index + 1) % this.cameras.length]

    await this.replaceInput("video", next.deviceId)
  },

  // ----------------------------------------------------------- video tiles

  primaryPeerId() {
    return this.orderedRoster()[0]?.id || null
  },

  primaryVideo() {
    const id = this.primaryPeerId()
    return (id && this.tiles.get(id)?.video) || this.remoteVideo
  },

  // The roster drives the grid: one tile per other participant, in a stable
  // order, so nobody's picture jumps when a third person arrives or leaves.
  renderTiles() {
    if (!this.remoteTiles) return
    const entries = this.orderedRoster()
    const keep = new Set(entries.map((entry) => entry.id))

    for (const [id, tile] of this.tiles) {
      if (keep.has(id)) continue
      // Dropping the element is not enough to release the remote stream, and
      // the template's video outlives its tile to be reused by the next one.
      tile.video.srcObject = null
      tile.figure.remove()
      this.tiles.delete(id)
    }

    entries.forEach((entry) => {
      const tile = this.tiles.get(entry.id) || this.createTile(entry)
      this.remoteTiles.appendChild(tile.figure)
      this.updateTile(entry)
    })

    this.remoteTiles.className = this.compactTiles
      ? "absolute left-3 top-16 z-20 grid h-24 w-32 grid-flow-col auto-cols-fr gap-px overflow-hidden rounded-xl border border-white/20 bg-black shadow-xl sm:left-4 sm:h-32 sm:w-44"
      : entries.length > 1
        ? "grid h-[60vh] w-full grid-cols-1 grid-rows-2 gap-px bg-base-300 sm:grid-cols-2 sm:grid-rows-1"
        : "grid h-[60vh] w-full grid-cols-1 bg-black"

    this.setRemoteFit(this.remoteFitMode)
    this.updateCallTitle()
    this.updatePeerBadges()
  },

  createTile(entry) {
    const figure = document.createElement("figure")
    figure.dataset.role = "remote-tile"
    figure.dataset.peerId = entry.id
    figure.className = "relative m-0 min-h-0 min-w-0 overflow-hidden bg-black"

    // The first tile reuses the server-rendered video element so that the
    // element identity picture-in-picture and the pop-out hold stays put.
    const reusable = this.remoteVideo && ![...this.tiles.values()].some((t) => t.video === this.remoteVideo)
    const video = reusable ? this.remoteVideo : document.createElement("video")
    video.autoplay = true
    video.playsInline = true
    if (!reusable) video.className = "size-full object-contain"
    figure.appendChild(video)

    const waiting = document.createElement("div")
    waiting.dataset.role = "tile-waiting"
    waiting.className =
      "pointer-events-none absolute inset-0 grid place-items-center px-4 text-center text-sm text-white/70"

    const caption = document.createElement("figcaption")
    caption.className = "pointer-events-none absolute inset-x-2 bottom-2 flex flex-wrap gap-1.5"

    const name = document.createElement("span")
    name.dataset.role = "tile-name"
    name.className =
      "rounded-full bg-black/70 px-2.5 py-0.5 text-xs font-medium text-white backdrop-blur"

    const badge = (role, text, extra) => {
      const span = document.createElement("span")
      span.dataset.role = role
      span.className = `hidden rounded-full px-2.5 py-0.5 text-xs font-medium backdrop-blur ${extra}`
      span.textContent = text
      return span
    }

    const muted = badge("tile-muted", "Muted", "bg-warning/85 text-warning-content")
    const cameraOff = badge("tile-camera-off", "Camera off", "bg-black/70 text-white")
    const sharing = badge("tile-sharing", "Sharing screen", "bg-primary/85 text-primary-content")

    caption.append(name, muted, cameraOff, sharing)
    figure.append(waiting, caption)

    const tile = {figure, video, waiting, name, muted, cameraOff, sharing}
    this.tiles.set(entry.id, tile)
    this.applySpeaker(video)
    return tile
  },

  updateTile(entry) {
    const tile = this.tiles.get(entry.id)
    if (!tile) return
    const peer = this.peers.get(entry.id)

    tile.name.textContent = entry.name
    tile.sharing.classList.toggle("hidden", this.sharingPeerId !== entry.id)
    tile.muted.classList.toggle("hidden", peer?.mediaState?.audio !== false)
    tile.cameraOff.classList.toggle("hidden", peer?.mediaState?.video !== false)

    const connected = peer?.pc?.connectionState === "connected"
    tile.waiting.textContent =
      entry.state === "ringing"
        ? `Ringing ${entry.name}…`
        : connected
          ? ""
          : `Connecting to ${entry.name}…`
    tile.waiting.classList.toggle("hidden", tile.waiting.textContent === "")
  },

  updateTileConnection(peer) {
    const entry = this.rosterEntry(peer.id)
    if (entry) this.updateTile(entry)
    if (this.lifecycle === "connected") this.say(this.connectedText())
  },

  updateCallTitle() {
    if (!this.titleEl || this.roster.length === 0) return
    const names = this.roster.map((entry) => entry.name)
    this.titleEl.textContent =
      names.length > 1 ? `📞 ${names.slice(0, -1).join(", ")} and ${names.at(-1)}` : `📞 ${names[0]}`
  },

  // The header badges describe "the other person", which only means anything
  // in a pair. With a third participant the per-tile badges say it instead.
  updatePeerBadges() {
    const solo = this.roster.length === 1
    const peer = solo ? this.peers.get(this.roster[0].id) : null

    for (const [role, active] of [
      ["peer-muted", peer?.mediaState?.audio !== false],
      ["peer-camera-off", peer?.mediaState?.video !== false],
    ]) {
      const badge = this.el.querySelector(`[data-role=${role}]`)
      if (!badge) continue
      badge.classList.toggle("hidden", !solo || active)
      badge.classList.toggle("inline-flex", solo && !active)
    }
  },

  // ------------------------------------------------------- quality control

  startQualityMonitoring() {
    if (this.peers.size === 0 || this.qualityTimer) return
    if (this.qualityEl) this.qualityEl.classList.remove("hidden")
    this.updateCallQuality()
    this.qualityTimer = setInterval(() => this.updateCallQuality(), 2_000)
  },

  stopQualityMonitoring() {
    clearInterval(this.qualityTimer)
    this.qualityTimer = null
    this.goodQualitySamples = 0
    this.degradedQualitySamples = 0
  },

  // WebRTC statistics stay in this browser. Only a coarse quality label is
  // rendered; no IP addresses, candidate details, or metrics reach Phoenix.
  async updateCallQuality() {
    if (!this.qualityEl) return
    const connected = [...this.peers.values()].filter(
      (peer) => peer.pc.connectionState === "connected"
    )
    if (connected.length === 0) return

    const samples = []
    for (const peer of connected) {
      const sample = await this.peerQuality(peer)
      if (sample) samples.push(sample)
    }
    if (samples.length === 0) return

    const quality = worstCallQuality(samples.map((sample) => sample.quality))
    const relayed = samples.some((sample) => sample.relayed)
    const loss = Math.max(...samples.map((sample) => sample.loss))
    const rtt = Math.max(...samples.map((sample) => sample.rtt))

    await this.observeCallQuality(quality)
    this.renderCallQuality(quality, relayed, {loss, rtt})
  },

  async peerQuality(peer) {
    try {
      const stats = await peer.pc.getStats()
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

      const previous = peer.previousInbound
      const receivedDelta = previous ? Math.max(0, received - previous.received) : 0
      const lostDelta = previous ? Math.max(0, lost - previous.lost) : 0
      const packetDelta = receivedDelta + lostDelta
      const loss = packetDelta > 0 ? lostDelta / packetDelta : 0
      peer.previousInbound = {received, lost}

      const localCandidate = pair && stats.get(pair.localCandidateId)
      const remoteCandidate = pair && stats.get(pair.remoteCandidateId)
      const relayed = Boolean(
        (localCandidate && localCandidate.candidateType === "relay") ||
          (remoteCandidate && remoteCandidate.candidateType === "relay")
      )
      const rtt = (pair && pair.currentRoundTripTime) || 0
      const bitrate = pair && pair.availableOutgoingBitrate

      return {quality: classifyCallQuality({loss, rtt, jitter, bitrate}), relayed, loss, rtt}
    } catch {
      // Stats availability differs across browsers; the call itself should
      // never be interrupted because a quality sample is unavailable.
      return null
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
    const previousEffective = this.effectiveProfileIndex()
    this.videoProfileIndex = nextIndex
    const applied = await this.applyVideoProfile({
      announce: this.effectiveProfileIndex() !== previousEffective,
    })
    if (!applied) this.videoProfileIndex = previousIndex
    this.goodQualitySamples = 0
    this.degradedQualitySamples = 0
  },

  // Each extra participant costs another outgoing copy of the video, so a
  // group call never runs at the HD profile however good the link looks.
  effectiveProfileIndex() {
    const floor = this.meshSize() > 1 ? GROUP_VIDEO_PROFILE_FLOOR : 0
    return Math.max(this.videoProfileIndex, floor)
  },

  async applyVideoProfile({announce = false} = {}) {
    const profile = VIDEO_PROFILES[this.effectiveProfileIndex()]
    let applied = false

    for (const peer of this.peers.values()) {
      const sender = peer.sender("video")
      if (!sender || !sender.getParameters || !sender.setParameters) continue

      try {
        const parameters = sender.getParameters()
        if (!parameters.encodings || parameters.encodings.length === 0) parameters.encodings = [{}]
        parameters.encodings[0].maxBitrate = profile.maxBitrate
        parameters.encodings[0].maxFramerate = profile.maxFramerate
        parameters.encodings[0].scaleResolutionDownBy = profile.scaleResolutionDownBy
        await sender.setParameters(parameters)
        applied = true
      } catch {
        // Some browser versions expose getParameters without allowing
        // encoding changes. That leg continues at the browser's own quality.
      }
    }

    if (applied && announce) {
      const reduced = this.effectiveProfileIndex() > 0
      this.showCallNotice(
        reduced
          ? `Video adjusted to ${profile.label.toLowerCase()} to keep audio clear.`
          : "Connection improved — HD video restored."
      )
    }

    return applied
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
    const profile = VIDEO_PROFILES[this.effectiveProfileIndex()]

    this.qualityEl.className =
      `rounded-full border px-2 py-0.5 text-xs font-medium ${styles[quality]}`
    this.qualityEl.textContent =
      `${quality === "good" ? "Good" : quality === "unstable" ? "Unstable" : "Poor"}` +
      ` · ${relayed ? "relayed" : "direct"}` +
      (this.effectiveProfileIndex() > 0 ? ` · ${profile.label}` : "")
    this.qualityEl.title =
      `Round trip ${Math.round(rtt * 1000)} ms · packet loss ${Math.round(loss * 100)}%` +
      ` · video ${profile.label}`
  },

  setLifecycle(state, text) {
    this.lifecycle = state
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
    if (this.peers.size === 0) return
    const audio = this.localStream?.getAudioTracks()[0]
    const video = this.localStream?.getVideoTracks()[0]
    this.broadcastSignal({
      kind: "media_state",
      audio: Boolean(audio && audio.enabled && audio.readyState === "live"),
      video: Boolean(this.screenTrack || (video && video.enabled && video.readyState === "live")),
    })
  },

  setPeerMediaState(peer, next) {
    peer.mediaState = peer.mediaState || {audio: true, video: true}
    for (const kind of ["audio", "video"]) {
      if (typeof next[kind] === "boolean") peer.mediaState[kind] = next[kind]
    }

    const entry = this.rosterEntry(peer.id)
    if (entry) this.updateTile(entry)
    this.updatePeerBadges()
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

  // ------------------------------------------------------------- call chat

  setupChatChannel(channel, peer) {
    channel.binaryType = "arraybuffer"
    channel.bufferedAmountLowThreshold = 256 * 1024

    channel.onopen = () => {
      this.updateChatStatus()
      this.updateChatComposer()
      // A participant can finish connecting after someone has already
      // started a YouTube share. Replaying the current share on this newly
      // opened pair keeps late and reconnecting conference clients in sync.
      this.youtube?.channelStateChanged(peer)
    }
    channel.onclose = () => {
      this.updateChatStatus()
      this.updateChatComposer()
      this.youtube?.channelStateChanged()
    }
    channel.onerror = () => this.showChatError("A direct chat connection was interrupted.")
    channel.onmessage = (event) => {
      this.handleChatData(event.data, peer).catch(() =>
        this.showChatError("A call chat item could not be received.")
      )
    }

    if (channel.readyState === "open") channel.onopen()
  },

  openChatChannels() {
    return [...this.peers.values()].filter((peer) => peer.chatReady())
  },

  chatReady() {
    return this.openChatChannels().length > 0
  },

  updateChatStatus() {
    if (!this.chatStatus) return
    const open = this.openChatChannels().length
    this.chatStatus.textContent =
      open === 0
        ? "Chat disconnected"
        : this.peers.size > 1
          ? `Direct · encrypted · ${open}/${this.peers.size}`
          : "Direct · encrypted"
  },

  async handleChatData(data, peer) {
    if (typeof data === "string") {
      let payload
      try {
        payload = JSON.parse(data)
      } catch {
        return
      }
      return this.handleChatPayload(payload, peer)
    }

    const buffer = data instanceof Blob ? await data.arrayBuffer() : data
    if (!(buffer instanceof ArrayBuffer) || buffer.byteLength <= CHAT_FILE_ID_BYTES) return

    const bytes = new Uint8Array(buffer)
    const id = new TextDecoder().decode(bytes.slice(0, CHAT_FILE_ID_BYTES))
    const transfer = this.incomingChatFiles.get(this.transferKey(peer, id))
    if (!transfer) return

    const chunk = bytes.slice(CHAT_FILE_ID_BYTES)
    if (transfer.received + chunk.byteLength > transfer.size) {
      this.incomingChatFiles.delete(this.transferKey(peer, id))
      return this.showChatError("An incoming file exceeded its announced size.")
    }

    transfer.chunks.push(chunk)
    transfer.received += chunk.byteLength
    if (this.chatStatus) {
      const percent = transfer.size === 0 ? 100 : Math.round((transfer.received / transfer.size) * 100)
      this.chatStatus.textContent = `Receiving ${transfer.name} · ${percent}%`
    }
  },

  // Transfer ids are chosen by the sender, so two peers sending at once must
  // not be able to collide with — or overwrite — each other's transfer.
  transferKey(peer, id) {
    return `${peer.id} ${id}`
  },

  handleChatPayload(payload, peer) {
    if (!payload || typeof payload !== "object") return
    if (this.youtube?.handlePayload(payload, peer)) return

    if (payload.kind === "chat_text" && typeof payload.text === "string") {
      const text = payload.text.slice(0, 4000)
      if (!text.trim()) return
      this.renderChatText(text, false, peer.name)
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
        return this.showChatError(`${peer.name} offered an unsupported file.`)
      }

      this.incomingChatFiles.set(this.transferKey(peer, payload.id), {
        name: this.safeChatFileName(payload.name),
        type: typeof payload.type === "string" ? payload.type.slice(0, 120) : "",
        size,
        received: 0,
        chunks: [],
      })
    } else if (payload.kind === "chat_file_end" && typeof payload.id === "string") {
      const key = this.transferKey(peer, payload.id)
      const transfer = this.incomingChatFiles.get(key)
      if (!transfer) return
      this.incomingChatFiles.delete(key)

      if (transfer.received !== transfer.size) {
        return this.showChatError(`Could not receive all of ${transfer.name}.`)
      }

      const blob = new Blob(transfer.chunks, {type: transfer.type || "application/octet-stream"})
      const url = URL.createObjectURL(blob)
      this.chatObjectUrls.push(url)
      this.renderChatFile(transfer.name, transfer.size, url, false, peer.name)
      this.markChatActivity()
      this.updateChatStatus()
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
    send.disabled = !hasContent || !this.chatReady() || this.chatSending
  },

  async sendChat() {
    if (this.chatSending || !this.chatReady()) {
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
      this.updateChatStatus()
    } catch (err) {
      this.showChatError(err.message || "Could not send that call chat item.")
    } finally {
      this.chatSending = false
      this.updateChatComposer()
    }
  },

  // Chat and files fan out over every open pair channel — there is no server
  // copy to relay them, so each peer is sent its own.
  sendChatJson(payload, targetPeer = null) {
    const message = JSON.stringify(payload)

    if (targetPeer) {
      if (!targetPeer.chatReady()) throw new Error("Call chat disconnected.")
      targetPeer.chatChannel.send(message)
      return
    }

    const open = this.openChatChannels()
    if (open.length === 0) throw new Error("Call chat disconnected.")
    for (const peer of open) peer.chatChannel.send(message)
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
      for (const peer of this.openChatChannels()) peer.chatChannel.send(frame.buffer)
    }
    this.sendChatJson({kind: "chat_file_end", id})
  },

  // The slowest leg sets the pace: sending the next chunk before every
  // channel has drained would grow one peer's buffer without bound.
  waitForChatBuffer() {
    const open = this.openChatChannels()
    if (open.length === 0) {
      return Promise.reject(new Error("Call chat disconnected during the file transfer."))
    }

    const congested = open.filter((peer) => peer.chatChannel.bufferedAmount > 512 * 1024)
    if (congested.length === 0) return Promise.resolve()

    return Promise.all(
      congested.map(
        (peer) =>
          new Promise((resolve, reject) => {
            const channel = peer.chatChannel
            const ready = () => {
              cleanup()
              resolve()
            }
            const closed = () => {
              cleanup()
              // One peer dropping mid-transfer must not fail the whole send
              // when others are still receiving it.
              if (this.openChatChannels().length === 0) {
                reject(new Error("Call chat disconnected during the file transfer."))
              } else {
                resolve()
              }
            }
            const cleanup = () => {
              channel.removeEventListener("bufferedamountlow", ready)
              channel.removeEventListener("close", closed)
            }
            channel.addEventListener("bufferedamountlow", ready, {once: true})
            channel.addEventListener("close", closed, {once: true})
          })
      )
    )
  },

  renderChatText(text, own, senderName) {
    const bubble = this.chatBubble(own, senderName)
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

  renderChatFile(name, size, url, own, senderName) {
    const bubble = this.chatBubble(own, senderName)
    const link = document.createElement("a")
    link.href = url
    link.download = name
    link.className = "flex items-center gap-2 text-sm font-medium underline underline-offset-2"
    link.textContent = `📎 ${name} · ${this.formatChatBytes(size)}`
    bubble.appendChild(link)
    this.appendChatBubble(bubble)
  },

  chatBubble(own, senderName) {
    const bubble = document.createElement("div")
    bubble.className = own
      ? "ml-8 self-end rounded-2xl rounded-br-md bg-primary px-3 py-2 text-primary-content shadow-sm"
      : "mr-8 self-start rounded-2xl rounded-bl-md bg-base-200 px-3 py-2 shadow-sm"

    // With one other person every incoming bubble is obviously theirs; with
    // two, an unattributed message is ambiguous.
    if (!own && senderName && this.roster.length > 1) {
      const author = document.createElement("p")
      author.className = "mb-0.5 text-xs font-semibold opacity-60"
      author.textContent = senderName
      bubble.appendChild(author)
    }
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

  // -------------------------------------------------------- viewing the mesh

  setPeerShareState(peer, sharing) {
    if (sharing && this.youtube?.active) this.youtube.stopShare()
    const wasSharing = this.sharingPeerId

    if (sharing) this.sharingPeerId = peer.id
    else if (this.sharingPeerId === peer.id) this.sharingPeerId = null
    if (wasSharing === this.sharingPeerId) return

    if (this.remoteShareStatus) {
      this.remoteShareStatus.classList.toggle("hidden", !this.sharingPeerId)
      this.remoteShareStatus.classList.toggle("inline-flex", Boolean(this.sharingPeerId))
    }

    const popout = this.el.querySelector("[data-role=popout-share]")
    if (popout) popout.classList.toggle("hidden", !this.sharingPeerId)

    // A shared screen takes the lead tile, so re-render before announcing it.
    this.renderTiles()

    if (sharing) {
      this.setRemoteFit("contain")
      this.showCallNotice(`${peer.name} started sharing their screen.`)
    } else {
      this.closeSharePopout()
      this.showCallNotice("Screen sharing stopped.")
    }
  },

  remoteSharing() {
    return Boolean(this.sharingPeerId)
  },

  toggleRemoteFit() {
    this.setRemoteFit(this.remoteFitMode === "contain" ? "cover" : "contain")
  },

  setRemoteFit(mode) {
    this.remoteFitMode = mode
    for (const tile of this.tiles.values()) {
      tile.video.classList.toggle("object-contain", mode === "contain")
      tile.video.classList.toggle("object-cover", mode === "cover")
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
    const video = this.primaryVideo()
    if (!video || !document.pictureInPictureEnabled) return

    try {
      if (document.pictureInPictureElement) {
        await document.exitPictureInPicture()
      } else {
        if (!video.srcObject) {
          return this.showCallNotice("Picture in picture is available once the call connects.")
        }
        await video.play()
        await video.requestPictureInPicture()
      }
    } catch (err) {
      this.showCallNotice(`Picture in picture is unavailable: ${err.message}`)
    }
  },

  updatePictureInPictureUi() {
    const label = this.el.querySelector("[data-role=pip-label]")
    if (label) {
      label.textContent = document.pictureInPictureElement
        ? "Exit picture in picture"
        : "Picture in picture"
    }
  },

  openSharePopout() {
    if (!this.remoteSharing()) {
      return this.showCallNotice("The pop-out is available while someone else is sharing.")
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
    video.srcObject = this.tiles.get(this.sharingPeerId)?.video.srcObject || null
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
      // Delegated so every tile, including ones added later, responds.
      this.remoteTiles?.addEventListener("dblclick", () => this.toggleFullscreen())
      this.fullscreenChangeHandler = () => this.updateFullscreenUi()
      document.addEventListener("fullscreenchange", this.fullscreenChangeHandler)
      document.addEventListener("webkitfullscreenchange", this.fullscreenChangeHandler)
    }

    const pip = this.el.querySelector("[data-role=toggle-pip]")
    if (pip && document.pictureInPictureEnabled && this.remoteVideo?.requestPictureInPicture) {
      pip.classList.remove("hidden")
      pip.addEventListener("click", () => this.togglePictureInPicture())
      this.remoteTiles?.addEventListener("enterpictureinpicture", () =>
        this.updatePictureInPictureUi()
      )
      this.remoteTiles?.addEventListener("leavepictureinpicture", () =>
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

    const dismissRing = () => {
      banner.remove()
      ringNotifications.get(detail.call_id)?.close()
      ringNotifications.delete(detail.call_id)
    }
    accept.addEventListener("click", dismissRing)
    busy.addEventListener("click", dismissRing)
    decline.addEventListener("click", dismissRing)

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
