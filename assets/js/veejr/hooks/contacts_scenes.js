// The WebGL contact views (Orbit and Soiree) and the loader that fetches
// three.min.js on demand.
//
// Three.js is served from this instance (priv/static/vendor) rather than a CDN
// so the Content-Security-Policy can keep script-src pinned to 'self', and it
// is loaded lazily because most sessions never open these views.

import {ConversationPreview} from "./messages.js"

let threeLoader = null

function loadThree(src) {
  if (window.THREE) return Promise.resolve(window.THREE)
  if (threeLoader) return threeLoader

  threeLoader = new Promise((resolve, reject) => {
    const tag = document.createElement("script")
    tag.src = src
    tag.async = true
    tag.onload = () => (window.THREE ? resolve(window.THREE) : reject(new Error("three absent")))
    tag.onerror = () => reject(new Error("three failed to load"))
    document.head.appendChild(tag)
  })

  // Let a later attempt retry rather than caching the rejection forever.
  threeLoader.catch(() => {
    threeLoader = null
  })
  return threeLoader
}

function webglAvailable() {
  try {
    const c = document.createElement("canvas")
    return !!(window.WebGLRenderingContext && (c.getContext("webgl2") || c.getContext("webgl")))
  } catch (_e) {
    return false
  }
}

// The 3D appearances, keyed by theme name. Adding another is a matter of
// writing a scene with the same contract and listing it here.

const SCENES = {
  orbit: (...args) => createOrbitViewer(...args),
  soiree: (...args) => createSoireeViewer(...args),
}

export const ContactsOrbit = {
  mounted() {
    this.workspace = this.el.closest("#contacts-workspace")
    this.list = this.el.parentElement.querySelector(".contacts-conversation-list")
    this.active = false
    this.viewer = null

    // Follow the appearance dropdown: build on entering Orbit, tear down on
    // leaving it, so no WebGL context is held by the other themes.
    this.themeObserver = new MutationObserver(() => this.sync())
    if (this.workspace) {
      this.themeObserver.observe(this.workspace, {
        attributes: true,
        attributeFilter: ["data-contacts-theme"],
      })
    }

    // Previews decrypt after mount and threads change over time; rebuild the
    // cards when the underlying list does.
    this.listObserver = new MutationObserver(() => {
      if (this.active && this.viewer) this.viewer.setItems(this.readItems())
    })
    if (this.list) {
      this.listObserver.observe(this.list, { subtree: true, childList: true, characterData: true })
    }

    this.sync()
  },

  updated() {
    if (this.active && this.viewer) this.viewer.setItems(this.readItems())
  },

  destroyed() {
    if (this.themeObserver) this.themeObserver.disconnect()
    if (this.listObserver) this.listObserver.disconnect()
    this.teardown()
  },

  sync() {
    const theme = this.workspace ? this.workspace.dataset.contactsTheme : null
    const wanted = SCENES[theme] ? theme : null
    if (wanted === this.active) return
    this.active = wanted
    this.teardown()
    if (wanted) this.build()
  },

  teardown() {
    if (this.viewer) {
      this.viewer.dispose()
      this.viewer = null
    }
    this.el.innerHTML = ""
    this.el.removeAttribute("data-orbit-ready")
  },

  // Scrape what LiveView rendered. Falling back to the list on any surprise is
  // intentional: this must never be the reason someone cannot reach a thread.
  readItems() {
    if (!this.list) return []
    return Array.from(this.list.querySelectorAll("li")).map((li) => {
      const link = li.querySelector("a[id^='open-conversation-']")
      const title = li.querySelector("p.truncate")
      const preview = li.querySelector("[id^='conversation-preview-']")
      const meta = li.querySelector("p.text-xs")
      const img = li.querySelector("img")
      const profileButton = li.querySelector("button[id^='conversation-avatar-']")
      const initialsEl = li.querySelector("span.uppercase")
      const previewText = preview ? preview.textContent.trim() : ""

      return {
        // Keep the element: opening a thread clicks the real link so it goes
        // through LiveView's router exactly as it would from the list.
        link: link,
        title: title ? title.textContent.trim() : "Conversation",
        // While a preview is still decrypting it renders as a loading dot.
        preview: previewText && previewText.length ? previewText : "Decrypting...",
        meta: meta ? meta.textContent.replace(/\s+/g, " ").trim() : "",
        unread: li.dataset.unread === "true",
        avatarUrl:
          profileButton?.dataset.avatarTextureUrl || (img ? img.getAttribute("src") : null),
        profileButton,
        initials: initialsEl ? initialsEl.textContent.trim().slice(0, 3) : "?",
      }
    })
  },

  build() {
    const items = this.readItems()
    if (!items.length) return

    // No WebGL, or Three unreachable: leave the plain list in place. The CSS
    // only hides the list once the mount reports itself ready.
    if (!webglAvailable()) return

    const wanted = this.active
    loadThree(this.el.dataset.threeSrc)
      .then((THREE) => {
        // The appearance may have changed while the library was downloading.
        if (this.active !== wanted || !SCENES[wanted] || this.viewer) return
        // Re-read rather than using the snapshot taken before the download:
        // ConversationPreview decrypts on mount, so by the time the library
        // arrives the previews have usually landed. Building from the stale
        // snapshot is what left every card reading "Decrypting..." forever,
        // since the observer below ignores changes while the viewer is null
        // and nothing mutates the list again afterwards.
        this.viewer = SCENES[wanted](
          THREE,
          this.el,
          this.readItems(),
          (item) => {
            if (item && item.link) item.link.click()
          },
          (item) => {
            if (item && item.profileButton) item.profileButton.click()
          },
        )
        this.el.setAttribute("data-orbit-ready", "true")
      })
      .catch(() => {
        // Stay on the list; nothing to clean up.
        this.el.removeAttribute("data-orbit-ready")
      })
  },
}

