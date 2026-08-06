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
      observe() {},
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

test("a controller reports the fresh position returned by YouTube", () => {
  const commands = []
  const controls = []
  const contentWindow = {
    postMessage(message) {
      commands.push(JSON.parse(message))
    },
  }
  const youtube = Object.assign(Object.create(CallYouTube.prototype), {
    active: true,
    localController: true,
    playback: "playing",
    position: 10,
    playerPosition: 10,
    playerState: 1,
    positionRequest: null,
    iframe: {id: "controller-player", contentWindow},
    assist: {observe() {}},
    hook: {
      chatReady: () => true,
      sendChatJson(payload) {
        controls.push(payload)
      },
    },
  })

  youtube.requestControlReport()

  assert.deepEqual(commands.map(({func}) => func), ["getCurrentTime"])
  assert.deepEqual(controls, [])

  youtube.handlePlayerMessage({
    origin: "https://www.youtube.com",
    source: contentWindow,
    data: {event: "infoDelivery", info: {currentTime: 15, playerState: 1}},
  })

  assert.equal(controls.length, 1)
  assert.equal(controls[0].position, 15)
})

test("a viewer waits for its fresh position before deciding to seek", () => {
  const {viewer, messages} = remoteViewer({
    active: true,
    playerPosition: 90,
    position: 100,
    appliedPlayback: "playing",
    playerState: 1,
    positionRequest: "sync",
  })

  viewer.handlePlayerMessage({
    origin: "https://www.youtube.com",
    source: viewer.iframe.contentWindow,
    data: {event: "infoDelivery", info: {currentTime: 100, playerState: 1}},
  })

  assert.deepEqual(messages, [])
})

test("a conference heartbeat refreshes the viewer before deciding to seek", () => {
  const peer = {id: "controller"}
  const {viewer, messages} = remoteViewer({
    active: true,
    controllerId: peer.id,
    playerPosition: 95,
    position: 95,
    appliedPlayback: "playing",
    playerState: 1,
  })

  viewer.handlePayload(
    {kind: "youtube_control", playback: "playing", position: 100},
    peer,
  )

  assert.deepEqual(messages.map(({func}) => func), ["getCurrentTime"])

  viewer.handlePlayerMessage({
    origin: "https://www.youtube.com",
    source: viewer.iframe.contentWindow,
    data: {event: "infoDelivery", info: {currentTime: 100, playerState: 1}},
  })

  assert.deepEqual(messages.map(({func}) => func), ["getCurrentTime"])
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
