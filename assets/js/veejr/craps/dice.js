// The dice: meshes with canvas pip textures, and the throw.
//
// The server has already decided the faces before this runs. The physics here
// is theatre — it tumbles the dice convincingly and then steers them onto the
// predetermined result, so the animation can never contradict the outcome.

// Standard die: opposite faces sum to seven. BoxGeometry material slots run
// +X, -X, +Y, -Y, +Z, -Z, so these pip counts put 1 on +Y with no rotation.
const FACE_NUMBERS = [3, 4, 1, 6, 5, 2]

// Euler rotation that turns a given face upward.
export const FACE_UP_EULER = {
  1: [0, 0, 0],
  2: [Math.PI / 2, 0, 0],
  3: [0, 0, Math.PI / 2],
  4: [0, 0, -Math.PI / 2],
  5: [-Math.PI / 2, 0, 0],
  6: [Math.PI, 0, 0],
}

const L = 0.28, R = 0.72, T = 0.28, M = 0.5, B = 0.72
const PIP_LAYOUTS = {
  1: [[M, M]],
  2: [[R, T], [L, B]],
  3: [[R, T], [M, M], [L, B]],
  4: [[L, T], [R, T], [L, B], [R, B]],
  5: [[L, T], [R, T], [M, M], [L, B], [R, B]],
  6: [[L, T], [R, T], [L, M], [R, M], [L, B], [R, B]],
}

function roundedRect(ctx, x, y, w, h, r) {
  ctx.beginPath()
  ctx.moveTo(x + r, y)
  ctx.lineTo(x + w - r, y)
  ctx.quadraticCurveTo(x + w, y, x + w, y + r)
  ctx.lineTo(x + w, y + h - r)
  ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h)
  ctx.lineTo(x + r, y + h)
  ctx.quadraticCurveTo(x, y + h, x, y + h - r)
  ctx.lineTo(x, y + r)
  ctx.quadraticCurveTo(x, y, x + r, y)
  ctx.closePath()
}

function makePipTexture(THREE, pips) {
  const size = 128
  const r = 10
  const canvas = document.createElement("canvas")
  canvas.width = canvas.height = size
  const ctx = canvas.getContext("2d")

  ctx.fillStyle = "#f5f5f0"
  roundedRect(ctx, 2, 2, size - 4, size - 4, 14)
  ctx.fill()

  ctx.strokeStyle = "#ccc"
  ctx.lineWidth = 2
  roundedRect(ctx, 2, 2, size - 4, size - 4, 14)
  ctx.stroke()

  ctx.fillStyle = "#1a1a1a"
  for (const [nx, ny] of PIP_LAYOUTS[pips]) {
    ctx.beginPath()
    ctx.arc(nx * size, ny * size, r, 0, Math.PI * 2)
    ctx.fill()
  }

  return new THREE.CanvasTexture(canvas)
}

export function createDieMesh(THREE, scene, position) {
  const mats = FACE_NUMBERS.map(
    (n) => new THREE.MeshLambertMaterial({map: makePipTexture(THREE, n)}),
  )
  const mesh = new THREE.Mesh(new THREE.BoxGeometry(0.8, 0.8, 0.8), mats)
  mesh.position.set(...position)
  mesh.castShadow = true
  scene.add(mesh)
  return mesh
}

export function setDiceFace(mesh, face) {
  const [rx, ry, rz] = FACE_UP_EULER[face]
  mesh.rotation.set(rx, ry, rz)
}

// ── Physics ──────────────────────────────────────────────────────────────────

const GRAVITY = -18
const DT = 1 / 120
const Y_FLOOR = 0.45
const REST_FLOOR = 0.48
const REST_WALL = 0.6
const FRIC_FLOOR = 0.72
const ANG_DAMP = 1.1
const MIN_VY = 0.7

const X_LIM = 7.4
const Z_BACK = -4.8
const Z_FRONT = 7.0

const THROW_MS = 4000
const SETTLE_AT = 0.82

const DIE_DIAM = 0.82
const REST_DIE = 0.6

const rand = (lo, hi) => lo + Math.random() * (hi - lo)

