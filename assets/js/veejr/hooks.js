// LiveView hooks for veejr's client-side crypto.
//
// Security rule: passphrases and secret keys are read from plain DOM inputs
// inside these hooks and never travel over the LiveView socket. Only public
// keys and ciphertext are pushed to the server.

import {
  generateIdentity,
  generateEphemeralIdentity,
  unlockIdentity,
  wrapSecretKey,
  cacheSecretKey,
  getSecretKey,
  forgetSecretKey,
  sealFor,
  openFrom,
  encryptBlob,
  decryptBlob,
} from "./crypto.js"
import {ensureLeaflet} from "./map_hook.js"
import {unzipSync, strFromU8} from "../../vendor/fflate.js"

// Promise wrapper around pushEvent-with-reply, shared by several hooks.
function pushWithReply(hook, event, params) {
  return new Promise((resolve, reject) => {
    hook.pushEvent(event, params, (reply) => {
      if (reply && reply.error) {
        const error = new Error(reply.error)
        error.reply = reply
        reject(error)
      }
      else resolve(reply)
    })
  })
}

const csrfToken = () =>
  document.querySelector("meta[name='csrf-token']").getAttribute("content")

const currentLocationPath = () =>
  `${window.location.pathname}${window.location.search}${window.location.hash}`

// Encrypts one file with a fresh symmetric key and uploads the ciphertext.
// Returns the attachment descriptor that rides inside the envelope payload.
async function encryptAndUpload(file, metadata = {}) {
  const bytes = new Uint8Array(await file.arrayBuffer())
  const enc = encryptBlob(bytes)
  const resp = await fetch("/blobs", {
    method: "POST",
    headers: {"content-type": "application/octet-stream", "x-csrf-token": csrfToken()},
    body: enc.data,
  })
  if (!resp.ok) throw new Error(`upload failed (${resp.status})`)
  const {id} = await resp.json()
  // `origin` records which instance holds the blob, so a recipient on a
  // different instance knows where to fetch it from.
  return {
    id,
    origin: window.location.origin,
    key: enc.key,
    nonce: enc.nonce,
    name: metadata.name || file.name,
    mime: metadata.mime || file.type,
    size: metadata.size || file.size,
    duration_ms: metadata.durationMs,
  }
}

async function decryptAttachmentBlob(att) {
  const urls = [
    att.origin ? `${att.origin}/api/blobs/${att.id}` : null,
    `/api/blobs/${att.id}`,
    `/blobs/${att.id}`,
  ].filter(Boolean)

  let resp = null
  let lastError = null
  for (const url of [...new Set(urls)]) {
    try {
      resp = await fetch(url)
      if (resp.ok) break
      lastError = new Error(`download failed (${resp.status})`)
    } catch (err) {
      lastError = err
    }
    resp = null
  }

  if (!resp || !resp.ok) throw lastError || new Error("download failed")
  const cipher = new Uint8Array(await resp.arrayBuffer())
  const plain = decryptBlob(cipher, att.key, att.nonce)
  if (!plain) throw new Error("attachment failed authentication")
  return new Blob([plain], {type: att.mime || "application/octet-stream"})
}

// Downloads an encrypted blob, decrypts it locally, and hands it to the user
// as a normal file download. Cross-instance attachments carry their origin
// and are fetched from that instance's public capability endpoint; legacy
// attachments (no origin) live on this instance behind the session route.
async function downloadAttachment(att) {
  const blob = await decryptAttachmentBlob(att)
  const url = URL.createObjectURL(blob)
  const a = document.createElement("a")
  a.href = url
  a.download = att.name || "attachment"
  a.click()
  setTimeout(() => URL.revokeObjectURL(url), 30_000)
}

function showError(el, msg) {
  const err = el.querySelector("[data-role=error]")
  if (err) {
    err.textContent = msg
    err.classList.remove("hidden")
  }
}

function preferredAudioMime() {
  const types = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4", "audio/ogg;codecs=opus"]
  return types.find((type) => window.MediaRecorder && MediaRecorder.isTypeSupported(type)) || ""
}

const MAX_VIDEO_DURATION_MS = 60_000

function preferredVideoMime() {
  const types = [
    "video/webm;codecs=vp9,opus",
    "video/webm;codecs=vp8,opus",
    "video/webm",
    "video/mp4",
  ]
  return types.find((type) => window.MediaRecorder && MediaRecorder.isTypeSupported(type)) || ""
}

function attachmentMime(att) {
  const mime = att.mime || ""
  const name = (att.name || "").toLowerCase()
  if (mime.startsWith("image/")) return mime
  if (mime.startsWith("video/")) return mime
  if (name.endsWith(".mp4") || name.endsWith(".m4v")) return "video/mp4"
  if (name.endsWith(".webm")) return "video/webm"
  if (name.endsWith(".mov")) return "video/quicktime"
  if (mime === "application/pdf" || mime === "application/x-pdf" || name.endsWith(".pdf")) {
    return "application/pdf"
  }
  return mime
}

function previewableMedia(att) {
  const mime = attachmentMime(att)
  return mime.startsWith("image/") || mime === "application/pdf"
}

function showMediaModal({blob, title, mime}) {
  const mediaBlob = mime === "application/pdf" && blob.type !== "application/pdf"
    ? new Blob([blob], {type: "application/pdf"})
    : blob
  const url = URL.createObjectURL(mediaBlob)
  const overlay = document.createElement("div")
  overlay.className = "fixed inset-0 z-[1100] flex items-center justify-center bg-black/70 p-4"
  overlay.setAttribute("role", "dialog")
  overlay.setAttribute("aria-modal", "true")

  const panel = document.createElement("div")
  panel.className = "flex max-h-[92vh] w-full max-w-5xl flex-col overflow-hidden rounded-lg bg-base-100 text-base-content shadow-2xl"

  const header = document.createElement("div")
  header.className = "flex items-center justify-between gap-3 border-b border-base-300 px-4 py-3"

  const h = document.createElement("h3")
  h.className = "truncate text-sm font-medium text-base-content"
  h.textContent = title || "Attachment"

  const close = document.createElement("button")
  close.type = "button"
  close.className = "btn btn-ghost btn-sm"
  close.textContent = "Close"

  const body = document.createElement("div")
  body.className = "min-h-0 flex-1 overflow-auto bg-slate-950 p-3"
  body.addEventListener("contextmenu", (event) => event.preventDefault())

  if ((mime || "").startsWith("image/")) {
    const img = document.createElement("img")
    img.src = url
    img.alt = title || "Image attachment"
    img.draggable = false
    img.className = "mx-auto max-h-[78vh] max-w-full object-contain"
    body.appendChild(img)
  } else {
    const frame = document.createElement("iframe")
    frame.src = `${url}#toolbar=0&navpanes=0&scrollbar=1`
    frame.title = title || "PDF attachment"
    frame.className = "h-[78vh] w-full rounded bg-base-100"
    body.appendChild(frame)
  }

  const cleanup = () => {
    URL.revokeObjectURL(url)
    document.removeEventListener("keydown", onKeydown)
    overlay.remove()
  }
  const onKeydown = (event) => {
    if (event.key === "Escape") cleanup()
  }

  close.addEventListener("click", cleanup)
  overlay.addEventListener("click", (event) => {
    if (event.target === overlay) cleanup()
  })
  document.addEventListener("keydown", onKeydown)

  header.appendChild(h)
  header.appendChild(close)
  panel.appendChild(header)
  panel.appendChild(body)
  overlay.appendChild(panel)
  document.body.appendChild(overlay)
}

// Full-screen map modal for a decrypted location or geo-note. The plaintext
// (coordinates, title, text) only ever exists in this browser; everything is
// written with textContent, matching the Decrypt hook's security rule.
async function showLocationModal({lat, lng, title, text, kind}) {
  const overlay = document.createElement("div")
  overlay.className = "fixed inset-0 z-[1100] flex items-center justify-center bg-black/70 p-4"
  overlay.setAttribute("role", "dialog")
  overlay.setAttribute("aria-modal", "true")

  const panel = document.createElement("div")
  panel.className = "flex max-h-[92vh] w-full max-w-3xl flex-col overflow-hidden rounded-lg bg-base-100 text-base-content shadow-2xl"

  const header = document.createElement("div")
  header.className = "flex items-center justify-between gap-3 border-b border-base-300 px-4 py-3"

  const h = document.createElement("h3")
  h.className = "truncate text-sm font-medium text-base-content"
  h.textContent = title || (kind === "note" ? "📝 Map note" : "📍 Shared location")

  const close = document.createElement("button")
  close.type = "button"
  close.className = "btn btn-ghost btn-sm"
  close.textContent = "Close"

  const mapDiv = document.createElement("div")
  mapDiv.className = "h-[55vh] min-h-64 w-full bg-base-200"
  mapDiv.setAttribute("data-role", "location-modal-map")

  const info = document.createElement("div")
  info.className = "space-y-1 border-t border-base-300 px-4 py-3"

  if (text) {
    const p = document.createElement("p")
    p.className = "whitespace-pre-wrap text-sm"
    p.textContent = text
    info.appendChild(p)
  }

  const coords = document.createElement("p")
  coords.className = "text-xs opacity-60"
  coords.textContent = `📍 ${lat.toFixed(5)}, ${lng.toFixed(5)}`
  info.appendChild(coords)

  let map = null
  const cleanup = () => {
    if (map) map.remove()
    document.removeEventListener("keydown", onKeydown)
    overlay.remove()
  }
  const onKeydown = (event) => {
    if (event.key === "Escape") cleanup()
  }

  close.addEventListener("click", cleanup)
  overlay.addEventListener("click", (event) => {
    if (event.target === overlay) cleanup()
  })
  document.addEventListener("keydown", onKeydown)

  header.appendChild(h)
  header.appendChild(close)
  panel.appendChild(header)
  panel.appendChild(mapDiv)
  panel.appendChild(info)
  overlay.appendChild(panel)
  document.body.appendChild(overlay)

  try {
    const L = await ensureLeaflet()
    if (!overlay.isConnected) return
    map = L.map(mapDiv).setView([lat, lng], 16)
    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 19,
      attribution: "&copy; OpenStreetMap contributors",
    }).addTo(map)
    L.marker([lat, lng]).addTo(map)
    // Leaflet measures its container on init; re-measure once layout settles.
    setTimeout(() => map && map.invalidateSize(), 60)
  } catch (err) {
    mapDiv.className = "flex min-h-64 w-full items-center justify-center p-4 text-sm opacity-70"
    mapDiv.textContent = err.message
  }
}

// Key setup: generate a keypair, wrap the secret key with the passphrase,
// push only public material to the server.
export const KeySetup = {
  mounted() {
    const form = this.el
    form.addEventListener("submit", async (e) => {
      e.preventDefault()
      const pass = form.querySelector("[data-role=passphrase]").value
      const confirm = form.querySelector("[data-role=confirm]").value
      if (pass.length < 8) return showError(form, "Passphrase must be at least 8 characters.")
      if (pass !== confirm) return showError(form, "Passphrases do not match.")

      const btn = form.querySelector("button[type=submit]")
      btn.disabled = true
      btn.textContent = "Generating keys…"
      try {
        const id = await generateIdentity(pass)
        cacheSecretKey(this.el.dataset.userId, id.secretKey)
        this.pushEvent("keys_generated", {
          public_key: id.publicKey,
          enc_secret_key: id.encSecretKey,
          key_salt: id.keySalt,
          key_nonce: id.keyNonce,
        })
      } catch (err) {
        btn.disabled = false
        btn.textContent = "Generate my keys"
        showError(form, `Key generation failed: ${err.message}`)
      }
    })
  },
}

// Key unlock: derive the wrapping key from the passphrase and unwrap the
// roaming secret key. Entirely client-side; on success we just navigate.
export const KeyUnlock = {
  mounted() {
    const form = this.el
    const {userId, encSecretKey, keySalt, keyNonce, returnTo} = form.dataset

    if (getSecretKey(userId)) {
      if (returnTo) {
        // the user was sent here to unlock before doing something else
        this.pushEvent("unlocked", {})
      } else {
        // visiting the keys page directly while unlocked: show state, keep
        // the management sections below reachable
        form.querySelectorAll("input, button, label").forEach((el) => el.classList.add("hidden"))
        const note = document.createElement("p")
        note.className = "text-sm text-success"
        note.textContent = "✓ Keys are unlocked for this session."
        form.appendChild(note)
      }
      return
    }

    form.addEventListener("submit", async (e) => {
      e.preventDefault()
      const pass = form.querySelector("[data-role=passphrase]").value
      const btn = form.querySelector("button[type=submit]")
      btn.disabled = true
      btn.textContent = "Unlocking…"
      const secretKey = await unlockIdentity(pass, encSecretKey, keySalt, keyNonce)
      if (secretKey) {
        cacheSecretKey(userId, secretKey)
        if (returnTo) window.location.assign(returnTo)
        else window.location.reload()
      } else {
        btn.disabled = false
        btn.textContent = "Unlock"
        showError(form, "Wrong passphrase.")
      }
    })
  },
}

// Passphrase change: unwrap with the current passphrase, re-wrap under the
// new one. The keypair — and therefore everything encrypted — is unchanged.
export const KeyRewrap = {
  mounted() {
    const form = this.el
    form.addEventListener("submit", async (e) => {
      e.preventDefault()
      const current = form.querySelector("[data-role=current]").value
      const next = form.querySelector("[data-role=next]").value
      const confirm = form.querySelector("[data-role=confirm]").value
      if (next.length < 8) return showError(form, "New passphrase must be at least 8 characters.")
      if (next !== confirm) return showError(form, "New passphrases do not match.")

      const {userId, encSecretKey, keySalt, keyNonce} = form.dataset
      const secretKey = await unlockIdentity(current, encSecretKey, keySalt, keyNonce)
      if (!secretKey) return showError(form, "Current passphrase is wrong.")

      const wrapped = await wrapSecretKey(secretKey, next)
      await pushWithReply(this, "rewrap_keys", {
        enc_secret_key: wrapped.encSecretKey,
        key_salt: wrapped.keySalt,
        key_nonce: wrapped.keyNonce,
      })
      cacheSecretKey(userId, secretKey)
      form.reset()
    })
  },
}

// Key rotation: decrypt the entire history with the old key, generate a new
// keypair, re-encrypt everything to it, and hand the server new wrapped keys
// plus the resealed ciphertext in one push. All crypto happens here.
export const KeyRotate = {
  mounted() {
    const form = this.el
    form.addEventListener("submit", async (e) => {
      e.preventDefault()
      const current = form.querySelector("[data-role=current]").value
      const next = form.querySelector("[data-role=next]").value
      if (next.length < 8) return showError(form, "New passphrase must be at least 8 characters.")

      const btn = form.querySelector("button[type=submit]")
      const busy = (label) => (btn.textContent = label)
      btn.disabled = true

      try {
        const {userId, encSecretKey, keySalt, keyNonce} = form.dataset
        const oldSecret = await unlockIdentity(current, encSecretKey, keySalt, keyNonce)
        if (!oldSecret) throw new Error("Current passphrase is wrong.")

        busy("Fetching history…")
        const {envelopes} = await pushWithReply(this, "list_resealable", {})

        busy(`Re-encrypting ${envelopes.length} items…`)
        const identity = await generateIdentity(next)
        const resealed = []
        let unreadable = 0
        for (const entry of envelopes) {
          const payload = openFrom(entry.ciphertext, entry.nonce, entry.peer_key, oldSecret)
          if (!payload) {
            unreadable++
            continue
          }
          resealed.push({
            public_id: entry.public_id,
            ...sealFor(identity.publicKey, payload, identity.secretKey),
          })
        }

        busy("Saving new keys…")
        await pushWithReply(this, "rotate_keys", {
          keys: {
            public_key: identity.publicKey,
            enc_secret_key: identity.encSecretKey,
            key_salt: identity.keySalt,
            key_nonce: identity.keyNonce,
          },
          envelopes: resealed,
          unreadable: unreadable,
        })
        cacheSecretKey(userId, identity.secretKey)
        window.location.reload()
      } catch (err) {
        btn.disabled = false
        btn.textContent = "Rotate my keys"
        showError(form, err.message)
      }
    })
  },
}

