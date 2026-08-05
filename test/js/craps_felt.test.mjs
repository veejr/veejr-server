// The craps felt's pure surface: which painted region means which bet, and
// the die geometry.
//
// The layout is mirrored onto both ends of the table and the click targets are
// positioned from the same numbers that painted the artwork, so a wrong entry
// here means a player clicks DON'T PASS and backs the pass line. A browser
// check would not catch that; these do.

import {test} from "node:test"
import assert from "node:assert/strict"

import {
  REGION_BET,
  PIP_LAYOUTS,
  PRIMARY_REGION,
  buildCells,
  betTypeFor,
  chipRegionFor,
  isOdds,
  DW,
  DH,
} from "../../assets/js/veejr/craps/felt.js"
import {FACE_UP_EULER} from "../../assets/js/veejr/craps/dice.js"

const CELLS = buildCells()

test("every region resolves to a bet the server takes", () => {
  const known = new Set([
    "pass_line", "dont_pass", "come", "dont_come",
    "place_4", "place_5", "place_6", "place_8", "place_9", "place_10",
    "hard_4", "hard_6", "hard_8", "hard_10",
    "field", "any_seven", "any_craps", "yo", "aces", "ace_deuce", "boxcars",
    "big_6", "big_8",
  ])

  for (const cell of CELLS) {
    assert.ok(cell.betType, `${cell.id} has no bet type`)
    assert.ok(known.has(cell.betType), `${cell.id} maps to unknown ${cell.betType}`)
  }
})

test("a mirrored region is the same bet as the end it mirrors", () => {
  for (const id of Object.keys(REGION_BET)) {
    assert.equal(betTypeFor(`${id}R`), REGION_BET[id], `${id}R drifted from ${id}`)
  }
})

test("both ends of the table carry the same layout", () => {
  const mirrored = CELLS.filter((c) => c.id.endsWith("R"))
  assert.ok(mirrored.length > 0)

  for (const cell of mirrored) {
    const base = CELLS.find((c) => c.id === cell.id.slice(0, -1))
    assert.ok(base, `${cell.id} mirrors nothing`)
    assert.equal(cell.betType, base.betType)
    assert.equal(cell.cw, base.cw)
    assert.equal(cell.ch, base.ch)
  }
})

test("the don't side is not quietly wired to the pass side", () => {
  assert.equal(REGION_BET.pass, "pass_line")
  assert.equal(REGION_BET.dontpass, "dont_pass")
  assert.equal(REGION_BET.come, "come")
  assert.equal(REGION_BET.dontcome, "dont_come")
  assert.equal(betTypeFor("dontpassR"), "dont_pass")
  assert.equal(betTypeFor("dontcomeR"), "dont_come")
})

test("the place numbers land on their own numbers", () => {
  for (const n of [4, 5, 6, 8, 9, 10]) {
    assert.equal(betTypeFor(`place${n}`), `place_${n}`)
    assert.equal(betTypeFor(`place${n}R`), `place_${n}`)
  }
})

test("the horn legs pay the number they show", () => {
  assert.equal(REGION_BET.horn2, "aces")
  assert.equal(REGION_BET.horn3, "ace_deuce")
  assert.equal(REGION_BET.horn11, "yo")
  assert.equal(REGION_BET.horn12, "boxcars")
})

test("every cell stays inside the felt it is painted on", () => {
  for (const cell of CELLS) {
    assert.ok(cell.left >= 0 && cell.left + cell.cw <= DW, `${cell.id} overflows width`)
    assert.ok(cell.top >= 0 && cell.top + cell.ch <= DH, `${cell.id} overflows height`)
  }
})

test("no two regions on the same half overlap", () => {
  const overlaps = (a, b) =>
    a.left < b.left + b.cw &&
    b.left < a.left + a.cw &&
    a.top < b.top + b.ch &&
    b.top < a.top + a.ch

  for (let i = 0; i < CELLS.length; i++) {
    for (let j = i + 1; j < CELLS.length; j++) {
      assert.ok(
        !overlaps(CELLS[i], CELLS[j]),
        `${CELLS[i].id} overlaps ${CELLS[j].id}`,
      )
    }
  }
})

test("every bet a chip can be laid on has a region to lay it on", () => {
  const ids = new Set(CELLS.map((c) => c.id))

  for (const [betType, regionId] of Object.entries(PRIMARY_REGION)) {
    assert.ok(ids.has(regionId), `${betType} points at missing region ${regionId}`)
    assert.equal(betTypeFor(regionId), betType, `${regionId} does not carry ${betType}`)
  }
})

test("a player's chips go to their own end of the table", () => {
  // The two ends are mirrors, so the same bet has a region on each.
  assert.equal(chipRegionFor("pass_line", null, "left"), "pass")
  assert.equal(chipRegionFor("pass_line", null, "right"), "passR")
  assert.equal(chipRegionFor("place_6", null, "left"), "place6")
  assert.equal(chipRegionFor("place_6", null, "right"), "place6R")
})

test("the centre propositions are shared, so they never mirror", () => {
  for (const bet of ["any_seven", "any_craps", "yo", "aces", "hard_8"]) {
    const left = chipRegionFor(bet, null, "left")
    assert.equal(chipRegionFor(bet, null, "right"), left, bet)
    assert.ok(!left.endsWith("R"), `${bet} mirrored when it should not`)
  }
})

test("odds sit on the bet they are backing, not on a box of their own", () => {
  // No felt paints an odds box; the chip goes behind the line bet.
  assert.equal(chipRegionFor("pass_odds", null, "left"), "pass")
  assert.equal(chipRegionFor("dont_pass_odds", null, "left"), "dontpass")
  assert.equal(chipRegionFor("pass_odds", null, "right"), "passR")

  // Come odds ride the number the come bet travelled to.
  assert.equal(chipRegionFor("come_odds", 6, "left"), "place6")
  assert.equal(chipRegionFor("dont_come_odds", 9, "right"), "place9R")
})

test("come odds with nowhere to go are not drawn", () => {
  assert.equal(chipRegionFor("come_odds", null, "left"), null)
})

test("isOdds knows the four odds bets and nothing else", () => {
  for (const bet of ["pass_odds", "dont_pass_odds", "come_odds", "dont_come_odds"]) {
    assert.ok(isOdds(bet), bet)
  }
  for (const bet of ["pass_line", "come", "place_6", "field", "horn"]) {
    assert.equal(isOdds(bet), false, bet)
  }
})

test("pip layouts have the right number of pips", () => {
  for (let face = 1; face <= 6; face++) {
    assert.equal(PIP_LAYOUTS[face].length, face, `face ${face}`)
    assert.equal(new Set(PIP_LAYOUTS[face]).size, face, `face ${face} repeats a cell`)
    for (const cell of PIP_LAYOUTS[face]) {
      assert.ok(cell >= 0 && cell <= 8, `face ${face} pip outside the grid`)
    }
  }
})

test("every die face has a rotation that brings it up", () => {
  for (let face = 1; face <= 6; face++) {
    const euler = FACE_UP_EULER[face]
    assert.ok(Array.isArray(euler) && euler.length === 3, `face ${face}`)
    assert.ok(euler.every(Number.isFinite), `face ${face} has a bad angle`)
  }
})
