import {clearFaviconActivity, setFaviconActivity} from "./favicon.js"
import {PlaybackAssist} from "./youtube_assist.js"
import {YOUTUBE_ORIGINS, youtubeEmbedUrl} from "./youtube_embed.js"

function playerCommand(iframe, func, args = []) {
  iframe?.contentWindow?.postMessage(
    JSON.stringify({event: "command", id: iframe.id, func, args}),
    "*",
  )
}

export const YouTubeWatch = {
  mounted() {
    this.faviconSource = `watch:${this.el.id || "youtube"}`
    setFaviconActivity(this.faviconSource, "youtube")
    this.iframe = this.el.querySelector("[data-role='player']")
    this.guard = this.el.querySelector("[data-role='guard']")
    this.host = this.el.dataset.host === "true"
    this.videoId = this.el.dataset.videoId
    this.playback = this.el.dataset.playback || "paused"
    this.position = Number(this.el.dataset.position) || 0
    this.ready = false

    this.assist = new PlaybackAssist({
      root: this.el,
      position: () => this.position,
      release: () => this.guard?.classList.add("hidden"),
      reload: () => this.reloadSignedIn(),
    })
    this.assist.watch(this.videoId)

    this.onMessage = event => {
      if (!YOUTUBE_ORIGINS.has(event.origin) || event.source !== this.iframe?.contentWindow) return

      let message
      try {
        message = typeof event.data === "string" ? JSON.parse(event.data) : event.data
      } catch (_error) {
        return
      }

      if (message?.event === "onReady") {
        this.ready = true
        if (this.listeningTimer) window.clearInterval(this.listeningTimer)
        playerCommand(this.iframe, "addEventListener", ["onStateChange"])
        playerCommand(this.iframe, "getCurrentTime")
        if (!this.host) this.applyPlayback()
      }

      if (message?.event === "onError") this.assist.observe({errorCode: Number(message.info)})

      if (message?.event === "infoDelivery") {
        if (Number.isFinite(message.info?.currentTime)) this.position = message.info.currentTime
        this.assist.observe({
          state: Number(message.info?.playerState),
          errorCode: Number(message.info?.errorCode),
        })
      }

      if (message?.event === "onStateChange") {
        this.assist.observe({state: Number(message.info)})

        if (this.host) {
          if (message.info === 1) this.playback = "playing"
          if (message.info === 0 || message.info === 2) this.playback = "paused"
          if ([0, 1, 2].includes(message.info)) this.reportPlayback()
        }
      }
    }

    window.addEventListener("message", this.onMessage)
    this.handleEvent("watch:control", detail => {
      if (this.host) return
      this.playback = detail.playback
      this.position = Number(detail.position) || 0
      this.applyPlayback()
    })

    // Before this tap the browser will not let the video make a sound. The
    // overlay then leaves entirely rather than staying on as a label — who is
    // steering is said by the badge above the player, which covers nothing.
    this.unlock = this.el.querySelector("[data-role='unlock']")
    this.unlock?.addEventListener(
      "click",
      () => {
        this.unlock.classList.add("hidden")
        this.applyPlayback()
      },
      {once: true},
    )

    this.fullscreenButton = document.querySelector("[data-watch-fullscreen]")
    this.onFullscreen = () => this.el.requestFullscreen?.()
    this.fullscreenButton?.addEventListener("click", this.onFullscreen)

    if (this.host) {
      this.heartbeat = window.setInterval(() => {
        playerCommand(this.iframe, "getCurrentTime")
        this.reportPlayback()
      }, 10_000)
    }

    this.startHandshake()
  },

  destroyed() {
    clearFaviconActivity(this.faviconSource)
    window.removeEventListener("message", this.onMessage)
    this.iframe?.removeEventListener("load", this.listenToPlayer)
    this.fullscreenButton?.removeEventListener("click", this.onFullscreen)
    this.assist?.destroy()
    if (this.heartbeat) window.clearInterval(this.heartbeat)
    if (this.listeningTimer) window.clearInterval(this.listeningTimer)
  },

  // The player answers nothing until it has been told someone is listening,
  // and when it becomes able to hear that varies, so the invitation repeats
  // until it is acknowledged.
  startHandshake() {
    this.listenToPlayer = () => {
      this.iframe?.contentWindow?.postMessage(
        JSON.stringify({event: "listening", id: this.iframe.id}),
        "*",
      )
    }
    this.iframe?.addEventListener("load", this.listenToPlayer)
    this.listenToPlayer()
    if (this.listeningTimer) window.clearInterval(this.listeningTimer)
    this.listeningTimer = window.setInterval(this.listenToPlayer, 500)
  },

  // The same video, served by the YouTube host that can see the viewer's own
  // account, so a bot check finally has somewhere to be answered.
  reloadSignedIn() {
    if (!this.iframe || !this.videoId) return

    this.ready = false
    this.iframe.removeEventListener("load", this.listenToPlayer)
    this.iframe.src = youtubeEmbedUrl(this.videoId, {
      signedIn: true,
      controls: this.host,
      fullscreen: true,
      origin: window.location.origin,
    })
    this.startHandshake()
  },

  reportPlayback() {
    this.pushEvent("watch_control", {playback: this.playback, position: this.position})
  },

  applyPlayback() {
    if (!this.ready) return
    playerCommand(this.iframe, "seekTo", [this.position, true])
    playerCommand(this.iframe, this.playback === "playing" ? "playVideo" : "pauseVideo")

    if (this.playback === "playing") this.assist.requested()
    else this.assist.idle()
  },
}

export function installWatchBanner() {
  let banner

  const remove = () => {
    banner?.remove()
    banner = null
  }

  window.addEventListener("phx:watch:ended", remove)
  window.addEventListener("phx:watch:invite", ({detail}) => {
    if (window.location.pathname === `/watch/${detail.public_id}`) return
    remove()

    banner = document.createElement("aside")
    banner.id = "watch-party-invite"
    banner.className = "fixed inset-x-3 bottom-3 z-[70] mx-auto flex max-w-xl items-center gap-3 rounded-2xl border border-primary/30 bg-base-100/95 p-4 text-base-content shadow-2xl backdrop-blur sm:bottom-5"
    banner.innerHTML = `
      <div class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-error/10 text-error" aria-hidden="true">▶</div>
      <div class="min-w-0 flex-1">
        <p class="font-semibold">${escapeHtml(detail.host)} started a watch party</p>
        <p class="text-sm opacity-65">Join the synchronized YouTube video.</p>
      </div>
      <a href="/watch/${encodeURIComponent(detail.public_id)}" class="btn btn-primary btn-sm">Join</a>
      <button type="button" class="btn btn-circle btn-ghost btn-sm" aria-label="Dismiss">×</button>
    `
    banner.querySelector("button")?.addEventListener("click", remove)
    document.body.appendChild(banner)
  })
}

function escapeHtml(value) {
  const span = document.createElement("span")
  span.textContent = String(value || "Someone")
  return span.innerHTML
}
