// Helpers shared by several hooks: LiveView reply promises, page-scoped
// lookups, attachment MIME handling, and the media preview modal.
//
// Decrypted content is written with textContent here as everywhere else — see
// the security note in ../hooks.js.

import {
  encryptBlob,
  decryptBlob,
} from "../crypto.js"
import {appendLinkedText} from "../link_text.js"
import {ensureLeaflet} from "../map_hook.js"

// Promise wrapper around pushEvent-with-reply, shared by several hooks.
export function pushWithReply(hook, event, params) {
  const statusToken = typeof window !== "undefined" ? window.veejrSendStatus?.start() : null

  return new Promise((resolve, reject) => {
    hook.pushEvent(event, params, (reply) => {
      if (reply && reply.error) {
        const error = new Error(reply.error)
        error.reply = reply
        reject(error)
      }
      else resolve(reply)
    })
  }).finally(() => {
    if (typeof window !== "undefined") window.veejrSendStatus?.finish(statusToken)
  })
}

export function liveViewConnected() {
  return (
    typeof window !== "undefined" &&
    navigator.onLine &&
    window.veejrConnectionState === "connected"
  )
}

export const csrfToken = () =>
  document.querySelector("meta[name='csrf-token']").getAttribute("content")

export const currentLocationPath = () =>
  `${window.location.pathname}${window.location.search}${window.location.hash}`

export function showError(el, msg) {
  const err = el.querySelector("[data-role=error]")
  if (err) {
    err.textContent = msg
    err.classList.remove("hidden")
  }
}

export async function encryptAndUpload(file, metadata = {}) {
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

export function attachmentDownloadUrls(att) {
  const id = encodeURIComponent(att.id)

  return [...new Set([
    // Federated attachments must stay same-origin in the browser: production's
    // CSP deliberately blocks arbitrary cross-origin fetches. The authenticated
    // blob route validates the encrypted payload's origin against a remote
    // sender in this user's history, then relays the opaque ciphertext.
    att.origin
      ? `/blobs/${id}?origin=${encodeURIComponent(att.origin)}`
      : null,
    `/api/blobs/${id}`,
    `/blobs/${id}`,
  ].filter(Boolean))]
}

export async function decryptAttachmentBlob(att) {
  const urls = attachmentDownloadUrls(att)

  let resp = null
  let lastError = null
  for (const url of urls) {
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
// and are relayed by this instance after it verifies that origin belongs to a
// remote sender in the viewer's history. Legacy attachments (no origin) live
// on this instance behind the session route.

export async function downloadAttachment(att) {
  const blob = await decryptAttachmentBlob(att)
  const url = URL.createObjectURL(blob)
  const a = document.createElement("a")
  a.href = url
  a.download = att.name || "attachment"
  a.click()
  setTimeout(() => URL.revokeObjectURL(url), 30_000)
}

export function preferredAudioMime() {
  const types = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4", "audio/ogg;codecs=opus"]
  return types.find((type) => window.MediaRecorder && MediaRecorder.isTypeSupported(type)) || ""
}

export const MAX_VIDEO_DURATION_MS = 60_000

export function preferredVideoMime() {
  const types = [
    "video/webm;codecs=vp9,opus",
    "video/webm;codecs=vp8,opus",
    "video/webm",
    "video/mp4",
  ]
  return types.find((type) => window.MediaRecorder && MediaRecorder.isTypeSupported(type)) || ""
}

export function attachmentMime(att) {
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

export function previewableMedia(att) {
  const mime = attachmentMime(att)
  return mime.startsWith("image/") || mime === "application/pdf"
}

export function showMediaModal({blob, title, mime}) {
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
// written with textContent, matching the Decrypt hook's security rule — except
// the note body, which goes through the same audited linkifier as a bubble.

export async function showLocationModal({lat, lng, title, text, kind}) {
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
    appendLinkedText(p, text)
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

export function urlB64ToBytes(b64url) {
  const b64 = b64url.replace(/-/g, "+").replace(/_/g, "/")
  const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4)
  const bin = atob(padded)
  const bytes = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
  return bytes
}

export function sameBytes(a, b) {
  const left = new Uint8Array(a)
  if (left.length !== b.length) return false
  return left.every((value, index) => value === b[index])
}

// Lock button: drop the cached secret key for this session.