function makeDieState(x0) {
  return {
    pos: {x: x0, y: rand(0.9, 1.3), z: 5.5},
    vel: {x: rand(-2.0, 2.0), y: rand(6.0, 9.0), z: rand(-10.5, -7.5)},
    angVel: {x: rand(-28, 28), y: rand(-18, 18), z: rand(-22, 22)},
    rot: {x: rand(0, Math.PI * 2), y: rand(0, Math.PI * 2), z: rand(0, Math.PI * 2)},
  }
}

function resolveInterDieCollision(a, b) {
  const dx = b.pos.x - a.pos.x
  const dy = b.pos.y - a.pos.y
  const dz = b.pos.z - a.pos.z
  const distSq = dx * dx + dy * dy + dz * dz
  if (distSq >= DIE_DIAM * DIE_DIAM || distSq < 1e-6) return 0

  const dist = Math.sqrt(distSq)
  const nx = dx / dist, ny = dy / dist, nz = dz / dist

  const relVN =
    (a.vel.x - b.vel.x) * nx + (a.vel.y - b.vel.y) * ny + (a.vel.z - b.vel.z) * nz
  if (relVN <= 0) return 0

  const impulse = (relVN * (1 + REST_DIE)) / 2
  a.vel.x -= impulse * nx; a.vel.y -= impulse * ny; a.vel.z -= impulse * nz
  b.vel.x += impulse * nx; b.vel.y += impulse * ny; b.vel.z += impulse * nz

  const push = (DIE_DIAM - dist) / 2
  a.pos.x -= nx * push; a.pos.y -= ny * push; a.pos.z -= nz * push
  b.pos.x += nx * push; b.pos.y += ny * push; b.pos.z += nz * push

  if (a.pos.y < Y_FLOOR) a.pos.y = Y_FLOOR
  if (b.pos.y < Y_FLOOR) b.pos.y = Y_FLOOR

  const spin = impulse * 2.0
  a.angVel.x += rand(-spin, spin); a.angVel.z += rand(-spin, spin)
  b.angVel.x += rand(-spin, spin); b.angVel.z += rand(-spin, spin)

  return impulse
}

// Returns the collision that happened this step, if any, so the caller can
// put a sound to it.
function stepDie(s, dt) {
  let hit = null

  s.vel.y += GRAVITY * dt
  s.pos.x += s.vel.x * dt
  s.pos.y += s.vel.y * dt
  s.pos.z += s.vel.z * dt

  if (s.pos.y < Y_FLOOR) {
    const impact = Math.abs(s.vel.y)
    s.pos.y = Y_FLOOR
    if (impact > MIN_VY) {
      s.vel.y = impact * REST_FLOOR
      s.vel.x *= FRIC_FLOOR
      s.vel.z *= FRIC_FLOOR
      s.angVel.x += s.vel.z * 2.2
      s.angVel.z -= s.vel.x * 2.2
      hit = {type: "floor", speed: impact}
    } else {
      s.vel.y = 0
    }
  }

  // Directional checks, so a die entering the table is not treated as one
  // escaping it.
  if (s.pos.x < -X_LIM && s.vel.x < 0) {
    const impact = Math.abs(s.vel.x)
    s.pos.x = -X_LIM
    s.vel.x = impact * REST_WALL
    s.angVel.y += rand(3, 9)
    s.angVel.z += rand(-6, 6)
    hit = {type: "wall", speed: impact}
  } else if (s.pos.x > X_LIM && s.vel.x > 0) {
    const impact = Math.abs(s.vel.x)
    s.pos.x = X_LIM
    s.vel.x = -impact * REST_WALL
    s.angVel.y -= rand(3, 9)
    s.angVel.z += rand(-6, 6)
    hit = {type: "wall", speed: impact}
  }

  if (s.pos.z < Z_BACK && s.vel.z < 0) {
    const impact = Math.abs(s.vel.z)
    s.pos.z = Z_BACK
    s.vel.z = impact * REST_WALL
    s.angVel.x += rand(-12, 12)
    s.angVel.y += rand(-8, 8)
    s.angVel.z += rand(-10, 10)
    hit = {type: "wall", speed: impact}
  }

  if (s.pos.z > Z_FRONT && s.vel.z > 0) {
    s.pos.z = Z_FRONT
    s.vel.z = -Math.abs(s.vel.z) * REST_WALL
  }

  s.rot.x += s.angVel.x * dt
  s.rot.y += s.angVel.y * dt
  s.rot.z += s.angVel.z * dt

  const d = Math.exp(-ANG_DAMP * dt)
  s.angVel.x *= d
  s.angVel.y *= d
  s.angVel.z *= d

  return hit
}

