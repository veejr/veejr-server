// The felt: an authentic double-layout craps board drawn to a canvas and
// used as a texture.
//
// The board is laid out in a fixed 2400x864 design space and scaled to the
// felt mesh, so every cell's position is known in normalised coordinates.
// That is what lets the invisible click targets in table.js line up exactly
// with the painted artwork without either being measured from the other.

const LINE = "rgba(248,244,232,0.92)"
const GOLD = "#f4c542"
const FELT_GRADIENT = ["#0f7a4d", "#0b5d3b", "#084a30"]

// Design canvas. The 25:9 aspect is what makes it read as a real craps table
// rather than a square board.
export const DW = 2400
export const DH = 864

const S = 1.6
const OFFX = 48
const OFFY = 32

// Region id to the bet the server knows. A mirrored "...R" region is the same
// bet as its base: both ends of a real table take identical action.
export const REGION_BET = {
  place4: "place_4",
  place5: "place_5",
  place6: "place_6",
  place8: "place_8",
  place9: "place_9",
  place10: "place_10",
  dontcome: "dont_come",
  come: "come",
  field: "field",
  dontpass: "dont_pass",
  pass: "pass_line",
  big6: "big_6",
  big8: "big_8",
  seven: "any_seven",
  anycraps: "any_craps",
  horn2: "aces",
  horn12: "boxcars",
  horn3: "ace_deuce",
  horn11: "yo",
  hard4: "hard_4",
  hard10: "hard_10",
  hard6: "hard_6",
  hard8: "hard_8",
  eleven: "yo",
  craps: "any_craps",
  elevenB: "yo",
  crapsB: "any_craps",
}

export function betTypeFor(regionId) {
  const base = regionId.endsWith("R") ? regionId.slice(0, -1) : regionId
  return REGION_BET[base]
}

// Where a chip for each bet belongs. Several regions can carry the same bet —
// yo is painted as a horn leg and twice more as an "E" — so this names the
// one a chip actually goes on.
export const PRIMARY_REGION = {
  pass_line: "pass",
  dont_pass: "dontpass",
  come: "come",
  dont_come: "dontcome",
  field: "field",
  big_6: "big6",
  big_8: "big8",
  place_4: "place4",
  place_5: "place5",
  place_6: "place6",
  place_8: "place8",
  place_9: "place9",
  place_10: "place10",
  hard_4: "hard4",
  hard_6: "hard6",
  hard_8: "hard8",
  hard_10: "hard10",
  any_seven: "seven",
  any_craps: "anycraps",
  aces: "horn2",
  ace_deuce: "horn3",
  yo: "horn11",
  boxcars: "horn12",
}

// Odds are never painted on a felt — they are laid behind the bet they back.
// This says which bet that is; a come-odds bet finds its number instead.
export const ODDS_BEHIND = {
  pass_odds: "pass_line",
  dont_pass_odds: "dont_pass",
}

export function isOdds(betType) {
  return (
    betType === "pass_odds" ||
    betType === "dont_pass_odds" ||
    betType === "come_odds" ||
    betType === "dont_come_odds"
  )
}

// The region a bet's chip sits on, for a player working the given side.
// A horn has no region of its own and is handled by the caller.
export function chipRegionFor(betType, target, side) {
  let base

  if (betType === "come_odds" || betType === "dont_come_odds") {
    base = target ? `place${target}` : null
  } else if (ODDS_BEHIND[betType]) {
    base = PRIMARY_REGION[ODDS_BEHIND[betType]]
  } else {
    base = PRIMARY_REGION[betType] || null
  }

  if (!base) return null

  // Only the two ends of the layout are mirrored; the centre proposition
  // cluster is shared and has no right-hand twin.
  return side === "right" && MIRRORED.has(base) ? `${base}R` : base
}

const MIRRORED = new Set([
  "place4", "place5", "place6", "place8", "place9", "place10",
  "dontcome", "come", "field", "dontpass", "pass", "big6", "big8",
])

