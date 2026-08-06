import {clearFaviconActivity, setFaviconActivity} from "./favicon.js"
import {PlaybackAssist} from "./youtube_assist.js"
import {YOUTUBE_ORIGINS, youtubeEmbedUrl} from "./youtube_embed.js"
import {syncActions} from "./youtube_sync.js"

const VIDEO_ID_PATTERN = /^[A-Za-z0-9_-]{11}$/u

export function extractYouTubeVideoId(input) {
  const value = String(input || "").trim()
  if (VIDEO_ID_PATTERN.test(value)) return value

  let url
  try {
    url = new URL(value)
  } catch {
    return null
  }

  if (!["http:", "https:"].includes(url.protocol)) return null
  const host = url.hostname.toLowerCase()
  let candidate

  if (["youtu.be", "www.youtu.be"].includes(host)) {
    candidate = url.pathname.split("/").filter(Boolean)[0]
  } else if (["youtube.com", "www.youtube.com", "m.youtube.com"].includes(host)) {
    candidate =
      url.pathname === "/watch"
        ? url.searchParams.get("v")
        : youtubePathVideoId(url.pathname)
  } else if (["youtube-nocookie.com", "www.youtube-nocookie.com"].includes(host)) {
    candidate = youtubePathVideoId(url.pathname)
  }

  return VIDEO_ID_PATTERN.test(candidate || "") ? candidate : null
}

function youtubePathVideoId(pathname) {
  const [kind, videoId] = pathname.split("/").filter(Boolean)
  return ["embed", "shorts", "live"].includes(kind) ? videoId : null
}

function command(iframe, func, args = []) {
  iframe?.contentWindow?.postMessage(
    JSON.stringify({event: "command", id: iframe.id, func, args}),
    "*",
  )
}

export class CallYouTube {
  constructor(hook) {
    this.hook = hook
    this.stage = hook.el.querySelector("[data-role='call-youtube-stage']")
    this.playerContainer = hook.el.querySelector("[data-role='call-youtube-player']")
    this.dialog = hook.el.querySelector("[data-role='call-youtube-dialog']")
    this.input = hook.el.querySelector("[data-role='call-youtube-input']")
    this.error = hook.el.querySelector("[data-role='call-youtube-error']")
    this.shareButton = hook.el.querySelector("[data-role='share-youtube']")
    this.endButton = hook.el.querySelector("[data-role='end-youtube']")
    this.controllerLabel = hook.el.querySelector("[data-role='youtube-controller-label']")
    this.unlock = hook.el.querySelector("[data-role='youtube-unlock']")
    this.unlockLabel = hook.el.querySelector("[data-role='youtube-unlock-label']")
    this.active = false
    this.localController = false
    this.localShareEnded = false
    this.controllerId = null
    this.ready = false
    this.unlocked = false
    this.signedIn = false
    this.playback = "paused"
    this.position = 0
    this.appliedPlayback = null
    this.playerPosition = null
    this.playerState = null
    this.positionRequest = null
    this.released = false
    this.localVideoClass = null
    this.faviconSource = `${hook.faviconSource || `call:${hook.el.dataset.callId}`}:youtube`

    this.assist = new PlaybackAssist({
      root: hook.el,
      position: () => this.position,
      release: () => this.releasePlayer(),
      reload: () => this.reloadSignedIn(),
    })

    this.onWindowMessage = event => this.handlePlayerMessage(event)
    window.addEventListener("message", this.onWindowMessage)
    this.setupControls()
    this.channelStateChanged()
  }

  destroy() {
    window.removeEventListener("message", this.onWindowMessage)
    this.clearPlayerTimers()
    this.assist.destroy()
    this.iframe?.remove()
    this.hook.el.dataset.youtubeActive = "false"
    clearFaviconActivity(this.faviconSource)
  }

  // Hands the player back to the viewer so they can answer whatever YouTube is
  // asking of them. Their next move may well be a pause or a seek, so the
  // controller's applied state is forgotten and the next heartbeat resyncs.
  releasePlayer() {
    this.iframe?.classList.remove("pointer-events-none")
    this.appliedPlayback = null
    this.released = true
  }

