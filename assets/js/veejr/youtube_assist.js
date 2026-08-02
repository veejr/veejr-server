import {playbackStalled, youtubeWatchUrl} from "./youtube_embed.js"

const POLL_MS = 1_000

// Drives the "this video is not playing here" panel for both shared players.
//
// A synchronized viewer does not steer the video, so the player sits behind a
// click guard — which is exactly what traps someone YouTube has decided to
// challenge. This watches for playback that was asked for and never arrived,
// and when it offers the way out it also drops the guard, because a prompt
// nobody can click is not a prompt.
//
// The surface supplies `reload` and `release`: a watch party and a call build
// their player differently, and only they know how.
export class PlaybackAssist {
  constructor({root, reload, release, position = () => 0}) {
    this.reload = reload
    this.release = release
    this.position = position

    this.panel = root.querySelector("[data-role='youtube-assist']")
    this.help = root.querySelector("[data-role='youtube-help']")
    this.openLink = this.panel?.querySelector("[data-role='youtube-open']")
    this.dismissButton = this.panel?.querySelector("[data-role='youtube-assist-dismiss']")
    this.signedInButton = this.panel?.querySelector("[data-role='youtube-signed-in']")

    this.videoId = null
    this.requestedAt = null
    this.state = null
    this.errorCode = null
    this.open = false
    this.dismissed = false

    this.onHelp = () => this.show()
    this.onDismiss = () => this.hide({dismissed: true})
    this.onSignedIn = () => {
      this.hide()
      this.reload()
    }

    this.help?.addEventListener("click", this.onHelp)
    this.dismissButton?.addEventListener("click", this.onDismiss)
    this.signedInButton?.addEventListener("click", this.onSignedIn)

    // Bare timers rather than `window.*` so the stall logic can be driven by a
    // test clock outside a browser.
    this.timer = setInterval(() => this.poll(), POLL_MS)
  }

  destroy() {
    clearInterval(this.timer)
    this.help?.removeEventListener("click", this.onHelp)
    this.dismissButton?.removeEventListener("click", this.onDismiss)
    this.signedInButton?.removeEventListener("click", this.onSignedIn)
  }

  // A fresh player starts with a clean slate: the previous one's silence says
  // nothing about this one, and a viewer who waved the panel away has not
  // waved away the next video.
  watch(videoId) {
    this.videoId = videoId
    this.requestedAt = null
    this.state = null
    this.errorCode = null
    this.dismissed = false
    this.hide()
  }

  // Playback has been asked of the player; from here silence is evidence.
  requested() {
    this.requestedAt = Date.now()
  }

  // Nobody asked this player to be playing, so it owes us nothing.
  idle() {
    this.requestedAt = null
  }

  observe({state, errorCode} = {}) {
    if (Number.isFinite(state)) this.state = state
    if (Number.isFinite(errorCode)) this.errorCode = errorCode
  }

  poll() {
    if (this.open || this.dismissed) return

    const stalled = playbackStalled({
      requestedAt: this.requestedAt,
      now: Date.now(),
      state: this.state,
      errorCode: this.errorCode,
    })

    if (stalled) this.show()
  }

  show() {
    if (!this.panel || this.open) return

    this.open = true
    if (this.openLink && this.videoId) {
      this.openLink.href = youtubeWatchUrl(this.videoId, this.position())
    }
    this.panel.classList.remove("hidden")
    this.panel.classList.add("flex")

    // Released for the rest of this share rather than until the panel closes:
    // answering YouTube takes several taps, and the host's next heartbeat
    // pulls anyone who wandered back into sync.
    this.release()
  }

  hide({dismissed = false} = {}) {
    if (!this.panel) return

    this.open = false
    this.dismissed = this.dismissed || dismissed
    this.errorCode = null
    this.requestedAt = null
    this.panel.classList.add("hidden")
    this.panel.classList.remove("flex")
  }
}