export function buildCells() {
  const cells = []
  const mk = (id, x, y, w, h, label, sub, opt = {}) =>
    cells.push({id, x, y, w, h, label, sub, opt})

  const pn = [[4, "4"], [5, "5"], [6, "SIX"], [8, "8"], [9, "NINE"], [10, "10"]]
  pn.forEach((p, i) =>
    mk("place" + p[0], 24 + i * 85, 16, 81, 98, p[1], "", {ls: 34, lw: 700}),
  )
  mk("dontcome", 24, 120, 81, 150, "DON'T COME", "BAR", {ls: 15, lw: 600})
  mk("come", 109, 120, 425, 150, "COME", "", {ls: 42, lw: 700})
  mk("field", 24, 280, 510, 58, "FIELD", "2 · 3 · 4 · 9 · 10 · 11 · 12", {
    ls: 20, ss: 12, bc: GOLD, fg: GOLD, lw: 700,
  })
  mk("dontpass", 24, 346, 510, 28, "DON'T PASS BAR", "", {ls: 14, lw: 600})
  mk("pass", 24, 380, 510, 42, "PASS LINE", "", {ls: 25, lw: 700, bc: GOLD, fg: GOLD})
  mk("big6", 24, 430, 78, 44, "BIG 6", "", {ls: 15, lw: 700})
  mk("big8", 106, 430, 78, 44, "BIG 8", "", {ls: 15, lw: 700})

  // Mirror that half onto the far end of the table.
  cells.slice().forEach((c) => {
    mk(c.id + "R", 1440 - c.x - c.w, c.y, c.w, c.h, c.label, c.sub, c.opt)
  })

  // The centre proposition cluster belongs to the whole table, not one end.
  mk("seven", 558, 18, 324, 40, "SEVEN", "4 TO 1", {ls: 22, lw: 700, bc: GOLD, fg: GOLD, round: 6})
  mk("anycraps", 558, 392, 324, 40, "ANY CRAPS", "7 TO 1", {ls: 20, lw: 700, round: 6})
  mk("horn2", 566, 66, 64, 52, "", "2 · 30:1", {graphic: {a: 1, b: 1, size: 27}, ss: 10, round: 6})
  mk("horn12", 810, 66, 64, 52, "", "12 · 30:1", {graphic: {a: 6, b: 6, size: 27}, ss: 10, round: 6})
  mk("horn3", 566, 322, 64, 52, "", "3 · 15:1", {graphic: {a: 1, b: 2, size: 27}, ss: 10, round: 6})
  mk("horn11", 810, 322, 64, 52, "", "11 · 15:1", {graphic: {a: 5, b: 6, size: 27}, ss: 10, round: 6})
  mk("hard4", 624, 148, 86, 68, "HARD 4", "7 : 1", {graphic: {a: 2, b: 2, size: 30}, ss: 11, ls: 12, lw: 600, round: 6})
  mk("hard10", 718, 148, 86, 68, "HARD 10", "7 : 1", {graphic: {a: 5, b: 5, size: 30}, ss: 11, ls: 12, lw: 600, round: 6})
  mk("hard6", 624, 226, 86, 68, "HARD 6", "9 : 1", {graphic: {a: 3, b: 3, size: 30}, ss: 11, ls: 12, lw: 600, round: 6})
  mk("hard8", 718, 226, 86, 68, "HARD 8", "9 : 1", {graphic: {a: 4, b: 4, size: 30}, ss: 11, ls: 12, lw: 600, round: 6})
  mk("eleven", 586, 150, 30, 30, "E", "", {ls: 15, lw: 700, round: 99, bc: GOLD, fg: GOLD})
  mk("craps", 824, 150, 30, 30, "C", "", {ls: 15, lw: 700, round: 99})
  mk("elevenB", 586, 254, 30, 30, "E", "", {ls: 15, lw: 700, round: 99, bc: GOLD, fg: GOLD})
  mk("crapsB", 824, 254, 30, 30, "C", "", {ls: 15, lw: 700, round: 99})

  return cells.map((c) => ({
    ...c,
    betType: betTypeFor(c.id),
    left: OFFX + c.x * S,
    top: OFFY + c.y * S,
    cw: c.w * S,
    ch: c.h * S,
  }))
}