  // The same video from the YouTube host that can see the viewer's own
  // account, which is the only place a bot check can be answered.
  reloadSignedIn() {
    if (!this.active) return

    this.signedIn = true
    this.ready = false
    this.appliedPlayback = null
    this.playerPosition = null
    this.playerState = null
    this.positionRequest = null
    this.createPlayer()
    this.releasePlayer()
  }

  setupControls() {
    this.shareButton?.addEventListener("click", () => this.toggleShare())
    this.endButton?.addEventListener("click", () => this.stopLocal())
    this.hook.el
      .querySelector("[data-role='start-youtube']")
      ?.addEventListener("click", () => this.startFromInput())
    this.hook.el
      .querySelector("[data-role='cancel-youtube']")
      ?.addEventListener("click", () => this.closeDialog())
    this.hook.el
      .querySelector("[data-role='youtube-fullscreen']")
      ?.addEventListener("click", () => this.hook.toggleFullscreen())
    this.unlock?.addEventListener("click", () => {
      if (this.localController) return
      this.unlocked = true
      this.unlock.classList.add("hidden")
      this.unlock.classList.remove("flex", "cursor-pointer")
      this.applyRemotePlayback()
    })
    this.input?.addEventListener("keydown", event => {
      if (event.key === "Enter") {
        event.preventDefault()
        this.startFromInput()
      } else if (event.key === "Escape") {
        this.closeDialog()
      }
    })
  }

  channelStateChanged(peer = null) {
    const ready = this.hook.chatReady()
    if (this.shareButton) {
      this.shareButton.disabled = !ready
      this.shareButton.title = ready
        ? "Watch a YouTube video together"
        : "YouTube sharing is available once the call connects"
    }

    // Conference data channels open independently. If this pair came up
    // after the share began, send the current state only to that participant;
    // the regular broadcast would be needlessly disruptive to existing
    // viewers and could race another peer's update.
    if (!ready || !peer) return
    if (this.active && this.localController) this.sendStart(peer)

    // Stop is state too, not merely a one-shot notification. A peer whose
    // SCTP channel was being rebuilt when the controller ended the share
    // missed the broadcast and otherwise kept a dead player over healthy
    // RTP video forever. Replaying the tombstone on that pair's new channel
    // makes channel recovery converge in both directions.
    if (!this.active && this.localShareEnded) this.sendStop(peer)
  }

  toggleShare() {
    if (this.active) {
      if (this.localController) this.stopLocal()
      else this.hook.showCallNotice("Only the person sharing this video can end it.")
      return
    }

    if (this.hook.screenTrack || this.hook.remoteSharing()) {
      return this.hook.showCallNotice("Stop screen sharing before sharing YouTube.")
    }
    if (!this.hook.chatReady()) {
      return this.hook.showCallNotice("YouTube sharing will be ready once the call connects.")
    }

    this.dialog?.classList.remove("hidden")
    this.dialog?.classList.add("grid")
    this.error?.classList.add("hidden")
    this.input?.focus()
  }

  closeDialog() {
    this.dialog?.classList.add("hidden")
    this.dialog?.classList.remove("grid")
    if (this.error) this.error.classList.add("hidden")
  }

  startFromInput() {
    const videoId = extractYouTubeVideoId(this.input?.value)
    if (!videoId) {
      if (this.error) {
        this.error.textContent = "Enter a valid YouTube link or video ID."
        this.error.classList.remove("hidden")
      }
      return
    }

    this.closeDialog()
    if (this.input) this.input.value = ""
    this.showShare(videoId, true, "paused", 0)
    this.sendStart()
  }

  sendStart(peer = null) {
    if (!this.active || !this.localController) return
    try {
      this.hook.sendChatJson({
        kind: "youtube_start",
        video_id: this.videoId,
        playback: this.playback,
        position: this.position,
      }, peer)
    } catch {
      this.hook.showCallNotice("The direct sharing connection was interrupted.")
    }
  }

