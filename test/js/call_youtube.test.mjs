import {test} from "node:test"
import assert from "node:assert/strict"

import {CallYouTube} from "../../assets/js/veejr/call_youtube.js"

function remoteViewer(overrides = {}) {
  const messages = []
  const viewer = Object.assign(Object.create(CallYouTube.prototype), {
    ready: true,
    unlocked: false,
    localController: false,
    playerPosition: null,
    position: 42,
    appliedPlayback: null,
    playback: "playing",
    playerState: -1,
    released: false,
    iframe: {
      id: "call-youtube-test",
      contentWindow: {
        postMessage(message) {
          messages.push(JSON.parse(message))
        },
      },
    },
    assist: {
      requested() {},
      idle() {},
    },
    ...overrides,
  })

  return {viewer, messages}
}

test("a conference viewer synchronizes beneath the tap overlay", () => {
  const {viewer, messages} = remoteViewer()

  viewer.applyRemotePlayback()

  assert.deepEqual(messages.map(({func}) => func), ["seekTo", "playVideo"])
  assert.equal(viewer.appliedPlayback, "playing")
})

test("a conference controller is never driven as a remote player", () => {
  const {viewer, messages} = remoteViewer({localController: true})

  viewer.applyRemotePlayback()

  assert.deepEqual(messages, [])
})
