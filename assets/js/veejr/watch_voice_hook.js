import {getSecretKey, sealFor, openFrom} from "./crypto.js"
import {requestKeyUnlock} from "./key_unlock.js"

const AUDIO_CONSTRAINTS = {
  echoCancellation: true,
  noiseSuppression: true,
  autoGainControl: true,
}

export const WatchVoice = {
  mounted() {
    this.participantId = this.el.dataset.participantId
    this.mySecret = getSecretKey(this.el.dataset.userId)
    this.iceServers = JSON.parse(this.el.dataset.iceServers || "[]")
    this.peers = new Map()
    this.localStream = null
    this.microphoneOn = false
    this.statusEl = this.el.querySelector("[data-role='voice-status']")
    this.micButton = this.el.querySelector("[data-role='toggle-microphone']")
    this.audioContainer = this.el.querySelector("[data-role='remote-audio']")

    if (!this.participantId || !this.mySecret) {
      this.micButton.disabled = true
      this.statusEl.textContent = ""
      const unlock = document.createElement("button")
      unlock.type = "button"
      unlock.className = "link text-sm"
      unlock.textContent = "Unlock here to use voice"
      unlock.addEventListener("click", requestKeyUnlock)
      this.statusEl.appendChild(unlock)
      return
    }

    const initialPeers = JSON.parse(this.el.dataset.peers || "[]")
    initialPeers.forEach(peer => this.addPeer(peer))

    this.handleEvent("watch:voice_joined", ({participant}) => this.addPeer(participant))
    this.handleEvent("watch:voice_left", ({participant_id: id}) => this.removePeer(id))
    this.handleEvent("watch:voice_signal", message => this.receiveSignal(message))

    this.toggleMicrophone = () => this.setMicrophone(!this.microphoneOn)
    this.micButton.addEventListener("click", this.toggleMicrophone)
    this.updateStatus()
  },

  destroyed() {
    this.micButton?.removeEventListener("click", this.toggleMicrophone)
    this.localStream?.getTracks().forEach(track => track.stop())
    this.localStream = null
    this.peers?.forEach(peer => peer.pc.close())
    this.peers?.clear()
  },

  addPeer(participant) {
    if (!participant?.id || participant.id === this.participantId || this.peers.has(participant.id)) return

    const pc = new RTCPeerConnection({iceServers: this.iceServers})
    const peer = {
      ...participant,
      pc,
      makingOffer: false,
      ignoreOffer: false,
      isSettingRemoteAnswerPending: false,
      polite: this.participantId > participant.id,
    }
    this.peers.set(participant.id, peer)

    const transceiver = pc.addTransceiver("audio", {direction: "recvonly"})
    if (this.localStream) {
      transceiver.sender.replaceTrack(this.localStream.getAudioTracks()[0])
      transceiver.direction = "sendrecv"
    }

    pc.onicecandidate = ({candidate}) => {
      if (candidate) this.sendSignal(peer, {candidate})
    }
    pc.ontrack = event => this.attachRemoteAudio(peer, event)
    pc.onconnectionstatechange = () => {
      if (["failed", "closed"].includes(pc.connectionState)) this.removePeer(peer.id)
      this.updateStatus()
    }
    pc.onnegotiationneeded = async () => {
      try {
        peer.makingOffer = true
        await pc.setLocalDescription()
        this.sendSignal(peer, {description: pc.localDescription})
      } catch (_error) {
        this.setStatus(`Could not connect voice with ${peer.name}.`)
      } finally {
        peer.makingOffer = false
      }
    }

    this.updateStatus()
  },

  async receiveSignal({sender, ciphertext, nonce}) {
    if (!sender?.id) return
    if (!this.peers.has(sender.id)) this.addPeer(sender)
    const peer = this.peers.get(sender.id)
    const payload = openFrom(ciphertext, nonce, sender.public_key, this.mySecret)
    if (!payload) return

    try {
      if (payload.description) {
        const readyForOffer =
          !peer.makingOffer &&
          (peer.pc.signalingState === "stable" || peer.isSettingRemoteAnswerPending)
        const offerCollision = payload.description.type === "offer" && !readyForOffer

        peer.ignoreOffer = !peer.polite && offerCollision
        if (peer.ignoreOffer) return

        peer.isSettingRemoteAnswerPending = payload.description.type === "answer"
        await peer.pc.setRemoteDescription(payload.description)
        peer.isSettingRemoteAnswerPending = false

        if (payload.description.type === "offer") {
          await peer.pc.setLocalDescription()
          this.sendSignal(peer, {description: peer.pc.localDescription})
        }
      } else if (payload.candidate) {
        try {
          await peer.pc.addIceCandidate(payload.candidate)
        } catch (error) {
          if (!peer.ignoreOffer) throw error
        }
      }
    } catch (_error) {
      this.setStatus(`Could not connect voice with ${peer.name}.`)
    }
  },

  sendSignal(peer, payload) {
    const sealed = sealFor(peer.public_key, payload, this.mySecret)
    this.pushEvent("watch_voice_signal", {target: peer.id, ...sealed})
  },

  async setMicrophone(enabled) {
    this.micButton.disabled = true

    try {
      if (enabled) {
        this.localStream = await navigator.mediaDevices.getUserMedia({audio: AUDIO_CONSTRAINTS})
        const track = this.localStream.getAudioTracks()[0]

        for (const peer of this.peers.values()) {
          const transceiver = peer.pc.getTransceivers().find(item => item.receiver.track?.kind === "audio")
          if (!transceiver) continue
          await transceiver.sender.replaceTrack(track)
          transceiver.direction = "sendrecv"
        }

        this.microphoneOn = true
      } else {
        await this.stopMicrophone()
      }
    } catch (_error) {
      this.setStatus("Microphone access was not granted. You can still listen.")
    } finally {
      this.micButton.disabled = false
      this.updateMicrophoneButton()
      if (this.microphoneOn || !enabled) this.updateStatus()
    }
  },

  async stopMicrophone() {
    this.localStream?.getTracks().forEach(track => track.stop())
    this.localStream = null
    this.microphoneOn = false

    for (const peer of this.peers?.values() || []) {
      const transceiver = peer.pc.getTransceivers().find(item => item.receiver.track?.kind === "audio")
      if (!transceiver) continue
      await transceiver.sender.replaceTrack(null).catch(() => {})
      if (transceiver.direction === "sendrecv") transceiver.direction = "recvonly"
    }
  },

  attachRemoteAudio(peer, event) {
    let audio = this.audioContainer.querySelector(`[data-peer-id="${peer.id}"]`)
    if (!audio) {
      audio = document.createElement("audio")
      audio.dataset.peerId = peer.id
      audio.autoplay = true
      audio.playsInline = true
      this.audioContainer.appendChild(audio)
    }
    audio.srcObject = event.streams[0] || new MediaStream([event.track])
    audio.play().catch(() => this.setStatus("Tap the microphone button once to enable party audio."))
  },

  removePeer(id) {
    const peer = this.peers.get(id)
    if (!peer) return
    peer.pc.close()
    this.peers.delete(id)
    this.audioContainer.querySelector(`[data-peer-id="${id}"]`)?.remove()
    this.updateStatus()
  },

  updateMicrophoneButton() {
    this.micButton.setAttribute("aria-pressed", String(this.microphoneOn))
    this.micButton.querySelector("[data-role='mic-label']").textContent =
      this.microphoneOn ? "Turn microphone off" : "Turn microphone on"
    this.micButton.querySelector("[data-role='mic-on-icon']").classList.toggle("hidden", this.microphoneOn)
    this.micButton.querySelector("[data-role='mic-off-icon']").classList.toggle("hidden", !this.microphoneOn)
    this.micButton.classList.toggle("btn-primary", !this.microphoneOn)
    this.micButton.classList.toggle("btn-error", this.microphoneOn)
  },

  updateStatus() {
    const connected = [...this.peers.values()].filter(peer => peer.pc.connectionState === "connected").length
    const total = this.peers.size
    const microphone = this.microphoneOn ? "Microphone on" : "Microphone off"
    this.setStatus(`${microphone} · ${connected}/${total} listener${total === 1 ? "" : "s"} connected`)
  },

  setStatus(message) {
    if (this.statusEl) this.statusEl.textContent = message
  },
}