  // `peer` is whoever's data channel delivered this, which is also who is
  // controlling the video — the mesh gives each pair its own channel, so the
  // sender never has to be named inside the payload.
  handlePayload(payload, peer) {
    if (payload.kind === "youtube_start") {
      if (!VIDEO_ID_PATTERN.test(payload.video_id || "")) return true

      // Two people can start a share at the same instant. The same ordering
      // that decides who is polite decides whose share survives.
      if (this.active && this.localController) {
        if (String(this.hook.localId) < String(peer.id)) {
          this.sendStart()
          return true
        }
      }

      const playback = payload.playback === "playing" ? "playing" : "paused"
      const position = this.validPosition(payload.position)
      this.controllerId = peer.id
      this.showShare(payload.video_id, false, playback, position)
      this.hook.showCallNotice(`${peer.name} shared a YouTube video.`)
      return true
    }

    // Only the person who started the share steers it, so a third
    // participant's stray control is ignored rather than obeyed.
    if (payload.kind === "youtube_control") {
      if (!this.active || this.localController || this.controllerId !== peer.id) return true
      this.playback = payload.playback === "playing" ? "playing" : "paused"
      this.position = this.validPosition(payload.position)
      this.requestRemoteSync()
      return true
    }

    if (payload.kind === "youtube_stop") {
      if (this.active && !this.localController && this.controllerId === peer.id) {
        this.stopShare()
        this.hook.showCallNotice("YouTube sharing stopped.")
      }
      return true
    }

    return false
  }

  // A share ends on its controller's say-so, and that message travels the
  // controller's own data channel. When they leave instead of stopping, no
  // `youtube_stop` can ever arrive, so every viewer would sit on a video
  // nobody is steering and no button of theirs can dismiss. Screen sharing
  // already gets this treatment in the hook's `dropPeer`.
  peerLeft(id) {
    if (!this.active || this.localController) return
    if (String(this.controllerId) !== String(id)) return

    this.stopShare()
    this.hook.showCallNotice("YouTube sharing ended.")
  }

  showShare(videoId, localController, playback, position) {
    this.stopShare()
    this.active = true
    this.localController = localController
    this.hook.el.dataset.youtubeActive = "true"
    setFaviconActivity(this.faviconSource, "youtube")
    this.videoId = videoId
    this.playback = playback
    this.position = position
    this.appliedPlayback = null
    this.playerPosition = null
    this.playerState = null
    this.positionRequest = null
    this.ready = false
    // A new video deserves the privacy host again, whatever the last one needed.
    this.signedIn = false
    this.assist.watch(videoId)

    this.stage?.classList.remove("hidden")
    this.stage?.classList.add("block")
    if (localController) {
      this.controllerId = null
      this.localShareEnded = false
    }
    this.controllerLabel.textContent = localController
      ? "You control this video"
      : `Controlled by ${this.controllerName()}`
    this.endButton?.classList.toggle("hidden", !localController)
    this.unlock?.classList.toggle("hidden", localController || this.unlocked)
    this.unlock?.classList.toggle("flex", !localController && !this.unlocked)
    if (!localController) {
      this.unlockLabel.textContent = "Tap to watch together"
      this.unlock?.classList.toggle("cursor-pointer", !this.unlocked)
    }

    this.compactCallVideos(true)
    this.createPlayer()
    this.updateShareButton()

    if (localController) {
      this.heartbeat = window.setInterval(() => {
        this.requestControlReport()
      }, 5_000)
    } else {
      // A viewer learns its own position only from `infoDelivery`, which the
      // player volunteers while it is playing and hardly at all when it is
      // not. Without a poll of its own, a viewer whose video never started
      // keeps an unknown position, every controller update reads as adrift,
      // and the player is re-seeked forever without ever being told to play
      // again. Asking costs one postMessage every five seconds.
      this.heartbeat = window.setInterval(() => {
        this.requestRemoteSync()
      }, 5_000)
    }
  }

