// The stickman and his stick.
//
// When a roll has landed and been shown, the stick works the table the way a
// real one does: it rakes the losing bets off the far edge, taps the point
// when one is established, and hooks the dice back toward the shooter. Winning
// bets are paid by hand — extra chips appear beside the stake and the lot is
// pulled in to the players' rail.
//
// All of it is theatre, in the same way the dice are: the server settled every
// bet before any of this runs, and nothing here decides anything. It only makes
// the board's changes legible — why there are fewer chips than a moment ago,
// which number is the point, and that the dice are free to be thrown again.

import {FD} from "./table.js"

// Where raked chips leave the felt: the dealers' edge, away from the players.
const FAR_EDGE = -FD / 2 + 0.12
// Where paid-out chips go: in to the players' rail.
const NEAR_EDGE = FD / 2 + 0.5

// The stick comes in from the right, up and behind the felt.
const REACH = {x: 1, y: 0.55, z: -0.45}
const STICK_LENGTH = 7
const REST_OFFSET = {x: 5, y: 1.7, z: -1.2}

/**
 * How long each chip gets, in milliseconds, so a whole sweep stays brisk.
 *
 * One chip is raked at a comfortable pace; a big board is hurried up to the
 * floor so a table full of losers never holds the game up.
 */
export function sweepSchedule(count, {budget = 2400, max = 700, min = 240} = {}) {
  if (count <= 0) return 0
  return Math.max(min, Math.min(max, budget / count))
}

/** How many extra chips a win is shown as: one stake's worth per chip, up to three. */
export function payoutChipCount(amount, payout) {
  if (!(amount > 0) || !(payout > amount)) return 0
  return Math.min(3, Math.max(1, Math.ceil((payout - amount) / amount)))
}

/** Whether a die has strayed far enough from its rest spot to be worth fetching. */
export function needsFetching(pos, rest, tolerance = 0.6) {
  return Math.hypot(pos.x - rest[0], pos.z - rest[2]) > tolerance
}

export function easeInOut(t) {
  const x = Math.min(1, Math.max(0, t))
  return x < 0.5 ? 2 * x * x : 1 - Math.pow(-2 * x + 2, 2) / 2
}

export function lerp(a, b, t) {
  return a + (b - a) * t
}

// Whether to skip the performance. Honoured here because a stick sweeping
// across the screen is exactly the motion the preference exists to avoid.
function prefersReducedMotion() {
  try {
    return window.matchMedia("(prefers-reduced-motion: reduce)").matches
  } catch (_error) {
    return false
  }
}

function disposeChip(chip) {
  chip.parent?.remove(chip)
  chip.geometry.dispose()
  chip.material.dispose()
}

/** A wooden stick with a curved hook, tip at the group's origin. */
export function createStick(THREE, scene) {
  const wood = new THREE.MeshLambertMaterial({color: 0xc99a52})
  const dark = new THREE.MeshLambertMaterial({color: 0x6b4318})
  const group = new THREE.Group()

  // The shaft runs along +Y from the tip, so orienting the group is one
  // rotation: point +Y back along the reach.
  const shaft = new THREE.Mesh(new THREE.CylinderGeometry(0.13, 0.055, STICK_LENGTH, 12), wood)
  shaft.position.y = STICK_LENGTH / 2
  group.add(shaft)

  const grip = new THREE.Mesh(new THREE.CylinderGeometry(0.16, 0.16, 1.1, 12), dark)
  grip.position.y = STICK_LENGTH - 0.4
  group.add(grip)

  // The hook: a quarter turn of tube that cups the back of a chip.
  const hook = new THREE.Mesh(new THREE.TorusGeometry(0.22, 0.055, 8, 16, Math.PI * 0.85), wood)
  hook.rotation.set(Math.PI / 2, 0, -Math.PI * 0.1)
  group.add(hook)

  const reach = new THREE.Vector3(REACH.x, REACH.y, REACH.z).normalize()
  group.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), reach)
  group.visible = false
  scene.add(group)

  return group
}

/**
 * A chip standing for winnings, laid beside the stake it was won on.
 *
 * Cloned from the stake so it is the same colour — whose money it is should be
 * as clear as whose bet it was.
 */
export function winningsChip(THREE, scene, stake, index) {
  const chip = new THREE.Mesh(stake.geometry.clone(), stake.material.clone())
  chip.position.copy(stake.position)
  chip.position.x += 0.28 * (index + 1)
  chip.userData.isChip = true
  scene.add(chip)
  return chip
}

// ── The timeline ─────────────────────────────────────────────────────────────
//
// Each beat is a promise that resolves true when it finishes and false if the
// performance was cancelled, so a new throw can cut the stick off mid-reach.

function tween(run, ms, step) {
  return new Promise((resolve) => {
    let start = null

    const frame = (now) => {
      if (run.cancelled) return resolve(false)
      if (start === null) start = now

      const t = ms <= 0 ? 1 : Math.min(1, (now - start) / ms)
      step(t)

      if (t >= 1) resolve(true)
      else requestAnimationFrame(frame)
    }

    requestAnimationFrame(frame)
  })
}

const pause = (run, ms) => tween(run, ms, () => {})

function moveTip(run, stick, to, ms, lift = 0.3) {
  const from = stick.position.clone()

  return tween(run, ms, (t) => {
    const e = easeInOut(t)
    stick.position.set(
      lerp(from.x, to.x, e),
      lerp(from.y, to.y, e) + Math.sin(Math.PI * t) * lift,
      lerp(from.z, to.z, e),
    )
  })
}

// Behind a chip, on the side the stick is pulling it away from.
const behind = (pos, dz) => ({x: pos.x, y: pos.y + 0.06, z: pos.z + dz})

