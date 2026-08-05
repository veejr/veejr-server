// The physical table: wooden rim, padded rails, felt, oval back end with
// pyramid bumpers, chip rail, and the dealer pucks.
//
// Also builds one invisible box per betting region, positioned from the same
// design-space coordinates that painted the artwork. Those are what slice two
// will raycast against so a player can bet by clicking the felt itself.

import {DW, DH, buildCells, buildFeltTexture, buildPyramidTexture} from "./felt.js"

const TABLE_WOOD = 0x3d2005
const RAIL_PAD = 0x7a5a14
const BET_HOVER = 0xffcc00

export const FW = 16
export const FD = (FW * DH) / DW
const FRONT_EXT = FD * 0.1

function createPointPuck(THREE, group, side) {
  const face = (label, bg, fg) => {
    const c = document.createElement("canvas")
    c.width = c.height = 128
    const x = c.getContext("2d")
    x.fillStyle = bg
    x.beginPath()
    x.arc(64, 64, 62, 0, Math.PI * 2)
    x.fill()
    x.strokeStyle = fg
    x.lineWidth = 7
    x.beginPath()
    x.arc(64, 64, 51, 0, Math.PI * 2)
    x.stroke()
    x.fillStyle = fg
    x.textAlign = "center"
    x.textBaseline = "middle"
    x.font = `700 ${label.length > 2 ? 36 : 46}px 'Oswald', system-ui, sans-serif`
    x.fillText(label, 64, 68)
    const t = new THREE.CanvasTexture(c)
    t.anisotropy = 8
    return t
  }

  const onTex = face("ON", "#f5f2e9", "#0b5d3b")
  const offTex = face("OFF", "#141414", "#e8e8e8")
  const sideMat = new THREE.MeshLambertMaterial({color: 0x141414})
  const geo = new THREE.CylinderGeometry(0.34, 0.34, 0.12, 40)
  const puck = new THREE.Mesh(geo, [
    sideMat,
    new THREE.MeshBasicMaterial({map: offTex}),
    new THREE.MeshLambertMaterial({color: 0x141414}),
  ])
  const rest =
    side === "R"
      ? {x: FW / 2 - 1.0, z: -FD / 2 + 0.75}
      : {x: -FW / 2 + 1.0, z: -FD / 2 + 0.75}
  puck.userData = {onTex, offTex, sideMat, side, rest}
  puck.position.set(rest.x, 0.17, rest.z)
  group.add(puck)
  return puck
}