// Key reset for a lost passphrase: brand-new keypair; old ciphertext is
// gone for good (the server deletes this user's undecryptable copies).
export const KeyReset = {
  mounted() {
    const form = this.el
    form.addEventListener("submit", async (e) => {
      e.preventDefault()
      const next = form.querySelector("[data-role=next]").value
      const confirm = form.querySelector("[data-role=confirm]").value
      if (next.length < 8) return showError(form, "Passphrase must be at least 8 characters.")
      if (next !== confirm) return showError(form, "Passphrases do not match.")
      if (!window.confirm("Really reset? Every message you've received so far becomes permanently unreadable."))
        return

      const identity = await generateIdentity(next)
      await pushWithReply(this, "reset_keys", {
        keys: {
          public_key: identity.publicKey,
          enc_secret_key: identity.encSecretKey,
          key_salt: identity.keySalt,
          key_nonce: identity.keyNonce,
        },
      })
      cacheSecretKey(this.el.dataset.userId, identity.secretKey)
      window.location.assign("/")
    })
  },
}

// PWA install button: visible only when the browser offered an install
// prompt (Chrome/Edge; other browsers install from their own menus).
export const InstallApp = {
  mounted() {
    const btn = this.el
    const show = () => btn.classList.remove("hidden")
    if (window.veejrInstallPrompt) show()
    window.addEventListener("veejr:installable", show)

    btn.addEventListener("click", async () => {
      const prompt = window.veejrInstallPrompt
      if (!prompt) return
      prompt.prompt()
      const {outcome} = await prompt.userChoice
      if (outcome === "accepted") {
        btn.textContent = "✅ Installed"
        btn.disabled = true
        window.veejrInstallPrompt = null
      }
    })
  },
}

// A chat-only appearance preference. This deliberately changes only the
// Messages workspace, leaving the app-wide light/dark/Art Deco theme intact.
export const ChatTheme = {
  mounted() {
    this.storageKey = "veejr:chat-theme"
    this.allowedThemes = new Set(["classic", "salon"])
    this.onThemeClick = (event) => {
      const option = event.target.closest("[data-chat-theme-option]")
      if (!option || !this.el.contains(option)) return
      this.applyTheme(option.dataset.chatThemeOption, true)
    }
    this.onThemeStorage = (event) => {
      if (event.key === this.storageKey) this.applyTheme(event.newValue, false)
    }

    this.el.addEventListener("click", this.onThemeClick)
    window.addEventListener("storage", this.onThemeStorage)
    this.applyTheme(localStorage.getItem(this.storageKey) || "classic", false)
  },

  updated() {
    this.applyTheme(this.currentTheme || "classic", false)
  },

  destroyed() {
    this.el.removeEventListener("click", this.onThemeClick)
    window.removeEventListener("storage", this.onThemeStorage)
  },

  applyTheme(theme, persist) {
    const selected = this.allowedThemes.has(theme) ? theme : "classic"
    this.currentTheme = selected
    this.el.dataset.chatTheme = selected

    this.el.querySelectorAll("[data-chat-theme-option]").forEach((option) => {
      option.setAttribute(
        "aria-pressed",
        String(option.dataset.chatThemeOption === selected),
      )
    })

    if (persist) localStorage.setItem(this.storageKey, selected)
  },
}

// A Contacts-only appearance preference, modeled on ChatTheme. Classic keeps
// the accordion cards; every other theme is a flat directory look defined
// under [data-contacts-theme="..."] in app.css. Because the flat looks want
// every section visible at once, we open the top-level <details> natively
// rather than fighting daisyUI's collapse styles from CSS.
export const ContactsTheme = {
  mounted() {
    this.storageKey = "veejr:contacts-theme"
    this.allowedThemes = new Set([
      "classic",
      "quiet",
      "bubblegum",
      "aurora",
      "arcade",
      "blueprint",
      "comic",
      "vapor",
      "orbit",
      "soiree",
    ])
    this.onThemeChange = (event) => {
      const select = event.target.closest("[data-contacts-theme-select]")
      if (!select || !this.el.contains(select)) return
      this.applyTheme(select.value, true)
    }
    this.onThemeStorage = (event) => {
      if (event.key === this.storageKey) this.applyTheme(event.newValue, false)
    }

    this.el.addEventListener("change", this.onThemeChange)
    window.addEventListener("storage", this.onThemeStorage)
    this.applyTheme(localStorage.getItem(this.storageKey) || "classic", false)
  },

  updated() {
    this.applyTheme(this.currentTheme || "classic", false)
  },

  destroyed() {
    this.el.removeEventListener("change", this.onThemeChange)
    window.removeEventListener("storage", this.onThemeStorage)
  },

  applyTheme(theme, persist) {
    const selected = this.allowedThemes.has(theme) ? theme : "classic"
    this.currentTheme = selected
    this.el.dataset.contactsTheme = selected

    const select = this.el.querySelector("[data-contacts-theme-select]")
    if (select && select.value !== selected) select.value = selected

    // The flat themes show all sections at once; Classic keeps its default of
    // only the first section open.
    if (selected !== "classic") {
      this.el.querySelectorAll(".contacts-section").forEach((s) => (s.open = true))
    }

    if (persist) localStorage.setItem(this.storageKey, selected)
  },
}

// The Contacts "Orbit" appearance: a WebGL carousel for picking a
// conversation. Three.js is deliberately NOT in the app bundle — it is a
// static file under /vendor and is fetched the first time someone selects
// this appearance, so everyone else pays nothing for it.
//
// The carousel reads the conversation list that LiveView already rendered
// instead of taking its own copy of the data. That keeps it correct with
// client-side decrypted previews (which arrive after mount, via the
// ConversationPreview hook) and means no server changes were needed.
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
        avatarUrl: img ? img.getAttribute("src") : null,
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
export const ScrollBottom = {
  mounted() {
    this.loadingMore = false
    this.beforeLoadHeight = 0
    this.threadId = this.el.id
    this.pinnedToBottom = true
    this.hasMore = () => {
      const value = this.el.dataset.hasMore
      return value === "" || value === "true"
    }
    this.loadMore = () => {
      if (this.loadingMore || !this.hasMore()) return

      this.loadingMore = true
      this.beforeLoadHeight = this.el.scrollHeight
      this.pushEvent("load_more_messages", {})
    }
    this.onScroll = () => {
      const distanceFromBottom =
        this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
      this.pinnedToBottom = distanceFromBottom <= 48

      if (this.loadingMore || !this.hasMore()) return
      if (this.el.scrollTop > 48) return

      this.loadMore()
    }
    this.onClick = (event) => {
      if (!event.target.closest("[data-role='load-more-messages']")) return
      if (this.loadingMore || !this.hasMore()) return

      // The button owns the LiveView event; record the pre-update height here
      // so updated() can preserve the user's viewport after older rows arrive.
      this.loadingMore = true
      this.beforeLoadHeight = this.el.scrollHeight
    }
    this.el.addEventListener("scroll", this.onScroll)
    this.el.addEventListener("click", this.onClick)
    this.handleEvent("scroll_to_bottom", ({thread_id}) => {
      if (thread_id !== this.el.id) return
      this.pinnedToBottom = true
      this.toBottom()
    })
    this.mutationObserver = new MutationObserver(() => {
      if (!this.loadingMore && this.pinnedToBottom) this.toBottom()
    })
    this.mutationObserver.observe(this.el, {childList: true, subtree: true})
    this.toBottom()
  },
  updated() {
    const threadChanged = this.threadId !== this.el.id
    this.threadId = this.el.id

    if (threadChanged) {
      this.loadingMore = false
      this.pinnedToBottom = true
      this.toBottom()
      return
    }

    if (this.loadingMore) {
      requestAnimationFrame(() => {
        const delta = this.el.scrollHeight - this.beforeLoadHeight
        this.el.scrollTop = this.el.scrollTop + delta
        this.loadingMore = false
      })
    } else if (this.pinnedToBottom) {
      this.toBottom()
    }
  },
  destroyed() {
    if (this.onScroll) this.el.removeEventListener("scroll", this.onScroll)
    if (this.onClick) this.el.removeEventListener("click", this.onClick)
    if (this.mutationObserver) this.mutationObserver.disconnect()
    clearTimeout(this.scrollRetry)
  },
  toBottom() {
    // Let decrypted bubbles and their media dimensions paint before measuring.
    const scroll = () => {
      requestAnimationFrame(() => {
        this.el.scrollTop = this.el.scrollHeight
        this.el.querySelector("[data-role='thread-end']")?.scrollIntoView({block: "end"})
      })
    }

    requestAnimationFrame(scroll)
    clearTimeout(this.scrollRetry)
    this.scrollRetry = setTimeout(scroll, 120)
  },
}

// Reply button on a conversation: preselects its participants in the
// composer and jumps there.
export const ReplyTo = {
  mounted() {
    this.el.addEventListener("click", () => {
      const ids = (this.el.dataset.friendIds || "").split(",").filter(Boolean)
      const composer = document.querySelector("#message-composer")
      if (!composer) return
      composer
        .querySelectorAll("input[name='friends[]']")
        .forEach((cb) => (cb.checked = ids.includes(cb.value)))
      composer.scrollIntoView({behavior: "smooth", block: "center"})
      const text = composer.querySelector("[data-role=text]")
      if (text) text.focus()
    })
  },
}

// Web Push opt-in for this device: permission → service worker → subscribe
// with the instance's VAPID key → register the subscription server-side.
export const PushSetup = {
  mounted() {
    const el = this.el
    const btn = el.querySelector("[data-role=push-enable]")
    const status = el.querySelector("[data-role=push-status]")
    const say = (msg) => status && (status.textContent = msg)

    if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
      btn.disabled = true
      say("Push is not supported in this browser.")
      return
    }

    btn.addEventListener("click", async () => {
      if (this.expired) return
      btn.disabled = true
      try {
        const permission = await Notification.requestPermission()
        if (permission !== "granted") {
          if (permission === "denied") {
            throw new Error(
              "Notifications are blocked for this site. Open the browser's site settings, allow Notifications, then reload this page."
            )
          }

          throw new Error("notification permission was not granted")
        }

        say("Registering service worker…")
        await navigator.serviceWorker.register("/sw.js")
        const registration = await navigator.serviceWorker.ready

        say("Subscribing…")
        const applicationServerKey = urlB64ToBytes(el.dataset.vapidKey)
        let subscription = await registration.pushManager.getSubscription()

        // A subscription is bound to the VAPID key used to create it. If the
        // instance was restored from a backup or its key was regenerated,
        // discard the stale browser subscription before creating a new one.
        const existingKey = subscription?.options?.applicationServerKey
        if (subscription && existingKey && !sameBytes(existingKey, applicationServerKey)) {
          say("Refreshing an old push subscriptionâ€¦")
          await subscription.unsubscribe()
          subscription = null
        }

        subscription ||= await registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey,
        })

        const resp = await fetch("/push/subscriptions", {
          method: "POST",
          headers: {"content-type": "application/json", "x-csrf-token": csrfToken()},
          body: JSON.stringify(subscription.toJSON()),
        })
        if (!resp.ok) throw new Error(`server refused the subscription (${resp.status})`)

        say("✅ Push notifications are enabled on this device.")
      } catch (err) {
        say(`Could not enable push: ${err.message}`)
        btn.disabled = false
      }
    })
  },
}

function urlB64ToBytes(b64url) {
  const b64 = b64url.replace(/-/g, "+").replace(/_/g, "/")
  const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4)
  const bin = atob(padded)
  const bytes = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
  return bytes
}

function sameBytes(a, b) {
  const left = new Uint8Array(a)
  if (left.length !== b.length) return false
  return left.every((value, index) => value === b[index])
}

// Lock button: drop the cached secret key for this session.
export const KeyLock = {
  mounted() {
    this.el.addEventListener("click", () => {
      forgetSecretKey(this.el.dataset.userId)
      window.location.reload()
    })
  },
}

// The server stores only the wrapped secret key. This status is therefore
// resolved locally from the browser session cache and never sends key data
// over the LiveView socket.
export const AccountStatus = {
  mounted() {
    this.renderIdentityStatus()
  },
  updated() {
    this.renderIdentityStatus()
  },
  renderIdentityStatus() {
    const status = this.el.querySelector("[data-role=identity-status]")
    if (!status) return

    const hasIdentity = this.el.dataset.hasIdentity === "true"
    const unlocked = hasIdentity && Boolean(getSecretKey(this.el.dataset.userId))
    const label = !hasIdentity ? "Not configured" : unlocked ? "Unlocked" : "Locked"
    const tone = !hasIdentity ? "badge-neutral" : unlocked ? "badge-success" : "badge-warning"

    status.textContent = label
    status.classList.remove("badge-neutral", "badge-success", "badge-warning")
    status.classList.add(tone)
  },
}

