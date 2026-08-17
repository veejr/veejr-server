// "Notes to yourself": the encrypted board, its card editor, and Google Keep
// import. Document and merge logic lives in ./notes_document.js.

import {
  getSecretKey,
  sealFor,
  openFrom,
} from "../crypto.js"
import {MAX_VIDEO_DURATION_MS, attachmentMime, decryptAttachmentBlob, downloadAttachment, encryptAndUpload, preferredAudioMime, preferredVideoMime, pushWithReply, showMediaModal} from "./shared.js"
import {compareSelfNotes, mergeNoteDocuments, normalizeNoteSearch, normalizeSelfNoteColor, noteDocument, noteSearchClauses, resolveNoteConflict, selfNoteColors, selfNoteSearchIndex} from "./notes_document.js"
import {unzipSync, strFromU8} from "../../../vendor/fflate.js"
import {describeScheduledTime, isoToLocalDateTime, localDateTimeIn, localDateTimeToIso} from "../schedule_time.js"
import {requestKeyUnlock} from "../key_unlock.js"

// The spreadsheet and word processor, and everything they pull in (the
// document model, the formula engine), live behind this one dynamic import.
// A session that never opens a document never downloads any of it — which is
// most sessions, and the reason the editors are a separate chunk rather than
// more of this file.
let documentEditor = null

function loadDocumentEditor() {
  if (!documentEditor) {
    documentEditor = import("../docs/editor.js").catch(() => {
      // Let a later attempt retry instead of caching the rejection forever.
      documentEditor = null
      throw new Error("The document editor could not be loaded. Check your connection and try again.")
    })
  }
  return documentEditor
}

// What a document card shows and what the board's local search matches on.
// Deliberately computed from the raw payload here rather than by importing
// docs/document.js, so listing documents costs nothing until one is opened.
function documentSummary(payload) {
  const isSheet = payload.doc_kind === "sheet"
  const parts = [payload.title, ...(Array.isArray(payload.labels) ? payload.labels : [])]
  let preview = ""

  if (isSheet) {
    const cells = payload.sheet?.cells || {}
    const refs = Object.keys(cells)
    for (const ref of refs) parts.push(cells[ref]?.f ?? cells[ref]?.v ?? "")
    preview = `${refs.length} cell${refs.length === 1 ? "" : "s"}`
  } else {
    const blocks = Array.isArray(payload.page?.blocks) ? payload.page.blocks : []
    for (const block of blocks) parts.push(block?.text ?? "")
    const words = blocks.map((block) => String(block?.text ?? "")).join(" ").trim()
    preview = words ? words.slice(0, 240) : "Empty document"
  }

  return {
    isSheet,
    kindLabel: isSheet ? "Spreadsheet" : "Document",
    title: payload.title || (isSheet ? "Untitled spreadsheet" : "Untitled document"),
    preview,
    searchText: parts.filter((value) => value !== undefined && value !== null).join(" "),
  }
}

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

function keepContentString(k) {
  const list = (Array.isArray(k.listContent) ? k.listContent : [])
    .map((i) => (i.isChecked ? "1" : "0") + ":" + (i.text || ""))
    .join("\n")
  const atts = (Array.isArray(k.attachments) ? k.attachments : []).map((a) => a.filePath || "").join(",")
  return JSON.stringify({t: k.title || "", b: k.textContent || "", l: list, a: atts, p: !!k.isPinned})
}

// An opaque content fingerprint (secret-salted), stored server-side so a
// re-import can tell a changed note from an unchanged one.

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

async function keepContentFingerprint(secret, k) {
  const suffix = new TextEncoder().encode("|keep-version|" + keepContentString(k))
  const material = new Uint8Array(secret.length + suffix.length)
  material.set(secret, 0)
  material.set(suffix, secret.length)
  const digest = await crypto.subtle.digest("SHA-256", material)
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("")
}

// A small fixed progress banner for the import run.