  createPlayer() {
    // A signed-in reload replaces a player that is already handshaking. The
    // controller's heartbeat outlives it, so only the handshake is torn down.
    this.clearListening()
    this.playerContainer?.replaceChildren()

    // A fresh frame starts back under this code's control, whatever the last
    // one was handed over for.
    this.released = false

    const iframe = document.createElement("iframe")
    iframe.id = `call-youtube-iframe-${this.hook.el.dataset.callId}`
    iframe.src = youtubeEmbedUrl(this.videoId, {
      signedIn: this.signedIn,
      controls: this.localController,
      origin: window.location.origin,
    })
    iframe.title = "Shared YouTube video"
    // Matches both watch-party embeds. Without `fullscreen` in `allow` — plus
    // the legacy attribute for engines that still consult it — a fullscreen
    // request originating inside the frame is refused outright. `fs` stays 0:
    // the call supplies its own fullscreen control, which keeps the
    // participant strip on screen instead of handing the display to YouTube.
    iframe.allow = "autoplay; encrypted-media; picture-in-picture; fullscreen"
    iframe.allowFullscreen = true
    iframe.referrerPolicy = "strict-origin-when-cross-origin"
    iframe.className = `size-full ${this.localController ? "" : "pointer-events-none"}`
    this.playerContainer?.appendChild(iframe)
    this.iframe = iframe

    this.listenToPlayer = () => {
      iframe.contentWindow?.postMessage(
        JSON.stringify({event: "listening", id: iframe.id}),
        "*",
      )
    }
    iframe.addEventListener("load", this.listenToPlayer)
    this.listenToPlayer()
    this.listeningTimer = window.setInterval(this.listenToPlayer, 500)
  }

  handlePlayerMessage(event) {
    if (!this.active || !YOUTUBE_ORIGINS.has(event.origin) || event.source !== this.iframe?.contentWindow) return

    let message
    try {
      message = typeof event.data === "string" ? JSON.parse(event.data) : event.data
    } catch {
      return
    }

    if (message?.event === "onReady") {
      this.ready = true
      window.clearInterval(this.listeningTimer)
      command(this.iframe, "addEventListener", ["onStateChange"])
      // Without this the player never pushes `onError`, so a video that
      // refuses to embed reaches the assist only via the slower stall
      // heuristic — and never at all if playback was not asked for yet.
      command(this.iframe, "addEventListener", ["onError"])
      command(this.iframe, "getCurrentTime")
      if (!this.localController) this.applyRemotePlayback()
    }

    if (message?.event === "onError") this.assist.observe({errorCode: Number(message.info)})

    if (message?.event === "infoDelivery") {
      let positionRequest = null

      if (Number.isFinite(message.info?.currentTime)) {
        this.playerPosition = this.validPosition(message.info.currentTime)
        if (this.localController) this.position = this.playerPosition

        positionRequest = this.positionRequest
        this.positionRequest = null
      }

      if (Number.isFinite(message.info?.playerState)) {
        this.playerState = Number(message.info.playerState)
      }

      this.assist.observe({
        state: Number(message.info?.playerState),
        errorCode: Number(message.info?.errorCode),
      })

      if (positionRequest === "report") this.sendControl()
      if (positionRequest === "sync") this.applyRemotePlayback()
    }

    if (message?.event === "onStateChange") {
      this.playerState = Number(message.info)
      this.assist.observe({state: Number(message.info)})

      if (this.localController) {
        if (message.info === 1) this.playback = "playing"
        if (message.info === 0 || message.info === 2) this.playback = "paused"
        if ([0, 1, 2].includes(message.info)) this.requestControlReport()
      } else {
        // The player just contradicted or confirmed what it was told. Either
        // way this is the moment to re-check. Refresh its position first so
        // a state event cannot turn an old timestamp into another seek.
        this.requestRemoteSync()
      }
    }
  }

  controllerName() {
    return this.hook.rosterEntry(this.controllerId)?.name || "the other person"
  }

  sendControl() {
    if (!this.active || !this.localController || !this.hook.chatReady()) return
    try {
      this.hook.sendChatJson({
        kind: "youtube_control",
        playback: this.playback,
        position: this.position,
      })
    } catch {
      // The call lifecycle reports a closed data channel; playback can remain local.
    }
  }

  // The iframe replies to `getCurrentTime` later through `infoDelivery`.
  // Sending before that reply broadcasts the previous poll's timestamp and
  // makes remote players oscillate on every heartbeat.
  requestControlReport() {
    if (!this.active || !this.localController) return
    this.positionRequest = "report"
    command(this.iframe, "getCurrentTime")
  }

