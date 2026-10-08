// Builds the WebGL craps table and keeps it in step with the server.
//
// Everything under craps/ is behind one dynamic import in the hook, so a
// browser that never opens the table downloads none of it and three.min.js is
// fetched only on arrival here.
//
// Bets are placed by dropping a chip on the felt, the way they are at a real
// table. The felt decides nothing: it raycasts to find which painted region
// was tapped and hands the server the bet that region carries. What that bet
// means right now — whether it is legal this phase, whether a chip on your
// own pass line is a new bet or odds behind the old one — was worked out
// server-side and arrives in `actions`.

import {createScene} from "./scene.js"
import {createTable, updatePointPuck, highlightBetArea, clearChips, placeChip, setComePucks} from "./table.js"
import {chipRegionFor, isOdds} from "./felt.js"
import {createDieMesh, setDiceFace, throwDice} from "./dice.js"
import {announce, playBounce, playThrow} from "./audio.js"

export function createCrapsTable(THREE, container, {onBet, onComeOdds, onSettled} = {}) {
  const scene3d = createScene(THREE, container)
  const {scene, camera, pointerNdc, onTap, onHover, setLocked, view, setView, destroy} = scene3d
  const {betMeshes, pointPucks} = createTable(THREE, scene)

  const die1 = createDieMesh(THREE, scene, [-1.1, 0.45, 1.6])
  const die2 = createDieMesh(THREE, scene, [0.1, 0.45, 1.6])

  const raycaster = new THREE.Raycaster()
  const pointer = new THREE.Vector2()

  let state = {phase: "come_out", point: null, seated: false, bets: [], actions: {}}
  let comePucks = []
  let hovered = null
  let shownRoll = null
  let opened = false

  const label = document.createElement("div")
  label.className = "craps-felt-label"
  label.hidden = true
  container.appendChild(label)

  setDiceFace(die1, 1)
  setDiceFace(die2, 2)

  // Whether the camera is pinned is this browser's business, like sound: the
  // button announces it and the preference survives a reload.
  //
  // The view it was pinned at is stored with it. A lock now means "hold this
  // angle", so without the angle a reload would come back locked to a table
  // nobody had framed.
  const LOCK_KEY = "veejr:craps-lock"
  const VIEW_KEY = "veejr:craps-view"

  const onLock = (event) => {
    const on = !!event.detail
    setLocked(on)
    if (!on) return

    try {
      window.localStorage.setItem(VIEW_KEY, JSON.stringify(view()))
    } catch (_error) {
      // Storage can be blocked; the lock still holds for this visit.
    }
  }

  window.addEventListener("veejr:craps-lock", onLock)

  let startLocked = false

  try {
    startLocked = window.localStorage.getItem(LOCK_KEY) === "on"
    // Only when arriving locked: a saved view is part of that lock, not a
    // standing preference for where a free camera should start.
    if (startLocked) setView(JSON.parse(window.localStorage.getItem(VIEW_KEY) || "null"))
  } catch (_error) {
    // Storage can be blocked, or hold something that is not a view. The lock
    // is still applied below; only the angle falls back to the default.
  }

  setLocked(startLocked)

  function pick(event) {
    raycaster.setFromCamera(pointerNdc(event, pointer), camera)

    // Come markers sit on top of the regions, so they get first refusal.
    const onPuck = raycaster.intersectObjects(comePucks, false)[0]
    if (onPuck) return {kind: "come_odds", object: onPuck.object}

    const onRegion = raycaster.intersectObjects(betMeshes, false)[0]
    if (onRegion) return {kind: "region", object: onRegion.object}

    return null
  }

  function actionFor(hit) {
    if (!hit) return null
    if (hit.kind === "come_odds") {
      const {comeTarget, comeType} = hit.object.userData
      const base = comeType === "come" ? "Come odds" : "Don't come odds"
      return {enabled: true, label: `${base} on ${comeTarget}`}
    }
    return state.actions[hit.object.userData.betType] || null
  }

  function clearHover() {
    if (hovered) highlightBetArea(hovered, false)
    hovered = null
    label.hidden = true
  }

  onHover((event) => {
    if (!state.seated) return clearHover()

    const hit = pick(event)
    const action = actionFor(hit)

    if (!hit || !action) return clearHover()

    const target = hit.kind === "region" ? hit.object : hit.object.parent
    if (hovered !== target) {
      if (hovered) highlightBetArea(hovered, false)
      hovered = target
      highlightBetArea(hovered, true)
    }

    const rect = container.getBoundingClientRect()
    label.textContent = action.label
    label.dataset.enabled = action.enabled ? "true" : "false"
    label.style.left = `${event.clientX - rect.left}px`
    label.style.top = `${event.clientY - rect.top}px`
    label.hidden = false
  })

  onTap((event) => {
    if (!state.seated) return

    const hit = pick(event)
    const action = actionFor(hit)
    if (!hit || !action || !action.enabled) return

    if (hit.kind === "come_odds") {
      const {comeTarget, comeType} = hit.object.userData
      if (onComeOdds) onComeOdds(comeTarget, comeType)
    } else if (action.bet && onBet) {
      // A number box holding your come bet carries the number its odds ride on.
      onBet(action.bet, action.target ?? null)
    }
  })

  // Every player's chips, one per bet, laid at the station its owner works.
  // Nothing is stacked: a heap on a square tells you money is there but not
  // whose or how much of it is yours.
  function drawBets() {
    clearChips(betMeshes)

    const byId = new Map(betMeshes.map((m) => [m.userData.regionId, m]))
    // Two bets of the same kind from the same player would otherwise land on
    // top of one another.
    const seen = new Map()

    for (const bet of state.bets) {
      const side = bet.side || "left"
      const slot = bet.slot || 0

      const mesh = byId.get(chipRegionFor(bet.type, bet.target, side) || "")
      if (!mesh) continue

      // Odds sit behind the bet they back, so they are a row of their own.
      const key = `${mesh.userData.regionId}:${slot}:${isOdds(bet.type)}`
      const stagger = seen.get(key) || 0
      seen.set(key, stagger + 1)

      placeChip(THREE, mesh, {mine: !!bet.mine, slot, odds: isOdds(bet.type), stagger})
    }
  }

  return {
    update(next) {
      state = {...state, ...next, actions: next.actions || {}, bets: next.bets || []}

      for (const puck of pointPucks) {
        updatePointPuck(puck, state.phase, state.point, betMeshes)
      }

      drawBets()
      comePucks = setComePucks(THREE, betMeshes, state.bets)
      if (!state.seated) clearHover()

      const roll = state.last_roll

      // The very first update is the baseline, not an event. Whatever is on
      // the felt when the page opens is already at rest — but every roll
      // after that has to be thrown, so this cannot be inferred from there
      // simply being no roll yet.
      if (!opened) {
        opened = true
        if (roll) {
          // Already at rest, and nothing is being held back for it — the page
          // has only just rendered this state. No need to report it.
          shownRoll = String(roll.id)
          setDiceFace(die1, roll.die1)
          setDiceFace(die2, roll.die2)
        }
        return
      }

      if (!roll) return

      // A re-render caused by somebody else's bet must not re-throw the dice.
      if (String(roll.id) === shownRoll) return

      shownRoll = String(roll.id)

      // Nothing about the outcome is on screen until this resolves — the
      // server is holding the total, the payouts and the puck until told the
      // dice have stopped.
      playThrow()
      throwDice(THREE, die1, die2, roll.die1, roll.die2, playBounce).then(() => {
        // The croupier's call is part of the outcome, so it belongs here with
        // the reveal and nowhere earlier. Keep these two together.
        announce(roll.event, roll.total)
        if (onSettled) onSettled(roll.id)
      })
    },

    destroy() {
      window.removeEventListener("veejr:craps-lock", onLock)
      label.remove()
      destroy()
    },
  }
}
