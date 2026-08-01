import {test} from "node:test"
import assert from "node:assert/strict"

import {
  CLASSIC,
  sectionOpen,
  shouldReapply,
} from "../../assets/js/veejr/contacts_sections.js"

test("Classic follows the server: only the marked section starts open", () => {
  assert.equal(sectionOpen(CLASSIC, true), true)
  assert.equal(sectionOpen(CLASSIC, false), false)
})

test("a flat appearance shows every section at once", () => {
  assert.equal(sectionOpen("quiet", false), true)
  assert.equal(sectionOpen("orbit", false), true)
})

test("a flat appearance reasserts on every render", () => {
  // LiveView may have patched a section back to the server's markup.
  assert.equal(shouldReapply(CLASSIC, "quiet"), true)
  assert.equal(shouldReapply("quiet", "quiet"), true)
  assert.equal(shouldReapply(undefined, "quiet"), true)
})

test("returning to Classic closes what the flat appearance opened", () => {
  // The regression: without this the sections stayed open until a reload.
  assert.equal(shouldReapply("quiet", CLASSIC), true)
  assert.equal(sectionOpen(CLASSIC, false), false)
})

test("Classic leaves a reader's own expansion alone on re-render", () => {
  // Reapplying here would slam shut a section they had just opened.
  assert.equal(shouldReapply(CLASSIC, CLASSIC), false)
})

test("mounting straight into Classic defers to the server", () => {
  assert.equal(shouldReapply(undefined, CLASSIC), false)
})