// Builds the Orbit carousel. Kept free of hook/LiveView specifics so it can be
// reasoned about (and thrown away) on its own: it takes THREE, a container, the
// items to show, and what to do when one is opened.
// Chrome shared by every 3D appearance: the canvas stage, the caption under
// it, a live region for screen readers, and the prev/open/next controls. Each
// scene supplies only its own 3D content.

function createViewerShell(container, label) {
  const stage = document.createElement("div")
  stage.className = "orbit-stage"
  stage.tabIndex = 0
  stage.setAttribute("role", "application")
  stage.setAttribute("aria-label", label)

  const readout = document.createElement("div")
  readout.className = "orbit-readout"
  readout.setAttribute("aria-hidden", "true")
  readout.innerHTML = '<span class="orbit-who"></span><span class="orbit-msg"></span>'

  const liveRegion = document.createElement("p")
  liveRegion.className = "orbit-live sr-only"
  liveRegion.setAttribute("aria-live", "polite")

  const controls = document.createElement("div")
  controls.className = "orbit-controls"
  const prevBtn = document.createElement("button")
  const openBtn = document.createElement("button")
  const nextBtn = document.createElement("button")
  prevBtn.type = nextBtn.type = openBtn.type = "button"
  prevBtn.className = nextBtn.className = "btn btn-sm"
  openBtn.className = "btn btn-primary btn-sm"
  prevBtn.textContent = "Prev"
  nextBtn.textContent = "Next"
  openBtn.textContent = "Open conversation"
  prevBtn.setAttribute("aria-label", "Previous conversation")
  nextBtn.setAttribute("aria-label", "Next conversation")
  controls.append(prevBtn, openBtn, nextBtn)

  container.append(stage, readout, liveRegion, controls)
  return { stage, readout, liveRegion, prevBtn, openBtn, nextBtn }
}

function loadAvatarImage(item, onLoad) {
  if (!item.avatarUrl) return null

  const image = new Image()
  image.crossOrigin = "anonymous"
  image.onload = () => onLoad(image)
  image.src = item.avatarUrl

  if (image.complete && image.naturalWidth) {
    image.onload = null
    return image
  }

  return null
}