// Composer: a plain (non-LiveView) form. Message text, files, and recipient
// choices are read locally; only ciphertext leaves this hook.
//
// Expects inside this.el:
//   [data-role=text]                the message textarea (optional for kinds
//                                   whose payload comes from data-payload)
//   input[name="friends[]"] / input[name="groups[]"] checked or hidden
//   [data-role=files]               file input (optional)
//   [data-role=error]               error line
// Dataset: user-id, my-key, kind
export const Composer = {
  mounted() {
    this.recordedAudio = []
    this.recordedVideo = []
    this.videoFacingMode = "user"
    this.textEl = this.el.querySelector("[data-role=text]")

    this.onTextKeydown = (e) => {
      if (e.key !== "Enter" || e.shiftKey || e.isComposing) return
      e.preventDefault()
      if (!e.repeat) this.send().catch((err) => showError(this.el, err.message))
    }

    this.onComposerClick = (e) => {
      const optionsToggle = e.target.closest("[data-role=toggle-options]")
      if (optionsToggle && this.el.contains(optionsToggle)) {
        e.preventDefault()
        const options = this.el.querySelector("[data-role=message-options]")
        if (!options) return

        options.classList.toggle("hidden")
        optionsToggle.classList.toggle("bg-primary/10")
        optionsToggle.classList.toggle("text-primary")
        return
      }

      const toggle = e.target.closest("[data-role=emoji-toggle]")
      if (toggle && this.el.contains(toggle)) {
        e.preventDefault()
        e.stopPropagation()
        this.captureEmojiElements()
        this.setEmojiMenuOpen(this.emojiMenu.classList.contains("hidden"))
        return
      }

      const audioToggle = e.target.closest("[data-role=audio-toggle]")
      if (audioToggle && this.el.contains(audioToggle)) {
        e.preventDefault()
        this.toggleAudioRecording().catch((err) => showError(this.el, err.message))
        return
      }

      const videoToggle = e.target.closest("[data-role=video-toggle]")
      if (videoToggle && this.el.contains(videoToggle)) {
        e.preventDefault()
        this.toggleVideoRecording().catch((err) => showError(this.el, err.message))
        return
      }

      const facingToggle = e.target.closest("[data-role=video-facing-toggle]")
      if (facingToggle && this.el.contains(facingToggle)) {
        e.preventDefault()
        this.toggleVideoFacing().catch((err) => showError(this.el, err.message))
        return
      }

      const discardAudio = e.target.closest("[data-role=discard-audio]")
      if (discardAudio && this.el.contains(discardAudio)) {
        e.preventDefault()
        this.discardAudio(parseInt(discardAudio.dataset.index))
        return
      }

      const discardVideo = e.target.closest("[data-role=discard-video]")
      if (discardVideo && this.el.contains(discardVideo)) {
        e.preventDefault()
        this.discardVideo(parseInt(discardVideo.dataset.index))
      }
    }

    this.onDocumentClick = (e) => {
      if (this.emojiMenu && this.emojiMenu.contains(e.target)) {
        const btn = e.target.closest("[data-role=emoji-option]")
        if (!btn) return

        e.preventDefault()
        this.insertEmoji(btn.dataset.emoji || "")
        this.setEmojiMenuOpen(false)
        return
      }

      if (this.el.contains(e.target)) return
      this.setEmojiMenuOpen(false)
    }

    this.onDocumentKeydown = (e) => {
      if (e.key === "Escape") this.setEmojiMenuOpen(false)
    }

    this.el.addEventListener("click", this.onComposerClick)
    document.addEventListener("click", this.onDocumentClick)
    document.addEventListener("keydown", this.onDocumentKeydown)
    if (this.textEl) this.textEl.addEventListener("keydown", this.onTextKeydown)

    this.el.addEventListener("submit", (e) => {
      e.preventDefault()
      this.send().catch((err) => showError(this.el, err.message))
    })
  },

  captureEmojiElements() {
    const previousMenu = this.emojiMenu
    this.emojiMenu = this.el.querySelector("[data-role=emoji-menu]")
    this.emojiToggle = this.el.querySelector("[data-role=emoji-toggle]")
    this.textEl = this.el.querySelector("[data-role=text]")
    if (this.emojiMenu && this.emojiMenu !== previousMenu) {
      this.originalEmojiParent = this.emojiMenu.parentElement
      this.originalEmojiNextSibling = this.emojiMenu.nextSibling
    }
  },

  destroyed() {
    clearTimeout(this.videoDurationTimer)
    if (this.mediaRecorder && this.mediaRecorder.state === "recording") this.mediaRecorder.stop()
    this.stopMediaTracks()
    if (this.onComposerClick) this.el.removeEventListener("click", this.onComposerClick)
    if (this.onDocumentClick) document.removeEventListener("click", this.onDocumentClick)
    if (this.onDocumentKeydown) document.removeEventListener("keydown", this.onDocumentKeydown)
    if (this.textEl) this.textEl.removeEventListener("keydown", this.onTextKeydown)
    if (this.emojiMenu && this.emojiMenu.parentElement === document.body) this.emojiMenu.remove()
    this.recordedAudio.forEach((entry) => URL.revokeObjectURL(entry.url))
    this.recordedVideo.forEach((entry) => URL.revokeObjectURL(entry.url))
  },

  setEmojiMenuOpen(open) {
    if (!this.emojiMenu || !this.emojiToggle) return
    if (open && this.emojiMenu.parentElement !== document.body) {
      document.body.appendChild(this.emojiMenu)
    }

    this.emojiMenu.classList.toggle("hidden", !open)
    this.emojiToggle.setAttribute("aria-expanded", open ? "true" : "false")

    if (!open) {
      if (
        this.originalEmojiParent &&
        this.originalEmojiParent.isConnected &&
        this.emojiMenu.parentElement === document.body
      ) {
        this.originalEmojiParent.insertBefore(this.emojiMenu, this.originalEmojiNextSibling)
      }
      return
    }

    const rect = this.emojiToggle.getBoundingClientRect()
    const gap = 8
    const menuWidth = this.emojiMenu.offsetWidth
    const menuHeight = this.emojiMenu.offsetHeight
    const left = Math.min(
      Math.max(gap, rect.right - menuWidth),
      Math.max(gap, window.innerWidth - menuWidth - gap)
    )
    let top = rect.top - menuHeight - gap
    if (top < gap) top = Math.min(window.innerHeight - menuHeight - gap, rect.bottom + gap)

    Object.assign(this.emojiMenu.style, {
      position: "fixed",
      bottom: "auto",
      right: "auto",
      left: `${left}px`,
      top: `${Math.max(gap, top)}px`,
      zIndex: "1000",
    })
  },

  insertEmoji(emoji) {
    if (!emoji || !this.textEl) return
    const textEl = this.textEl
    const start = textEl.selectionStart ?? textEl.value.length
    const end = textEl.selectionEnd ?? textEl.value.length
    textEl.setRangeText(emoji, start, end, "end")
    textEl.dispatchEvent(new Event("input", {bubbles: true}))
    textEl.focus()
  },

  async toggleAudioRecording() {
    if (this.recordingFinalizing) throw new Error("Wait for the current recording to finish.")

    if (this.mediaRecorder && this.mediaRecorder.state === "recording") {
      if (this.activeRecordingKind !== "audio") {
        throw new Error("Stop the video recording first.")
      }
      this.recordingFinalizing = true
      this.mediaRecorder.stop()
      this.setAudioStatus("Finishing recording...")
      return
    }

    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia || !window.MediaRecorder) {
      throw new Error("Audio recording is not supported in this browser.")
    }

    const mimeType = preferredAudioMime()
    const stream = await navigator.mediaDevices.getUserMedia({audio: true})
    const recorder = new MediaRecorder(stream, mimeType ? {mimeType} : undefined)
    const chunks = []
    const startedAt = Date.now()

    recorder.addEventListener("dataavailable", (event) => {
      if (event.data && event.data.size > 0) chunks.push(event.data)
    })

    recorder.addEventListener("stop", () => {
      this.stopMediaTracks()
      this.setRecordingButton("audio-toggle", false)
      this.recordingFinalizing = false
      this.activeRecordingKind = null
      if (this.mediaRecorder === recorder) this.mediaRecorder = null
      const type = recorder.mimeType || mimeType || "audio/webm"
      const blob = new Blob(chunks, {type})
      if (blob.size === 0) {
        this.setAudioStatus("Recording was empty.")
        return
      }

      const extension = type.includes("mp4") ? "m4a" : type.includes("ogg") ? "ogg" : "webm"
      const durationMs = Date.now() - startedAt
      const name = `voice-message-${new Date().toISOString().replace(/[:.]/g, "-")}.${extension}`
      const file = new File([blob], name, {type})
      this.recordedAudio.push({file, url: URL.createObjectURL(blob), durationMs})
      this.renderAudioPreview()
      this.setAudioStatus("Voice message ready to send.")
    })

    this.audioStream = stream
    this.mediaStream = stream
    this.activeRecordingKind = "audio"
    this.mediaRecorder = recorder
    recorder.start()
    this.setRecordingButton("audio-toggle", true)
    this.setAudioStatus("Recording... click the microphone again to stop.")
  },

  stopMediaTracks() {
    const stream = this.mediaStream || this.audioStream
    if (!stream) return
    stream.getTracks().forEach((track) => track.stop())
    this.mediaStream = null
    this.audioStream = null
  },

  setAudioStatus(message) {
    const status = this.el.querySelector("[data-role=audio-status]")
    if (!status) return
    status.textContent = message
    status.classList.toggle("hidden", !message)
  },

  setRecordingButton(role, active) {
    const button = this.el.querySelector(`[data-role="${role}"]`)
    if (!button) return
    button.setAttribute("aria-pressed", active ? "true" : "false")
    button.classList.toggle("bg-error", active)
    button.classList.toggle("text-error-content", active)
    button.classList.toggle("opacity-100", active)
  },

  renderAudioPreview() {
    const preview = this.el.querySelector("[data-role=audio-preview]")
    if (!preview) return
    preview.textContent = ""

    this.recordedAudio.forEach((entry, index) => {
      const row = document.createElement("div")
      row.className = "flex items-center gap-2 rounded-lg bg-base-200 px-3 py-2"

      const audio = document.createElement("audio")
      audio.controls = true
      audio.src = entry.url
      audio.className = "min-w-0 flex-1"

      const btn = document.createElement("button")
      btn.type = "button"
      btn.dataset.role = "discard-audio"
      btn.dataset.index = index.toString()
      btn.className = "btn btn-ghost btn-xs"
      btn.textContent = "Remove"

      row.appendChild(audio)
      row.appendChild(btn)
      preview.appendChild(row)
    })
  },

  discardAudio(index) {
    const entry = this.recordedAudio[index]
    if (!entry) return
    URL.revokeObjectURL(entry.url)
    this.recordedAudio.splice(index, 1)
    this.renderAudioPreview()
    this.setAudioStatus(this.recordedAudio.length > 0 ? "Voice message ready to send." : "")
  },

  clearAudioRecordings() {
    this.recordedAudio.forEach((entry) => URL.revokeObjectURL(entry.url))
    this.recordedAudio = []
    this.renderAudioPreview()
    this.setAudioStatus("")
  },

  async toggleVideoRecording() {
    if (this.recordingFinalizing) throw new Error("Wait for the current recording to finish.")

    if (this.mediaRecorder && this.mediaRecorder.state === "recording") {
      if (this.activeRecordingKind !== "video") {
        throw new Error("Stop the voice recording first.")
      }
      this.recordingFinalizing = true
      this.mediaRecorder.stop()
      this.setVideoStatus("Finishing recording...")
      return
    }

    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia || !window.MediaRecorder) {
      throw new Error("Video recording is not supported in this browser.")
    }

    const mimeType = preferredVideoMime()
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: true,
      video: {
        facingMode: {ideal: this.videoFacingMode},
        width: {ideal: 1280},
        height: {ideal: 720},
      },
    })
    const options = mimeType ? {mimeType, videoBitsPerSecond: 2_000_000} : {videoBitsPerSecond: 2_000_000}
    let recorder
    try {
      recorder = new MediaRecorder(stream, options)
    } catch (error) {
      try {
        recorder = new MediaRecorder(stream, mimeType ? {mimeType} : undefined)
      } catch {
        stream.getTracks().forEach((track) => track.stop())
        throw error
      }
    }
    const chunks = []
    const startedAt = Date.now()

    recorder.addEventListener("dataavailable", (event) => {
      if (event.data && event.data.size > 0) chunks.push(event.data)
    })

    recorder.addEventListener("stop", () => {
      clearTimeout(this.videoDurationTimer)
      this.videoDurationTimer = null
      this.stopMediaTracks()
      this.setRecordingButton("video-toggle", false)
      this.recordingFinalizing = false
      this.activeRecordingKind = null
      if (this.mediaRecorder === recorder) this.mediaRecorder = null
      const type = recorder.mimeType || mimeType || "video/webm"
      const blob = new Blob(chunks, {type})
      if (blob.size === 0) {
        this.renderVideoPreview()
        this.setVideoStatus("Recording was empty.")
        return
      }

      const extension = type.includes("mp4") ? "mp4" : "webm"
      const durationMs = Math.min(Date.now() - startedAt, MAX_VIDEO_DURATION_MS)
      const name = `video-message-${new Date().toISOString().replace(/[:.]/g, "-")}.${extension}`
      const file = new File([blob], name, {type})
      this.recordedVideo.push({file, url: URL.createObjectURL(blob), durationMs})
      this.renderVideoPreview()
      this.setVideoStatus("Video message ready to send.")
    })

    this.mediaStream = stream
    this.activeRecordingKind = "video"
    this.mediaRecorder = recorder
    this.renderLiveVideoPreview(stream)
    recorder.start(1_000)
    this.setRecordingButton("video-toggle", true)
    this.videoDurationTimer = setTimeout(() => {
      if (recorder.state === "recording") {
        this.recordingFinalizing = true
        recorder.stop()
        this.setVideoStatus("Maximum recording length reached. Finishing recording...")
      }
    }, MAX_VIDEO_DURATION_MS)
    this.setVideoStatus("Recording... click the camera again to stop. Maximum 60 seconds.")
  },

  async toggleVideoFacing() {
    if (this.mediaRecorder && this.mediaRecorder.state === "recording") {
      throw new Error("Stop recording before switching cameras.")
    }
    if (this.recordingFinalizing) throw new Error("Wait for the current recording to finish.")
    this.videoFacingMode = this.videoFacingMode === "user" ? "environment" : "user"
    const label = this.videoFacingMode === "user" ? "front" : "rear"
    this.setVideoStatus(`The ${label} camera will be used for the next recording.`)
  },

  setVideoStatus(message) {
    const status = this.el.querySelector("[data-role=video-status]")
    if (!status) return
    status.textContent = message
    status.classList.toggle("hidden", !message)
  },

  renderLiveVideoPreview(stream) {
    const preview = this.el.querySelector("[data-role=video-preview]")
    if (!preview) return
    preview.textContent = ""
    const video = document.createElement("video")
    video.srcObject = stream
    video.autoplay = true
    video.muted = true
    video.playsInline = true
    video.className = "max-h-64 w-full rounded-lg bg-black object-contain"
    preview.appendChild(video)
  },

  renderVideoPreview() {
    const preview = this.el.querySelector("[data-role=video-preview]")
    if (!preview) return
    preview.textContent = ""

    this.recordedVideo.forEach((entry, index) => {
      const row = document.createElement("div")
      row.className = "flex flex-col gap-2 rounded-lg bg-base-200 p-2 sm:flex-row sm:items-center"

      const video = document.createElement("video")
      video.controls = true
      video.controlsList = "nodownload"
      video.disablePictureInPicture = true
      video.src = entry.url
      video.className = "max-h-56 min-w-0 flex-1 rounded bg-black object-contain"

      const btn = document.createElement("button")
      btn.type = "button"
      btn.dataset.role = "discard-video"
      btn.dataset.index = index.toString()
      btn.className = "btn btn-ghost btn-sm"
      btn.textContent = "Remove"

      row.append(video, btn)
      preview.appendChild(row)
    })
  },

  discardVideo(index) {
    const entry = this.recordedVideo[index]
    if (!entry) return
    URL.revokeObjectURL(entry.url)
    this.recordedVideo.splice(index, 1)
    this.renderVideoPreview()
    this.setVideoStatus(this.recordedVideo.length > 0 ? "Video message ready to send." : "")
  },

  clearVideoRecordings() {
    this.recordedVideo.forEach((entry) => URL.revokeObjectURL(entry.url))
    this.recordedVideo = []
    this.renderVideoPreview()
    this.setVideoStatus("")
  },

  async send() {
    if (this.sending) return

    const form = this.el
    const {userId, myKey, kind} = form.dataset
    if (this.mediaRecorder && this.mediaRecorder.state === "recording") {
      throw new Error("Stop recording before sending.")
    }
    if (this.recordingFinalizing) throw new Error("Wait for the recording to finish before sending.")

    const mySecret = getSecretKey(userId)
    if (!mySecret) {
      window.location.assign(`/keys?return_to=${encodeURIComponent(currentLocationPath())}`)
      return
    }

    const selectedValues = (name) => [
      ...new Set(
        [...form.querySelectorAll(`input[name='${name}']`)]
          .filter((el) => el.type === "hidden" || el.checked)
          .map((el) => el.value)
          .filter(Boolean),
      ),
    ]

    const friendIds = selectedValues("friends[]")
    const groupIds = selectedValues("groups[]")
    const includeSelf = !!form.querySelector("input[name='self']:checked, input[name='self'][type='hidden']")
    if (friendIds.length + groupIds.length === 0 && !includeSelf) {
      throw new Error("Pick at least one recipient.")
    }

    const textEl = form.querySelector("[data-role=text]")
    // Payload providers let other hooks (the map) contribute client-side-only
    // fields like coordinates without routing them through the server.
    const provider = window.veejrPayloadProviders && window.veejrPayloadProviders[form.id]
    const extra = provider
      ? provider()
      : form.dataset.payload
        ? JSON.parse(form.dataset.payload)
        : {}
    if (extra === null) throw new Error("Pick or acquire a location first.")
    const text = textEl ? textEl.value.trim() : ""
    const filesEl = form.querySelector("[data-role=files]")
    const files = filesEl ? [...filesEl.files] : []
    const recordedAudio = this.recordedAudio || []
    const recordedVideo = this.recordedVideo || []
    if (
      !text &&
      files.length === 0 &&
      recordedAudio.length === 0 &&
      recordedVideo.length === 0 &&
      Object.keys(extra).length === 0
    ) {
      throw new Error("Nothing to send.")
    }

    const btn = form.querySelector("button[type=submit]")
    this.sending = true
    if (btn) btn.disabled = true
    const originalLabel = btn?.textContent
    const busy = (label) => {
      if (btn) btn.textContent = label
    }

    try {
      busy("Resolving recipients…")
      const {recipients, missing_keys} = await this.pushWithReply("resolve_recipients", {
        friend_ids: friendIds,
        group_ids: groupIds,
        include_self: includeSelf,
      })
      if (missing_keys.length > 0) {
        throw new Error(`No encryption keys yet: ${missing_keys.join(", ")}. They must finish key setup first.`)
      }
      if (recipients.length === 0) throw new Error("Nobody to send to.")

      const attachments = []
      for (const [i, file] of files.entries()) {
        busy(`Encrypting attachment ${i + 1}/${files.length}…`)
        attachments.push(await encryptAndUpload(file))
      }
      for (const [i, entry] of recordedAudio.entries()) {
        busy(`Encrypting voice message ${i + 1}/${recordedAudio.length}...`)
        attachments.push(
          await encryptAndUpload(entry.file, {
            name: entry.file.name,
            mime: entry.file.type,
            size: entry.file.size,
            durationMs: entry.durationMs,
          })
        )
      }
      for (const [i, entry] of recordedVideo.entries()) {
        busy(`Encrypting video message ${i + 1}/${recordedVideo.length}...`)
        attachments.push(
          await encryptAndUpload(entry.file, {
            name: entry.file.name,
            mime: entry.file.type,
            size: entry.file.size,
            durationMs: entry.durationMs,
          })
        )
      }

      // recipient handles ride inside the encrypted payload so group
      // messages can show all participants after decryption
      const to = recipients.map((r) => r.handle || `@${r.username}`)
      const payload = kind === "self_note"
        ? noteDocument({body: text, attachments})
        : {v: 1, kind, text, attachments, to, sent_at: new Date().toISOString(), ...extra}
      const ttl = parseInt(form.querySelector("[data-role=ttl]")?.value || "", 10)
      const maxDisplays = parseInt(form.querySelector("[data-role=max-displays]")?.value || "", 10)
      const messageOptions = {}
      if (attachments.length > 0) {
        messageOptions.attachment_ids = attachments.map((attachment) => attachment.id)
      }
      if (Number.isInteger(ttl) && ttl > 0) {
        messageOptions.expires_at = new Date(Date.now() + ttl * 1000).toISOString()
      }
      if (Number.isInteger(maxDisplays) && maxDisplays > 0) {
        messageOptions.max_displays = maxDisplays
      }

      busy("Encrypting…")
      const envelopes = recipients.map((r) => ({
        recipient_id: r.id,
        ...sealFor(r.public_key, payload, mySecret),
      }))
      // Self-copy so our own history stays readable.
      if (!recipients.some((r) => String(r.id) === String(userId))) {
        envelopes.push({recipient_id: parseInt(userId), ...sealFor(myKey, payload, mySecret)})
      }

      busy("Sending…")
      await this.pushWithReply("send_batch", {kind, envelopes, ...messageOptions})

      form.reset()
      this.clearAudioRecordings()
      this.clearVideoRecordings()
      const err = form.querySelector("[data-role=error]")
      if (err) err.classList.add("hidden")
    } finally {
      this.sending = false
      if (btn) {
        btn.disabled = false
        btn.textContent = originalLabel
      }
    }
  },

  pushWithReply(event, params) {
    return new Promise((resolve, reject) => {
      this.pushEvent(event, params, (reply) => {
        if (reply.error) reject(new Error(reply.error))
        else resolve(reply)
      })
    })
  },
}

