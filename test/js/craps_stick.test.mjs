import test from "node:test"
import assert from "node:assert/strict"

import {sweepSchedule, easeInOut, lerp} from "../../assets/js/veejr/craps/stick.js"

test("a lone chip is raked at a comfortable pace", () => {
  assert.equal(sweepSchedule(1), 700)
})

test("a crowded board is hurried so the game is not held up", () => {
  const per = sweepSchedule(6)
  assert.ok(per < 700)
  assert.ok(per * 6 <= 2400 + 1)
})

test("but never so fast the stick is a blur", () => {
  assert.equal(sweepSchedule(40), 240)
})

test("nothing to sweep takes no time", () => {
  assert.equal(sweepSchedule(0), 0)
})

test("easing runs from rest to rest and clamps", () => {
  assert.equal(easeInOut(0), 0)
  assert.equal(easeInOut(1), 1)
  assert.equal(easeInOut(0.5), 0.5)
  assert.equal(easeInOut(-1), 0)
  assert.equal(easeInOut(3), 1)
})

test("lerp interpolates", () => {
  assert.equal(lerp(2, 6, 0.25), 3)
})

import {payoutChipCount, needsFetching} from "../../assets/js/veejr/craps/stick.js"

test("a win is shown as a chip of winnings per stake, up to three", () => {
  assert.equal(payoutChipCount(10, 20), 1) // even money
  assert.equal(payoutChipCount(10, 25), 2) // 3:2 odds
  assert.equal(payoutChipCount(10, 100), 3) // a long shot, capped
})

test("nothing is added for a push or a loss", () => {
  assert.equal(payoutChipCount(10, 10), 0)
  assert.equal(payoutChipCount(10, 0), 0)
  assert.equal(payoutChipCount(0, 20), 0)
})

test("dice already by the shooter are left alone", () => {
  const rest = [-1.1, 0.45, 1.6]
  assert.equal(needsFetching({x: -1.0, z: 1.5}, rest), false)
  assert.equal(needsFetching({x: 2, z: -2}, rest), true)
})