function createOrbitViewer(THREE, container, items, onOpen) {
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches
  const CARD_W = 1.95
  const CARD_H = 2.52
  const RADIUS = 3.55

  const shell = createViewerShell(
    container,
    "Conversation carousel. Left and right arrows move between conversations, Enter opens the front one.",
  )
  const { stage, readout, liveRegion, prevBtn, openBtn, nextBtn } = shell

  const scene = new THREE.Scene()
  const camera = new THREE.PerspectiveCamera(46, 1, 0.1, 100)
  camera.position.set(0, 0.35, 6.9)
  camera.lookAt(0, -0.05, 0)

  const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true })
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2))
  stage.appendChild(renderer.domElement)

  const ring = new THREE.Group()
  scene.add(ring)

  let cards = []
  let data = []
  let rotation = 0
  let target = 0
  let index = 0
  let step = 0
  let dragging = false
  let moved = 0
  let lastX = 0
  let wheelAcc = 0
  let running = true
  let itemGeneration = 0

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath()
    ctx.moveTo(x + r, y)
    ctx.arcTo(x + w, y, x + w, y + h, r)
    ctx.arcTo(x + w, y + h, x, y + h, r)
    ctx.arcTo(x, y + h, x, y, r)
    ctx.arcTo(x, y, x + w, y, r)
    ctx.closePath()
  }

  function wrapText(ctx, text, maxW, maxLines) {
    const words = text.split(" ")
    const lines = []
    let line = ""
    for (const word of words) {
      const test = line ? `${line} ${word}` : word
      if (ctx.measureText(test).width > maxW && line) {
        lines.push(line)
        line = word
      } else {
        line = test
      }
      if (lines.length === maxLines) break
    }
    if (lines.length < maxLines && line) lines.push(line)
    return lines
  }

  // A stable colour per conversation so cards stay recognisable between visits.
  function hueFor(text) {
    let h = 0
    for (let i = 0; i < text.length; i++) h = (h * 31 + text.charCodeAt(i)) % 360
    return h
  }

  function drawCard(item) {
    const cv = document.createElement("canvas")
    cv.width = 512
    cv.height = 660
    const ctx = cv.getContext("2d")
    const hue = hueFor(item.title)

    ctx.fillStyle = "#151a30"
    roundRect(ctx, 8, 8, 496, 644, 34)
    ctx.fill()
    const edge = ctx.createLinearGradient(0, 0, 0, 660)
    edge.addColorStop(0, "rgba(160,185,255,.30)")
    edge.addColorStop(1, "rgba(160,185,255,.06)")
    ctx.strokeStyle = edge
    ctx.lineWidth = 3
    roundRect(ctx, 8, 8, 496, 644, 34)
    ctx.stroke()

    const cx = 256
    const cy = 210
    const r = 108
    ctx.save()
    ctx.beginPath()
    ctx.arc(cx, cy, r, 0, Math.PI * 2)
    ctx.closePath()
    ctx.clip()
    if (item.image) {
      ctx.drawImage(item.image, cx - r, cy - r, r * 2, r * 2)
    } else {
      const g = ctx.createLinearGradient(cx - r, cy - r, cx + r, cy + r)
      g.addColorStop(0, `hsl(${hue} 80% 62%)`)
      g.addColorStop(1, `hsl(${(hue + 48) % 360} 78% 52%)`)
      ctx.fillStyle = g
      ctx.fillRect(cx - r, cy - r, r * 2, r * 2)
      ctx.fillStyle = "#fff"
      ctx.font = `800 ${item.initials.length > 2 ? 62 : 76}px ui-sans-serif, system-ui, sans-serif`
      ctx.textAlign = "center"
      ctx.textBaseline = "middle"
      ctx.fillText(item.initials, cx, cy + 4)
    }
    ctx.restore()
    ctx.strokeStyle = "rgba(255,255,255,.22)"
    ctx.lineWidth = 5
    ctx.beginPath()
    ctx.arc(cx, cy, r, 0, Math.PI * 2)
    ctx.stroke()

    ctx.textAlign = "center"
    ctx.textBaseline = "middle"
    ctx.fillStyle = "#e8ecff"
    ctx.font = "800 44px ui-sans-serif, system-ui, sans-serif"
    const name = item.title.length > 17 ? `${item.title.slice(0, 16)}...` : item.title
    ctx.fillText(name, cx, 396)

    ctx.fillStyle = "#9aa6d0"
    ctx.font = "400 30px ui-sans-serif, system-ui, sans-serif"
    wrapText(ctx, item.preview, 416, 2).forEach((l, i) => ctx.fillText(l, cx, 452 + i * 38))

    ctx.fillStyle = "rgba(142,154,196,.72)"
    ctx.font = "400 24px ui-sans-serif, system-ui, sans-serif"
    ctx.fillText(item.meta.length > 34 ? `${item.meta.slice(0, 33)}...` : item.meta, cx, 566)

    if (item.unread) {
      ctx.fillStyle = "#ff5c8a"
      roundRect(ctx, 194, 596, 124, 34, 17)
      ctx.fill()
      ctx.fillStyle = "#fff"
      ctx.font = "800 20px ui-sans-serif, system-ui, sans-serif"
      ctx.fillText("UNREAD", cx, 614)
    }

    const tex = new THREE.CanvasTexture(cv)
    tex.colorSpace = THREE.SRGBColorSpace
    tex.anisotropy = 8
    return tex
  }

  function disposeCards() {
    cards.forEach((c) => {
      ring.remove(c.holder)
      c.mesh.geometry.dispose()
      if (c.mat.map) c.mat.map.dispose()
      c.mat.dispose()
      if (c.rim) {
        c.rim.geometry.dispose()
        if (c.rim.material.map) c.rim.material.map.dispose()
        c.rim.material.dispose()
      }
    })
    cards = []
  }

  function buildCards() {
    disposeCards()
    step = (Math.PI * 2) / Math.max(data.length, 1)
    cards = data.map((item, i) => {
      const holder = new THREE.Group()
      const mat = new THREE.MeshBasicMaterial({
        map: drawCard(item),
        transparent: true,
        side: THREE.DoubleSide,
      })
      const mesh = new THREE.Mesh(new THREE.PlaneGeometry(CARD_W, CARD_H), mat)
      mesh.userData.index = i
      holder.add(mesh)

      let rim = null
      if (item.unread) {
        const rcv = document.createElement("canvas")
        rcv.width = 256
        rcv.height = 330
        const rx = rcv.getContext("2d")
        const rg = rx.createRadialGradient(128, 165, 60, 128, 165, 165)
        rg.addColorStop(0, "rgba(255,92,138,.55)")
        rg.addColorStop(1, "rgba(255,92,138,0)")
        rx.fillStyle = rg
        rx.fillRect(0, 0, 256, 330)
        const rtex = new THREE.CanvasTexture(rcv)
        rtex.colorSpace = THREE.SRGBColorSpace
        rim = new THREE.Mesh(
          new THREE.PlaneGeometry(CARD_W * 1.5, CARD_H * 1.4),
          new THREE.MeshBasicMaterial({
            map: rtex,
            transparent: true,
            blending: THREE.AdditiveBlending,
            depthWrite: false,
          }),
        )
        rim.position.z = -0.02
        holder.add(rim)
      }

      ring.add(holder)
      return { holder, mesh, mat, rim }
    })
  }

  function announce(text) {
    liveRegion.textContent = text
  }

  function setIndex(i, tell) {
    if (!data.length) return
    index = ((i % data.length) + data.length) % data.length
    const want = -index * step
    const k = Math.round((rotation - want) / (Math.PI * 2))
    target = want + k * Math.PI * 2
    if (reduceMotion) rotation = target
    const item = data[index]
    readout.querySelector(".orbit-who").textContent = item.title
    readout.querySelector(".orbit-msg").textContent = item.preview
    if (tell) announce(`${item.title}. ${item.preview}. ${item.unread ? "Unread." : ""}`)
  }

  function layout() {
    cards.forEach((c, i) => {
      const a = i * step + rotation
      c.holder.position.set(Math.sin(a) * RADIUS, 0, Math.cos(a) * RADIUS)
      c.holder.rotation.y = a
      const t = (Math.cos(a) + 1) / 2
      c.holder.scale.setScalar(0.82 + t * 0.3)
      c.mat.opacity = 0.28 + t * 0.72
      if (c.rim) c.rim.material.opacity = 0.35 + t * 0.65
    })
  }

  const raycaster = new THREE.Raycaster()
  const ndc = new THREE.Vector2()

  function pick(clientX, clientY) {
    const rect = renderer.domElement.getBoundingClientRect()
    ndc.x = ((clientX - rect.left) / rect.width) * 2 - 1
    ndc.y = -((clientY - rect.top) / rect.height) * 2 + 1
    raycaster.setFromCamera(ndc, camera)
    const hits = raycaster.intersectObjects(cards.map((c) => c.mesh), false)
    return hits.length ? hits[0].object.userData.index : null
  }

  const onPointerDown = (e) => {
    dragging = true
    moved = 0
    lastX = e.clientX
    stage.setPointerCapture(e.pointerId)
  }
  const onPointerMove = (e) => {
    if (!dragging) return
    const dx = e.clientX - lastX
    lastX = e.clientX
    moved += Math.abs(dx)
    rotation += dx * 0.006
  }
  const onPointerUp = (e) => {
    if (!dragging) return
    dragging = false
    if (moved < 6) {
      const hit = pick(e.clientX, e.clientY)
      if (hit !== null) {
        if (hit === index) onOpen(data[index])
        else setIndex(hit, true)
        return
      }
    }
    setIndex(Math.round(-rotation / step), true)
  }
  const onWheel = (e) => {
    e.preventDefault()
    wheelAcc += e.deltaY
    if (Math.abs(wheelAcc) > 40) {
      setIndex(index + (wheelAcc > 0 ? 1 : -1), true)
      wheelAcc = 0
    }
  }
  const onKeyDown = (e) => {
    if (e.key === "ArrowRight") {
      e.preventDefault()
      setIndex(index + 1, true)
    } else if (e.key === "ArrowLeft") {
      e.preventDefault()
      setIndex(index - 1, true)
    } else if (e.key === "Enter" || e.key === " ") {
      e.preventDefault()
      onOpen(data[index])
    }
  }

  stage.addEventListener("pointerdown", onPointerDown)
  stage.addEventListener("pointermove", onPointerMove)
  stage.addEventListener("pointerup", onPointerUp)
  stage.addEventListener("pointercancel", onPointerUp)
  stage.addEventListener("wheel", onWheel, { passive: false })
  stage.addEventListener("keydown", onKeyDown)
  prevBtn.addEventListener("click", () => setIndex(index - 1, true))
  nextBtn.addEventListener("click", () => setIndex(index + 1, true))
  openBtn.addEventListener("click", () => onOpen(data[index]))

  function resize() {
    const w = stage.clientWidth
    const h = stage.clientHeight
    if (!w || !h) return
    renderer.setSize(w, h, false)
    camera.aspect = w / h
    camera.updateProjectionMatrix()
  }
  const onResize = () => resize()
  window.addEventListener("resize", onResize)

  let last = performance.now()
  function frame(now) {
    if (!running) return
    const dt = Math.min((now - last) / 1000, 0.05)
    last = now
    if (!dragging) rotation += (target - rotation) * Math.min(1, dt * 7.5)
    layout()
    renderer.render(scene, camera)
    requestAnimationFrame(frame)
  }

  function setItems(next) {
    const generation = ++itemGeneration
    data = next.map((item, itemIndex) => {
      const entry = Object.assign({}, item, { image: null })
      entry.image = loadAvatarImage(entry, (image) => {
        if (!running || generation !== itemGeneration) return
        entry.image = image
        const card = cards[itemIndex]
        if (!card) return
        const texture = drawCard(entry)
        if (card.mat.map) card.mat.map.dispose()
        card.mat.map = texture
        card.mat.needsUpdate = true
      })
      return entry
    })
    buildCards()
    setIndex(Math.min(index, data.length - 1), false)
    rotation = target
  }

  setItems(items)
  resize()
  requestAnimationFrame(frame)

  return {
    setItems,
    dispose() {
      running = false
      window.removeEventListener("resize", onResize)
      stage.removeEventListener("pointerdown", onPointerDown)
      stage.removeEventListener("pointermove", onPointerMove)
      stage.removeEventListener("pointerup", onPointerUp)
      stage.removeEventListener("pointercancel", onPointerUp)
      stage.removeEventListener("wheel", onWheel)
      stage.removeEventListener("keydown", onKeyDown)
      disposeCards()
      renderer.dispose()
      if (renderer.forceContextLoss) renderer.forceContextLoss()
      container.innerHTML = ""
    },
  }
}