export function throwDice(THREE, die1Mesh, die2Mesh, targetFace1, targetFace2, onImpact) {
  return new Promise((resolve) => {
    const s1 = makeDieState(rand(-4.2, -2.5))
    const s2 = makeDieState(rand(-2.0, -0.3))

    const [rx1, ry1, rz1] = FACE_UP_EULER[targetFace1]
    const [rx2, ry2, rz2] = FACE_UP_EULER[targetFace2]
    const qTarget1 = new THREE.Quaternion().setFromEuler(new THREE.Euler(rx1, ry1, rz1))
    const qTarget2 = new THREE.Quaternion().setFromEuler(new THREE.Euler(rx2, ry2, rz2))

    die1Mesh.visible = true
    die2Mesh.visible = true

    let elapsed = 0
    let lastFrameNow = null

    function tick(now) {
      if (lastFrameNow === null) lastFrameNow = now
      const frameDt = Math.min((now - lastFrameNow) / 1000, 0.04)
      lastFrameNow = now
      elapsed += frameDt
      const t = Math.min(elapsed / (THROW_MS / 1000), 1)

      const steps = Math.max(1, Math.round(frameDt / DT))
      const stepDt = frameDt / steps

      if (t < SETTLE_AT) {
        // One sound per die per frame at most: sub-steps can register the
        // same bounce several times, and the result is a buzz not a clatter.
        let hit1 = null
        let hit2 = null
        let clack = 0
        for (let i = 0; i < steps; i++) {
          hit1 = stepDie(s1, stepDt) || hit1
          hit2 = stepDie(s2, stepDt) || hit2
          clack = Math.max(clack, resolveInterDieCollision(s1, s2))
        }
        if (onImpact) {
          if (hit1) onImpact(hit1.type, hit1.speed)
          if (hit2) onImpact(hit2.type, hit2.speed)
          if (clack > 1.0) onImpact("wall", clack * 1.2)
        }
        die1Mesh.position.set(s1.pos.x, s1.pos.y, s1.pos.z)
        die2Mesh.position.set(s2.pos.x, s2.pos.y, s2.pos.z)
        die1Mesh.rotation.set(s1.rot.x, s1.rot.y, s1.rot.z)
        die2Mesh.rotation.set(s2.rot.x, s2.rot.y, s2.rot.z)
      } else {
        // Hand off from physics to a guided landing on the server's faces.
        const p = (t - SETTLE_AT) / (1 - SETTLE_AT)
        const ease = p * p * (3 - 2 * p)

        const vMul = 1 - ease * 0.96
        for (const s of [s1, s2]) {
          s.vel.x *= vMul; s.vel.y *= vMul; s.vel.z *= vMul
          s.angVel.x *= vMul; s.angVel.y *= vMul; s.angVel.z *= vMul
        }

        for (let i = 0; i < steps; i++) {
          stepDie(s1, stepDt)
          stepDie(s2, stepDt)
          resolveInterDieCollision(s1, s2)
        }

        die1Mesh.position.set(s1.pos.x, s1.pos.y + (Y_FLOOR - s1.pos.y) * ease, s1.pos.z)
        die2Mesh.position.set(s2.pos.x, s2.pos.y + (Y_FLOOR - s2.pos.y) * ease, s2.pos.z)

        const qCur1 = new THREE.Quaternion().setFromEuler(
          new THREE.Euler(s1.rot.x, s1.rot.y, s1.rot.z),
        )
        const qCur2 = new THREE.Quaternion().setFromEuler(
          new THREE.Euler(s2.rot.x, s2.rot.y, s2.rot.z),
        )
        die1Mesh.quaternion.slerpQuaternions(qCur1, qTarget1, ease)
        die2Mesh.quaternion.slerpQuaternions(qCur2, qTarget2, ease)
      }

      if (t < 1) {
        requestAnimationFrame(tick)
      } else {
        die1Mesh.position.y = Y_FLOOR
        die2Mesh.position.y = Y_FLOOR
        die1Mesh.quaternion.copy(qTarget1)
        die2Mesh.quaternion.copy(qTarget2)
        resolve()
      }
    }

    requestAnimationFrame(tick)
  })
}