// Decrypt: renders one envelope's plaintext. The ciphertext arrives as data
// attributes; decryption happens here and the result is written with
// textContent (never innerHTML).
//
// Dataset: user-id, peer-key, ciphertext, nonce, kind
export const Decrypt = {
  mounted() {
    this.displayRecorded = false
    this.expired = false
    this.expiryTimer = null
    this.mediaCleanups = []
    this.render()
  },

  render() {
    const {userId, peerKey, ciphertext, nonce, kind} = this.el.dataset
    this.scheduleExpiry()
    if (this.expired) return

    const mySecret = getSecretKey(userId)

    this.el.textContent = ""

    if (!mySecret) {
      const a = document.createElement("a")
      a.href = `/keys?return_to=${encodeURIComponent(currentLocationPath())}`
      a.className = "link text-sm opacity-70"
      a.textContent = "🔒 Locked — unlock your keys to read"
      this.el.appendChild(a)
      return
    }

    const payload = openFrom(ciphertext, nonce, peerKey, mySecret)
    if (!payload) {
      const p = document.createElement("p")
      p.className = "text-error text-sm"
      p.textContent = "⚠ Could not decrypt (wrong keys or tampered data)."
      this.el.appendChild(p)
      return
    }

    this.el.veejrPayload = payload
    this.recordDisplay()

    if (kind === "note" && payload.title) {
      const h = document.createElement("p")
      h.className = "font-semibold"
      h.textContent = payload.title
      this.el.appendChild(h)
    }

    if (payload.text) {
      const p = document.createElement("p")
      p.className = "whitespace-pre-wrap"
      p.textContent = payload.text
      this.el.appendChild(p)
    }

    if (Array.isArray(payload.to) && payload.to.length > 1) {
      const p = document.createElement("p")
      p.className = "text-xs opacity-60 mt-1"
      p.textContent = `👥 ${payload.to.join(", ")}`
      this.el.appendChild(p)
    }

    if (kind === "location" || kind === "note") {
      if (typeof payload.lat === "number" && typeof payload.lng === "number") {
        const btn = document.createElement("button")
        btn.type = "button"
        btn.className = "btn btn-outline btn-xs mt-1"
        btn.setAttribute("data-role", "view-location")
        btn.textContent = `📍 ${payload.lat.toFixed(5)}, ${payload.lng.toFixed(5)} · View map`
        btn.addEventListener("click", () => {
          if (this.expired) return
          showLocationModal({
            lat: payload.lat,
            lng: payload.lng,
            title: payload.title,
            text: payload.text,
            kind,
          })
        })
        this.el.appendChild(btn)
      }
    }

    for (const att of payload.attachments || []) {
      const mime = attachmentMime(att)

      if (mime.startsWith("video/")) {
        this.renderVideoAttachment(att, mime)
        continue
      }

      if (previewableMedia(att)) {
        this.renderMediaAttachment(att)
        continue
      }

      if (mime.startsWith("audio/")) {
        this.renderAudioAttachment(att)
        continue
      }

      const btn = document.createElement("button")
      btn.className = "btn btn-outline btn-xs mt-1 mr-1"
      btn.textContent = `📎 ${att.name || "attachment"} (${Math.ceil((att.size || 0) / 1024)} KB)`
      btn.addEventListener("click", () =>
        (this.expired
          ? Promise.reject(new Error("This message has expired."))
          : downloadAttachment(att)
        ).catch((err) => (btn.textContent = `⚠ ${err.message}`))
      )
      this.el.appendChild(btn)
    }
  },

  renderMediaAttachment(att) {
    const btn = document.createElement("button")
    btn.type = "button"
    btn.className = "btn btn-outline btn-xs mt-1 mr-1"
    const mime = attachmentMime(att)
    const kind = mime.startsWith("image/") ? "Image" : "PDF"
    btn.textContent = `View ${kind}: ${att.name || "attachment"}`
    btn.addEventListener("click", async () => {
      if (this.expired) return
      btn.disabled = true
      const original = btn.textContent
      btn.textContent = `Opening ${kind.toLowerCase()}...`
      try {
        const blob = await decryptAttachmentBlob(att)
        if (this.expired) throw new Error("This message has expired.")
        showMediaModal({blob, title: att.name, mime})
        btn.textContent = original
      } catch (err) {
        btn.textContent = `Could not open ${kind.toLowerCase()}: ${err.message}`
      } finally {
        btn.disabled = false
      }
    })
    this.el.appendChild(btn)
  },

  renderVideoAttachment(att, mime) {
    const wrap = document.createElement("div")
    wrap.className = "mt-2 w-full max-w-lg overflow-hidden rounded-lg bg-black/5 p-2"
    wrap.addEventListener("contextmenu", (event) => event.preventDefault())

    const label = document.createElement("p")
    label.className = "mb-2 truncate text-xs opacity-70"
    const duration = att.duration_ms ? ` · ${Math.ceil(att.duration_ms / 1000)} sec` : ""
    label.textContent = `${att.name || "Video message"} (${Math.ceil((att.size || 0) / 1024)} KB${duration})`

    const play = document.createElement("button")
    play.type = "button"
    play.className = "btn btn-primary btn-sm"
    play.textContent = "Play video"
    play.addEventListener("click", async () => {
      if (this.expired) return
      play.disabled = true
      play.textContent = "Decrypting video..."

      try {
        const blob = await decryptAttachmentBlob(att)
        if (this.expired) throw new Error("This message has expired.")

        const url = URL.createObjectURL(blob)
        const video = document.createElement("video")
        video.controls = true
        video.playsInline = true
        video.preload = "metadata"
        video.controlsList = "nodownload noplaybackrate"
        video.disablePictureInPicture = true
        video.disableRemotePlayback = true
        video.setAttribute("aria-label", att.name || "Video message")
        video.className = "aspect-video w-full rounded bg-black object-contain"

        const source = document.createElement("source")
        source.src = url
        source.type = mime || blob.type || "video/webm"
        video.appendChild(source)

        let cleanedUp = false
        const cleanup = () => {
          if (cleanedUp) return
          cleanedUp = true
          video.pause()
          URL.revokeObjectURL(url)
        }
        this.mediaCleanups.push(cleanup)

        video.addEventListener(
          "error",
          () => {
            play.disabled = false
            play.textContent = "This browser cannot play this video format."
            if (!play.isConnected) video.replaceWith(play)
            cleanup()
          },
          {once: true}
        )

        play.replaceWith(video)
        video.play().catch(() => {})

      } catch (err) {
        play.disabled = false
        play.textContent = `Could not play video: ${err.message}`
      }
    })

    wrap.append(label, play)
    this.el.appendChild(wrap)
  },

  renderAudioAttachment(att) {
    const wrap = document.createElement("div")
    wrap.className = "mt-2 rounded-2xl bg-black/5 p-2"

    const label = document.createElement("p")
    label.className = "mb-1 text-xs opacity-70"
    label.textContent = `Voice message (${Math.ceil((att.size || 0) / 1024)} KB)`

    const status = document.createElement("p")
    status.className = "text-xs opacity-70"
    status.textContent = "Loading voice message..."

    wrap.append(label, status)
    this.el.appendChild(wrap)

    this.loadAudioAttachment(att, wrap, status).catch((err) => {
      if (this.expired) return
      status.className = "text-xs text-error"
      status.textContent = `Could not load voice message: ${err.message}`
      wrap.appendChild(this.audioDownloadButton(att))
    })
  },

  async loadAudioAttachment(att, wrap, status) {
    const blob = await decryptAttachmentBlob(att)
    if (this.expired) return
    const url = URL.createObjectURL(blob)
    const mime = attachmentMime(att) || blob.type || "audio/webm"

    const audio = document.createElement("audio")
    audio.controls = true
    audio.preload = "metadata"
    audio.className = "w-full max-w-xs"

    const source = document.createElement("source")
    source.src = url
    source.type = mime
    audio.appendChild(source)

    const fallback = document.createElement("a")
    fallback.href = url
    fallback.download = att.name || "voice-message"
    fallback.className = "link text-xs"
    fallback.textContent = "Download voice message"
    audio.appendChild(fallback)

    audio.addEventListener(
      "error",
      () => {
        status.className = "text-xs text-error"
        status.textContent = "This browser cannot play this voice format."
        if (!status.isConnected) wrap.appendChild(status)
        wrap.appendChild(fallback.cloneNode(true))
      },
      {once: true}
    )

    status.remove()
    wrap.appendChild(audio)
    this.mediaCleanups.push(() => URL.revokeObjectURL(url))
  },

  audioDownloadButton(att) {
    const btn = document.createElement("button")
    btn.type = "button"
    btn.className = "btn btn-outline btn-xs mt-2"
    btn.textContent = "Download voice message"
    btn.addEventListener("click", () =>
      (this.expired
        ? Promise.reject(new Error("This message has expired."))
        : downloadAttachment(att)
      ).catch((err) => {
        btn.textContent = `Could not download: ${err.message}`
      })
    )
    return btn
  },

  async recordDisplay() {
    if (this.displayRecorded || !this.el.dataset.publicId) return
    this.displayRecorded = true

    try {
      await pushWithReply(this, "message_displayed", {id: this.el.dataset.publicId})
    } catch {
      // Display accounting should never block reading a message.
    }
  },

  scheduleExpiry() {
    if (this.expiryTimer) clearTimeout(this.expiryTimer)

    const expiresAt = Date.parse(this.el.dataset.expiresAt || "")
    if (!Number.isFinite(expiresAt)) return

    const delay = expiresAt - Date.now()
    if (delay <= 0) {
      this.expire()
      return
    }

    this.expiryTimer = setTimeout(() => this.expire(), delay)
  },

  expire() {
    if (this.expired) return
    this.expired = true
    this.cleanupMedia()
    this.el.veejrPayload = null
    this.el.textContent = ""

    const p = document.createElement("p")
    p.className = "text-sm opacity-60"
    p.textContent = "This message has expired."
    this.el.appendChild(p)
  },

  destroyed() {
    if (this.expiryTimer) clearTimeout(this.expiryTimer)
    this.cleanupMedia()
  },

  cleanupMedia() {
    this.mediaCleanups.forEach((cleanup) => cleanup())
    this.mediaCleanups = []
  },
}

// Decrypts only the first line of the latest conversation item for list
// previews. Unlike the full Decrypt hook, this does not count as opening or
// displaying the message.
export const ConversationPreview = {
  mounted() {
    const {userId, peerKey, ciphertext, nonce, kind} = this.el.dataset
    const mySecret = getSecretKey(userId)

    if (!mySecret) {
      this.el.textContent = "Unlock your keys to preview"
      return
    }

    const payload = openFrom(ciphertext, nonce, peerKey, mySecret)

    if (!payload) {
      this.el.textContent = "Preview unavailable"
      return
    }

    const fallback = {
      location: "Location shared",
      note: "Map note",
      self_note: "Note",
      message: "Message",
    }[kind] || "Encrypted item"
    const preview = payload.text || payload.title || fallback

    this.el.textContent = String(preview).split(/\r?\n/, 1)[0].trim() || fallback
  },
}