function rrPath(ctx, x, y, w, h, r) {
  r = Math.min(r, w / 2, h / 2)
  ctx.beginPath()
  if (ctx.roundRect) {
    ctx.roundRect(x, y, w, h, r)
    return
  }
  ctx.moveTo(x + r, y)
  ctx.arcTo(x + w, y, x + w, y + h, r)
  ctx.arcTo(x + w, y + h, x, y + h, r)
  ctx.arcTo(x, y + h, x, y, r)
  ctx.arcTo(x, y, x + w, y, r)
  ctx.closePath()
}

// Pip cell indices for a die face on a 3x3 grid.
export const PIP_LAYOUTS = {
  1: [4],
  2: [0, 8],
  3: [0, 4, 8],
  4: [0, 2, 6, 8],
  5: [0, 2, 4, 6, 8],
  6: [0, 2, 3, 5, 6, 8],
}

function drawPip(ctx, cx, cy, face, size) {
  const set = new Set(PIP_LAYOUTS[face] || [])
  const pad = size * 0.1
  const cell = (size - 2 * pad) / 3
  const dot = size * 0.165
  ctx.fillStyle = "#f7f5ee"
  rrPath(ctx, cx - size / 2, cy - size / 2, size, size, size * 0.16)
  ctx.fill()
  ctx.fillStyle = "#1a1a1a"
  for (let i = 0; i < 9; i++) {
    if (!set.has(i)) continue
    const dx = cx - size / 2 + pad + cell * ((i % 3) + 0.5)
    const dy = cy - size / 2 + pad + cell * (Math.floor(i / 3) + 0.5)
    ctx.beginPath()
    ctx.arc(dx, dy, dot / 2, 0, Math.PI * 2)
    ctx.fill()
  }
}

function drawDicePair(ctx, cx, cy, a, b, size) {
  const gap = 4
  drawPip(ctx, cx - (size + gap) / 2, cy, a, size)
  drawPip(ctx, cx + (size + gap) / 2, cy, b, size)
}

function drawCell(ctx, c) {
  const {left, top, cw, ch, opt} = c
  const cx = left + cw / 2

  // Border only: the felt shows through, as it does on a real layout.
  ctx.strokeStyle = opt.bc || LINE
  ctx.lineWidth = 2 * S
  rrPath(ctx, left, top, cw, ch, (opt.round || 4) * S)
  ctx.stroke()

  const labelPx = (opt.ls || 16) * S
  const subPx = (opt.ss || 9) * S
  const items = []
  if (opt.graphic) items.push({t: "g", h: opt.graphic.size})
  if (c.label) items.push({t: "l", h: labelPx})
  if (c.sub) items.push({t: "s", h: subPx})
  const gap = 3
  const total = items.reduce((s, it) => s + it.h, 0) + gap * Math.max(0, items.length - 1)
  let y = top + ch / 2 - total / 2

  ctx.textAlign = "center"
  ctx.textBaseline = "middle"
  for (const it of items) {
    const midY = y + it.h / 2
    if (it.t === "g") {
      drawDicePair(ctx, cx, midY, opt.graphic.a, opt.graphic.b, opt.graphic.size)
    } else if (it.t === "l") {
      ctx.fillStyle = opt.fg || LINE
      ctx.font = `${opt.lw || 600} ${labelPx}px 'Oswald', system-ui, sans-serif`
      if ("letterSpacing" in ctx) ctx.letterSpacing = `${0.5 * S}px`
      ctx.fillText(c.label.toUpperCase(), cx, midY)
      if ("letterSpacing" in ctx) ctx.letterSpacing = "0px"
    } else {
      ctx.fillStyle = opt.fg || LINE
      ctx.globalAlpha = 0.82
      ctx.font = `500 ${subPx}px 'Oswald', system-ui, sans-serif`
      ctx.fillText(c.sub.toUpperCase(), cx, midY)
      ctx.globalAlpha = 1
    }
    y += it.h + gap
  }
}

