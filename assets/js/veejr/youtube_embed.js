// Embed URLs and the stalled-playback signal, shared by watch parties and
// in-call sharing.
//
// YouTube intermittently interrupts a viewer with "sign in to confirm you're
// not a bot". That check is answered by a signed-in YouTube session *in the
// frame that shows it*, and `youtube-nocookie.com` is a separate origin from
// `youtube.com`, so the viewer's own session never reaches the privacy host —
// the prompt is unanswerable there no matter how long they stare at it. The
// privacy host therefore stays the default and `youtube.com` is the escape
// hatch a stuck viewer can reach for.

export const PRIVATE_EMBED_HOST = "https://www.youtube-nocookie.com"
export const SIGNED_IN_EMBED_HOST = "https://www.youtube.com"

export const YOUTUBE_ORIGINS = new Set([PRIVATE_EMBED_HOST, SIGNED_IN_EMBED_HOST])

// `controls` doubles as "this person steers the video": whoever gets the
// YouTube controls also keeps the keyboard shortcuts.
export function youtubeEmbedUrl(videoId, options = {}) {
  const {signedIn = false, controls = false, fullscreen = false, origin = null} = options

  const query = new URLSearchParams({
    enablejsapi: "1",
    playsinline: "1",
    rel: "0",
    controls: controls ? "1" : "0",
    disablekb: controls ? "0" : "1",
    fs: fullscreen ? "1" : "0",
    iv_load_policy: "3",
  })
  if (origin) query.set("origin", origin)

  return `${signedIn ? SIGNED_IN_EMBED_HOST : PRIVATE_EMBED_HOST}/embed/${videoId}?${query}`
}

// Where a stuck viewer goes to answer YouTube directly. First-party
// youtube.com carries their real session, so the check can actually be
// satisfied there, and `t` drops them where everyone else is watching.
export function youtubeWatchUrl(videoId, position = 0) {
  const seconds = Math.max(0, Math.floor(Number(position) || 0))
  const query = new URLSearchParams({v: videoId})
  if (seconds > 0) query.set("t", `${seconds}s`)

  return `${SIGNED_IN_EMBED_HOST}/watch?${query}`
}

// 5 cannot play here, 100 is gone, 101/150 forbid embedding, 153 lost the
// referrer. Every one of them means the same thing to a viewer: not here.
// 2 is our own malformed request and is not something they can act on.
export const FATAL_PLAYER_ERRORS = new Set([5, 100, 101, 150, 153])

const PLAYING = 1
const BUFFERING = 3

// The IFrame API has no event for the bot check — the gate is painted inside
// the frame and the player simply never leaves `unstarted`. So the signal is
// behavioural: playback was asked for, and a grace period later nothing is
// happening. Silence is only evidence once we have actually asked.
export function playbackStalled({requestedAt, now, state, errorCode, grace = 6000}) {
  if (FATAL_PLAYER_ERRORS.has(errorCode)) return true
  if (!Number.isFinite(requestedAt)) return false
  if (state === PLAYING || state === BUFFERING) return false

  return now - requestedAt >= grace
}