export const MessageBubble = {
  mounted() {
    const edit = this.el.querySelector("[data-role=edit-message]")
    if (!edit) return

    edit.addEventListener("click", () => {
      this.openEditor().catch((err) => window.alert(err.message))
    })
  },

  async openEditor() {
    if (this.editor) {
      this.editor.querySelector("textarea").focus()
      return
    }

    const decryptEl = this.el.querySelector("[phx-hook='Decrypt'], [data-peer-key]")
    const payload = decryptEl && decryptEl.veejrPayload
    if (!payload) throw new Error("Unlock this message before editing it.")
    if (payload.attachments && payload.attachments.length > 0) {
      throw new Error("Messages with attachments cannot be edited yet.")
    }

    const publicId = decryptEl.dataset.publicId
    const {copies} = await pushWithReply(this, "prepare_edit", {id: publicId})
    const textarea = document.createElement("textarea")
    textarea.className = "mt-2 w-full min-w-64 resize-none rounded-2xl border border-base-300 bg-base-100 px-3 py-2 text-sm text-base-content shadow-sm outline-none focus:ring-2 focus:ring-primary/30"
    textarea.rows = 3
    textarea.value = payload.text || ""

    const save = document.createElement("button")
    save.type = "button"
    save.className = "rounded-full bg-primary px-3 py-1.5 text-xs font-medium text-primary-content transition hover:bg-primary/90"
    save.textContent = "Save"

    const cancel = document.createElement("button")
    cancel.type = "button"
    cancel.className = "rounded-full px-3 py-1.5 text-xs font-medium opacity-70 transition hover:bg-base-200 hover:opacity-100"
    cancel.textContent = "Cancel"

    const actions = document.createElement("div")
    actions.className = "mt-2 flex justify-end gap-2"
    actions.append(cancel, save)

    const editor = document.createElement("div")
    editor.className = "max-w-[78%]"
    editor.append(textarea, actions)
    this.el.appendChild(editor)
    this.editor = editor
    textarea.focus()

    cancel.addEventListener("click", () => this.closeEditor())
    save.addEventListener("click", async () => {
      const text = textarea.value.trim()
      if (!text) return window.alert("Message text cannot be empty.")

      const mySecret = getSecretKey(decryptEl.dataset.userId)
      if (!mySecret) throw new Error("Unlock your keys before editing.")

      save.disabled = true
      save.textContent = "Saving..."

      try {
        const nextPayload = {...payload, text, edited_at: new Date().toISOString()}
        const envelopes = copies.map((copy) => ({
          public_id: copy.public_id,
          ...sealFor(copy.public_key, nextPayload, mySecret),
        }))
        await pushWithReply(this, "edit_batch", {id: publicId, envelopes})
        decryptEl.dataset.ciphertext = envelopes.find((entry) => entry.public_id === publicId)?.ciphertext || decryptEl.dataset.ciphertext
        decryptEl.dataset.nonce = envelopes.find((entry) => entry.public_id === publicId)?.nonce || decryptEl.dataset.nonce
        decryptEl.veejrPayload = nextPayload
        decryptEl.textContent = ""
        const p = document.createElement("p")
        p.className = "whitespace-pre-wrap"
        p.textContent = text
        decryptEl.appendChild(p)
        this.closeEditor()
      } finally {
        save.disabled = false
        save.textContent = "Save"
      }
    })
  },

  closeEditor() {
    if (this.editor) this.editor.remove()
    this.editor = null
  },
}

const selfNoteColors = new Set(["default", "sand", "rose", "violet", "blue", "mint"])

function normalizeSelfNoteColor(value) {
  return selfNoteColors.has(value) ? value : "default"
}

function noteDocument(payload = {}) {
  const now = new Date().toISOString()
  return {
    v: 2,
    kind: "self_note",
    note_id: payload.note_id || crypto.randomUUID(),
    title: payload.title || "",
    body: payload.body || "",
    checklist: Array.isArray(payload.checklist) ? payload.checklist : [],
    labels: Array.isArray(payload.labels) ? payload.labels : [],
    color: normalizeSelfNoteColor(payload.color),
    pinned: !!payload.pinned,
    archived_at: payload.archived_at || null,
    trashed_at: payload.trashed_at || null,
    created_at: payload.created_at || now,
    updated_at: now,
    attachments: Array.isArray(payload.attachments) ? payload.attachments : [],
    settings: {move_checked_to_bottom: !!payload.settings?.move_checked_to_bottom},
    legacy_message_id: payload.legacy_message_id || null,
  }
}

function normalizeNoteSearch(value) {
  return String(value ?? "")
    .normalize("NFKD")
    .replace(/\p{M}/gu, "")
    .toLocaleLowerCase()
    .replace(/\s+/g, " ")
    .trim()
}

function noteSearchClauses(value) {
  const clauses = []
  const query = normalizeNoteSearch(value).replace(/[“”„‟«»]/g, "\"")

  for (const match of query.matchAll(/"([^"]*)"|"([^"]*)$|([^"\s]+)/g)) {
    const clause = normalizeNoteSearch(match[1] ?? match[2] ?? match[3])
    if (clause) clauses.push(clause)
  }

  return clauses
}

const selfNoteSearchIndex = new WeakMap()

function noteEditor(board, payload, save, {mount = null, tall = false} = {}) {
  const returnFocus = document.activeElement
  const inline = !!mount
  const colorCard = mount?.closest(".self-note-card")
  const originalColor = normalizeSelfNoteColor(colorCard?.dataset.noteColor || payload.color)
  const previousContent = document.createDocumentFragment()
  if (inline) {
    while (mount.firstChild) previousContent.appendChild(mount.firstChild)
    mount.closest(".self-note-card")?.setAttribute("data-editing", "true")
  }
  const editor = document.createElement("section")
  editor.setAttribute("data-role", "note-editor")
  editor.dataset.tall = String(inline && tall)
  editor.className = inline
    ? "self-note-inline-editor rounded-xl border border-primary/30 bg-base-100/95 p-3 shadow-inner"
    : "mb-5 rounded-2xl border border-primary/30 bg-base-100 p-4 shadow-lg"
  editor.innerHTML = `<input data-note-title class="mb-3 w-full bg-transparent text-lg font-semibold outline-none" placeholder="Title"><textarea data-note-body class="min-h-28 w-full resize-y bg-transparent text-sm outline-none" placeholder="Take a note…"></textarea><input data-note-labels class="mt-3 w-full bg-transparent text-xs outline-none" placeholder="Labels, separated by commas"><div class="mt-3 flex flex-wrap items-center gap-2"><label title="Attach files" class="flex size-9 cursor-pointer items-center justify-center rounded-full bg-base-200 opacity-70 transition hover:bg-base-300 hover:opacity-100"><span data-note-attachment-icon aria-hidden="true"></span><span class="sr-only">Attach files</span><input data-note-files type="file" multiple class="sr-only" aria-label="Attach files"></label><button type="button" data-note-audio title="Record voice note" aria-label="Record voice note" class="flex size-9 items-center justify-center rounded-full bg-base-200 opacity-70 transition hover:bg-base-300 hover:opacity-100"><span data-note-audio-icon aria-hidden="true"></span></button><button type="button" data-note-video title="Record video note" aria-label="Record video note" class="flex size-9 items-center justify-center rounded-full bg-base-200 opacity-70 transition hover:bg-base-300 hover:opacity-100"><span data-note-video-icon aria-hidden="true"></span></button><button type="button" data-note-camera title="Switch camera" aria-label="Switch camera" class="flex size-9 items-center justify-center rounded-full bg-base-200 opacity-70 transition hover:bg-base-300 hover:opacity-100"><span data-note-camera-icon aria-hidden="true"></span></button><button type="button" data-note-checklist class="btn btn-ghost btn-xs">Checklist</button><select data-note-color class="select select-sm"><option value="default">Default</option><option value="sand">Sand</option><option value="rose">Rose</option><option value="violet">Violet</option><option value="blue">Blue</option><option value="mint">Mint</option></select><span class="flex-1"></span><button type="button" data-note-cancel class="btn btn-ghost btn-sm">Cancel</button><button type="button" data-note-save class="btn btn-primary btn-sm">Save note</button></div><p data-note-record-status class="mt-3 hidden text-sm opacity-70" aria-live="polite"></p><div data-note-recordings class="mt-3 space-y-2"></div><p data-note-error class="mt-3 hidden text-sm text-error" role="alert"></p><div data-note-items class="mt-3 space-y-2"></div>`
  const title = editor.querySelector("[data-note-title]")
  const body = editor.querySelector("[data-note-body]")
  const labels = editor.querySelector("[data-note-labels]")
  const fileInput = editor.querySelector("[data-note-files]")
  const color = editor.querySelector("[data-note-color]")
  color.setAttribute("aria-label", "Note color")
  const items = editor.querySelector("[data-note-items]")
  const settings = payload.settings || {}
  const completedLast = document.createElement("label")
  completedLast.className = "flex items-center gap-1 text-xs"
  completedLast.innerHTML = '<input data-note-sort-checked type="checkbox"> Completed last'
  const sortChecked = completedLast.querySelector("input")
  sortChecked.checked = !!settings.move_checked_to_bottom
  color.insertAdjacentElement("afterend", completedLast)
  ;[["attachment", "[data-note-attachment-icon]"], ["audio", "[data-note-audio-icon]"], ["video", "[data-note-video-icon]"], ["camera", "[data-note-camera-icon]"]].forEach(([name, target]) => {
    const icon = board.querySelector(`[data-note-icon="${name}"]`)?.cloneNode(true)
    if (icon) editor.querySelector(target)?.replaceChildren(icon)
  })
  const recordings = {audio: [], video: [], recorder: null, stream: null, kind: null, finalizing: false, timer: null, facingMode: "user"}
  const recordStatus = editor.querySelector("[data-note-record-status]")
  const recordPreview = editor.querySelector("[data-note-recordings]")
  const setRecordStatus = (message) => {
    recordStatus.textContent = message
    recordStatus.classList.toggle("hidden", !message)
  }
  const stopTracks = () => {
    recordings.stream?.getTracks().forEach((track) => track.stop())
    recordings.stream = null
  }
  const cleanupRecordings = () => {
    clearTimeout(recordings.timer)
    if (recordings.recorder?.state === "recording") recordings.recorder.stop()
    stopTracks()
    ;[...recordings.audio, ...recordings.video].forEach((entry) => URL.revokeObjectURL(entry.url))
  }
  const renderRecordings = () => {
    recordPreview.textContent = ""
    for (const [kind, entries] of [["audio", recordings.audio], ["video", recordings.video]]) {
      entries.forEach((entry, index) => {
        const row = document.createElement("div")
        row.className = "flex items-center gap-2 rounded-lg bg-base-200 p-2"
        const media = document.createElement(kind)
        media.controls = true; media.src = entry.url
        media.className = kind === "video" ? "max-h-48 min-w-0 flex-1 rounded bg-black" : "min-w-0 flex-1"
        const remove = document.createElement("button")
        remove.type = "button"; remove.className = "btn btn-ghost btn-xs"; remove.textContent = "Remove"
        remove.addEventListener("click", () => {
          URL.revokeObjectURL(entry.url)
          entries.splice(index, 1)
          renderRecordings()
        })
        row.append(media, remove); recordPreview.appendChild(row)
      })
    }
  }
  const toggleRecording = async (kind) => {
    if (recordings.finalizing) throw new Error("Wait for the recording to finish.")
    if (recordings.recorder?.state === "recording") {
      if (recordings.kind !== kind) throw new Error("Stop the current recording first.")
      recordings.finalizing = true
      recordings.recorder.stop()
      setRecordStatus("Finishing recording…")
      return
    }
    if (!navigator.mediaDevices?.getUserMedia || !window.MediaRecorder) throw new Error("Recording is not supported in this browser.")
    const mimeType = kind === "audio" ? preferredAudioMime() : preferredVideoMime()
    const stream = await navigator.mediaDevices.getUserMedia(kind === "audio" ? {audio: true} : {audio: true, video: {facingMode: {ideal: recordings.facingMode}, width: {ideal: 1280}, height: {ideal: 720}}})
    const options = mimeType ? {mimeType, ...(kind === "video" ? {videoBitsPerSecond: 2_000_000} : {})} : undefined
    const recorder = new MediaRecorder(stream, options)
    const chunks = []; const startedAt = Date.now()
    recorder.addEventListener("dataavailable", (event) => { if (event.data?.size > 0) chunks.push(event.data) })
    recorder.addEventListener("stop", () => {
      clearTimeout(recordings.timer); stopTracks()
      recordings.finalizing = false; recordings.recorder = null; recordings.kind = null
      const type = recorder.mimeType || mimeType || (kind === "audio" ? "audio/webm" : "video/webm")
      const blob = new Blob(chunks, {type})
      if (blob.size === 0) return setRecordStatus("Recording was empty.")
      const extension = type.includes("mp4") ? (kind === "audio" ? "m4a" : "mp4") : type.includes("ogg") ? "ogg" : "webm"
      const file = new File([blob], `${kind}-note-${new Date().toISOString().replace(/[:.]/g, "-")}.${extension}`, {type})
      recordings[kind].push({file, url: URL.createObjectURL(blob), durationMs: Date.now() - startedAt})
      renderRecordings(); setRecordStatus(`${kind === "audio" ? "Audio" : "Video"} ready to attach.`)
    })
    recordings.stream = stream; recordings.recorder = recorder; recordings.kind = kind
    recorder.start(1_000)
    if (kind === "video") recordings.timer = setTimeout(() => recorder.state === "recording" && recorder.stop(), MAX_VIDEO_DURATION_MS)
    setRecordStatus(`Recording ${kind}… click ${kind === "audio" ? "Microphone" : "Video"} again to stop.`)
  }
  title.value = payload.title || ""
  body.value = payload.body || ""
  labels.value = (payload.labels || []).join(", ")
  color.value = normalizeSelfNoteColor(payload.color)
  const previewColor = () => {
    const value = normalizeSelfNoteColor(color.value)
    editor.dataset.noteColor = value
    if (colorCard) colorCard.dataset.noteColor = value
  }
  color.addEventListener("change", previewColor)
  previewColor()
  const renderItems = () => {
    items.textContent = ""
    ;(payload.checklist || []).forEach((item, index) => {
      const row = document.createElement("label")
      row.className = "flex items-center gap-2 text-sm"
      const check = document.createElement("input")
      check.type = "checkbox"; check.checked = !!item.checked
      const input = document.createElement("input")
      input.value = item.text || ""; input.className = "flex-1 bg-transparent outline-none"
      check.addEventListener("change", () => { item.checked = check.checked })
      input.addEventListener("input", () => { item.text = input.value })
      input.addEventListener("keydown", (event) => {
        if (event.key === "Enter") {
          event.preventDefault()
          payload.checklist.splice(index + 1, 0, {id: crypto.randomUUID(), text: "", checked: false})
          renderItems()
          items.querySelectorAll("input:not([type=checkbox])")[index + 1]?.focus()
        } else if (event.key === "Backspace" && !input.value && payload.checklist.length > 1) {
          event.preventDefault()
          payload.checklist.splice(index, 1)
          renderItems()
          items.querySelectorAll("input:not([type=checkbox])")[Math.max(0, index - 1)]?.focus()
        }
      })
      row.append(check, input); items.appendChild(row)
    })
  }
  renderItems()
  editor.querySelector("[data-note-checklist]").addEventListener("click", () => {
    payload.checklist = [...(payload.checklist || []), {id: crypto.randomUUID(), text: "", checked: false}]
    renderItems(); items.querySelector("input:last-child")?.focus()
  })
  editor.querySelector("[data-note-audio]").addEventListener("click", () => toggleRecording("audio").catch((error) => setRecordStatus(error.message)))
  editor.querySelector("[data-note-video]").addEventListener("click", () => toggleRecording("video").catch((error) => setRecordStatus(error.message)))
  editor.querySelector("[data-note-camera]").addEventListener("click", () => {
    if (recordings.recorder?.state === "recording" || recordings.finalizing) return setRecordStatus("Stop recording before switching cameras.")
    recordings.facingMode = recordings.facingMode === "user" ? "environment" : "user"
    setRecordStatus(`The ${recordings.facingMode === "user" ? "front" : "rear"} camera will be used next.`)
  })
  let saveTimer = null
  let saving = false
  const scheduleSave = () => {
    if (!payload.note_id || saving) return
    clearTimeout(saveTimer)
    saveTimer = setTimeout(() => submit(), 600)
  }
  // Auto-save only when focus leaves the editor entirely (Keep-style
  // "click away to save"), never when moving between the editor's own fields —
  // otherwise editing a note would save and close it mid-edit.
  ;[title, body, labels, color, sortChecked].forEach((field) =>
    field.addEventListener("blur", (event) => {
      if (!editor.contains(event.relatedTarget)) scheduleSave()
    }),
  )
  let closed = false
  const closeEditor = ({restore = true} = {}) => {
    if (closed) return
    closed = true
    clearTimeout(saveTimer)
    cleanupRecordings()
    editor.remove()
    if (inline) {
      if (restore && colorCard) colorCard.dataset.noteColor = originalColor
      mount.closest(".self-note-card")?.removeAttribute("data-editing")
      if (restore) mount.appendChild(previousContent)
    }
    if (returnFocus?.isConnected) returnFocus.focus()
  }
  editor.querySelector("[data-note-cancel]").addEventListener("click", closeEditor)
  const submit = async () => {
    if (saving) return
    const error = editor.querySelector("[data-note-error]")
    error.textContent = ""
    error.classList.add("hidden")
    const next = noteDocument({...payload, title: title.value.trim(), body: body.value.trim(), color: color.value, labels: labels.value.split(",").map((v) => v.trim()).filter(Boolean).slice(0, 10), settings: {move_checked_to_bottom: sortChecked.checked}})
    next.checklist = (payload.checklist || []).filter((item) => item.text.trim())
    if (next.settings.move_checked_to_bottom) next.checklist.sort((left, right) => Number(left.checked) - Number(right.checked))
    const files = [...fileInput.files]
    const captured = [...recordings.audio, ...recordings.video]
    if (recordings.recorder?.state === "recording" || recordings.finalizing) {
      error.textContent = "Stop the recording before saving."
      error.classList.remove("hidden")
      return
    }
    if (!next.title && !next.body && next.checklist.length === 0 && next.attachments.length === 0 && files.length === 0 && captured.length === 0) return
    const button = editor.querySelector("[data-note-save]")
    saving = true
    button.disabled = true; button.textContent = "Encrypting…"
    try {
      for (const file of files) {
        button.textContent = `Encrypting ${file.name}…`
        next.attachments.push(await encryptAndUpload(file))
      }
      for (const entry of captured) {
        button.textContent = `Encrypting ${entry.file.name}…`
        next.attachments.push(await encryptAndUpload(entry.file, {name: entry.file.name, mime: entry.file.type, size: entry.file.size, durationMs: entry.durationMs}))
      }
      await save(next)
      closeEditor({restore: !inline})
      if (inline) mount.dispatchEvent(new CustomEvent("self-notes:refresh"))
    } catch (saveError) {
      saving = false
      button.disabled = false; button.textContent = "Save note"
      error.textContent = saveError.message || "Could not save this note."
      error.classList.remove("hidden")
    }
  }
  editor.querySelector("[data-note-save]").addEventListener("click", submit)
  editor.addEventListener("keydown", (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key === "Enter") submit()
  })
  if (inline) mount.appendChild(editor)
  else board.prepend(editor)
  title.focus()
}

