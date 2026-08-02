import {afterEach, mock, test} from "node:test"
import assert from "node:assert/strict"

import {PlaybackAssist} from "../../assets/js/veejr/youtube_assist.js"

// Enough of an element for the panel: classes, a click listener, an href.
function element(role) {
  const classes = new Set(["hidden"])

  return {
    dataset: {role},
    href: null,
    handlers: {},
    classList: {
      add: (...names) => names.forEach(name => classes.add(name)),
      remove: (...names) => names.forEach(name => classes.delete(name)),
      contains: name => classes.has(name),
    },
    addEventListener(type, handler) {
      this.handlers[type] = handler
    },
    removeEventListener(type) {
      delete this.handlers[type]
    },
    click() {
      this.handlers.click?.()
    },
  }
}

function player() {
  const parts = {
    panel: element("youtube-assist"),
    help: element("youtube-help"),
    open: element("youtube-open"),
    dismiss: element("youtube-assist-dismiss"),
    signedIn: element("youtube-signed-in"),
  }

  const find = selector => {
    if (selector.includes("youtube-assist-dismiss")) return parts.dismiss
    if (selector.includes("youtube-assist")) return parts.panel
    if (selector.includes("youtube-help")) return parts.help
    if (selector.includes("youtube-open")) return parts.open
    if (selector.includes("youtube-signed-in")) return parts.signedIn
    return null
  }

  parts.panel.querySelector = find
  parts.root = {querySelector: find}
  parts.showing = () => !parts.panel.classList.contains("hidden")

  return parts
}

function assist(parts, overrides = {}) {
  const calls = {released: 0, reloaded: 0}

  const subject = new PlaybackAssist({
    root: parts.root,
    position: () => 61,
    release: () => calls.released++,
    reload: () => calls.reloaded++,
    ...overrides,
  })

  return {subject, calls}
}

afterEach(() => mock.timers.reset())

test("a player that never starts offers the way out on its own", () => {
  mock.timers.enable({apis: ["setInterval", "Date"]})
  const parts = player()
  const {subject, calls} = assist(parts)

  subject.watch("dQw4w9WgXcQ")
  subject.requested()
  subject.observe({state: -1})

  mock.timers.tick(4_000)
  assert.equal(parts.showing(), false, "not before the player has had its chance")

  mock.timers.tick(4_000)
  assert.equal(parts.showing(), true)
  // A prompt nobody can click is not a prompt.
  assert.equal(calls.released, 1)
  assert.equal(parts.open.href, "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=61s")
})

test("a video that is playing is left alone", () => {
  mock.timers.enable({apis: ["setInterval", "Date"]})
  const parts = player()
  const {subject, calls} = assist(parts)

  subject.watch("dQw4w9WgXcQ")
  subject.requested()
  subject.observe({state: 1})

  mock.timers.tick(60_000)
  assert.equal(parts.showing(), false)
  assert.equal(calls.released, 0)
})

test("a paused party is not a stalled one", () => {
  mock.timers.enable({apis: ["setInterval", "Date"]})
  const parts = player()
  const {subject} = assist(parts)

  subject.watch("dQw4w9WgXcQ")
  subject.requested()
  subject.idle()
  subject.observe({state: 2})

  mock.timers.tick(60_000)
  assert.equal(parts.showing(), false)
})

test("the way out is always one tap away", () => {
  mock.timers.enable({apis: ["setInterval", "Date"]})
  const parts = player()
  const {subject, calls} = assist(parts)

  subject.watch("dQw4w9WgXcQ")
  parts.help.click()

  assert.equal(parts.showing(), true)
  assert.equal(calls.released, 1)
})

test("waving the panel away is not an invitation to nag", () => {
  mock.timers.enable({apis: ["setInterval", "Date"]})
  const parts = player()
  const {subject} = assist(parts)

  subject.watch("dQw4w9WgXcQ")
  subject.requested()
  subject.observe({state: -1})
  mock.timers.tick(8_000)
  assert.equal(parts.showing(), true)

  parts.dismiss.click()
  assert.equal(parts.showing(), false)

  subject.requested()
  mock.timers.tick(60_000)
  assert.equal(parts.showing(), false, "dismissed means dismissed")
})

test("the next video gets the panel back", () => {
  mock.timers.enable({apis: ["setInterval", "Date"]})
  const parts = player()
  const {subject} = assist(parts)

  subject.watch("dQw4w9WgXcQ")
  subject.requested()
  subject.observe({state: -1})
  mock.timers.tick(8_000)
  parts.dismiss.click()

  subject.watch("aqz-KE-bpKQ")
  subject.requested()
  subject.observe({state: -1})
  mock.timers.tick(8_000)

  assert.equal(parts.showing(), true)
  assert.equal(parts.open.href, "https://www.youtube.com/watch?v=aqz-KE-bpKQ&t=61s")
})

test("reloading against the signed-in host closes the panel", () => {
  mock.timers.enable({apis: ["setInterval", "Date"]})
  const parts = player()
  const {subject, calls} = assist(parts)

  subject.watch("dQw4w9WgXcQ")
  parts.help.click()
  parts.signedIn.click()

  assert.equal(calls.reloaded, 1)
  assert.equal(parts.showing(), false)
})

test("a destroyed player stops watching the clock", () => {
  mock.timers.enable({apis: ["setInterval", "Date"]})
  const parts = player()
  const {subject} = assist(parts)

  subject.watch("dQw4w9WgXcQ")
  subject.requested()
  subject.observe({state: -1})
  subject.destroy()

  mock.timers.tick(60_000)
  assert.equal(parts.showing(), false)
})
