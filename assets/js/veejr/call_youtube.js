const VIDEO_ID_PATTERN = /^[A-Za-z0-9_-]{11}$/u
const YOUTUBE_ORIGINS = new Set(["https://www.youtube.com", "https://www.youtube-nocookie.com"])

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
    this.controllerId = null
    this.ready = false
    this.unlocked = false
    this.playback = "paused"
    this.position = 0
    this.appliedPlayback = null
    this.playerPosition = null

    this.onWindowMessage = event => this.handlePlayerMessage(event)
    window.addEventListener("message", this.onWindowMessage)
    this.setupControls()
    this.channelStateChanged()
  }

  destroy() {
    window.removeEventListener("message", this.onWindowMessage)
    this.clearPlayerTimers()
    this.iframe?.remove()
    this.hook.el.dataset.youtubeActive = "false"
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

  channelStateChanged() {
    if (!this.shareButton) return
    const ready = this.hook.chatReady()
    this.shareButton.disabled = !ready
    this.shareButton.title = ready
      ? "Watch a YouTube video together"
      : "YouTube sharing is available once the call connects"
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

  sendStart() {
    if (!this.active || !this.localController) return
    try {
      this.hook.sendChatJson({
        kind: "youtube_start",
        video_id: this.videoId,
        playback: this.playback,
        position: this.position,
      })
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
      this.applyRemotePlayback()
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

  showShare(videoId, localController, playback, position) {
    this.stopShare()
    this.active = true
    this.localController = localController
    this.hook.el.dataset.youtubeActive = "true"
    this.videoId = videoId
    this.playback = playback
    this.position = position
    this.appliedPlayback = null
    this.playerPosition = null
    this.ready = false

    this.stage?.classList.remove("hidden")
    this.stage?.classList.add("block")
    if (localController) this.controllerId = null
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
        command(this.iframe, "getCurrentTime")
        this.sendControl()
      }, 5_000)
    }
  }

  createPlayer() {
    this.playerContainer?.replaceChildren()
    const query = new URLSearchParams({
      enablejsapi: "1",
      playsinline: "1",
      rel: "0",
      controls: this.localController ? "1" : "0",
      disablekb: this.localController ? "0" : "1",
      fs: "0",
      iv_load_policy: "3",
      origin: window.location.origin,
    })
    const iframe = document.createElement("iframe")
    iframe.id = `call-youtube-iframe-${this.hook.el.dataset.callId}`
    iframe.src = `https://www.youtube-nocookie.com/embed/${this.videoId}?${query}`
    iframe.title = "Shared YouTube video"
    iframe.allow = "autoplay; encrypted-media; picture-in-picture"
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
      command(this.iframe, "getCurrentTime")
      if (!this.localController) this.applyRemotePlayback()
    }

    if (message?.event === "infoDelivery" && Number.isFinite(message.info?.currentTime)) {
      this.playerPosition = this.validPosition(message.info.currentTime)
      if (this.localController) this.position = this.playerPosition
    }

    if (this.localController && message?.event === "onStateChange") {
      if (message.info === 1) this.playback = "playing"
      if (message.info === 0 || message.info === 2) this.playback = "paused"
      if ([0, 1, 2].includes(message.info)) this.sendControl()
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

  applyRemotePlayback() {
    if (!this.ready || !this.unlocked || this.localController) return

    if (
      this.playerPosition === null ||
      Math.abs(this.playerPosition - this.position) > 2
    ) {
      command(this.iframe, "seekTo", [this.position, true])
    }

    if (this.appliedPlayback !== this.playback) {
      command(this.iframe, this.playback === "playing" ? "playVideo" : "pauseVideo")
      this.appliedPlayback = this.playback
    }
  }

  stopLocal() {
    if (!this.active || !this.localController) return
    if (this.hook.chatReady()) {
      try {
        this.hook.sendChatJson({kind: "youtube_stop"})
      } catch {
        // Every peer has already disconnected.
      }
    }
    this.stopShare()
  }

  stopShare() {
    this.clearPlayerTimers()
    this.iframe?.remove()
    this.iframe = null
    this.active = false
    this.localController = false
    this.controllerId = null
    this.ready = false
    this.appliedPlayback = null
    this.playerPosition = null
    this.hook.el.dataset.youtubeActive = "false"
    this.stage?.classList.add("hidden")
    this.stage?.classList.remove("block")
    this.compactCallVideos(false)
    this.updateShareButton()
  }

  clearPlayerTimers() {
    window.clearInterval(this.heartbeat)
    window.clearInterval(this.listeningTimer)
    this.heartbeat = null
    this.listeningTimer = null
    this.iframe?.removeEventListener("load", this.listenToPlayer)
  }

  // The shared video takes the stage, so the participants shrink to a strip.
  // The tile grid's own layout belongs to the hook, which re-applies it on
  // every roster change — hence a flag rather than a saved class name.
  compactCallVideos(compact) {
    const local = this.hook.localVideo
    if (!local) return

    this.hook.compactTiles = compact
    this.hook.renderTiles()

    if (compact) {
      this.localVideoClass = local.className
      local.className = "absolute right-3 top-16 z-20 h-24 w-32 rounded-xl border border-white/20 bg-black object-cover shadow-xl sm:right-4 sm:h-32 sm:w-44"
    } else if (this.localVideoClass) {
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