export function createTable(THREE, scene) {
  const cells = buildCells()
  const group = new THREE.Group()

  const rimMat = new THREE.MeshLambertMaterial({color: TABLE_WOOD})
  const rim = new THREE.Mesh(new THREE.BoxGeometry(FW + 3.0, 0.85, FD + 1.0), rimMat)
  rim.position.set(0, -0.42, 0.8)
  group.add(rim)

  const bedMat = new THREE.MeshLambertMaterial({color: 0x081208})
  const bed = new THREE.Mesh(
    new THREE.BoxGeometry(FW + 0.6, 0.25, FD + 0.6 + FRONT_EXT),
    bedMat,
  )
  bed.position.set(0, -0.08, FRONT_EXT / 2)
  group.add(bed)

  const padMat = new THREE.MeshLambertMaterial({color: RAIL_PAD})
  const padW = 0.55
  const railLen = FD - 0.2 + FRONT_EXT
  const rails = [
    [FW + 1.2, padW, 0, FD / 2 + padW / 2 + 0.05 + FRONT_EXT],
    [padW, railLen, -(FW / 2 + padW / 2 + 0.05), 0.4 + FRONT_EXT / 2],
    [padW, railLen, FW / 2 + padW / 2 + 0.05, 0.4 + FRONT_EXT / 2],
  ]
  for (const [w, d, px, pz] of rails) {
    const m = new THREE.Mesh(new THREE.BoxGeometry(w, 0.28, d), padMat)
    m.position.set(px, 0.18, pz)
    group.add(m)
  }

  const feltTex = buildFeltTexture(THREE, cells)
  feltTex.anisotropy = 16
  const felt = new THREE.Mesh(
    new THREE.PlaneGeometry(FW, FD),
    new THREE.MeshBasicMaterial({map: feltTex}),
  )
  felt.rotation.x = -Math.PI / 2
  felt.position.y = 0.05
  felt.receiveShadow = true
  group.add(felt)

  // ── Oval back end ─────────────────────────────────────────────────────────
  const wallH = 1.8
  const bumperH = 0.55
  const ovalHalfW = FW / 2 + 0.5
  const ovalDepth = 2.5

  const makeOvalMesh = (geo, mat, scaleX, scaleZ, yPos) => {
    const m = new THREE.Mesh(geo, mat)
    m.scale.set(scaleX, 1, scaleZ)
    m.position.set(0, yPos, -FD / 2)
    return m
  }

  const ovalRimGeo = new THREE.CylinderGeometry(1, 1, 0.85, 64, 1, false, Math.PI / 2, Math.PI)
  group.add(
    makeOvalMesh(ovalRimGeo, new THREE.MeshLambertMaterial({color: TABLE_WOOD}), ovalHalfW + 1.0, ovalDepth + 0.8, -0.42),
  )

  const ovalPadGeo = new THREE.CylinderGeometry(1, 1, 0.28, 64, 1, false, Math.PI / 2, Math.PI)
  group.add(makeOvalMesh(ovalPadGeo, padMat, ovalHalfW + 0.3, ovalDepth + 0.3, 0.18))

  const pyramidTex = buildPyramidTexture(THREE, (Math.PI * (ovalHalfW + ovalDepth)) / 2, wallH)
  const ovalWallGeo = new THREE.CylinderGeometry(1, 1, wallH, 64, 1, true, Math.PI / 2, Math.PI)
  group.add(
    makeOvalMesh(
      ovalWallGeo,
      new THREE.MeshBasicMaterial({map: pyramidTex, side: THREE.DoubleSide}),
      ovalHalfW,
      ovalDepth,
      wallH / 2,
    ),
  )

  // ── Interior bumper walls ─────────────────────────────────────────────────
  const darkMat = new THREE.MeshLambertMaterial({color: 0x0f2010})
  const woodTopM = new THREE.MeshLambertMaterial({color: TABLE_WOOD})
  const THICK = 0.55

  const bumperBox = (w, h, d, innerFace, px, py, pz) => {
    const innerMat = new THREE.MeshBasicMaterial({
      map: buildPyramidTexture(THREE, Math.max(w, d), h),
    })
    const mats = [darkMat, darkMat, woodTopM, darkMat, darkMat, darkMat]
    mats[innerFace] = innerMat
    const mesh = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), mats)
    mesh.position.set(px, py, pz)
    group.add(mesh)
  }

  bumperBox(THICK, bumperH, FD + FRONT_EXT, 0, -FW / 2 + THICK / 2, bumperH / 2, FRONT_EXT / 2)
  bumperBox(THICK, bumperH, FD + FRONT_EXT, 1, FW / 2 - THICK / 2, bumperH / 2, FRONT_EXT / 2)
  bumperBox(FW, bumperH, THICK, 5, 0, bumperH / 2, FD / 2 - THICK / 2 + FRONT_EXT)

  // ── Chip rail ─────────────────────────────────────────────────────────────
  const chipRailMat = new THREE.MeshLambertMaterial({color: 0x140804})
  const chipRailY = 0.34

  const frontCR = new THREE.Mesh(new THREE.BoxGeometry(FW + 1.2, 0.07, 0.72), chipRailMat)
  frontCR.position.set(0, chipRailY, FD / 2 + 1.15 + FRONT_EXT)
  group.add(frontCR)

  for (const xOff of [-(FW / 2 + 1.15), FW / 2 + 1.15]) {
    const sideCR = new THREE.Mesh(
      new THREE.BoxGeometry(0.72, 0.07, FD + 0.2 + FRONT_EXT),
      chipRailMat,
    )
    sideCR.position.set(xOff, chipRailY, FRONT_EXT / 2)
    group.add(sideCR)
  }

  const chipColors = [0xff2222, 0x22aa44, 0x1144cc, 0xdddddd, 0x222222, 0xff8800]
  for (let i = -5; i <= 5; i++) {
    const chipMat = new THREE.MeshLambertMaterial({
      color: chipColors[Math.abs(i) % chipColors.length],
    })
    const stackHeight = 4 + Math.floor(Math.abs(i * 0.7 + 1))
    for (let s = 0; s < stackHeight; s++) {
      const cm = new THREE.Mesh(new THREE.CylinderGeometry(0.2, 0.2, 0.07, 16), chipMat)
      cm.position.set(i * 1.3, chipRailY + 0.05 + s * 0.075, FD / 2 + 1.15 + FRONT_EXT)
      group.add(cm)
    }
  }

  // ── Click targets, aligned to the painted artwork ─────────────────────────
  // Design canvas to world: x = (u - 0.5) * FW, z = (v - 0.5) * FD.
  const betMeshes = []
  for (const c of cells) {
    const u = (c.left + c.cw / 2) / DW
    const v = (c.top + c.ch / 2) / DH
    const mesh = new THREE.Mesh(
      new THREE.BoxGeometry((c.cw / DW) * FW, 0.06, (c.ch / DH) * FD),
      new THREE.MeshBasicMaterial({
        color: BET_HOVER,
        transparent: true,
        opacity: 0,
        depthWrite: false,
      }),
    )
    mesh.position.set((u - 0.5) * FW, 0.09, (v - 0.5) * FD)
    mesh.userData = {regionId: c.id, betType: c.betType}
    group.add(mesh)
    betMeshes.push(mesh)
  }

  const pointPucks = [createPointPuck(THREE, group, "L"), createPointPuck(THREE, group, "R")]

  group.position.z = -0.9
  scene.add(group)
  return {group, betMeshes, pointPucks}
}