function noteAttachmentPreview(att) {
  const mime = attachmentMime(att)
  const wrap = document.createElement("div")
  wrap.className = "group relative overflow-hidden rounded-xl border border-base-300 bg-base-200/50"
  wrap.addEventListener("click", (event) => event.stopPropagation())

  const download = () => {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "btn btn-ghost btn-xs"
    button.textContent = `Download ${att.name || "file"}`
    button.addEventListener("click", () => {
      button.disabled = true
      downloadAttachment(att)
        .catch((error) => { button.textContent = error.message || "Could not download" })
        .finally(() => { if (button.isConnected) button.disabled = false })
    })
    return button
  }

  if (mime.startsWith("image/")) {
    const status = document.createElement("p")
    status.className = "p-3 text-xs opacity-70"
    status.textContent = "Decrypting image…"
    wrap.appendChild(status)
    decryptAttachmentBlob(att)
      .then((blob) => {
        const url = URL.createObjectURL(blob)
        const image = document.createElement("img")
        image.src = url
        image.alt = att.name || "Image attachment"
        image.className = "max-h-64 w-full cursor-zoom-in object-cover"
        image.addEventListener("click", () => showMediaModal({blob, title: att.name, mime}))
        status.replaceWith(image)
      })
      .catch((error) => {
        status.textContent = `Could not display image: ${error.message}`
        status.className = "p-3 text-xs text-error"
        wrap.appendChild(download())
      })
    return wrap
  }

  const label = document.createElement("p")
  label.className = "truncate px-3 pt-3 text-xs font-medium"
  label.textContent = att.name || "Attachment"
  wrap.appendChild(label)

  if (mime === "application/pdf") {
    const open = document.createElement("button")
    open.type = "button"
    open.className = "btn btn-ghost btn-xs m-2"
    open.textContent = "Open PDF"
    open.addEventListener("click", async () => {
      open.disabled = true
      try {
        showMediaModal({blob: await decryptAttachmentBlob(att), title: att.name, mime})
      } catch (error) {
        open.textContent = error.message || "Could not open PDF"
      } finally {
        if (open.isConnected) open.disabled = false
      }
    })
    wrap.append(open, download())
    return wrap
  }

  if (mime.startsWith("audio/") || mime.startsWith("video/")) {
    const play = document.createElement("button")
    play.type = "button"
    play.className = "btn btn-primary btn-xs m-2"
    play.textContent = mime.startsWith("video/") ? "Play video" : "Play audio"
    play.addEventListener("click", async () => {
      play.disabled = true
      play.textContent = "Decrypting…"
      try {
        const blob = await decryptAttachmentBlob(att)
        const url = URL.createObjectURL(blob)
        const media = document.createElement(mime.startsWith("video/") ? "video" : "audio")
        media.controls = true
        media.preload = "metadata"
        media.className = mime.startsWith("video/") ? "aspect-video w-full bg-black object-contain" : "mx-2 mb-2 w-[calc(100%-1rem)]"
        media.src = url
        media.addEventListener("ended", () => URL.revokeObjectURL(url), {once: true})
        play.replaceWith(media)
      } catch (error) {
        play.disabled = false
        play.textContent = error.message || "Could not play attachment"
      }
    })
    wrap.append(play, download())
    return wrap
  }

  wrap.append(download())
  return wrap
}

// --- Google Keep (Takeout) import ---------------------------------------
// The zip is read, mapped, encrypted, and uploaded entirely in the browser;
// Keep note content never reaches the server as plaintext.
const KEEP_PREFIX = "Takeout/Keep/"

// A Keep note is imported only if it is active (not archived/trashed) and
// carries something — text, a non-empty checklist item, or an attachment.
function keepNoteIsImportable(k) {
  if (k.isArchived || k.isTrashed) return false
  const hasText = typeof k.textContent === "string" && k.textContent.trim() !== ""
  const hasList = Array.isArray(k.listContent) && k.listContent.some((i) => (i.text || "").trim() !== "")
  const hasAttach = Array.isArray(k.attachments) && k.attachments.length > 0
  return hasText || hasList || hasAttach
}

function keepUsecToIso(usec) {
  const n = Number(usec)
  return Number.isFinite(n) && n > 0 ? new Date(Math.round(n / 1000)).toISOString() : new Date().toISOString()
}

// Maps one Keep note (with already-uploaded attachment descriptors) into a
// v2 self_note document matching noteDocument()'s shape.
function keepNoteToDocument(k, attachments) {
  const checklist = (Array.isArray(k.listContent) ? k.listContent : [])
    .filter((i) => (i.text || "").trim() !== "")
    .map((i) => ({id: crypto.randomUUID(), text: i.text || "", checked: !!i.isChecked}))
  return {
    v: 2,
    kind: "self_note",
    note_id: crypto.randomUUID(),
    title: k.title || "",
    body: k.textContent || "",
    checklist,
    labels: [],
    color: "default",
    pinned: !!k.isPinned,
    archived_at: null,
    trashed_at: null,
    created_at: keepUsecToIso(k.createdTimestampUsec),
    updated_at: keepUsecToIso(k.userEditedTimestampUsec),
    attachments,
    settings: {move_checked_to_bottom: false},
    legacy_message_id: null,
  }
}

// An opaque, deterministic idempotency key for a Keep note. Derived from the
// account secret + the note's stable Keep identity (its creation timestamp), so
// re-importing the same note yields the same key while the server learns nothing
// about the note's content or its Keep timestamp.
async function keepDedupKey(secret, k) {
  const identity = k.createdTimestampUsec
    ? "c:" + k.createdTimestampUsec
    : "h:" + (k.title || "") + "|" + (k.textContent || "").slice(0, 200)
  const suffix = new TextEncoder().encode("|keep-dedup|" + identity)
  const material = new Uint8Array(secret.length + suffix.length)
  material.set(secret, 0)
  material.set(suffix, secret.length)
  const digest = await crypto.subtle.digest("SHA-256", material)
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("")
}

// A canonical string of a Keep note's content — anything that, if changed,
// means the note should be re-synced (title, body, checklist, attachments, pin).
function keepContentString(k) {
  const list = (Array.isArray(k.listContent) ? k.listContent : [])
    .map((i) => (i.isChecked ? "1" : "0") + ":" + (i.text || ""))
    .join("\n")
  const atts = (Array.isArray(k.attachments) ? k.attachments : []).map((a) => a.filePath || "").join(",")
  return JSON.stringify({t: k.title || "", b: k.textContent || "", l: list, a: atts, p: !!k.isPinned})
}

// An opaque content fingerprint (secret-salted), stored server-side so a
// re-import can tell a changed note from an unchanged one.
async function keepContentFingerprint(secret, k) {
  const suffix = new TextEncoder().encode("|keep-version|" + keepContentString(k))
  const material = new Uint8Array(secret.length + suffix.length)
  material.set(secret, 0)
  material.set(suffix, secret.length)
  const digest = await crypto.subtle.digest("SHA-256", material)
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("")
}

// A small fixed progress banner for the import run.
function keepImportStatus() {
  const wrap = document.createElement("div")
  wrap.className =
    "fixed inset-x-0 bottom-4 z-50 mx-auto w-[min(92vw,28rem)] rounded-xl border border-base-300 bg-base-100 p-4 shadow-xl"
  wrap.setAttribute("role", "status")
  wrap.setAttribute("aria-live", "polite")
  wrap.innerHTML =
    '<p data-msg class="text-sm font-medium"></p><progress data-bar class="progress progress-primary mt-2 w-full" value="0" max="1"></progress>'
  document.body.appendChild(wrap)
  const msg = wrap.querySelector("[data-msg]")
  const bar = wrap.querySelector("[data-bar]")
  return {
    set(text, value) { msg.textContent = text; if (value != null) bar.value = value },
    done(text) { msg.textContent = text; bar.value = 1 },
    fail(text) { msg.textContent = text; bar.classList.add("progress-error"); setTimeout(() => wrap.remove(), 6000) },
  }
}

