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

test("a conference share keeps its controller through start, control, and stop", () => {
  const peer = {id: "controller", name: "Alice"}
  const messages = []
  const youtube = Object.assign(Object.create(CallYouTube.prototype), {
    active: false,
    localController: false,
    localShareEnded: false,
    controllerId: null,
    unlocked: false,
    faviconSource: null,
    released: false,
    heartbeat: null,
    iframe: {
      id: "conference-player",
      contentWindow: {
        postMessage(message) {
          messages.push(JSON.parse(message))
        },
      },
    },
    hook: {
      el: {dataset: {}},
      rosterEntry: () => peer,
      showCallNotice() {},
    },
    assist: {watch() {}, hide() {}, requested() {}, idle() {}},
    controllerLabel: {textContent: ""},
    unlockLabel: {textContent: ""},
    stopShare() {
      this.active = false
      this.controllerId = null
    },
    compactCallVideos() {},
    createPlayer() {},
    updateShareButton() {},
  })

  youtube.handlePayload(
    {kind: "youtube_start", video_id: "dQw4w9WgXcQ", playback: "paused", position: 0},
    peer,
  )

  assert.equal(youtube.controllerId, peer.id)
  assert.equal(youtube.controllerLabel.textContent, "Controlled by Alice")

  youtube.ready = true
  youtube.playerPosition = 0
  youtube.playerState = 2
  youtube.appliedPlayback = "paused"
  youtube.handlePayload(
    {kind: "youtube_control", playback: "playing", position: 20},
    peer,
  )

  assert.deepEqual(messages.map(({func}) => func), ["seekTo", "playVideo"])

  youtube.handlePayload({kind: "youtube_stop"}, peer)
  assert.equal(youtube.active, false)
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

test("a conference heartbeat ignores ordinary drift without polling the viewer", () => {
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