export const SelfNotesBoard = {
  control(selector) {
    return document.querySelector(`#self-notes-command-center ${selector}`)
  },
  controls(selector) {
    return document.querySelectorAll(`#self-notes-command-center ${selector}`)
  },
  mounted() {
    this.filter = "active"
    this.view = "grid"
    this.label = null
    this.searchTerm = ""
    this.sortBy = "updated"
    this.queryClauses = []
    this.allNotesRequested = false
    this.dateFrom = ""
    this.dateTo = ""
    this.selected = new Map()
    this.el.addEventListener("self-notes:new", () => this.create())
    this.control("[data-role=new-note]")?.addEventListener("click", () => this.create())
    this.el.addEventListener("self-notes:import", () => this.el.querySelector("[data-role=import-file]")?.click())
    this.el.querySelector("[data-role=import-file]")?.addEventListener("change", (event) => {
      const file = event.target.files?.[0]
      event.target.value = ""
      if (file) this.importKeep(file)
    })
    document.querySelector("#self-notes-search")?.addEventListener("input", (event) => {
      this.searchTerm = event.target.value
      this.queryClauses = noteSearchClauses(this.searchTerm)
      if (this.queryClauses.length > 0 && !this.allNotesRequested && this.el.querySelector("[data-role=load-all-notes]")) {
        this.allNotesRequested = true
        this.pushEvent("load_all_notes", {}, () => { this.allNotesRequested = false })
      }
      this.applyFilters()
    })
    document.querySelector("#self-notes-sort")?.addEventListener("change", (event) => {
      this.sortBy = event.target.value
      this.applyFilters()
    })
    this.control("[data-role=date-from]")?.addEventListener("change", (event) => {
      this.dateFrom = event.target.value
      this.applyFilters()
    })
    this.control("[data-role=date-to]")?.addEventListener("change", (event) => {
      this.dateTo = event.target.value
      this.applyFilters()
    })
    this.controls("[data-role=date-preset]").forEach((button) => button.addEventListener("click", () => {
      const days = Number(button.dataset.days)
      const today = new Date()
      const from = new Date(today)
      from.setDate(today.getDate() - days)
      const formatDate = (date) => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`
      this.dateFrom = formatDate(from)
      this.dateTo = formatDate(today)
      const fromInput = this.control("[data-role=date-from]")
      const toInput = this.control("[data-role=date-to]")
      if (fromInput) fromInput.value = this.dateFrom
      if (toInput) toInput.value = this.dateTo
      this.controls("[data-role=date-preset]").forEach((control) => control.setAttribute("aria-pressed", String(control === button)))
      this.applyFilters()
    }))
    this.control("[data-role=clear-dates]")?.addEventListener("click", () => {
      this.dateFrom = ""
      this.dateTo = ""
      const from = this.control("[data-role=date-from]")
      const to = this.control("[data-role=date-to]")
      if (from) from.value = ""
      if (to) to.value = ""
      this.controls("[data-role=date-preset]").forEach((control) => control.setAttribute("aria-pressed", "false"))
      this.applyFilters()
    })
    this.controls("[data-role=filter]").forEach((button) => button.addEventListener("click", () => {
      this.filter = button.dataset.filter
      this.controls("[data-role=filter]").forEach((control) => control.setAttribute("aria-pressed", String(control === button)))
      this.applyFilters()
    }))
    this.controls("[data-role=view]").forEach((button) => button.addEventListener("click", () => {
      this.view = button.dataset.view
      this.controls("[data-role=view]").forEach((control) => control.setAttribute("aria-pressed", String(control === button)))
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
    this.control("[data-role=delete-trashed]")?.addEventListener("click", () => this.deleteTrashed())
    this.control("[data-role=new-sheet]")?.addEventListener("click", () => this.createDocument("sheet"))
    this.control("[data-role=new-page]")?.addEventListener("click", () => this.createDocument("page"))
    this.onEdit = (event) => this.edit(event.detail)
    this.onEditDocument = (event) => this.editDocument(event.detail)
    this.onDocumentState = (event) => this.updateDocumentState(event.detail)
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
      if (event.key === "/") { event.preventDefault(); document.querySelector("#self-notes-search")?.focus() }
      if (event.key.toLowerCase() === "c") { event.preventDefault(); this.create() }
    }
    window.addEventListener("veejr:self-note-edit", this.onEdit)
    window.addEventListener("veejr:self-doc-edit", this.onEditDocument)
    window.addEventListener("veejr:self-doc-state", this.onDocumentState)
    window.addEventListener("veejr:self-note-save", this.onSave)
    window.addEventListener("veejr:self-note-rendered", this.onRendered)
    window.addEventListener("veejr:self-note-selected", this.onSelected)
    window.addEventListener("keydown", this.onKeydown)
  },
  updated() {
    const search = document.querySelector("#self-notes-search")
    if (search) search.value = this.searchTerm
    const sort = document.querySelector("#self-notes-sort")
    if (sort) sort.value = this.sortBy
    this.applyFilters()
  },
  destroyed() {
    window.removeEventListener("veejr:self-note-edit", this.onEdit)
    window.removeEventListener("veejr:self-doc-edit", this.onEditDocument)
    window.removeEventListener("veejr:self-doc-state", this.onDocumentState)
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
      .sort((left, right) => compareSelfNotes(
        {
          pinned: left.dataset.notePinned === "true",
          title: left.dataset.noteTitle,
          createdAt: left.dataset.noteCreated,
          updatedAt: left.dataset.noteUpdated,
        },
        {
          pinned: right.dataset.notePinned === "true",
          title: right.dataset.noteTitle,
          createdAt: right.dataset.noteCreated,
          updatedAt: right.dataset.noteUpdated,
        },
        this.sortBy,
      ))
      .forEach((card) => grid.appendChild(card))
    const labels = [...new Set(cards.flatMap((card) => JSON.parse(card.dataset.noteLabels || "[]")))].sort()
    const labelBar = this.control("[data-role=labels]")
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
    const filterStatus = this.control("[data-role=filter-status]")
    if (filterStatus) {
      const suffix = this.filter === "reminders" ? " Reminders are not available yet." : ""
      const dateDescription = this.dateFrom || this.dateTo ? ` Updated ${this.dateFrom || "any time"} to ${this.dateTo || "today"}.` : ""
      filterStatus.textContent = `${visibleCount} note${visibleCount === 1 ? "" : "s"} shown.${dateDescription}${suffix}`
    }
    this.el.querySelector("[data-role=reminders-empty]")?.classList.toggle("hidden", this.filter !== "reminders")
    const deleteTrashed = this.control("[data-role=delete-trashed]")
    if (deleteTrashed) {
      const count = cards.filter((card) => card.dataset.noteTrashed === "true").length
      deleteTrashed.disabled = count === 0
      deleteTrashed.textContent = count === 0
        ? "Delete all trashed forever"
        : `Delete all ${count} trashed note${count === 1 ? "" : "s"} forever`
    }
  },
  async deleteTrashed() {
    const button = this.control("[data-role=delete-trashed]")
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
    if (!secret) {
      requestKeyUnlock()
      return status.fail("Unlock here, then choose the archive again.")
    }
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
  // Creating a document downloads the editor chunk first; the board itself
  // never carries the grid, the block editor, or the formula engine.
  async createDocument(docKind) {
    const {userId, peerKey: key} = this.el.dataset
    if (!userId || !key) return

    const secret = getSecretKey(userId)
    if (!secret) {
      requestKeyUnlock()
      return
    }

    try {
      const {openDocumentEditor} = await loadDocumentEditor()
      const saved = await openDocumentEditor({
        payload: {doc_kind: docKind},
        save: async (doc) => {
          await pushWithReply(this, "send_batch", {
            kind: "self_doc",
            envelopes: [{recipient_id: Number(userId), ...sealFor(key, doc, secret)}],
          })
        },
      })
      // The board's card list comes from the server, so a first save needs a
      // refresh to show the new card. Editing an existing one does not.
      if (saved) this.pushEvent("refresh_self_notes", {})
    } catch (error) {
      window.alert(error.message || "The document could not be opened.")
    }
  },
  async editDocument({payload, element}) {
    const secret = getSecretKey(element.dataset.userId)
    if (!secret) {
      requestKeyUnlock()
      return
    }

    try {
      const {openDocumentEditor} = await loadDocumentEditor()
      await openDocumentEditor({
        payload,
        confirmSaveMode: payload.doc_kind === "sheet",
        save: async (doc, {mode}) => {
          if (mode === "copy") {
            const {userId, peerKey} = this.el.dataset
            await pushWithReply(this, "send_batch", {
              kind: "self_doc",
              envelopes: [{recipient_id: Number(userId), ...sealFor(peerKey, doc, secret)}],
            })
            this.pushEvent("refresh_self_notes", {})
          } else {
            await this.persistDocument(doc, element, secret)
          }
        },
      })
      element.dispatchEvent(new CustomEvent("self-notes:refresh"))
    } catch (error) {
      window.alert(error.message || "The document could not be opened.")
    }
  },
  async persistDocument(doc, element, secret = getSecretKey(element.dataset.userId)) {
    if (!secret) throw new Error("Unlock your keys before saving a document.")
    const {copies} = await pushWithReply(this, "prepare_edit", {id: element.dataset.publicId})
    const envelopes = copies.map((copy) => ({
      public_id: copy.public_id,
      ...sealFor(copy.public_key, doc, secret),
    }))

    await pushWithReply(this, "edit_batch", {
      id: element.dataset.publicId,
      envelopes,
      expected_updated_at: element.dataset.updatedAt,
    })

    // Keep the card ciphertext current so another action in this session does
    // not try to write against the stale encrypted envelope.
    const current = envelopes.find((entry) => entry.public_id === element.dataset.publicId)
    if (current) {
      element.dataset.ciphertext = current.ciphertext
      element.dataset.nonce = current.nonce
      element.dataset.updatedAt = new Date().toISOString()
    }
  },
  async updateDocumentState({payload, element, action}) {
    const previous = payload.trashed_at
    const previousUpdatedAt = payload.updated_at
    payload.trashed_at = action === "restore" ? null : new Date().toISOString()
    payload.updated_at = new Date().toISOString()

    try {
      await this.persistDocument(payload, element)
      element.dispatchEvent(new CustomEvent("self-notes:refresh"))
    } catch (error) {
      payload.trashed_at = previous
      payload.updated_at = previousUpdatedAt
      element.dispatchEvent(new CustomEvent("self-notes:refresh"))
      window.alert(error.message || "The document could not be updated.")
    }
  },
  edit({payload, element}) {
    const tall = element.querySelector(".self-note-body")?.dataset.collapsible === "true"
    noteEditor(this.el, payload, async (note) => {
      const secret = getSecretKey(element.dataset.userId)
      if (!secret) throw new Error("Unlock your keys before saving a note.")
      const {copies} = await pushWithReply(this, "prepare_edit", {id: element.dataset.publicId})
      let envelopes = copies.map((copy) => ({public_id: copy.public_id, ...sealFor(copy.public_key, note, secret)}))
      try {
        await pushWithReply(this, "edit_batch", {id: element.dataset.publicId, envelopes, attachment_ids: note.attachments.map((attachment) => attachment.id), expected_updated_at: element.dataset.updatedAt})
      } catch (error) {
        if (!error.reply?.stale) throw error

        const latestBatch = await pushWithReply(this, "prepare_edit", {
          id: element.dataset.publicId,
        })
        const latest = openFrom(
          latestBatch.current.ciphertext,
          latestBatch.current.nonce,
          latestBatch.current.peer_key,
          secret
        )
        if (!latest) throw new Error("The latest note version could not be decrypted.")

        const resolution = await resolveNoteConflict(note, latest)
        if (resolution === "latest") {
          window.location.reload()
          return
        }

        const resolved = resolution === "merge" ? mergeNoteDocuments(note, latest) : note
        const resolvedEnvelopes = latestBatch.copies.map((copy) => ({
          public_id: copy.public_id,
          ...sealFor(copy.public_key, resolved, secret),
        }))
        envelopes = resolvedEnvelopes
        await pushWithReply(this, "edit_batch", {
          id: element.dataset.publicId,
          envelopes: resolvedEnvelopes,
          attachment_ids: resolved.attachments.map((attachment) => attachment.id),
        })
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
    // Notes edit inline on the card; documents open their own editor.
    this.openEvent = () =>
      this.payload?.kind === "self_doc" ? "veejr:self-doc-edit" : "veejr:self-note-edit"
    this.onCardClick = (event) => {
      if (this.card.dataset.editing === "true" || event.target.closest("button, input, textarea, select, label, a, [data-role='note-editor']")) return
      if (this.payload) window.dispatchEvent(new CustomEvent(this.openEvent(), {detail: {payload: this.payload, element: this.el}}))
    }
    this.onCardKeydown = (event) => {
      if (this.card.dataset.editing === "true" || event.target !== this.card || !["Enter", " "].includes(event.key) || !this.payload) return
      event.preventDefault()
      window.dispatchEvent(new CustomEvent(this.openEvent(), {detail: {payload: this.payload, element: this.el}}))
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
  // Set or clear a reminder. Unlike everything else on a card, the time is
  // stored server-side in plaintext — something has to know when to fire it —
  // so the button says so, and the reminder itself carries no note content.
  reminderButton() {
    const current = this.el.dataset.remindAt || ""
    const button = document.createElement("button")
    button.type = "button"
    button.className = current ? "btn btn-xs btn-outline btn-primary" : "btn btn-ghost btn-xs"
    button.textContent = current ? `⏰ ${describeScheduledTime(current)}` : "⏰ Remind me"
    button.title = current
      ? "Change or clear this reminder. The time is stored unencrypted; the note is not."
      : "Set a reminder. The time is stored unencrypted; the note stays encrypted."

    button.addEventListener("click", async (event) => {
      event.stopPropagation()
      const answer = window.prompt(
        "Reminder time (YYYY-MM-DDTHH:MM, your local time). Leave empty to clear it.",
        current ? isoToLocalDateTime(current) : localDateTimeIn(60)
      )
      if (answer === null) return

      const remindAt = answer.trim() === "" ? null : localDateTimeToIso(answer.trim())
      if (answer.trim() !== "" && !remindAt) {
        window.alert("That time could not be read. Use the form YYYY-MM-DDTHH:MM.")
        return
      }

      button.disabled = true
      try {
        await pushWithReply(this, "set_reminder", {id: this.el.dataset.publicId, remind_at: remindAt})
        this.el.dataset.remindAt = remindAt || ""
      } catch (error) {
        window.alert(error.message || "The reminder could not be set.")
      } finally {
        button.disabled = false
      }
    })

    return button
  },
  // A document card: title, what kind it is, and a preview. Opening it loads
  // the editor chunk; the card itself needs none of it.
  renderDocument(payload, card) {
    const summary = documentSummary(payload)
    this.payload = payload

    card.tabIndex = 0
    card.dataset.selfDoc = payload.doc_kind === "sheet" ? "sheet" : "page"
    card.setAttribute("aria-label", `Open ${summary.title}`)
    card.dataset.noteLabels = JSON.stringify(
      (Array.isArray(payload.labels) ? payload.labels : []).filter((label) => typeof label === "string").slice(0, 10)
    )
    card.dataset.noteUpdated = payload.updated_at || ""
    card.dataset.noteCreated = payload.created_at || ""
    card.dataset.noteTitle = summary.title
    card.dataset.noteArchived = String(!!payload.archived_at)
    card.dataset.noteTrashed = String(!!payload.trashed_at)
    card.dataset.notePinned = String(!!payload.pinned)

    selfNoteSearchIndex.set(card, normalizeNoteSearch([
      summary.kindLabel,
      "document",
      summary.searchText,
      "updated", payload.updated_at,
      "created", payload.created_at,
    ].filter(Boolean).join(" ")))

    const header = document.createElement("div")
    header.className = "flex items-center gap-2"

    const badge = document.createElement("span")
    badge.className = "rounded-full bg-base-200 px-2 py-0.5 text-xs opacity-70"
    badge.textContent = summary.kindLabel

    const title = document.createElement("h3")
    title.className = "min-w-0 flex-1 truncate font-semibold"
    title.textContent = payload.pinned ? `📌 ${summary.title}` : summary.title

    header.append(badge, title)

    const preview = document.createElement("p")
    preview.className = "mt-2 line-clamp-3 whitespace-pre-wrap text-sm opacity-70"
    preview.textContent = summary.preview

    const open = document.createElement("button")
    open.type = "button"
    open.className = "btn btn-outline btn-xs"
    open.textContent = summary.isSheet ? "Open spreadsheet" : "Open document"
    open.addEventListener("click", (event) => {
      event.stopPropagation()
      window.dispatchEvent(new CustomEvent("veejr:self-doc-edit", {detail: {payload, element: this.el}}))
    })

    const actions = document.createElement("div")
    actions.className = "mt-3 flex flex-wrap items-center gap-2"
    actions.append(open, this.reminderButton())

    const trash = document.createElement("button")
    trash.type = "button"
    trash.className = "btn btn-ghost btn-xs"
    trash.dataset.role = "document-trash"
    trash.textContent = payload.trashed_at ? "Restore" : "Trash"
    trash.addEventListener("click", (event) => {
      event.stopPropagation()
      trash.disabled = true
      window.dispatchEvent(new CustomEvent("veejr:self-doc-state", {
        detail: {
          payload,
          element: this.el,
          action: payload.trashed_at ? "restore" : "trash",
        },
      }))
    })
    actions.appendChild(trash)

    if (payload.trashed_at) {
      const remove = document.createElement("button")
      remove.type = "button"
      remove.className = "btn btn-error btn-xs"
      remove.dataset.role = "document-delete"
      remove.textContent = "Delete forever"
      remove.addEventListener("click", async (event) => {
        event.stopPropagation()
        const kind = summary.isSheet ? "spreadsheet" : "document"
        if (!window.confirm(`Permanently delete this encrypted ${kind}?`)) return
        remove.disabled = true
        try {
          await pushWithReply(this, "delete_self_note", {id: this.el.dataset.publicId})
        } catch (error) {
          remove.disabled = false
          window.alert(error.message || `The ${kind} could not be deleted.`)
        }
      })
      actions.appendChild(remove)
    }

    this.el.append(header, preview, actions)
    window.dispatchEvent(new CustomEvent("veejr:self-note-rendered"))
  },
  render() {
    const card = this.card || this.el.closest(".self-note-card")
    selfNoteSearchIndex.delete(card)
    const secret = getSecretKey(this.el.dataset.userId)
    this.el.textContent = ""
    if (!secret) {
      this.payload = null
      const button = document.createElement("button")
      button.type = "button"
      button.className = "link text-left"
      button.textContent = "Locked — unlock here to read"
      button.addEventListener("click", requestKeyUnlock)
      this.el.appendChild(button)
      return
    }
    const payload = openFrom(this.el.dataset.ciphertext, this.el.dataset.nonce, this.el.dataset.peerKey, secret)
    if (payload && payload.kind === "self_doc") { this.renderDocument(payload, card); return }
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
    card.dataset.noteCreated = payload.created_at || ""
    card.dataset.noteTitle = payload.title || "Untitled note"
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
        const search = document.querySelector("#self-notes-search")
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
    actions.appendChild(this.reminderButton())
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