export const SelfNotesBoard = {
  mounted() {
    this.filter = "active"
    this.view = "grid"
    this.label = null
    this.searchTerm = ""
    this.queryClauses = []
    this.allNotesRequested = false
    this.dateFrom = ""
    this.dateTo = ""
    this.selected = new Map()
    this.el.addEventListener("self-notes:new", () => this.create())
    this.el.querySelector("[data-role=new-note]")?.addEventListener("click", () => this.create())
    this.el.addEventListener("self-notes:import", () => this.el.querySelector("[data-role=import-file]")?.click())
    this.el.querySelector("[data-role=import-file]")?.addEventListener("change", (event) => {
      const file = event.target.files?.[0]
      event.target.value = ""
      if (file) this.importKeep(file)
    })
    this.el.querySelector("[data-role=search]")?.addEventListener("input", (event) => {
      this.searchTerm = event.target.value
      this.queryClauses = noteSearchClauses(this.searchTerm)
      if (this.queryClauses.length > 0 && !this.allNotesRequested && this.el.querySelector("[data-role=load-all-notes]")) {
        this.allNotesRequested = true
        this.pushEvent("load_all_notes", {}, () => { this.allNotesRequested = false })
      }
      this.applyFilters()
    })
    this.el.querySelector("[data-role=date-from]")?.addEventListener("change", (event) => {
      this.dateFrom = event.target.value
      this.applyFilters()
    })
    this.el.querySelector("[data-role=date-to]")?.addEventListener("change", (event) => {
      this.dateTo = event.target.value
      this.applyFilters()
    })
    this.el.querySelectorAll("[data-role=date-preset]").forEach((button) => button.addEventListener("click", () => {
      const days = Number(button.dataset.days)
      const today = new Date()
      const from = new Date(today)
      from.setDate(today.getDate() - days)
      const formatDate = (date) => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`
      this.dateFrom = formatDate(from)
      this.dateTo = formatDate(today)
      const fromInput = this.el.querySelector("[data-role=date-from]")
      const toInput = this.el.querySelector("[data-role=date-to]")
      if (fromInput) fromInput.value = this.dateFrom
      if (toInput) toInput.value = this.dateTo
      this.el.querySelectorAll("[data-role=date-preset]").forEach((control) => control.setAttribute("aria-pressed", String(control === button)))
      this.applyFilters()
    }))
    this.el.querySelector("[data-role=clear-dates]")?.addEventListener("click", () => {
      this.dateFrom = ""
      this.dateTo = ""
      const from = this.el.querySelector("[data-role=date-from]")
      const to = this.el.querySelector("[data-role=date-to]")
      if (from) from.value = ""
      if (to) to.value = ""
      this.el.querySelectorAll("[data-role=date-preset]").forEach((control) => control.setAttribute("aria-pressed", "false"))
      this.applyFilters()
    })
    this.el.querySelectorAll("[data-role=filter]").forEach((button) => button.addEventListener("click", () => {
      this.filter = button.dataset.filter
      this.el.querySelectorAll("[data-role=filter]").forEach((control) => control.setAttribute("aria-pressed", String(control === button)))
      this.applyFilters()
    }))
    this.el.querySelectorAll("[data-role=view]").forEach((button) => button.addEventListener("click", () => {
      this.view = button.dataset.view
      this.el.querySelectorAll("[data-role=view]").forEach((control) => control.setAttribute("aria-pressed", String(control === button)))
      this.applyFilters()
    }))
    this.el.querySelector("[data-role=bulk-clear]")?.addEventListener("click", () => this.clearSelection())
    this.el.querySelector("[data-role=bulk-pin]")?.addEventListener("click", () => this.bulk((note) => { note.pinned = true }))
    this.el.querySelector("[data-role=bulk-archive]")?.addEventListener("click", () => this.bulk((note) => { note.archived_at = new Date().toISOString(); note.trashed_at = null }))
    this.el.querySelector("[data-role=bulk-trash]")?.addEventListener("click", () => this.bulk((note) => { note.trashed_at = new Date().toISOString() }))
    this.el.querySelector("[data-role=bulk-color]")?.addEventListener("click", () => {
      const input = window.prompt("Color: default, sand, rose, violet, blue, or mint", "default")
      if (!input) return
      const color = input.trim().toLocaleLowerCase()
      if (!selfNoteColors.has(color)) return
      this.bulk((note) => { note.color = color })
    })
    this.el.querySelector("[data-role=bulk-label]")?.addEventListener("click", () => {
      const label = window.prompt("Add a label to selected notes")?.trim()
      if (label) this.bulk((note) => { note.labels = [...new Set([...(note.labels || []), label])].slice(0, 10) })
    })
    this.el.querySelector("[data-role=delete-trashed]")?.addEventListener("click", () => this.deleteTrashed())
    this.onEdit = (event) => this.edit(event.detail)
    this.onSave = (event) => this.save(event.detail)
    this.onRendered = () => this.applyFilters()
    this.onSelected = (event) => this.setSelected(event.detail)
    this.onKeydown = (event) => {
      if (!this.el.isConnected) return
      const editing = event.target.matches("input, textarea, select")
      if (event.key === "Escape") {
        const editor = this.el.querySelector("[data-role=note-editor]")
        if (editor) {
          editor.querySelector("[data-note-cancel]")?.click()
          return
        }
        if (this.selected.size > 0) this.clearSelection()
      }
      if (editing) return
      if (event.key === "/") { event.preventDefault(); this.el.querySelector("[data-role=search]")?.focus() }
      if (event.key.toLowerCase() === "c") { event.preventDefault(); this.create() }
    }
    window.addEventListener("veejr:self-note-edit", this.onEdit)
    window.addEventListener("veejr:self-note-save", this.onSave)
    window.addEventListener("veejr:self-note-rendered", this.onRendered)
    window.addEventListener("veejr:self-note-selected", this.onSelected)
    window.addEventListener("keydown", this.onKeydown)
  },
  updated() {
    const search = this.el.querySelector("[data-role=search]")
    if (search) search.value = this.searchTerm
    this.applyFilters()
  },
  destroyed() {
    window.removeEventListener("veejr:self-note-edit", this.onEdit)
    window.removeEventListener("veejr:self-note-save", this.onSave)
    window.removeEventListener("veejr:self-note-rendered", this.onRendered)
    window.removeEventListener("veejr:self-note-selected", this.onSelected)
    window.removeEventListener("keydown", this.onKeydown)
  },
  setSelected({element, payload, checked}) {
    if (checked) this.selected.set(element.dataset.publicId, {element, payload})
    else this.selected.delete(element.dataset.publicId)
    const toolbar = this.el.querySelector("[data-role=selection-toolbar]")
    toolbar.classList.toggle("hidden", this.selected.size === 0)
    toolbar.classList.toggle("flex", this.selected.size > 0)
    toolbar.querySelector("[data-role=selection-count]").textContent = `${this.selected.size} selected`
  },
  clearSelection() {
    this.selected.clear()
    this.el.querySelectorAll("[data-role=note-select]").forEach((input) => { input.checked = false })
    this.el.querySelector("[data-role=selection-toolbar]").classList.add("hidden")
    this.el.querySelector("[data-role=selection-toolbar]").classList.remove("flex")
  },
  async bulk(update) {
    const selected = [...this.selected.values()]
    for (const entry of selected) {
      update(entry.payload)
      await this.save(entry)
      const card = entry.element.closest(".self-note-card")
      card.dataset.notePinned = String(!!entry.payload.pinned)
      card.dataset.noteArchived = String(!!entry.payload.archived_at)
      card.dataset.noteTrashed = String(!!entry.payload.trashed_at)
    }
    this.clearSelection()
    this.applyFilters()
  },
  applyFilters() {
    const queryClauses = this.queryClauses || []
    const grid = this.el.querySelector("#self-notes-grid")
    const cards = [...this.el.querySelectorAll(".self-note-card")]
    grid.className = this.view === "list" ? "space-y-3" : "columns-1 gap-4 sm:columns-2 xl:columns-3"
    cards
      .sort((left, right) => Number(right.dataset.notePinned === "true") - Number(left.dataset.notePinned === "true") || String(right.dataset.noteUpdated || "").localeCompare(String(left.dataset.noteUpdated || "")))
      .forEach((card) => grid.appendChild(card))
    const labels = [...new Set(cards.flatMap((card) => JSON.parse(card.dataset.noteLabels || "[]")))].sort()
    const labelBar = this.el.querySelector("[data-role=labels]")
    if (labelBar) {
      labelBar.textContent = ""
      labels.forEach((label) => {
        const chip = document.createElement("button")
        chip.type = "button"; chip.className = "rounded-full bg-base-200 px-2 py-0.5 text-xs hover:bg-base-300"
        chip.textContent = `#${label}`; chip.setAttribute("aria-pressed", String(this.label === label))
        chip.addEventListener("click", () => { this.label = this.label === label ? null : label; this.applyFilters() })
        labelBar.appendChild(chip)
      })
    }
    let visibleCount = 0
    cards.forEach((card) => {
      const stateMatch = this.filter === "reminders" ? false : this.filter === "trashed"
        ? card.dataset.noteTrashed === "true"
        : this.filter === "archived"
          ? card.dataset.noteArchived === "true" && card.dataset.noteTrashed !== "true"
          : card.dataset.noteArchived !== "true" && card.dataset.noteTrashed !== "true"
      const labelMatch = !this.label || JSON.parse(card.dataset.noteLabels || "[]").includes(this.label)
      const updatedOn = (card.dataset.noteUpdated || "").slice(0, 10)
      const dateMatch = (!this.dateFrom || updatedOn >= this.dateFrom) && (!this.dateTo || updatedOn <= this.dateTo)
      const noteSearch = selfNoteSearchIndex.get(card) || ""
      const searchMatch = queryClauses.every((clause) => noteSearch.includes(clause))
      card.hidden = !stateMatch || !labelMatch || !dateMatch || !searchMatch
      if (!card.hidden) visibleCount += 1
    })
    const filterStatus = this.el.querySelector("[data-role=filter-status]")
    if (filterStatus) {
      const suffix = this.filter === "reminders" ? " Reminders are not available yet." : ""
      const dateDescription = this.dateFrom || this.dateTo ? ` Updated ${this.dateFrom || "any time"} to ${this.dateTo || "today"}.` : ""
      filterStatus.textContent = `${visibleCount} note${visibleCount === 1 ? "" : "s"} shown.${dateDescription}${suffix}`
    }
    this.el.querySelector("[data-role=reminders-empty]")?.classList.toggle("hidden", this.filter !== "reminders")
    const deleteTrashed = this.el.querySelector("[data-role=delete-trashed]")
    if (deleteTrashed) {
      const count = cards.filter((card) => card.dataset.noteTrashed === "true").length
      deleteTrashed.disabled = count === 0
      deleteTrashed.textContent = count === 0
        ? "Delete all trashed forever"
        : `Delete all ${count} trashed note${count === 1 ? "" : "s"} forever`
    }
  },
  async deleteTrashed() {
    const button = this.el.querySelector("[data-role=delete-trashed]")
    const notes = [...this.el.querySelectorAll(".self-note-card")]
      .filter((card) => card.dataset.noteTrashed === "true")
      .map((card) => card.querySelector("[data-public-id]")?.dataset.publicId)
      .filter(Boolean)
    if (notes.length === 0) return this.applyFilters()
    if (!window.confirm(`Permanently delete ${notes.length} trashed note${notes.length === 1 ? "" : "s"}? This cannot be undone.`)) return
    button.disabled = true
    try {
      for (const [index, id] of notes.entries()) {
        button.textContent = `Deleting ${index + 1}/${notes.length}…`
        await pushWithReply(this, "delete_self_note", {id})
      }
      this.clearSelection()
      this.applyFilters()
    } catch (error) {
      button.textContent = error.message || "Could not delete all trashed notes"
      button.disabled = false
    }
  },
  async importKeep(file) {
    if (this._importing) return
    const {userId, peerKey: key} = this.el.dataset
    if (!userId || !key) return
    const secret = getSecretKey(userId)
    const status = keepImportStatus()
    if (!secret) return status.fail("Unlock your keys before importing.")
    this._importing = true
    try {
      status.set("Reading your Takeout zip…")
      const raw = new Uint8Array(await file.arrayBuffer())
      // Keep the note JSON and any attachment media; skip the redundant
      // per-note .html and the Labels.txt.
      const entries = unzipSync(raw, {
        filter: (f) => f.name.startsWith(KEEP_PREFIX) && !f.name.endsWith(".html") && !f.name.endsWith(".txt"),
      })

      const notes = []
      for (const [name, bytes] of Object.entries(entries)) {
        if (!name.endsWith(".json")) continue
        let note
        try { note = JSON.parse(strFromU8(bytes)) } catch { continue }
        if (keepNoteIsImportable(note)) notes.push(note)
      }
      if (notes.length === 0) return status.fail("No importable notes found in that zip.")

      // Idempotency + sync: compute an identity key and a content fingerprint
      // per note, ask the server which are already imported (and their stored
      // fingerprint), then import new notes, update changed ones, skip unchanged.
      status.set("Checking what's new or changed…")
      const keyed = []
      for (const note of notes) {
        keyed.push({
          note,
          dedupKey: await keepDedupKey(secret, note),
          version: await keepContentFingerprint(secret, note),
        })
      }
      const versions = {}
      for (let i = 0; i < keyed.length; i += 400) {
        const slice = keyed.slice(i, i + 400).map((x) => x.dedupKey)
        const reply = await pushWithReply(this, "check_self_note_dedup", {keys: slice})
        Object.assign(versions, reply?.versions || {})
      }
      const toSend = keyed.filter((x) => !(x.dedupKey in versions) || versions[x.dedupKey] !== x.version)
      const unchanged = keyed.length - toSend.length
      const total = toSend.length
      if (total === 0) {
        status.done(`Already in sync — all ${keyed.length} notes were up to date.`)
        setTimeout(() => window.location.reload(), 1600)
        return
      }

      let imported = 0
      let updated = 0
      let unreadable = 0
      let chunk = []
      const flush = async () => {
        if (chunk.length === 0) return
        const batch = chunk
        chunk = []
        const reply = await pushWithReply(this, "import_self_notes", {notes: batch})
        imported += reply?.imported ?? 0
        updated += reply?.updated ?? 0
      }

      for (let i = 0; i < total; i++) {
        const {note, dedupKey, version} = toSend[i]
        status.set(`Encrypting note ${i + 1} of ${total}…`, (i + 1) / total)
        const attachments = []
        for (const att of note.attachments || []) {
          const bytes = entries[KEEP_PREFIX + att.filePath]
          if (!bytes) continue
          try {
            const upload = new File([bytes], att.filePath, {type: att.mimetype})
            attachments.push(await encryptAndUpload(upload, {name: att.filePath, mime: att.mimetype}))
          } catch {
            // A failed attachment upload should not lose the note's text.
          }
        }
        try {
          const doc = keepNoteToDocument(note, attachments)
          chunk.push({
            ...sealFor(key, doc, secret),
            dedup_key: dedupKey,
            dedup_version: version,
            attachment_ids: attachments.map((a) => a.id),
          })
        } catch {
          unreadable++
        }
        if (chunk.length >= 25) await flush()
      }
      await flush()

      status.done(
        `Imported ${imported} new note${imported === 1 ? "" : "s"} from Google Keep` +
          (updated ? `, updated ${updated} changed` : "") +
          (unchanged ? `, skipped ${unchanged} unchanged` : "") +
          (unreadable ? ` (${unreadable} could not be read)` : "") +
          ".",
      )
      setTimeout(() => window.location.reload(), 1800)
    } catch (error) {
      status.fail(error.message || "Import failed.")
    } finally {
      this._importing = false
    }
  },
  create() {
    const {userId, peerKey: key} = this.el.dataset
    if (!userId || !key) return
    noteEditor(this.el, {}, async (note) => {
      const secret = getSecretKey(userId)
      if (!secret) throw new Error("Unlock your keys before saving a note.")
      await pushWithReply(this, "send_batch", {
        kind: "self_note",
        envelopes: [{recipient_id: Number(userId), ...sealFor(key, note, secret)}],
        attachment_ids: note.attachments.map((attachment) => attachment.id),
      })
    })
  },
  edit({payload, element}) {
    const tall = element.querySelector(".self-note-body")?.dataset.collapsible === "true"
    noteEditor(this.el, payload, async (note) => {
      const secret = getSecretKey(element.dataset.userId)
      if (!secret) throw new Error("Unlock your keys before saving a note.")
      const {copies} = await pushWithReply(this, "prepare_edit", {id: element.dataset.publicId})
      const envelopes = copies.map((copy) => ({public_id: copy.public_id, ...sealFor(copy.public_key, note, secret)}))
      try {
        await pushWithReply(this, "edit_batch", {id: element.dataset.publicId, envelopes, attachment_ids: note.attachments.map((attachment) => attachment.id), expected_updated_at: element.dataset.updatedAt})
      } catch (error) {
        if (!error.reply?.stale) throw error
        if (!window.confirm("This note changed on another device. Press OK to keep your version, or Cancel to load the latest version.")) {
          window.location.reload()
          return
        }
        await pushWithReply(this, "edit_batch", {id: element.dataset.publicId, envelopes, attachment_ids: note.attachments.map((attachment) => attachment.id)})
      }
      const current = envelopes.find((entry) => entry.public_id === element.dataset.publicId)
      if (current) {
        element.dataset.ciphertext = current.ciphertext
        element.dataset.nonce = current.nonce
        element.dataset.updatedAt = new Date().toISOString()
      }
    }, {mount: element, tall})
  },
  async save({payload, element}) {
    const secret = getSecretKey(element.dataset.userId)
    if (!secret) throw new Error("Unlock your keys before saving a note.")
    const {copies} = await pushWithReply(this, "prepare_edit", {id: element.dataset.publicId})
    const next = noteDocument(payload)
    const envelopes = copies.map((copy) => ({public_id: copy.public_id, ...sealFor(copy.public_key, next, secret)}))
    await pushWithReply(this, "edit_batch", {id: element.dataset.publicId, envelopes, attachment_ids: next.attachments.map((attachment) => attachment.id), expected_updated_at: element.dataset.updatedAt})
    window.dispatchEvent(new CustomEvent("veejr:self-note-save-complete", {detail: {element}}))
  },
}

