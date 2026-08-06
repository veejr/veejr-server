import {test} from "node:test"
import assert from "node:assert/strict"

import {CallYouTube} from "../../assets/js/veejr/call_youtube.js"
import {sendJsonToPeers} from "../../assets/js/veejr/call_hook.js"

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

test("an ended share is replayed when a peer data channel reopens", () => {
  const peer = {id: "late-peer"}
  const messages = []
  const youtube = Object.assign(Object.create(CallYouTube.prototype), {
    active: false,
    localController: false,
    localShareEnded: true,
    shareButton: null,
    hook: {
      chatReady: () => true,
      sendChatJson(payload, target) {
        messages.push({payload, target})
      },
    },
  })

  youtube.channelStateChanged(peer)

  assert.deepEqual(messages, [{payload: {kind: "youtube_stop"}, target: peer}])
})

test("a peer that has never shared does not invent a stop", () => {
  const messages = []
  const youtube = Object.assign(Object.create(CallYouTube.prototype), {
    active: false,
    localController: false,
    localShareEnded: false,
    shareButton: null,
    hook: {
      chatReady: () => true,
      sendChatJson(payload) {
        messages.push(payload)
      },
    },
  })

  youtube.channelStateChanged({id: "new-peer"})

  assert.deepEqual(messages, [])
})

test("one closing conference channel does not block later peers", () => {
  const received = []
  const peers = [
    {chatChannel: {send() { throw new Error("closed") }}},
    {chatChannel: {send(message) { received.push(JSON.parse(message)) }}},
  ]

  sendJsonToPeers(peers, {kind: "youtube_stop"})

  assert.deepEqual(received, [{kind: "youtube_stop"}])
})

test("fan-out reports failure when every data channel closed", () => {
  const peers = [
    {chatChannel: {send() { throw new Error("first closed") }}},
    {chatChannel: {send() { throw new Error("second closed") }}},
  ]

  assert.throws(() => sendJsonToPeers(peers, {kind: "youtube_stop"}), /second closed/)
})