async function rake(run, THREE, stick, chips) {
  const per = sweepSchedule(chips.length)

  for (const chip of chips) {
    if (!(await moveTip(run, stick, behind(chip.position, 0.2), per * 0.4))) return false

    const startZ = chip.position.z
    const ok = await tween(run, per * 0.6, (t) => {
      const e = easeInOut(t)
      chip.position.z = lerp(startZ, FAR_EDGE, e)
      // Shrinks over the last stretch, as if dropping into the dealers' box.
      chip.scale.setScalar(Math.max(0.01, t > 0.8 ? 1 - (t - 0.8) / 0.2 : 1))
      stick.position.set(chip.position.x, chip.position.y + 0.06, chip.position.z + 0.2)
    })

    if (!ok) return false
    disposeChip(chip)
  }

  return true
}

// Paid by hand, not by stick: the extra chips sit beside the stake for a beat
// so the win is seen, then everything is drawn in to the players' rail.
async function payOut(run, chips) {
  if (!(await pause(run, 500))) return false

  const starts = chips.map((chip) => chip.position.z)
  const ok = await tween(run, 750, (t) => {
    const e = easeInOut(t)
    chips.forEach((chip, i) => {
      chip.position.z = lerp(starts[i], NEAR_EDGE, e)
      chip.scale.setScalar(Math.max(0.01, t > 0.75 ? 1 - (t - 0.75) / 0.25 : 1))
    })
  })

  if (ok) chips.forEach(disposeChip)
  return ok
}

// Two taps on the number, the way a stickman calls the point.
async function tapPoint(run, stick, pos) {
  if (!(await moveTip(run, stick, {x: pos.x, y: pos.y + 0.8, z: pos.z}, 450))) return false

  for (let i = 0; i < 2; i++) {
    if (!(await tween(run, 150, (t) => (stick.position.y = lerp(pos.y + 0.8, pos.y + 0.18, easeInOut(t)))))) return false
    if (!(await tween(run, 170, (t) => (stick.position.y = lerp(pos.y + 0.18, pos.y + 0.8, easeInOut(t)))))) return false
  }

  return true
}

// Hooks the dice from behind and draws them back to where the shooter picks
// them up. Orientation is left alone — they still show what was rolled.
async function fetchDice(run, stick, dice) {
  const far = Math.min(...dice.map((d) => d.mesh.position.z))
  const mid = dice.reduce((sum, d) => sum + d.mesh.position.x, 0) / dice.length
  const hookZ = far - 0.7

  if (!(await moveTip(run, stick, {x: mid, y: 0.55, z: hookZ}, 450))) return false

  const starts = dice.map((d) => d.mesh.position.clone())
  const startHook = stick.position.clone()

  return tween(run, 800, (t) => {
    const e = easeInOut(t)

    dice.forEach((d, i) => {
      d.mesh.position.x = lerp(starts[i].x, d.rest[0], e)
      d.mesh.position.z = lerp(starts[i].z, d.rest[2], e)
    })

    const centre = dice.reduce((sum, d) => sum + d.mesh.position.z, 0) / dice.length
    stick.position.set(
      lerp(startHook.x, (dice[0].rest[0] + dice[1].rest[0]) / 2, e),
      startHook.y,
      centre - 0.7,
    )
  })
}

/**
 * Works the table after a roll.
 *
 * `act` is what the roll changed:
 *   - `losers`  chips to rake off the far edge (already children of the scene)
 *   - `paid`    chips of winning and pushed bets, with their winnings chips, to
 *               draw in to the players
 *   - `point`   world position of the point number just established, or null
 *   - `dice`    `{mesh, rest}` pairs to hook back to the shooter, or null
 *
 * Returns a function that stops the performance at once and clears every chip
 * it was holding — for a new throw, or the table being torn down mid-act.
 */
export function perform(THREE, stick, act, {onDone} = {}) {
  const losers = act.losers || []
  const paid = act.paid || []
  // Both dice are fetched together if either has strayed from its rest spot.
  const dice =
    act.dice && act.dice.some((d) => needsFetching(d.mesh.position, d.rest)) ? act.dice : null
  const wantsStick = losers.length > 0 || act.point || dice !== null

  const run = {cancelled: false}
  const holding = [...losers, ...paid]

  const clearChips = () => holding.forEach((chip) => chip.parent && disposeChip(chip))

  const snapDice = () => (act.dice || []).forEach((d) => d.mesh.position.set(d.rest[0], d.rest[1], d.rest[2]))

  if (prefersReducedMotion()) {
    clearChips()
    snapDice()
    if (onDone) onDone()
    return () => {}
  }

  const first =
    (losers[0] && losers[0].position) ||
    act.point ||
    (dice && dice[0].mesh.position)

  async function show() {
    // Winners are paid while the stick is busy with the losers.
    const paying = paid.length > 0 ? payOut(run, paid) : Promise.resolve(true)

    if (wantsStick) {
      stick.position.set(first.x + REST_OFFSET.x, REST_OFFSET.y, first.z + REST_OFFSET.z)
      stick.visible = true

      if (losers.length > 0 && !(await rake(run, THREE, stick, losers))) return
      if (act.point && !(await tapPoint(run, stick, act.point))) return
      if (dice && !(await fetchDice(run, stick, dice))) return

      const out = {x: stick.position.x + REST_OFFSET.x, y: REST_OFFSET.y, z: stick.position.z + REST_OFFSET.z}
      if (!(await moveTip(run, stick, out, 380, 0))) return
      stick.visible = false
    }

    if (!(await paying)) return
    if (onDone) onDone()
  }

  show()

  return () => {
    if (run.cancelled) return
    run.cancelled = true
    clearChips()
    stick.visible = false
  }
}