function noisePattern(ctx) {
  const n = document.createElement("canvas")
  n.width = n.height = 140
  const nc = n.getContext("2d")
  const img = nc.createImageData(140, 140)
  for (let i = 0; i < img.data.length; i += 4) {
    const v = (Math.random() * 255) | 0
    img.data[i] = img.data[i + 1] = img.data[i + 2] = v
    img.data[i + 3] = 255
  }
  nc.putImageData(img, 0, 0)
  return ctx.createPattern(n, "repeat")
}

function drawFelt(ctx, cells) {
  ctx.clearRect(0, 0, DW, DH)

  const g = ctx.createRadialGradient(DW / 2, DH * 0.35, 0, DW / 2, DH * 0.35, DW * 0.72)
  g.addColorStop(0, FELT_GRADIENT[0])
  g.addColorStop(0.55, FELT_GRADIENT[1])
  g.addColorStop(1, FELT_GRADIENT[2])
  ctx.fillStyle = g
  ctx.fillRect(0, 0, DW, DH)

  // A little grain, so the felt does not read as flat plastic.
  ctx.save()
  ctx.globalAlpha = 0.05
  ctx.fillStyle = noisePattern(ctx)
  ctx.fillRect(0, 0, DW, DH)
  ctx.restore()

  ctx.strokeStyle = "rgba(244,197,66,0.5)"
  ctx.lineWidth = 3
  rrPath(ctx, 20, 20, DW - 40, DH - 40, 60)
  ctx.stroke()

  ctx.strokeStyle = GOLD
  ctx.lineWidth = 5
  rrPath(ctx, OFFX + 877, OFFY + 13, 550, 694, 22)
  ctx.stroke()

  for (const c of cells) drawCell(ctx, c)
}

export function buildFeltTexture(THREE, cells) {
  const RES = 2
  const canvas = document.createElement("canvas")
  canvas.width = DW * RES
  canvas.height = DH * RES
  const ctx = canvas.getContext("2d")
  ctx.scale(RES, RES)

  const tex = new THREE.CanvasTexture(canvas)
  const paint = () => {
    drawFelt(ctx, cells)
    tex.needsUpdate = true
  }
  paint()

  // Canvas cannot wait on a webfont, so repaint once Oswald has arrived.
  if (document.fonts && document.fonts.load) {
    Promise.all([
      document.fonts.load("700 40px 'Oswald'"),
      document.fonts.load("500 20px 'Oswald'"),
    ])
      .then(paint)
      .catch(() => {})
  }
  return tex
}

export function buildPyramidTexture(THREE, wallW, wallH) {
  const T = 32
  const H = T / 2
  const tile = document.createElement("canvas")
  tile.width = tile.height = T
  const tc = tile.getContext("2d")
  const faces = [
    {pts: [[0, 0], [T, 0], [H, H]], color: "#4a6b50"},
    {pts: [[T, 0], [T, T], [H, H]], color: "#3a5540"},
    {pts: [[T, T], [0, T], [H, H]], color: "#2a3d2e"},
    {pts: [[0, T], [0, 0], [H, H]], color: "#3e5944"},
  ]
  for (const f of faces) {
    tc.fillStyle = f.color
    tc.beginPath()
    tc.moveTo(...f.pts[0])
    tc.lineTo(...f.pts[1])
    tc.lineTo(...f.pts[2])
    tc.closePath()
    tc.fill()
  }
  tc.strokeStyle = "#1e2820"
  tc.lineWidth = 0.8
  tc.beginPath()
  tc.moveTo(H, H); tc.lineTo(0, 0)
  tc.moveTo(H, H); tc.lineTo(T, 0)
  tc.moveTo(H, H); tc.lineTo(T, T)
  tc.moveTo(H, H); tc.lineTo(0, T)
  tc.stroke()
  const tex = new THREE.CanvasTexture(tile)
  tex.wrapS = tex.wrapT = THREE.RepeatWrapping
  tex.repeat.set(wallW / 0.22, wallH / 0.22)
  return tex
}