  // Controller heartbeats and viewer polls do not share a clock. Comparing a
  // fresh controller update with the viewer's previous poll invents several
  // seconds of drift and causes a visible seek/control-bar flash every five
  // seconds. Wait for this player's fresh response before deciding.
  requestRemoteSync() {
    if (!this.active || !this.ready || this.localController) return
    this.positionRequest = "sync"
    command(this.iframe, "getCurrentTime")
  }

  applyRemotePlayback() {
    // Match watch-party viewers: cue and synchronize beneath the consent
    // overlay, then let the tap reveal the player. Waiting until the overlay
    // click to send the first seek/play commands leaves some dynamically
    // created conference frames black, even though the same video works in a
    // watch party. The overlay still owns pointer input until the viewer taps.
    if (!this.ready || this.localController) return

    const {seek, command: next} = syncActions({
      playerPosition: this.playerPosition,
      position: this.position,
      appliedPlayback: this.appliedPlayback,
      playback: this.playback,
      // While the player is in the viewer's own hands — they are answering a
      // bot check — their pause has to stand. Withholding the state falls
      // back to asking once rather than fighting them for the controls.
      playerState: this.released ? null : this.playerState,
    })

    if (seek !== null) command(this.iframe, "seekTo", [seek, true])

    if (next) {
      command(this.iframe, next)
      this.appliedPlayback = this.playback

      if (this.playback === "playing") this.assist.requested()
      else this.assist.idle()
    }
  }

  stopLocal() {
    if (!this.active || !this.localController) return
    this.localShareEnded = true
    if (this.hook.chatReady()) {
      this.sendStop()
    }
    this.stopShare()
  }

  sendStop(peer = null) {
    try {
      this.hook.sendChatJson({kind: "youtube_stop"}, peer)
    } catch {
      // No open route to this peer yet. `channelStateChanged` replays the
      // stopped state if that pair's data channel comes back.
    }
  }

  stopShare() {
    this.clearPlayerTimers()
    this.assist.hide()
    this.iframe?.remove()
    this.iframe = null
    this.active = false
    this.localController = false
    this.controllerId = null
    this.ready = false
    this.appliedPlayback = null
    this.playerPosition = null
    this.playerState = null
    this.released = false
    this.hook.el.dataset.youtubeActive = "false"
    clearFaviconActivity(this.faviconSource)
    this.stage?.classList.add("hidden")
    this.stage?.classList.remove("block")
    this.compactCallVideos(false)
    this.updateShareButton()
  }

  clearListening() {
    window.clearInterval(this.listeningTimer)
    this.listeningTimer = null
    this.iframe?.removeEventListener("load", this.listenToPlayer)
  }

  clearPlayerTimers() {
    window.clearInterval(this.heartbeat)
    this.heartbeat = null
    this.clearListening()
  }

  // The shared video takes the stage, so the participants shrink to a strip.
  // The tile grid's own layout belongs to the hook, which re-applies it on
  // every roster change — hence a flag rather than a saved class name.
  //
  // The grid follows the share whether or not this participant has a local
  // video element of their own; gating it on one used to leave the strip
  // layout behind after a share ended.
  compactCallVideos(compact) {
    this.hook.compactTiles = compact
    this.hook.renderTiles()

    const local = this.hook.localVideo
    if (!local) return

    if (compact) {
      this.localVideoClass = local.className
      local.className = "absolute right-3 top-16 z-20 h-24 w-32 rounded-xl border border-white/20 bg-black object-cover shadow-xl sm:right-4 sm:h-32 sm:w-44"
    } else if (this.localVideoClass !== null) {
      local.className = this.localVideoClass
      this.localVideoClass = null
    }
  }

  updateShareButton() {
    if (!this.shareButton) return
    const label = this.shareButton.querySelector("[data-role='youtube-share-label']")
    if (label) {
      label.textContent = this.active
        ? this.localController
          ? "Stop YouTube"
          : "YouTube shared"
        : "YouTube"
    }
    this.shareButton.setAttribute("aria-pressed", String(this.active))
  }

  validPosition(position) {
    const value = Number(position)
    return Number.isFinite(value) && value >= 0 && value < 86_400 ? value : 0
  }
}