export const SelfNotes = {
  mounted() {
    this.card = this.el.closest(".self-note-card")
    this.onCardClick = (event) => {
      if (this.card.dataset.editing === "true" || event.target.closest("button, input, textarea, select, label, a, [data-role='note-editor']")) return
      if (this.payload) window.dispatchEvent(new CustomEvent("veejr:self-note-edit", {detail: {payload: this.payload, element: this.el}}))
    }
    this.onCardKeydown = (event) => {
      if (this.card.dataset.editing === "true" || event.target !== this.card || !["Enter", " "].includes(event.key) || !this.payload) return
      event.preventDefault()
      window.dispatchEvent(new CustomEvent("veejr:self-note-edit", {detail: {payload: this.payload, element: this.el}}))
    }
    this.card.addEventListener("click", this.onCardClick)
    this.card.addEventListener("keydown", this.onCardKeydown)
    this.onRefresh = () => this.render()
    this.el.addEventListener("self-notes:refresh", this.onRefresh)
    this.render()
  },
  updated() {
    this.render()
  },
  destroyed() {
    this.card?.removeEventListener("click", this.onCardClick)
    this.card?.removeEventListener("keydown", this.onCardKeydown)
    this.el.removeEventListener("self-notes:refresh", this.onRefresh)
    if (this.card) selfNoteSearchIndex.delete(this.card)
  },
  render() {
    const card = this.card || this.el.closest(".self-note-card")
    selfNoteSearchIndex.delete(card)
    const secret = getSecretKey(this.el.dataset.userId)
    this.el.textContent = ""
    if (!secret) { this.payload = null; this.el.textContent = "Locked — unlock keys to read"; return }
    const payload = openFrom(this.el.dataset.ciphertext, this.el.dataset.nonce, this.el.dataset.peerKey, secret)
    if (!payload || payload.v !== 2 || payload.kind !== "self_note" || !Array.isArray(payload.checklist) || !Array.isArray(payload.labels) || !Array.isArray(payload.attachments)) { this.payload = null; this.el.textContent = "Unsupported or malformed encrypted note."; return }
    this.payload = payload
    card.tabIndex = 0
    card.setAttribute("aria-label", `Edit ${payload.title || "untitled note"}`)
    const attachmentMetadata = payload.attachments.flatMap((attachment) => [
      "attachment",
      attachment.id,
      attachment.name,
      attachment.mime,
      attachment.size,
      attachment.durationMs,
    ])
    selfNoteSearchIndex.set(card, normalizeNoteSearch([
      "title", payload.title,
      "body", payload.body,
      ...payload.labels.flatMap((label) => ["label", label]),
      ...payload.checklist.flatMap((item) => [
        "checklist",
        item.text,
        item.checked ? "completed checked" : "open unchecked",
      ]),
      ...attachmentMetadata,
      "color", payload.color,
      "pin", payload.pinned ? "pinned" : "unpinned",
      "archive", payload.archived_at ? "archived" : "active",
      "trash", payload.trashed_at ? "trashed" : "not trashed",
      "created", payload.created_at,
      "updated", payload.updated_at,
      "note id", payload.note_id,
      "legacy id", payload.legacy_message_id,
    ].filter((value) => value !== undefined && value !== null).join(" ")))
    card.dataset.noteLabels = JSON.stringify(payload.labels.filter((label) => typeof label === "string").slice(0, 10))
    card.dataset.noteUpdated = payload.updated_at || ""
    card.dataset.noteArchived = String(!!payload.archived_at)
    card.dataset.noteTrashed = String(!!payload.trashed_at)
    card.dataset.notePinned = String(!!payload.pinned)
    if (payload.legacy_message_id) this.el.closest(".self-note-card").dataset.legacySource = payload.legacy_message_id
    window.dispatchEvent(new CustomEvent("veejr:self-note-rendered"))
    const title = document.createElement("h3"); title.className = "font-semibold"; title.textContent = payload.title || "Untitled note"
    if (payload.pinned) title.textContent = `📌 ${title.textContent}`
    const body = document.createElement("p")
    body.className = "self-note-body mt-2 whitespace-pre-wrap text-sm"
    body.textContent = payload.body || ""
    body.dataset.expanded = "false"
    const setBodyExpanded = (expanded) => {
      body.dataset.expanded = String(expanded)
      body.setAttribute("aria-expanded", String(expanded))
      body.setAttribute(
        "aria-label",
        expanded ? "Expanded note text. Click to edit or Control-click to collapse." : "Expand note text",
      )
      body.title = expanded ? "Click to edit · Control-click to collapse" : "Expand note text"
    }
    const handleBodyAction = (event) => {
      if (body.dataset.collapsible !== "true") return
      const expanded = body.dataset.expanded === "true"
      if (!expanded || event.ctrlKey) {
        event.preventDefault()
        event.stopPropagation()
        setBodyExpanded(!expanded)
      }
    }
    body.addEventListener("click", handleBodyAction)
    body.addEventListener("keydown", (event) => {
      if (!["Enter", " "].includes(event.key)) return
      if (body.dataset.expanded === "true" && !event.ctrlKey) {
        event.preventDefault()
        event.stopPropagation()
        window.dispatchEvent(new CustomEvent("veejr:self-note-edit", {detail: {payload, element: this.el}}))
      } else {
        handleBodyAction(event)
      }
    })
    const list = document.createElement("ul"); list.className = "mt-2 space-y-1 text-sm"
    ;(payload.checklist || []).forEach((item) => { const li = document.createElement("li"); li.textContent = `${item.checked ? "✓" : "○"} ${item.text}`; li.className = item.checked ? "opacity-50 line-through" : ""; list.appendChild(li) })
    const meta = document.createElement("div"); meta.className = "mt-3 flex flex-wrap gap-1"
    ;(payload.labels || []).forEach((label) => {
      const chip = document.createElement("button")
      chip.type = "button"; chip.className = "rounded-full bg-base-200 px-2 py-0.5 text-xs opacity-70 hover:opacity-100"; chip.textContent = `#${label}`
      chip.addEventListener("click", (event) => {
        event.stopPropagation()
        const board = document.querySelector("#self-notes-board")
        const search = board?.querySelector("[data-role=search]")
        if (!search) return
        search.value = label
        search.dispatchEvent(new Event("input", {bubbles: true}))
        search.focus()
      })
      meta.appendChild(chip)
    })
    const attachments = document.createElement("div"); attachments.className = "mt-3 grid gap-2 sm:grid-cols-2"
    ;(payload.attachments || []).forEach((attachment) => {
      attachments.appendChild(noteAttachmentPreview(attachment))
    })
    const actions = document.createElement("div"); actions.className = "mt-3 flex justify-end gap-1"
    const select = document.createElement("input")
    select.type = "checkbox"; select.className = "mr-2"; select.setAttribute("data-role", "note-select"); select.setAttribute("aria-label", `Select ${payload.title || "note"}`)
    select.addEventListener("click", (event) => event.stopPropagation())
    select.addEventListener("change", () => window.dispatchEvent(new CustomEvent("veejr:self-note-selected", {detail: {element: this.el, payload, checked: select.checked}})))
    actions.appendChild(select)
    const action = (label, update) => {
      const button = document.createElement("button")
      button.type = "button"; button.className = "btn btn-ghost btn-xs"; button.textContent = label
      button.addEventListener("click", async (event) => {
        event.stopPropagation()
        button.disabled = true
        try {
          update()
          await new Promise((resolve, reject) => {
            const listener = async (saveEvent) => {
              if (saveEvent.detail.element !== this.el) return
              window.removeEventListener("veejr:self-note-save-complete", listener)
              resolve()
            }
            window.addEventListener("veejr:self-note-save-complete", listener)
            window.dispatchEvent(new CustomEvent("veejr:self-note-save", {detail: {payload, element: this.el}}))
            setTimeout(() => reject(new Error("Save timed out")), 15000)
          })
          const card = this.el.closest(".self-note-card")
          card.dataset.noteArchived = String(!!payload.archived_at)
          card.dataset.noteTrashed = String(!!payload.trashed_at)
          card.dataset.notePinned = String(!!payload.pinned)
          window.dispatchEvent(new CustomEvent("veejr:self-note-rendered"))
        } catch { button.disabled = false }
      })
      actions.appendChild(button)
    }
    action(payload.pinned ? "Unpin" : "Pin", () => { payload.pinned = !payload.pinned })
    action(payload.archived_at ? "Unarchive" : "Archive", () => { payload.archived_at = payload.archived_at ? null : new Date().toISOString() })
    action(payload.trashed_at ? "Restore" : "Trash", () => { payload.trashed_at = payload.trashed_at ? null : new Date().toISOString() })
    if (payload.trashed_at) {
      const remove = document.createElement("button")
      remove.type = "button"; remove.className = "btn btn-error btn-xs"; remove.textContent = "Delete forever"
      remove.addEventListener("click", async (event) => {
        event.stopPropagation()
        if (!window.confirm("Permanently delete this encrypted note?")) return
        remove.disabled = true
        try { await pushWithReply(this, "delete_self_note", {id: this.el.dataset.publicId}) } catch { remove.disabled = false }
      })
      actions.appendChild(remove)
    }
    this.el.append(title, body, list, meta, attachments, actions)
    requestAnimationFrame(() => {
      if (!body.isConnected || !body.textContent) return
      const collapsible = body.scrollHeight > body.clientHeight + 1
      body.dataset.collapsible = String(collapsible)
      if (collapsible) {
        body.tabIndex = 0
        body.setAttribute("role", "button")
        setBodyExpanded(false)
      }
    })
    card.dataset.noteColor = normalizeSelfNoteColor(payload.color)
    card.style.removeProperty("background")
  },
}

export const AutoDismissFlash = {
  mounted() {
    const ms = parseInt(this.el.dataset.autoDismissMs || "1000", 10)
    this.timer = setTimeout(() => {
      if (this.el.isConnected) this.el.click()
    }, Number.isInteger(ms) && ms >= 0 ? ms : 1000)
  },

  destroyed() {
    if (this.timer) clearTimeout(this.timer)
  },
}

export const PasswordVisibility = {
  mounted() {
    const input = this.el.querySelector("input[type=password]")
    const toggle = this.el.querySelector("[data-role=password-visibility-toggle]")
    const icon = this.el.querySelector("[data-role=password-visibility-icon] > span")

    if (!input || !toggle || !icon) return

    const secretLabel = toggle.dataset.secretLabel || "password"

    toggle.addEventListener("click", () => {
      const showing = input.type === "text"
      input.type = showing ? "password" : "text"
      toggle.setAttribute("aria-pressed", String(!showing))
      toggle.setAttribute("aria-label", `${showing ? "Show" : "Hide"} ${secretLabel}`)
      icon.classList.toggle("hero-eye", showing)
      icon.classList.toggle("hero-eye-slash", !showing)
    })
  },
}

async function decodeAvatarImage(file) {
  if (window.createImageBitmap) {
    try {
      return await createImageBitmap(file, {imageOrientation: "from-image"})
    } catch (_error) {
      // Fall through for browsers that expose createImageBitmap without image files.
    }
  }

  return new Promise((resolve, reject) => {
    const image = new Image()
    const url = URL.createObjectURL(file)
    image.onload = () => {
      URL.revokeObjectURL(url)
      resolve(image)
    }
    image.onerror = () => {
      URL.revokeObjectURL(url)
      reject(new Error("That image could not be opened."))
    }
    image.src = url
  })
}

export const AvatarUpload = {
  mounted() {
    const input = this.el.querySelector("input[type=file]")
    const submit = this.el.querySelector("button[type=submit]")
    const status = this.el.querySelector("[data-role=avatar-status]")
    const preview = this.el.querySelector("[data-role=avatar-preview]")
    let selectedFile = null

    input.addEventListener("change", () => {
      selectedFile = input.files?.[0] || null
      status.textContent = selectedFile ? selectedFile.name : ""

      if (selectedFile) {
        const url = URL.createObjectURL(selectedFile)
        preview.src = url
        preview.classList.remove("opacity-0")
        preview.onload = () => URL.revokeObjectURL(url)
      }
    })

    this.el.addEventListener("submit", async (event) => {
      event.preventDefault()
      if (!selectedFile) return

      if (!selectedFile.type.startsWith("image/") || selectedFile.size > 15_000_000) {
        status.textContent = "Choose an image smaller than 15 MB."
        return
      }

      submit.disabled = true
      status.textContent = "Preparing your photo..."

      try {
        const bitmap = await decodeAvatarImage(selectedFile)
        const width = bitmap.width || bitmap.naturalWidth
        const height = bitmap.height || bitmap.naturalHeight

        if (width * height > 40_000_000) {
          throw new Error("That image has too many pixels. Please choose a smaller one.")
        }

        const edge = Math.min(width, height)
        const sourceX = Math.floor((width - edge) / 2)
        const sourceY = Math.floor((height - edge) / 2)
        const canvas = document.createElement("canvas")
        canvas.width = 512
        canvas.height = 512
        const context = canvas.getContext("2d", {alpha: false})
        context.fillStyle = "#ffffff"
        context.fillRect(0, 0, 512, 512)
        context.drawImage(bitmap, sourceX, sourceY, edge, edge, 0, 0, 512, 512)
        if (bitmap.close) bitmap.close()

        const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.86))
        if (!blob) throw new Error("Your browser could not prepare that image.")

        const response = await fetch("/account/avatar", {
          method: "POST",
          headers: {"content-type": "image/jpeg", "x-csrf-token": csrfToken()},
          body: blob,
        })
        const result = await response.json()
        if (!response.ok) throw new Error(result.error || "Avatar upload failed.")

        status.textContent = "Profile image updated."
        input.value = ""
        selectedFile = null
        this.pushEvent("avatar_uploaded", {version: result.version})
      } catch (error) {
        status.textContent = error.message || "Avatar upload failed."
      } finally {
        submit.disabled = false
      }
    })
  },
}

import VeejrMap from "./map_hook.js"

const GuestConferenceLobby = {
  mounted() {
    this.button = this.el.querySelector("[data-role=guest-ready]")
    this.nameInput = this.el.querySelector("#guest-display-name")
    this.preview = this.el.querySelector("[data-role=guest-preview]")
    this.previewEmpty = this.el.querySelector("[data-role=guest-preview-empty]")
    this.status = this.el.querySelector("[data-role=guest-lobby-status]")
    this.stream = null
    this.button.addEventListener("click", () => this.prepare())
  },

  async prepare() {
    const displayName = this.nameInput.value.trim()
    if (!displayName) {
      this.status.textContent = "Enter the name your host will recognize."
      this.nameInput.focus()
      return
    }

    this.button.disabled = true
    this.button.textContent = "Checking camera and microphoneâ€¦"
    this.status.textContent = ""

    try {
      this.stream = await navigator.mediaDevices.getUserMedia({video: true, audio: true})
      this.preview.srcObject = this.stream
      this.previewEmpty.classList.add("hidden")

      const identity = generateEphemeralIdentity()
      cacheSecretKey(this.el.dataset.guestId, identity.secretKey)

      const reply = await new Promise((resolve) => {
        this.pushEvent(
          "guest_ready",
          {display_name: displayName, public_key: identity.publicKey},
          resolve
        )
      })

      if (!reply?.ok) throw new Error(reply?.error || "Could not enter the waiting room.")
      this.stopPreview()
    } catch (error) {
      this.status.textContent =
        error?.name === "NotAllowedError"
          ? "Camera and microphone access is required for this guest call."
          : error.message || "Could not prepare your devices."
      this.button.disabled = false
      this.button.textContent = "Check devices and enter waiting room"
      this.stopPreview()
    }
  },

  destroyed() {
    this.stopPreview()
  },

  stopPreview() {
    if (this.stream) this.stream.getTracks().forEach((track) => track.stop())
    this.stream = null
    if (this.preview) this.preview.srcObject = null
  },
}

export default {
  KeySetup,
  KeyUnlock,
  KeyLock,
  KeyRewrap,
  KeyRotate,
  KeyReset,
  PushSetup,
  AccountStatus,
  InstallApp,
  ChatTheme,
  ContactsTheme,
  ContactsOrbit,
  Composer,
  Decrypt,
  ConversationPreview,
  SelfNotes,
  SelfNotesBoard,
  MessageBubble,
  AutoDismissFlash,
  PasswordVisibility,
  AvatarUpload,
  ReplyTo,
  ScrollBottom,
  GuestConferenceLobby,
  VeejrMap,
}
