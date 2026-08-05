// One peer connection inside a call.
//
// A call used to be exactly one RTCPeerConnection, so the session hook could
// own it directly and decide who offers by role: the caller always offered,
// the callee always answered. That does not generalise — with three people
// every pair has to negotiate independently and both ends may try to offer at
// once.
//
// So each pair is a CallPeer using *perfect negotiation*: the peer with the
// lower id is "polite" and yields when offers collide. This is the same
// pattern the watch-party voice mesh already uses (see watch_voice_hook.js),
// which is where it was debugged in production.
//
// A CallPeer owns its connection, its data channel, and its remote stream.
// Everything shared across peers — local capture, device pickers, chat UI,
// quality rendering — stays in the session hook.

export class CallPeer {
  // `id` identifies the remote participant and must be stable and agreed by
  // both sides: the user id for members, "host"/"guest" for guest calls.
  constructor({id, name, publicKey, iceServers, localId, session}) {
    this.id = id
    this.name = name
    this.publicKey = publicKey
    this.session = session
    this.localId = localId

    // Deterministic and opposite on the two ends, which is all perfect
    // negotiation needs. String compare so mixed ids ("host"/number) work.
    this.polite = String(localId) > String(id)

    this.makingOffer = false
    this.ignoreOffer = false
    this.isSettingRemoteAnswerPending = false
    this.pendingIce = []
    this.chatChannel = null
    this.remoteStream = null
    this.closed = false
    // Media sections must be created in the same order on both sides of a
    // connection. A camera or microphone being unavailable on one device
    // must not make its first offer omit that section, because adding it in a
    // later renegotiation changes the m-line order and Chromium rejects the
    // next offer with "the order of m-lines ... doesn't match".
    this.transceivers = new Map()

    // Per-pair state the session reads: what this peer says about their own
    // microphone and camera, how many recovery attempts this leg has spent,
    // and the previous statistics sample used to derive packet loss.
    this.mediaState = {audio: true, video: true}
    this.restartAttempts = 0
    this.previousInbound = null
    this.disconnectTimer = null
    this.renegotiateTimer = null

    this.pc = new RTCPeerConnection({iceServers})
    this.#wire()
  }

  #wire() {
    const pc = this.pc

    pc.onicecandidate = ({candidate}) => {
      if (candidate) this.session.sendSignal(this, {kind: "ice", candidate: candidate.toJSON()})
    }

    pc.ontrack = (event) => {
      this.remoteStream = event.streams[0] || null
      this.session.onPeerTrack(this, event)

      if (event.track) {
        event.track.addEventListener("ended", () =>
          this.session.onPeerMediaState(this, {[event.track.kind]: false})
        )
      }
    }

    // The impolite side creates the channel so exactly one exists per pair.
    pc.ondatachannel = (event) => this.attachChatChannel(event.channel)

    pc.onnegotiationneeded = async () => {
      try {
        this.makingOffer = true
        await pc.setLocalDescription()
        this.session.sendSignal(this, {kind: "offer", sdp: pc.localDescription.sdp})
      } catch (_error) {
        // A failed offer is recoverable: ICE restart or a later renegotiation
        // will try again.
      } finally {
        this.makingOffer = false
      }
    }

    pc.onconnectionstatechange = () => {
      this.session.onPeerConnectionState(this, pc.connectionState)
      if (["failed", "closed"].includes(pc.connectionState)) this.session.dropPeer(this.id)
    }

