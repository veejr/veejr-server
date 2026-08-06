// Keeping a shared YouTube player in step without touching it needlessly.
//
// The controller reports every few seconds. Acting on each report makes the
// player raise its control bar, so the pause button blinks at every viewer
// for the length of the video. These check that an agreeing viewer is left
// entirely alone.

import {test} from "node:test"
import assert from "node:assert/strict"

import {DRIFT_TOLERANCE_SECONDS, syncActions} from "../../assets/js/veejr/youtube_sync.js"

const agreeing = {
  playerPosition: 100,
  position: 100,
  appliedPlayback: "playing",
  playback: "playing",
}

test("a viewer who already agrees is not touched at all", () => {
  assert.deepEqual(syncActions(agreeing), {seek: null, command: null})
})

test("the repeat reports of an unchanged party do nothing", () => {
  // What the bug looked like: ten seconds of drift-free playback, reported
  // over and over, each report yanking the player.
  for (let tick = 0; tick < 5; tick++) {
    const drifted = {...agreeing, playerPosition: 100 + tick * 0.2}
    assert.deepEqual(syncActions(drifted), {seek: null, command: null}, `tick ${tick}`)
  }
})

test("small drift is tolerated rather than corrected", () => {
  for (const off of [0, 0.5, 1, 1.9, -1.9]) {
    const actions = syncActions({...agreeing, playerPosition: 100 + off})
    assert.equal(actions.seek, null, `off by ${off}`)
  }
})

test("real drift is corrected, in either direction", () => {
  assert.equal(syncActions({...agreeing, playerPosition: 90}).seek, 100)
  assert.equal(syncActions({...agreeing, playerPosition: 130}).seek, 100)
})

test("the tolerance is the boundary, not a suggestion", () => {
  const justInside = syncActions({...agreeing, playerPosition: 100 + DRIFT_TOLERANCE_SECONDS})
  const justOutside = syncActions({
    ...agreeing,
    playerPosition: 100 + DRIFT_TOLERANCE_SECONDS + 0.01,
  })

  assert.equal(justInside.seek, null)
  assert.equal(justOutside.seek, 100)
})

test("a player whose position is unknown is always seeked", () => {
  // A fresh player, or one just handed back after a bot check.
  for (const unknown of [null, undefined, NaN]) {
    assert.equal(syncActions({...agreeing, playerPosition: unknown}).seek, 100, String(unknown))
  }
})

test("play and pause are issued only when the state actually changes", () => {
  assert.equal(syncActions({...agreeing, appliedPlayback: "paused"}).command, "playVideo")

  assert.equal(
    syncActions({...agreeing, playback: "paused", appliedPlayback: "playing"}).command,
    "pauseVideo",
  )

  assert.equal(syncActions({...agreeing, appliedPlayback: "playing"}).command, null)
})

test("a player nothing has been applied to yet gets told once", () => {
  assert.equal(syncActions({...agreeing, appliedPlayback: null}).command, "playVideo")

  assert.equal(
    syncActions({...agreeing, playback: "paused", appliedPlayback: null}).command,
    "pauseVideo",
  )
})

test("a viewer who paused for themselves is not fought over", () => {
  // The controller keeps reporting "playing" and this code already sent
  // play. Sending it again every few seconds would wrestle the viewer.
  const reports = Array.from({length: 4}, () => syncActions(agreeing))

  assert.ok(reports.every((r) => r.command === null))
})

test("seeking and starting can both be needed at once", () => {
  const actions = syncActions({
    playerPosition: 0,
    position: 250,
    appliedPlayback: null,
    playback: "playing",
  })

  assert.deepEqual(actions, {seek: 250, command: "playVideo"})
})

test("a missing position is treated as the start, not as NaN", () => {
  const actions = syncActions({playerPosition: null, appliedPlayback: null, playback: "paused"})

  assert.equal(actions.seek, 0)
  assert.equal(actions.command, "pauseVideo")
})

// What the player reports about itself, which is not the same as what it was
// told. Asking once and recording that we asked leaves a refused play — or a
// player that never left `unstarted` — stuck with nothing to correct it.

test("a player that ignored the play it was sent is asked again", () => {
  // -1 unstarted, 0 ended, 2 paused, 5 cued: none of them are playing.
  for (const state of [-1, 0, 2, 5]) {
    const actions = syncActions({...agreeing, playerState: state})
    assert.equal(actions.command, "playVideo", `state ${state}`)
  }
})

test("a player that is actually playing is left alone", () => {
  // 1 playing, 3 buffering — buffering is on its way, not a refusal.
  for (const state of [1, 3]) {
    assert.equal(syncActions({...agreeing, playerState: state}).command, null, `state ${state}`)
  }
})

test("a player still playing after a pause is asked again", () => {
  const actions = syncActions({
    ...agreeing,
    playback: "paused",
    appliedPlayback: "paused",
    playerState: 1,
  })

  assert.equal(actions.command, "pauseVideo")
})

test("an unknown player state decides nothing on its own", () => {
  // Before the player has said anything, and for callers that do not track
  // it at all, the decision stays with appliedPlayback exactly as before.
  for (const unknown of [null, undefined, NaN]) {
    assert.equal(syncActions({...agreeing, playerState: unknown}).command, null, String(unknown))
  }
})

test("re-asking does not become a loop once the player complies", () => {
  // The correction is issued while the player disagrees and stops the moment
  // it reports that it is playing.
  assert.equal(syncActions({...agreeing, playerState: -1}).command, "playVideo")
  assert.equal(syncActions({...agreeing, playerState: 3}).command, null)
  assert.equal(syncActions({...agreeing, playerState: 1}).command, null)
})
