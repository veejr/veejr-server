import {test} from "node:test"
import assert from "node:assert/strict"

import {CallSession} from "../../assets/js/veejr/call_hook.js"

function classList(...initial) {
  const classes = new Set(initial)

  return {
    add(...names) {
      names.forEach((name) => classes.add(name))
    },
    remove(...names) {
      names.forEach((name) => classes.delete(name))
    },
    contains(name) {
      return classes.has(name)
    },
  }
}

test("conference startup restores a previously hidden device check", () => {
  const setupEl = {classList: classList("hidden")}

  CallSession.showInitialDeviceSetup.call({setupEl, joinedCall: false})

  assert.equal(setupEl.classList.contains("hidden"), false)
  assert.equal(setupEl.classList.contains("flex"), true)
})

test("opening startup does not interrupt an already joined call", () => {
  const setupEl = {classList: classList("hidden")}

  CallSession.showInitialDeviceSetup.call({setupEl, joinedCall: true})

  assert.equal(setupEl.classList.contains("hidden"), true)
  assert.equal(setupEl.classList.contains("flex"), false)
})