    pc.oniceconnectionstatechange = () =>
      this.session.onPeerIceState(this, pc.iceConnectionState)
  }

  // Called once local capture has settled, so an offer actually carries this
  // side's tracks rather than being receive-only.
  addLocalTracks(stream) {
    if (!stream || this.closed) return

    // Always establish the audio section before the video section, even when
    // one of the tracks is missing. `addTransceiver(track)` assigns the track
    // synchronously, so the first queued negotiation includes the settled
    // capture state without relying on a later replaceTrack promise.
    for (const kind of ["audio", "video"]) {
      const track = stream.getTracks().find((item) => item.kind === kind)
      const transceiver = this.pc.addTransceiver(track || kind, {
        direction: "sendrecv",
        ...(track ? {streams: [stream]} : {}),
      })
      this.transceivers.set(kind, transceiver)
    }
  }

  createChatChannel() {
    if (this.chatChannel || this.closed) return null
    const channel = this.pc.createDataChannel("veejr-call-chat", {ordered: true})
    this.attachChatChannel(channel)
    return channel
  }

  attachChatChannel(channel) {
    if (this.chatChannel && this.chatChannel !== channel) this.chatChannel.close()
    this.chatChannel = channel
    this.session.setupChatChannel(channel, this)
  }

  // The perfect-negotiation core. Both sides may offer; the polite one backs
  // off when the offers collide, so neither ends up permanently stuck.
  async applySignal(payload) {
    if (this.closed) return

    if (payload.kind === "offer" || payload.kind === "answer") {
      const description = {type: payload.kind, sdp: payload.sdp}
      const readyForOffer =
        !this.makingOffer &&
        (this.pc.signalingState === "stable" || this.isSettingRemoteAnswerPending)
      const offerCollision = description.type === "offer" && !readyForOffer

      this.ignoreOffer = !this.polite && offerCollision
      if (this.ignoreOffer) return

      this.isSettingRemoteAnswerPending = description.type === "answer"
      await this.pc.setRemoteDescription(description)
      this.isSettingRemoteAnswerPending = false

      if (description.type === "offer") {
        await this.pc.setLocalDescription()
        this.session.sendSignal(this, {kind: "answer", sdp: this.pc.localDescription.sdp})
      }

      await this.flushPendingIce()
      return
    }

    if (payload.kind === "ice") {
      if (this.pc.remoteDescription) {
        try {
          await this.pc.addIceCandidate(payload.candidate)
        } catch (error) {
          if (!this.ignoreOffer) throw error
        }
      } else {
        // Candidates can arrive before the description they belong to.
        this.pendingIce.push(payload.candidate)
      }
    }
  }

  async flushPendingIce() {
    const queued = this.pendingIce
    this.pendingIce = []

    for (const candidate of queued) {
      try {
        await this.pc.addIceCandidate(candidate)
      } catch (_error) {
        // A candidate that no longer applies is not worth failing the call.
      }
    }
  }

  // `restartIce` raises `negotiationneeded`, so the recovery offer goes out
  // through the same path as every other one.
  async restartIce() {
    if (this.closed || typeof this.pc.restartIce !== "function") return
    this.pc.restartIce()
  }

  // Forces one negotiation round so the far side's decoder picks up a track
  // that was swapped in place — replaceTrack alone can leave it decoding the
  // previous stream and holding a frozen frame. A collision with the other
  // end's own offer is what perfect negotiation is there for.
  async renegotiate(attempt = 0) {
    if (this.closed || this.pc.connectionState === "closed") return

    // A negotiation already in flight refreshes the decoder anyway; waiting
    // it out beats colliding with it.
    if (this.makingOffer || this.pc.signalingState !== "stable") {
      if (attempt >= 3) return
      clearTimeout(this.renegotiateTimer)
      this.renegotiateTimer = setTimeout(() => this.renegotiate(attempt + 1), 1_000)
      return
    }

    try {
      this.makingOffer = true
      await this.pc.setLocalDescription()
      this.session.sendSignal(this, {kind: "offer", sdp: this.pc.localDescription.sdp})
    } catch (_error) {
      // The new track is already on the sender, so the call itself is fine;
      // only the far side's decoder refresh was missed.
    } finally {
      this.makingOffer = false
    }
  }

  sender(kind) {
    return this.transceivers.get(kind)?.sender ||
      this.pc.getSenders().find((s) => s.track?.kind === kind)
  }

  async replaceTrack(kind, track) {
    const sender = this.sender(kind)
    if (sender) {
      await sender.replaceTrack(track)
    } else if (track && this.session.localStream) {
      // This is only a compatibility fallback for a peer created before the
      // fixed transceiver set was installed. Keep its section order explicit
      // rather than using addTrack, which appends an m-line opportunistically.
      const transceiver = this.pc.addTransceiver(kind, {direction: "sendrecv"})
      this.transceivers.set(kind, transceiver)
      await transceiver.sender.replaceTrack(track)
    }
  }

  chatReady() {
    return this.chatChannel && this.chatChannel.readyState === "open"
  }

  close() {
    if (this.closed) return
    this.closed = true
    clearTimeout(this.renegotiateTimer)
    clearTimeout(this.disconnectTimer)
    try {
      this.chatChannel?.close()
    } catch (_error) {
      /* already gone */
    }
    try {
      this.pc.close()
    } catch (_error) {
      /* already gone */
    }
  }
}
