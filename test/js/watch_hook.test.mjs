import {test} from "node:test"
import assert from "node:assert/strict"

import {YouTubeWatch} from "../../assets/js/veejr/watch_hook.js"

function mountedWatch(host) {
  const commands = []
  const controls = []
  const contentWindow = {
    postMessage(message) {
      commands.push(JSON.parse(message))
    },
  }
  const iframe = {
    id: "watch-player-test",
    contentWindow,
    addEventListener() {},
    removeEventListener() {},
  }
  const element = {
    id: "watch-test",
    dataset: {
      host: String(host),
      videoId: "abcdefghijk",
      playback: "playing",
      position: "10",
    },
    querySelector(selector) {
      return selector === "[data-role='player']" ? iframe : null
    },
  }
  const watch = Object.assign(Object.create(YouTubeWatch), {
    el: element,
    handleEvent() {},
    pushEvent(event, payload) {
      controls.push({event, payload})
    },
  })

  watch.mounted()

  return {watch, commands, controls, contentWindow}
}

function fakeDocument() {
  return {
    head: {appendChild() {}},
    querySelector() {
      return null
    },
    createElement() {
      return {
        dataset: {},
        setAttribute() {},
      }
    },
  }
}

test("a watch-party host reports only after YouTube returns a fresh position", () => {
  const originalDocument = globalThis.document
  const originalWindow = globalThis.window
  globalThis.document = fakeDocument()
  globalThis.window = {
    addEventListener() {},
    removeEventListener() {},
    setInterval,
    clearInterval,
  }

  const {watch, commands, controls, contentWindow} = mountedWatch(true)

  try {
    commands.length = 0
    watch.requestPlaybackReport()

    assert.deepEqual(commands.map(({func}) => func), ["getCurrentTime"])
    assert.deepEqual(controls, [])

    watch.onMessage({
      origin: "https://www.youtube.com",
      source: contentWindow,
      data: {event: "infoDelivery", info: {currentTime: 15, playerState: 1}},
    })

    assert.deepEqual(controls, [
      {event: "watch_control", payload: {playback: "playing", position: 15}},
    ])
  } finally {
    watch.destroyed()
    globalThis.document = originalDocument
    globalThis.window = originalWindow
  }
})

test("a current watch-party viewer is not seeked using its stale poll", () => {
  const originalDocument = globalThis.document
  const originalWindow = globalThis.window
  globalThis.document = fakeDocument()
  globalThis.window = {
    addEventListener() {},
    removeEventListener() {},
    setInterval,
    clearInterval,
  }

  const {watch, commands, contentWindow} = mountedWatch(false)

  try {
    commands.length = 0
    watch.ready = true
    watch.playerPosition = 90
    watch.position = 100
    watch.appliedPlayback = "playing"
    watch.playerState = 1
    watch.positionRequest = "sync"

    watch.onMessage({
      origin: "https://www.youtube.com",
      source: contentWindow,
      data: {event: "infoDelivery", info: {currentTime: 100, playerState: 1}},
    })

    assert.deepEqual(commands, [])
  } finally {
    watch.destroyed()
    globalThis.document = originalDocument
    globalThis.window = originalWindow
  }
})
