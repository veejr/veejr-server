// Deciding what to tell a shared YouTube player, and — mostly — deciding to
// tell it nothing.
//
// Both places veejr shares YouTube (watch parties and in-call sharing) have a
// controller reporting its position every few seconds. Acting on every report
// makes the player surface its control bar, so the pause button blinks into
// view on every viewer's screen for as long as the video lasts. Commands are
// therefore issued only when the viewer actually disagrees with the
// controller.
//
// This lives apart from both callers because it was once fixed in only one of
// them, and the other kept flickering for months.

// How far a viewer may drift before a seek is worth the interruption. Small
// enough that nobody notices the gap, large enough that ordinary jitter
// between two players never triggers one.
export const DRIFT_TOLERANCE_SECONDS = 2

// The two YouTube player states that mean the video is actually going.
// `unstarted` (-1), `ended` (0), `paused` (2) and `cued` (5) all mean it is not.
const PLAYING = 1
const BUFFERING = 3

/**
 * What to send the player to match the controller.
 *
 * `playerPosition` is where this browser's player is, or null when that is
 * not known yet — on a fresh player, or after it has been handed back to the
 * viewer to answer a bot check. Not knowing always means seek.
 *
 * `appliedPlayback` is the last play/pause this code issued, which is not the
 * same as what the player is doing: a viewer may have paused it themselves,
 * and re-issuing pause at them would be noise.
 *
 * `playerState` is what the player last reported about itself, and it settles
 * the case `appliedPlayback` cannot. Asking is not the same as being obeyed —
 * a play the browser refused, or a player that never left `unstarted`, leaves
 * the two permanently disagreeing with nothing left to re-issue the command.
 * Omit it and the decision falls back to `appliedPlayback` alone.
 *
 * Returns `{seek, command}` where either may be null for "leave it alone".
 */
export function syncActions({
  playerPosition,
  position,
  appliedPlayback,
  playback,
  playerState,
  tolerance = DRIFT_TOLERANCE_SECONDS,
} = {}) {
  const target = Number.isFinite(position) ? position : 0

  const adrift =
    !Number.isFinite(playerPosition) || Math.abs(playerPosition - target) > tolerance

  const settled =
    playback === "playing"
      ? playerState === PLAYING || playerState === BUFFERING
      : playerState !== PLAYING

  // Only contradict the player when it has actually told us something. An
  // unknown state is not evidence of disagreement.
  const ignoring = Number.isFinite(playerState) && !settled

  const changed = appliedPlayback !== playback || ignoring

  return {
    seek: adrift ? target : null,
    command: changed ? (playback === "playing" ? "playVideo" : "pauseVideo") : null,
  }
}