// Builds the Soiree scene: every conversation is a guest at a small party,
// wearing its profile picture and holding a drink. Some are seated at the
// table, the rest mingle around it. Same contract as the Orbit viewer.

function createSoireeViewer(THREE, container, items, onOpen, onProfile) {
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches
  const shell = createViewerShell(
    container,
    "A party of your conversations. Left and right arrows move between guests, Enter opens the conversation.",
  )
  const { stage, readout, liveRegion, prevBtn, openBtn, nextBtn } = shell

  const scene = new THREE.Scene()
  scene.fog = new THREE.Fog(0x120d18, 8, 20)
  const camera = new THREE.PerspectiveCamera(44, 1, 0.1, 100)
  camera.position.set(0, 2.25, 5.35)
  camera.lookAt(0, 1.02, 0)

  const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true })
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2))
  stage.appendChild(renderer.domElement)

  scene.add(new THREE.AmbientLight(0xffd9b0, 0.55))
  const key = new THREE.PointLight(0xffb45c, 42, 22, 2)
  key.position.set(0, 5.2, 1.4)
  scene.add(key)
  const pink = new THREE.PointLight(0xff6b9d, 26, 16, 2)
  pink.position.set(-4.2, 2.4, 2.2)
  scene.add(pink)
  const mint = new THREE.PointLight(0x6be3c0, 22, 16, 2)
  mint.position.set(4.4, 2.1, -1.2)
  scene.add(mint)

  const room = new THREE.Group()
  scene.add(room)

  // Warm bone colour with a little emissive, or the thin limbs vanish into
  // the dark room entirely.
  const LIMB = new THREE.MeshStandardMaterial({
    color: 0xf0dcc4,
    emissive: 0x3a2a24,
    roughness: 0.55,
    metalness: 0.05,
  })
  const PARENT_Q = new THREE.Quaternion()
  const TABLE_H = 0.74
  const TABLE_R = 1.05
  const disposables = []

  function track(obj) {
    disposables.push(obj)
    return obj
  }

  function hueFor(text) {
    let h = 0
    for (let i = 0; i < text.length; i++) h = (h * 31 + text.charCodeAt(i)) % 360
    return h
  }

  function headTexture(item) {
    const s = 256
    const cv = document.createElement("canvas")
    cv.width = cv.height = s
    const x = cv.getContext("2d")
    x.save()
    x.beginPath()
    x.arc(s / 2, s / 2, s / 2 - 6, 0, Math.PI * 2)
    x.closePath()
    x.clip()
    if (item.image) {
      x.drawImage(item.image, 0, 0, s, s)
    } else {
      const hue = hueFor(item.title)
      const g = x.createLinearGradient(0, 0, s, s)
      g.addColorStop(0, `hsl(${hue} 80% 62%)`)
      g.addColorStop(1, `hsl(${(hue + 48) % 360} 78% 52%)`)
      x.fillStyle = g
      x.fillRect(0, 0, s, s)
      x.fillStyle = "#fff"
      x.font = `800 ${item.initials.length > 2 ? 74 : 92}px ui-sans-serif, system-ui, sans-serif`
      x.textAlign = "center"
      x.textBaseline = "middle"
      x.fillText(item.initials, s / 2, s / 2 + 4)
    }
    x.restore()
    x.strokeStyle = "rgba(255,225,190,.85)"
    x.lineWidth = 7
    x.beginPath()
    x.arc(s / 2, s / 2, s / 2 - 6, 0, Math.PI * 2)
    x.stroke()
    const t = new THREE.CanvasTexture(cv)
    t.colorSpace = THREE.SRGBColorSpace
    t.anisotropy = 8
    return track(t)
  }

  // A limb segment whose origin is the joint; the bone hangs down -Y and the
  // tip chains the next segment, so elbows and knees animate by rotation.
  function bone(len, r) {
    const grp = new THREE.Group()
    const m = new THREE.Mesh(track(new THREE.CylinderGeometry(r, r * 0.85, len, 7)), LIMB)
    m.position.y = -len / 2
    grp.add(m)
    grp.add(new THREE.Mesh(track(new THREE.SphereGeometry(r * 1.25, 8, 6)), LIMB))
    grp.userData.tip = new THREE.Group()
    grp.userData.tip.position.y = -len
    grp.add(grp.userData.tip)
    return grp
  }

  function buildTable() {
    const wood = new THREE.MeshStandardMaterial({ color: 0x6b3b4a, roughness: 0.55, metalness: 0.08 })
    const dark = new THREE.MeshStandardMaterial({ color: 0x4a2833, roughness: 0.8 })
    const top = new THREE.Mesh(track(new THREE.CylinderGeometry(TABLE_R, TABLE_R, 0.06, 40)), wood)
    top.position.y = TABLE_H
    room.add(top)
    const ped = new THREE.Mesh(track(new THREE.CylinderGeometry(0.09, 0.13, TABLE_H, 12)), dark)
    ped.position.y = TABLE_H / 2
    room.add(ped)
    const foot = new THREE.Mesh(track(new THREE.CylinderGeometry(0.34, 0.38, 0.04, 16)), dark)
    foot.position.y = 0.02
    room.add(foot)
    track(wood)
    track(dark)

    const candle = new THREE.Mesh(
      track(new THREE.CylinderGeometry(0.05, 0.055, 0.17, 12)),
      track(new THREE.MeshStandardMaterial({ color: 0xf3e2c8, roughness: 0.6 })),
    )
    candle.position.y = TABLE_H + 0.115
    room.add(candle)
    const flame = new THREE.Mesh(
      track(new THREE.SphereGeometry(0.035, 10, 8)),
      track(new THREE.MeshBasicMaterial({ color: 0xffd27a })),
    )
    flame.position.y = TABLE_H + 0.225
    flame.scale.y = 1.7
    room.add(flame)
    const candleLight = new THREE.PointLight(0xffb45c, 6, 4.2, 2)
    candleLight.position.set(0, TABLE_H + 0.3, 0)
    room.add(candleLight)
    room.userData.flame = flame
    room.userData.candleLight = candleLight
  }

  function buildFloor() {
    const cv = document.createElement("canvas")
    cv.width = cv.height = 256
    const fx = cv.getContext("2d")
    const g = fx.createRadialGradient(128, 128, 10, 128, 128, 128)
    g.addColorStop(0, "rgba(255,180,92,.34)")
    g.addColorStop(0.55, "rgba(120,70,110,.16)")
    g.addColorStop(1, "rgba(18,13,24,0)")
    fx.fillStyle = g
    fx.fillRect(0, 0, 256, 256)
    const tex = track(new THREE.CanvasTexture(cv))
    tex.colorSpace = THREE.SRGBColorSpace
    const floor = new THREE.Mesh(
      track(new THREE.PlaneGeometry(15, 15)),
      track(new THREE.MeshBasicMaterial({ map: tex, transparent: true, depthWrite: false })),
    )
    floor.rotation.x = -Math.PI / 2
    room.add(floor)
  }

  function makeGuest(item, seated) {
    const root = new THREE.Group()
    const body = new THREE.Group()
    root.add(body)

    const HIP = seated ? 0.6 : 0.92
    const SHOULDER = HIP + 0.54
    const HEAD_Y = SHOULDER + 0.28

    const torso = new THREE.Mesh(
      track(new THREE.CylinderGeometry(0.043, 0.052, SHOULDER - HIP, 8)),
      LIMB,
    )
    torso.position.y = (SHOULDER + HIP) / 2
    body.add(torso)

    const head = new THREE.Mesh(
      track(new THREE.CircleGeometry(0.27, 32)),
      track(new THREE.MeshBasicMaterial({ map: headTexture(item), transparent: true })),
    )
    head.position.y = HEAD_Y
    body.add(head)

    const neck = new THREE.Mesh(track(new THREE.CylinderGeometry(0.022, 0.022, 0.12, 6)), LIMB)
    neck.position.y = SHOULDER + 0.06
    body.add(neck)

    const hips = new THREE.Group()
    hips.position.y = HIP
    body.add(hips)
    const legs = [-1, 1].map((side) => {
      const thigh = bone(0.46, 0.032)
      thigh.position.x = side * 0.07
      const shin = bone(0.44, 0.027)
      thigh.userData.tip.add(shin)
      if (seated) {
        thigh.rotation.x = -Math.PI / 2 + 0.12
        thigh.rotation.z = side * 0.1
        shin.rotation.x = Math.PI / 2 - 0.06
      } else {
        thigh.rotation.z = side * 0.06
      }
      hips.add(thigh)
      return { thigh, shin }
    })

    if (seated) {
      const seatMat = track(new THREE.MeshStandardMaterial({ color: 0x53303f, roughness: 0.8 }))
      const stool = new THREE.Mesh(track(new THREE.CylinderGeometry(0.21, 0.19, 0.06, 12)), seatMat)
      stool.position.y = HIP - 0.07
      root.add(stool)
      const legGeo = track(new THREE.CylinderGeometry(0.016, 0.016, HIP - 0.1, 6))
      ;[-1, 1].forEach((sx) => {
        ;[-1, 1].forEach((sz) => {
          const leg = new THREE.Mesh(legGeo, seatMat)
          leg.position.set(sx * 0.12, (HIP - 0.1) / 2, sz * 0.12)
          root.add(leg)
        })
      })
    }

    const shoulders = new THREE.Group()
    shoulders.position.y = SHOULDER
    body.add(shoulders)
    const arm = (side) => {
      const upper = bone(0.36, 0.028)
      upper.position.x = side * 0.115
      const fore = bone(0.33, 0.024)
      upper.userData.tip.add(fore)
      shoulders.add(upper)
      return { upper, fore }
    }
    const rightArm = arm(1)
    const leftArm = arm(-1)

    // the drink
    const drink = new THREE.Group()
    const glass = new THREE.Mesh(
      track(new THREE.CylinderGeometry(0.052, 0.04, 0.135, 10, 1, true)),
      track(
        new THREE.MeshStandardMaterial({
          color: 0xd8ecff,
          transparent: true,
          opacity: 0.34,
          roughness: 0.12,
          side: THREE.DoubleSide,
        }),
      ),
    )
    glass.position.y = 0.068
    drink.add(glass)
    const drinkHue = (hueFor(item.title) + 140) % 360
    const liquid = new THREE.Mesh(
      track(new THREE.CylinderGeometry(0.045, 0.036, 0.082, 10)),
      track(
        new THREE.MeshStandardMaterial({
          color: new THREE.Color(`hsl(${drinkHue}, 75%, 60%)`),
          emissive: new THREE.Color(`hsl(${drinkHue}, 70%, 35%)`),
          roughness: 0.3,
        }),
      ),
    )
    liquid.position.y = 0.05
    drink.add(liquid)
    rightArm.fore.userData.tip.add(drink)

    const halo = new THREE.Mesh(
      track(new THREE.TorusGeometry(0.31, 0.025, 12, 40)),
      track(
        new THREE.MeshBasicMaterial({
          color: 0xffd27a,
          transparent: true,
          opacity: 0,
          blending: THREE.AdditiveBlending,
          depthWrite: false,
        }),
      ),
    )
    halo.rotation.x = Math.PI / 2
    halo.position.y = HEAD_Y + 0.38
    body.add(halo)

    // generous invisible column, so clicking anywhere on a guest works
    const hit = new THREE.Mesh(
      track(new THREE.CylinderGeometry(0.42, 0.42, HEAD_Y + 0.3, 8)),
      track(new THREE.MeshBasicMaterial({ visible: false })),
    )
    hit.position.y = (HEAD_Y + 0.3) / 2
    root.add(hit)

    return {
      item,
      root,
      body,
      head,
      halo,
      hit,
      rightArm,
      leftArm,
      legs,
      seated,
      phase: hueFor(item.title) / 57,
      sipAt: 3 + (hueFor(item.title) % 60) / 10,
      sipT: -1,
      baseRot: 0,
    }
  }

  let guests = []
  let data = []
  let index = 0
  let yaw = 0
  let yawTarget = 0
  let dragging = false
  let moved = 0
  let lastX = 0
  let running = true
  let itemGeneration = 0

  function clearGuests() {
    guests.forEach((g) => room.remove(g.root))
    guests = []
  }

  function placeGuests() {
    clearGuests()
    const n = data.length
    const XMAX = 3.05
    // Spacing evenly across x rather than by angle is what keeps guests from
    // overlapping on screen: an even spread in angle bunches up badly once
    // perspective is applied. Whoever lands near the middle sits at the table.
    data.forEach((item, i) => {
      const x = n === 1 ? 0 : -XMAX + (i / (n - 1)) * 2 * XMAX
      const jitter = ((i * 0.53) % 0.34) - 0.17
      const seated = Math.abs(x) <= TABLE_R + 0.5
      const z = seated
        ? -(TABLE_R + 0.4) + Math.abs(x) * 0.16
        : 0.3 - Math.abs(x) * 0.32 + jitter * 0.4
      const g = makeGuest(item, seated)
      g.head.userData.index = i
      g.hit.userData.index = i
      g.root.position.set(x + jitter * 0.5, 0, z)
      g.baseRot = Math.atan2(-g.root.position.x, -(g.root.position.z - 0.15)) + jitter * 0.7
      g.root.rotation.y = g.baseRot
      g.root.scale.setScalar(0.97 + ((i * 0.23) % 0.09))
      room.add(g.root)
      guests.push(g)
    })
  }

  function select(i, tell) {
    if (!data.length) return
    index = ((i % data.length) + data.length) % data.length
    const item = data[index]
    readout.querySelector(".orbit-who").textContent = item.title
    readout.querySelector(".orbit-msg").textContent = item.preview
    if (tell) {
      liveRegion.textContent = `${item.title}. ${item.preview}. ${item.unread ? "Unread." : ""}`
    }
    const p = guests[index] ? guests[index].root.position : { x: 0, z: 0 }
    yawTarget = -Math.atan2(p.x, p.z + 4.4) * 0.55
  }

  const raycaster = new THREE.Raycaster()
  const ndc = new THREE.Vector2()
  function pick(cx, cy) {
    const r = renderer.domElement.getBoundingClientRect()
    ndc.x = ((cx - r.left) / r.width) * 2 - 1
    ndc.y = -((cy - r.top) / r.height) * 2 + 1
    raycaster.setFromCamera(ndc, camera)

    const headHits = raycaster.intersectObjects(guests.map((g) => g.head), false)
    if (headHits.length) {
      return { index: headHits[0].object.userData.index, target: "profile" }
    }

    const hits = raycaster.intersectObjects(guests.map((g) => g.hit), false)
    if (!hits.length) return null
    return { index: hits[0].object.userData.index, target: "conversation" }
  }

  function open() {
    if (!data.length) return
    if (guests[index]) guests[index].sipT = 0.0001 // raise the glass
    onOpen(data[index])
  }

  const onPointerDown = (e) => {
    dragging = true
    moved = 0
    lastX = e.clientX
    stage.setPointerCapture(e.pointerId)
  }
  const onPointerMove = (e) => {
    if (!dragging) return
    const dx = e.clientX - lastX
    lastX = e.clientX
    moved += Math.abs(dx)
    yaw += dx * 0.005
    yawTarget = yaw
  }
  const onPointerUp = (e) => {
    if (!dragging) return
    dragging = false
    if (moved < 6) {
      const hit = pick(e.clientX, e.clientY)
      if (hit !== null) {
        if (hit.target === "profile" && data[hit.index]?.profileButton) {
          select(hit.index, true)
          onProfile(data[hit.index])
        } else if (hit.index === index) {
          open()
        } else {
          select(hit.index, true)
        }
      }
    }
  }
  const onKeyDown = (e) => {
    if (e.key === "ArrowRight") {
      e.preventDefault()
      select(index + 1, true)
    } else if (e.key === "ArrowLeft") {
      e.preventDefault()
      select(index - 1, true)
    } else if (e.key === "Enter" || e.key === " ") {
      e.preventDefault()
      open()
    }
  }

  stage.addEventListener("pointerdown", onPointerDown)
  stage.addEventListener("pointermove", onPointerMove)
  stage.addEventListener("pointerup", onPointerUp)
  stage.addEventListener("pointercancel", onPointerUp)
  stage.addEventListener("keydown", onKeyDown)
  prevBtn.addEventListener("click", () => select(index - 1, true))
  nextBtn.addEventListener("click", () => select(index + 1, true))
  openBtn.addEventListener("click", open)

  function resize() {
    const w = stage.clientWidth
    const h = stage.clientHeight
    if (!w || !h) return
    renderer.setSize(w, h, false)
    camera.aspect = w / h
    camera.updateProjectionMatrix()
  }
  const onResize = () => resize()
  window.addEventListener("resize", onResize)

  let last = performance.now()
  let clock = 0
  function frame(now) {
    if (!running) return
    const dt = Math.min((now - last) / 1000, 0.05)
    last = now
    clock += dt

    yaw += (yawTarget - yaw) * Math.min(1, dt * 4)
    room.rotation.y = yaw

    guests.forEach((g, i) => {
      const t = clock + g.phase
      const sel = i === index

      if (!reduce) {
        g.body.position.y = Math.sin(t * 1.15) * (g.seated ? 0.006 : 0.014)
        g.body.rotation.z = Math.sin(t * 0.8) * (g.seated ? 0.018 : 0.032)
        g.body.rotation.y = Math.sin(t * 0.45) * 0.1
        if (!g.seated) {
          g.legs[0].thigh.rotation.x = Math.sin(t * 0.8) * 0.03
          g.legs[1].thigh.rotation.x = -Math.sin(t * 0.8) * 0.03
        }
      }

      // the drink arm: held at the chest, raised to the head for a sip
      g.sipAt -= dt
      if (g.sipAt <= 0 && g.sipT < 0) {
        g.sipT = 0
        g.sipAt = 7 + ((i * 13) % 9)
      }
      let sip = 0
      if (g.sipT >= 0) {
        g.sipT += dt
        sip = Math.sin(Math.min(g.sipT / 2.1, 1) * Math.PI)
        if (g.sipT >= 2.1) g.sipT = -1
      }
      g.rightArm.upper.rotation.x = -0.45 - sip * 0.55
      g.rightArm.upper.rotation.z = -0.3
      g.rightArm.fore.rotation.x = -1.05 - sip * 0.62

      // free arm: gestures while talking, waves when the thread is unread
      if (g.item.unread) {
        const wave = reduce ? 0.2 : 0.5 + Math.sin(t * 6.5) * 0.42
        g.leftArm.upper.rotation.z = 1.15 + wave * 0.35
        g.leftArm.upper.rotation.x = -0.25
        g.leftArm.fore.rotation.z = 0.45 + wave * 0.55
      } else {
        const talk = reduce ? 0 : Math.sin(t * 1.9) * 0.22
        g.leftArm.upper.rotation.x = -0.22 + talk * 0.5
        g.leftArm.upper.rotation.z = 0.3
        g.leftArm.fore.rotation.x = -0.75 + talk
      }

      const want = sel ? -room.rotation.y : g.baseRot
      g.root.rotation.y += (want - g.root.rotation.y) * Math.min(1, dt * 4)
      const haloOpacity = sel ? (reduce ? 0.82 : 0.72 + Math.sin(t * 2.4) * 0.12) : 0
      g.halo.material.opacity +=
        (haloOpacity - g.halo.material.opacity) * Math.min(1, dt * 6)

      // Heads always look at the viewer so profile pictures stay readable,
      // even for guests turned away. Cancel the parent's world rotation first.
      g.head.parent.getWorldQuaternion(PARENT_Q)
      g.head.quaternion.copy(PARENT_Q.invert()).multiply(camera.quaternion)
    })

    if (!reduce && room.userData.flame) {
      const f = 1 + Math.sin(clock * 11) * 0.09 + Math.sin(clock * 27) * 0.05
      room.userData.flame.scale.set(f * 0.9, 1.7 * f, f * 0.9)
      if (room.userData.candleLight) room.userData.candleLight.intensity = 6 * f
    }

    renderer.render(scene, camera)
    requestAnimationFrame(frame)
  }

  function setItems(next) {
    const generation = ++itemGeneration
    data = next.map((item, itemIndex) => {
      const entry = Object.assign({}, item, { image: null })
      entry.image = loadAvatarImage(entry, (image) => {
        if (!running || generation !== itemGeneration) return
        entry.image = image
        const guest = guests[itemIndex]
        if (!guest) return
        const texture = headTexture(entry)
        if (guest.head.material.map) guest.head.material.map.dispose()
        guest.head.material.map = texture
        guest.head.material.needsUpdate = true
      })
      return entry
    })
    placeGuests()
    select(Math.min(index, data.length - 1), false)
  }

  buildFloor()
  buildTable()
  setItems(items)
  resize()
  requestAnimationFrame(frame)

  return {
    setItems,
    dispose() {
      running = false
      window.removeEventListener("resize", onResize)
      stage.removeEventListener("pointerdown", onPointerDown)
      stage.removeEventListener("pointermove", onPointerMove)
      stage.removeEventListener("pointerup", onPointerUp)
      stage.removeEventListener("pointercancel", onPointerUp)
      stage.removeEventListener("keydown", onKeyDown)
      clearGuests()
      disposables.forEach((d) => d.dispose && d.dispose())
      LIMB.dispose()
      renderer.dispose()
      if (renderer.forceContextLoss) renderer.forceContextLoss()
      container.innerHTML = ""
    },
  }
}

// Keeps a chat thread scrolled to the newest message at the bottom, the way
// a messaging app does. Runs on mount and whenever the thread re-renders.