export function highlightBetArea(mesh, on) {
  mesh.material.opacity = on ? 0.3 : 0
}

const MY_CHIP = 0xffd700
const THEIR_CHIPS = [0xd94f4f, 0x4f7fd9, 0x4fbf72, 0xdd8a3a, 0xb9b9c4]

export function clearChips(betMeshes) {
  for (const mesh of betMeshes) {
    mesh.children
      .filter((c) => c.userData.isChip)
      .forEach((c) => {
        c.geometry.dispose()
        c.material.dispose()
        mesh.remove(c)
      })
  }
}

// One chip, laid where its owner would reach to put it.
//
// Players are spread across the width of the region by their slot so nobody's
// money lands on anybody else's, and odds are set back from the front edge —
// behind the bet they are backing, the way they sit on a real layout.
export function placeChip(THREE, mesh, {mine, slot, odds, stagger = 0}) {
  const width = mesh.geometry.parameters.width
  const depth = mesh.geometry.parameters.depth

  // Four stations across a region is as many as stays legible.
  const lane = Math.min(slot, 3)
  const laneWidth = width / 4.4
  const x = (lane - 1.5) * laneWidth + stagger * 0.045

  // The front edge of a region is the one nearest the players, so a chip sits
  // there and its odds sit behind it, further from the middle of the felt.
  const front = depth * 0.22
  const z = odds ? front + depth * 0.3 : front

  const chip = new THREE.Mesh(
    new THREE.CylinderGeometry(0.12, 0.12, 0.055, 20),
    new THREE.MeshLambertMaterial({
      color: mine ? MY_CHIP : THEIR_CHIPS[slot % THEIR_CHIPS.length],
    }),
  )
  chip.position.set(x, 0.11, z)
  chip.userData.isChip = true
  mesh.add(chip)
  return chip
}

// A marker on the number a come bet travelled to. It is also the thing you
// drop a chip on to lay odds on that bet, so it is returned for raycasting.
export function setComePucks(THREE, betMeshes, bets) {
  const clickable = []

  for (const mesh of betMeshes) {
    mesh.children
      .filter((c) => c.userData.isPuck)
      .forEach((c) => {
        c.geometry.dispose()
        c.material.dispose()
        mesh.remove(c)
      })
  }

  for (const bet of bets) {
    if (!bet.target) continue
    if (bet.type !== "come" && bet.type !== "dont_come") continue

    // On the owner's own half, like their chips.
    const regionId = bet.side === "right" ? `place${bet.target}R` : `place${bet.target}`
    const mesh = betMeshes.find((m) => m.userData.regionId === regionId)
    if (!mesh) continue

    const existing = mesh.children.filter((c) => c.userData.isPuck)
    if (existing.length >= 3) continue

    const puck = new THREE.Mesh(
      new THREE.CylinderGeometry(0.1, 0.1, 0.05, 16),
      new THREE.MeshLambertMaterial({
        color: bet.type === "come" ? 0xf0f0f0 : 0x8b0000,
      }),
    )
    puck.position.set(-0.15 + existing.length * 0.14, 0.2, -0.12)
    puck.userData = {isPuck: true, comeTarget: bet.target, comeType: bet.type, mine: !!bet.mine}
    mesh.add(puck)

    // Everyone's come points are drawn, but only your own take your odds.
    if (bet.mine) clickable.push(puck)
  }

  return clickable
}

// The dealer puck sits OFF at its resting spot on the come-out and moves ON to
// the point number on its own half of the layout once one is established.
export function updatePointPuck(puck, phase, point, betMeshes) {
  if (!puck) return
  const on = phase === "point" && !!point
  puck.material[1].map = on ? puck.userData.onTex : puck.userData.offTex
  puck.material[1].needsUpdate = true
  puck.userData.sideMat.color.set(on ? 0xf5f2e9 : 0x141414)
  if (on) {
    const rid = puck.userData.side === "R" ? `place${point}R` : `place${point}`
    const box = betMeshes.find((b) => b.userData.regionId === rid)
    if (box) puck.position.set(box.position.x, 0.17, box.position.z - 0.26)
  } else {
    const {rest} = puck.userData
    puck.position.set(rest.x, 0.17, rest.z)
  }
}
