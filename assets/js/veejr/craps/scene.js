// Renderer, camera, lighting, and drag-to-orbit for the craps table.
//
// Sized to its container rather than the window: this canvas sits inside a
// page that has a header and controls under it, so window dimensions would
// overflow both.
//
// The vendored three.min.js is the core build, which does not carry
// OrbitControls, so the small amount of camera control the table needs —
// orbit, zoom, and a floor the camera cannot drop below — is here instead of
// pulling in an addon.

const MIN_DISTANCE = 6
const MAX_DISTANCE = 42
const MAX_POLAR = Math.PI / 2.05

export function createScene(THREE, container) {
  const canvas = document.createElement("canvas")
  canvas.style.display = "block"
  canvas.style.width = "100%"
  canvas.style.height = "100%"
  canvas.style.touchAction = "none"
  container.appendChild(canvas)

  const renderer = new THREE.WebGLRenderer({canvas, antialias: true})
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2))
  renderer.shadowMap.enabled = true

  const scene = new THREE.Scene()
  scene.background = new THREE.Color(0x1a1a2e)

  const camera = new THREE.PerspectiveCamera(45, 1, 0.1, 200)

  scene.add(new THREE.AmbientLight(0xffffff, 1.2))
  const key = new THREE.DirectionalLight(0xffffff, 1.0)
  key.position.set(0, 20, 8)
  key.castShadow = true
  scene.add(key)
  const fill = new THREE.DirectionalLight(0xffffff, 0.4)
  fill.position.set(0, 10, -8)
  scene.add(fill)

  // Spherical camera position, aimed a little behind centre so the near rail
  // and the chip rack do not eat the bottom of the frame. The default radius
  // is set to just fit the 16-unit felt at a 45 degree vertical field.
  const target = new THREE.Vector3(0, 0, -0.6)
  const orbit = {radius: 12.5, theta: 0, phi: 0.92}
  const desired = {...orbit}

  function applyCamera() {
    // Ease toward the desired orbit so dragging feels weighted rather than rigid.
    orbit.radius += (desired.radius - orbit.radius) * 0.12
    orbit.theta += (desired.theta - orbit.theta) * 0.15
    orbit.phi += (desired.phi - orbit.phi) * 0.15

    camera.position.set(
      target.x + orbit.radius * Math.sin(orbit.phi) * Math.sin(orbit.theta),
      target.y + orbit.radius * Math.cos(orbit.phi),
      target.z + orbit.radius * Math.sin(orbit.phi) * Math.cos(orbit.theta),
    )
    camera.lookAt(target)
  }

  let dragging = null
  let travelled = 0
  const handlers = {tap: null, hover: null}

  // Dragging orbits the camera, so a press only counts as placing a chip if
  // the pointer barely moved. Without this every orbit would drop a bet.
  const TAP_SLOP = 6

  const onPointerDown = (event) => {
    dragging = {x: event.clientX, y: event.clientY}
    travelled = 0
    canvas.setPointerCapture(event.pointerId)
  }

  const onPointerMove = (event) => {
    if (!dragging) {
      if (handlers.hover) handlers.hover(event)
      return
    }
    const dx = event.clientX - dragging.x
    const dy = event.clientY - dragging.y
    travelled += Math.abs(dx) + Math.abs(dy)
    dragging = {x: event.clientX, y: event.clientY}
    desired.theta -= dx * 0.005
    desired.phi = Math.min(MAX_POLAR, Math.max(0.12, desired.phi - dy * 0.005))
  }

  const onPointerUp = (event) => {
    const wasTap = dragging && travelled <= TAP_SLOP
    dragging = null
    if (canvas.hasPointerCapture(event.pointerId)) canvas.releasePointerCapture(event.pointerId)
    if (wasTap && handlers.tap) handlers.tap(event)
  }

  const onWheel = (event) => {
    event.preventDefault()
    const next = desired.radius + event.deltaY * 0.02
    desired.radius = Math.min(MAX_DISTANCE, Math.max(MIN_DISTANCE, next))
  }

  canvas.addEventListener("pointerdown", onPointerDown)
  canvas.addEventListener("pointermove", onPointerMove)
  canvas.addEventListener("pointerup", onPointerUp)
  canvas.addEventListener("pointercancel", onPointerUp)
  canvas.addEventListener("wheel", onWheel, {passive: false})

  function resize() {
    const w = container.clientWidth || 1
    const h = container.clientHeight || 1
    camera.aspect = w / h
    camera.updateProjectionMatrix()
    renderer.setSize(w, h, false)
  }

  const observer = new ResizeObserver(resize)
  observer.observe(container)
  resize()

  let running = true
  function frame() {
    if (!running) return
    requestAnimationFrame(frame)
    applyCamera()
    renderer.render(scene, camera)
  }
  frame()

  function destroy() {
    running = false
    observer.disconnect()
    canvas.removeEventListener("pointerdown", onPointerDown)
    canvas.removeEventListener("pointermove", onPointerMove)
    canvas.removeEventListener("pointerup", onPointerUp)
    canvas.removeEventListener("pointercancel", onPointerUp)
    canvas.removeEventListener("wheel", onWheel)
    renderer.dispose()
    canvas.remove()
  }

  // Normalised device coordinates for a pointer event, which is what the
  // raycaster wants.
  function pointerNdc(event, out) {
    const rect = canvas.getBoundingClientRect()
    out.x = ((event.clientX - rect.left) / rect.width) * 2 - 1
    out.y = -((event.clientY - rect.top) / rect.height) * 2 + 1
    return out
  }

  return {
    scene,
    camera,
    renderer,
    canvas,
    pointerNdc,
    onTap: (fn) => (handlers.tap = fn),
    onHover: (fn) => (handlers.hover = fn),
    destroy,
  }
}
