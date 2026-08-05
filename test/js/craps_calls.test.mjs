// What the table says out loud.
//
// The croupier's call carries the result, so it must never be spoken for a
// roll that has not landed — that is enforced at the call site. What is
// checked here is that the words themselves are right, and that the gallery
// only cheers a win.

import {test} from "node:test"
import assert from "node:assert/strict"

import {
  CHEERS,
  STREAK_CHEERS,
  cheerPool,
  croupierCall,
  galleryCheer,
  isWin,
  nextStreak,
} from "../../assets/js/veejr/craps/calls.js"

test("the croupier names what happened", () => {
  assert.equal(croupierCall("natural", 7), "Seven! Natural! Winner!")
  assert.equal(croupierCall("natural", 11), "Eleven! Natural! Winner!")
  assert.equal(croupierCall("craps", 2), "Two — snake eyes! Craps!")
  assert.equal(croupierCall("craps", 12), "Twelve — boxcars! Craps!")
  assert.equal(croupierCall("craps", 3), "Three! Craps!")
  assert.equal(croupierCall("point_set", 6), "Six. The point is six.")
  assert.equal(croupierCall("point_made", 8), "Eight! Winner! Point made!")
  assert.equal(croupierCall("seven_out", 7), "Seven out! Line away!")
  assert.equal(croupierCall("roll", 9), "Nine.")
})

test("an event nobody named gets no call", () => {
  assert.equal(croupierCall("something_else", 5), null)
})

test("only the shooter coming good is a win", () => {
  assert.ok(isWin("natural"))
  assert.ok(isWin("point_made"))
  refuteWin("craps")
  refuteWin("seven_out")
  refuteWin("point_set")
  refuteWin("roll")

  function refuteWin(event) {
    assert.equal(isWin(event), false, event)
  }
})

test("the gallery cheers a win and stays quiet otherwise", () => {
  assert.ok(CHEERS.includes(galleryCheer("natural", 1, () => 0)))
  assert.ok(CHEERS.includes(galleryCheer("point_made", 1, () => 0)))

  for (const event of ["craps", "seven_out", "point_set", "roll"]) {
    assert.equal(galleryCheer(event, 5, () => 0), null, event)
  }
})

test("the cheers are the ones asked for", () => {
  assert.ok(CHEERS.includes("You da man!"))
  assert.ok(CHEERS.includes("Sweet!"))
  assert.ok(CHEERS.includes("Yessir!"))
  assert.ok(STREAK_CHEERS.some((c) => c.includes("on a roll")))
})

test("'on a roll' waits for an actual run", () => {
  // One win is not a run.
  assert.deepEqual(cheerPool(1), CHEERS)
  refute(cheerPool(1).some((c) => c.includes("on a roll")))

  // Two in a row is.
  assert.ok(cheerPool(2).some((c) => c.includes("on a roll")))

  function refute(value) {
    assert.equal(value, false)
  }
})

test("a run builds on wins and dies on a loss", () => {
  let streak = 0
  streak = nextStreak(streak, "natural")
  assert.equal(streak, 1)

  streak = nextStreak(streak, "point_made")
  assert.equal(streak, 2)

  // An ordinary point-phase roll is neither.
  streak = nextStreak(streak, "roll")
  assert.equal(streak, 2)

  streak = nextStreak(streak, "point_set")
  assert.equal(streak, 2)

  streak = nextStreak(streak, "seven_out")
  assert.equal(streak, 0)

  streak = nextStreak(streak, "natural")
  streak = nextStreak(streak, "craps")
  assert.equal(streak, 0)
})

test("every draw lands on a real phrase", () => {
  for (const streak of [1, 2, 9]) {
    for (const r of [0, 0.25, 0.5, 0.75, 0.999]) {
      const cheer = galleryCheer("natural", streak, () => r)
      assert.ok(cheerPool(streak).includes(cheer), `${streak} @ ${r} → ${cheer}`)
    }
  }
})
