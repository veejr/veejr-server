import {test} from "node:test"
import assert from "node:assert/strict"

import {
  faviconHrefFor,
  faviconStateFor,
} from "../../assets/js/veejr/favicon.js"

test("the Veejr logo is the default favicon", () => {
  assert.equal(faviconStateFor([]), "default")
  assert.equal(faviconHrefFor("default"), "/images/favicon-veejr.svg")
})

test("an active call uses the phone favicon", () => {
  assert.equal(faviconStateFor(["call"]), "call")
  assert.equal(faviconHrefFor("call"), "/images/favicon-phone.svg")
})

test("YouTube sharing takes priority over an active call", () => {
  assert.equal(faviconStateFor(["call", "youtube"]), "youtube")
  assert.equal(faviconHrefFor("youtube"), "/images/favicon-projector.svg")
})

test("unknown states safely restore the Veejr logo", () => {
  assert.equal(faviconHrefFor("missing"), "/images/favicon-veejr.svg")
})
