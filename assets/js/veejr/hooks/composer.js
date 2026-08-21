// The message composer: gathers recipients, text, and attachments, encrypts
// everything in the browser, and pushes only ciphertext.
//
// Deliberately not a LiveView form — its inputs are read here, not sent as
// form params.

import {
  cacheSecretKey,
  getSecretKey,
  sealFor,
  sealLocal,
  openLocal,
  unlockIdentity,
} from "../crypto.js"
import {MAX_VIDEO_DURATION_MS, currentLocationPath, encryptAndUpload, preferredAudioMime, preferredVideoMime, pushWithReply, showError} from "./shared.js"
import {noteDocument} from "./notes_document.js"
import {localDateTimeToIso} from "../schedule_time.js"
import {Decrypt} from "./messages.js"
import {deleteDraftMedia, loadDraftMedia, saveDraftMedia} from "../local_media_drafts.js"

// A drag only counts when it actually carries files: dragging selected text
// or a link across the thread must not arm the drop target.
function draggingFiles(event) {
  return [...(event.dataTransfer?.types || [])].includes("Files")
}

// Same name, size, and mtime is the same file. Guards against dropping a
// batch twice, which is easy to do with a big drop target.
function sameFile(a, b) {
  return a.name === b.name && a.size === b.size && a.lastModified === b.lastModified
}

// Clipboard images are all called "image.png", so three pasted screenshots
// would arrive as three identical names — and dedupe would eat two of them.
function namedPaste(file) {
  if (!file.type.startsWith("image/") || !/^image\.\w+$/u.test(file.name || "")) return file

  const stamp = new Date().toISOString().replace(/[:.]/gu, "-").slice(0, 19)
  const extension = file.name.split(".").pop()
  return new File([file], `pasted-${stamp}.${extension}`, {
    type: file.type,
    lastModified: file.lastModified,
  })
}

function formatBytes(size) {
  if (!Number.isFinite(size)) return ""
  if (size < 1024) return `${size} B`
  if (size < 1024 * 1024) return `${Math.ceil(size / 1024)} KB`
  return `${(size / (1024 * 1024)).toFixed(1)} MB`
}

// A file dropped just outside a drop target replaces the page with that file,
// losing an unsent draft. Swallow those, once per document.
let strayDropGuardInstalled = false

function installStrayDropGuard() {
  if (strayDropGuardInstalled) return
  strayDropGuardInstalled = true

  for (const type of ["dragover", "drop"]) {
    document.addEventListener(type, (event) => {
      if (!draggingFiles(event) || event.defaultPrevented) return
      if (event.target instanceof Element && event.target.closest("[data-composer-dropzone]")) {
        return
      }
      event.preventDefault()
      if (type === "drop" && event.dataTransfer) event.dataTransfer.dropEffect = "none"
    })
  }
}

export const Composer = {
  mounted() {
    this.recordedAudio = []
    this.recordedVideo = []
    this.videoFacingMode = "user"
    this.thumbnailUrls = []
    this.clientBatchId = crypto.randomUUID()
    this.textEl = this.el.querySelector("[data-role=text]")
    this.restoreDraft()
    this.setupAttachments()

    this.onDraftInput = () => {
      clearTimeout(this.draftTimer)
      this.draftTimer = setTimeout(() => this.saveDraft(), 250)
    }
    this.el.addEventListener("input", this.onDraftInput)
    this.el.addEventListener("change", this.onDraftInput)

    this.onReplyMessage = ({detail}) => {
      if (!detail?.publicId || this.el.dataset.kind !== "message") return
      this.replyTo = {
        id: detail.publicId,
        from: String(detail.from || ""),
        text: String(detail.text || "").slice(0, 500),
      }
      this.renderReplyPreview()
      this.saveDraft()
      this.textEl?.focus()
    }
    window.addEventListener("veejr:reply-message", this.onReplyMessage)

    // Delegated, not bound to the textarea: switching conversations patches a
    // new textarea into the same form, and a listener held on the old element
    // goes with it — which silently killed Enter-to-send after a switch.
    this.onTextKeydown = (e) => {
      if (e.key !== "Enter" || e.shiftKey || e.isComposing) return

      // Enter in the unlock prompt unlocks; it must not also submit the form.
      if (e.target.matches?.("[data-role=composer-passphrase]")) {
        e.preventDefault()
        if (!e.repeat) this.attemptUnlock?.()
        return
      }

      if (!e.target.matches?.("[data-role=text]")) return
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

      const pauseRecording = e.target.closest("[data-role=recording-pause]")
      if (pauseRecording && this.el.contains(pauseRecording)) {
        e.preventDefault()
        this.toggleRecordingPause()
        return
      }

      const stopRecording = e.target.closest("[data-role=recording-stop]")
      if (stopRecording && this.el.contains(stopRecording)) {
        e.preventDefault()
        this.stopActiveRecording()
        return
      }

      const switchRecordingCamera = e.target.closest("[data-role=recording-camera]")
      if (switchRecordingCamera && this.el.contains(switchRecordingCamera)) {
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
        return
      }

      const discardFile = e.target.closest("[data-role=discard-file]")
      if (discardFile && this.el.contains(discardFile)) {
        e.preventDefault()
        this.discardFile(parseInt(discardFile.dataset.index))
        return
      }

      const unlockSubmit = e.target.closest("[data-role=composer-unlock-submit]")
      if (unlockSubmit && this.el.contains(unlockSubmit)) {
        e.preventDefault()
        this.attemptUnlock?.()
        return
      }

      const unlockCancel = e.target.closest("[data-role=composer-unlock-cancel]")
      if (unlockCancel && this.el.contains(unlockCancel)) {
        e.preventDefault()
        // Cancelling abandons the send but keeps the text and attachments,
        // so nothing typed is lost by changing your mind.
        this.finishUnlock?.(null)
        return
      }

      const cancelReply = e.target.closest("[data-role=cancel-reply]")
      if (cancelReply && this.el.contains(cancelReply)) {
        e.preventDefault()
        this.clearReply()
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
    this.el.addEventListener("keydown", this.onTextKeydown)

    this.el.addEventListener("submit", (e) => {
      e.preventDefault()
      this.send().catch((err) => showError(this.el, err.message))
    })
  },

  // Attachments: paste, drop, and the visible strip.
  //
  // The `[data-role=files]` input stays the single source of truth — `send()`
  // reads it and `form.reset()` clears it — so pasted and dropped files are
  // written *into* it with a DataTransfer rather than kept alongside it.
  setupAttachments() {
    const input = this.attachmentInput()
    if (!input) return

    this.onFilesChanged = (e) => {
      if (e.target.matches?.("[data-role=files]")) {
        this.renderFilePreview()
        this.saveDraft()
      }
    }
    this.el.addEventListener("change", this.onFilesChanged)

    // Delegated for the same reason as keydown: the textarea is replaced when
    // the conversation changes, the form is not.
    this.onComposerPaste = (e) => {
      const files = [...(e.clipboardData?.files || [])]
      if (files.length === 0) return // ordinary text paste, left alone
      e.preventDefault()
      this.addFiles(files.map((file) => namedPaste(file)))
    }
    this.el.addEventListener("paste", this.onComposerPaste)

    // The whole thread is the target where one is marked; elsewhere (self
    // notes, the map) the composer is its own. Start from the parent so the
    // composer's own marker does not win over the thread's.
    this.dropzone = this.el.parentElement?.closest("[data-composer-dropzone]") || this.el

    const dragging = (on) => this.dropzone.classList.toggle("is-dropping", on)

    this.onDragOver = (e) => {
      if (!draggingFiles(e)) return
      e.preventDefault()
      e.dataTransfer.dropEffect = "copy"
      dragging(true)
    }
    this.onDragLeave = (e) => {
      // dragleave also fires moving between children, so only a pointer that
      // actually left the zone clears the highlight.
      if (!this.dropzone.contains(e.relatedTarget)) dragging(false)
    }
    this.onDrop = (e) => {
      if (!draggingFiles(e)) return
      e.preventDefault()
      dragging(false)
      this.addFiles([...(e.dataTransfer?.files || [])])
    }

    this.dropzone.addEventListener("dragover", this.onDragOver)
    this.dropzone.addEventListener("dragleave", this.onDragLeave)
    this.dropzone.addEventListener("drop", this.onDrop)
    installStrayDropGuard()
    this.renderFilePreview()
    this.saveDraft()
  },

  // Resolves to the unwrapped secret key, or null if the person backs out.
  // Only ever one prompt: pressing Enter twice waits on the same one.
  unlockInPlace() {
    if (this.unlockPending) return this.unlockPending

    const {userId, encSecretKey, keySalt, keyNonce} = this.el.dataset
    const panel = this.el.querySelector("[data-role=composer-unlock]")
    const input = this.el.querySelector("[data-role=composer-passphrase]")

    // Someone who never finished key setup has nothing to unwrap; that is
    // still the keys page's job.
    if (!panel || !input || !encSecretKey || !keySalt || !keyNonce) {
      window.location.assign(`/keys?return_to=${encodeURIComponent(currentLocationPath())}`)
      return Promise.resolve(null)
    }

    const error = this.el.querySelector("[data-role=composer-unlock-error]")
    const submit = this.el.querySelector("[data-role=composer-unlock-submit]")
    panel.classList.remove("hidden")
    panel.classList.add("flex")
    error?.classList.add("hidden")
    window.setTimeout(() => input.focus(), 0)

    this.unlockPending = new Promise((resolve) => {
      this.finishUnlock = (secretKey) => {
        panel.classList.add("hidden")
        panel.classList.remove("flex")
        input.value = ""
        error?.classList.add("hidden")
        this.unlockPending = null
        this.finishUnlock = null
        this.attemptUnlock = null
        resolve(secretKey)
      }

      this.attemptUnlock = async () => {
        if (!input.value || submit?.disabled) return
        if (submit) {
          submit.disabled = true
          submit.textContent = "Unlocking…"
        }

        try {
          const secretKey = await unlockIdentity(input.value, encSecretKey, keySalt, keyNonce)
          if (!secretKey) {
            if (error) {
              error.textContent = "Wrong passphrase."
              error.classList.remove("hidden")
            }
            input.select()
            return
          }

          cacheSecretKey(userId, secretKey)
          this.finishUnlock(secretKey)
        } catch {
          if (error) {
            error.textContent = "Could not unlock your keys on this device."
            error.classList.remove("hidden")
          }
        } finally {
          if (submit) {
            submit.disabled = false
            submit.textContent = "Unlock and send"
          }
        }
      }
    })

    return this.unlockPending
  },

  attachmentInput() {
    return this.el.querySelector("[data-role=files]")
  },

  maxUploadBytes() {
    const value = parseInt(this.el.dataset.maxUploadBytes || "", 10)
    return Number.isInteger(value) && value > 0 ? value : null
  },

  addFiles(incoming) {
    const input = this.attachmentInput()
    if (!input || incoming.length === 0) return

    const max = this.maxUploadBytes()
    const kept = [...input.files]
    const tooLarge = []

    for (const file of incoming) {
      if (max && file.size > max) {
        tooLarge.push(file.name)
      } else if (!kept.some((existing) => sameFile(existing, file))) {
        kept.push(file)
      }
    }

    try {
      const transfer = new DataTransfer()
      for (const file of kept) transfer.items.add(file)
      input.files = transfer.files
    } catch {
      return showError(
        this.el,
        "This browser cannot attach pasted or dropped files. Use the paper clip instead.",
      )
    }

    if (tooLarge.length > 0) {
      showError(
        this.el,
        `Too large for this instance (limit ${formatBytes(max)}): ${tooLarge.join(", ")}.`,
      )
    } else {
      this.el.querySelector("[data-role=error]")?.classList.add("hidden")
    }

    this.renderFilePreview()
    this.saveDraft()
  },

  discardFile(index) {
    const input = this.attachmentInput()
    if (!input) return
    const kept = [...input.files].filter((_file, i) => i !== index)
    const transfer = new DataTransfer()
    for (const file of kept) transfer.items.add(file)
    input.files = transfer.files
    this.renderFilePreview()
  },

  renderFilePreview() {
    const preview = this.el.querySelector("[data-role=file-preview]")
    if (!preview) return

    this.thumbnailUrls.forEach((url) => URL.revokeObjectURL(url))
    this.thumbnailUrls = []
    preview.textContent = ""

    const files = [...(this.attachmentInput()?.files || [])]
    preview.classList.toggle("hidden", files.length === 0)
    preview.classList.toggle("flex", files.length > 0)

    files.forEach((file, index) => {
      const chip = document.createElement("span")
      chip.className =
        "inline-flex max-w-full items-center gap-2 rounded-full border border-base-300 bg-base-200 py-1 pl-1 pr-1.5 text-xs"

      if (file.type.startsWith("image/")) {
        const url = URL.createObjectURL(file)
        this.thumbnailUrls.push(url)
        const thumb = document.createElement("img")
        thumb.src = url
        thumb.alt = ""
        thumb.className = "size-7 shrink-0 rounded-full object-cover"
        chip.appendChild(thumb)
      } else {
        const badge = document.createElement("span")
        badge.className =
          "grid size-7 shrink-0 place-items-center rounded-full bg-base-300 text-[0.7rem]"
        badge.textContent = "📄"
        chip.appendChild(badge)
      }

      const label = document.createElement("span")
      label.className = "min-w-0 truncate"
      label.textContent = file.name
      label.title = `${file.name} · ${formatBytes(file.size)}`

      const size = document.createElement("span")
      size.className = "shrink-0 opacity-60"
      size.textContent = formatBytes(file.size)

      const remove = document.createElement("button")
      remove.type = "button"
      remove.dataset.role = "discard-file"
      remove.dataset.index = index.toString()
      remove.setAttribute("aria-label", `Remove ${file.name}`)
      remove.className =
        "grid size-5 shrink-0 place-items-center rounded-full opacity-60 transition hover:bg-base-300 hover:opacity-100"
      remove.textContent = "×"

      chip.append(label, size, remove)
      preview.appendChild(chip)
    })
  },

  // A patch can swap the textarea and the file input for fresh elements while
  // keeping this form, so cached references are refreshed rather than trusted.
  updated() {
    this.textEl = this.el.querySelector("[data-role=text]")
    this.renderFilePreview()
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
    clearTimeout(this.draftTimer)
    clearTimeout(this.videoDurationTimer)
    clearInterval(this.recordingClock)
    if (this.mediaRecorder && this.mediaRecorder.state !== "inactive") this.mediaRecorder.stop()
    this.stopMediaTracks()
    if (this.onComposerClick) this.el.removeEventListener("click", this.onComposerClick)
    if (this.onDocumentClick) document.removeEventListener("click", this.onDocumentClick)
    if (this.onDocumentKeydown) document.removeEventListener("keydown", this.onDocumentKeydown)
    if (this.onTextKeydown) this.el.removeEventListener("keydown", this.onTextKeydown)
    if (this.onDraftInput) {
      this.el.removeEventListener("input", this.onDraftInput)
      this.el.removeEventListener("change", this.onDraftInput)
    }
    if (this.onReplyMessage) window.removeEventListener("veejr:reply-message", this.onReplyMessage)
    if (this.emojiMenu && this.emojiMenu.parentElement === document.body) this.emojiMenu.remove()
    if (this.onComposerPaste) this.el.removeEventListener("paste", this.onComposerPaste)
    if (this.onFilesChanged) this.el.removeEventListener("change", this.onFilesChanged)
    if (this.dropzone) {
      this.dropzone.removeEventListener("dragover", this.onDragOver)
      this.dropzone.removeEventListener("dragleave", this.onDragLeave)
      this.dropzone.removeEventListener("drop", this.onDrop)
      this.dropzone.classList.remove("is-dropping")
    }
    this.recordedAudio.forEach((entry) => URL.revokeObjectURL(entry.url))
    this.recordedVideo.forEach((entry) => URL.revokeObjectURL(entry.url))
    this.thumbnailUrls.forEach((url) => URL.revokeObjectURL(url))
  },

  draftStorageKey() {
    const {userId, kind, draftKey} = this.el.dataset
    const context = draftKey || `${window.location.pathname}${window.location.search}`
    return `veejr:draft:${userId}:${kind}:${context}`
  },

  async restoreDraft() {
    const secret = getSecretKey(this.el.dataset.userId)
    if (!secret) return

    try {
      const stored = JSON.parse(localStorage.getItem(this.draftStorageKey()) || "null")
      const draft = stored && openLocal(stored, secret)
      if (!draft) return

      const text = this.el.querySelector("[data-role=text]")
      const ttl = this.el.querySelector("[data-role=ttl]")
      const displays = this.el.querySelector("[data-role=max-displays]")
      const deliverAt = this.el.querySelector("[data-role=deliver-at]")
      if (text && typeof draft.text === "string") text.value = draft.text
      if (ttl && typeof draft.ttl === "string") ttl.value = draft.ttl
      if (displays && typeof draft.maxDisplays === "string") displays.value = draft.maxDisplays
      // A send time already in the past is not worth restoring — the user
      // would have to notice and clear it before the message would go.
      if (deliverAt && typeof draft.deliverAt === "string" && draft.deliverAt) {
        const restored = localDateTimeToIso(draft.deliverAt)
        if (restored && new Date(restored).getTime() > Date.now()) deliverAt.value = draft.deliverAt
      }
      if (draft.replyTo?.id) this.replyTo = draft.replyTo
      if (typeof draft.clientBatchId === "string" && draft.clientBatchId) {
        this.clientBatchId = draft.clientBatchId
      }
      this.renderReplyPreview()
      this.renderExpirySummary()
      this.renderScheduleSummary()
      this.setDraftStatus("Draft restored")
      const media = await loadDraftMedia(this.draftStorageKey(), secret)
      const files = media.filter((entry) => entry.kind === "file").map((entry) => entry.file)
      if (files.length > 0) {
        const transfer = new DataTransfer()
        files.forEach((file) => transfer.items.add(file))
        const input = this.attachmentInput()
        if (input) input.files = transfer.files
        this.renderFilePreview()
      }
      this.recordedAudio = media
        .filter((entry) => entry.kind === "audio")
        .map((entry) => ({...entry, url: URL.createObjectURL(entry.file)}))
      this.recordedVideo = media
        .filter((entry) => entry.kind === "video")
        .map((entry) => ({...entry, url: URL.createObjectURL(entry.file)}))
      this.renderAudioPreview()
      this.renderVideoPreview()
      if (media.length > 0) this.setDraftStatus("Draft and media restored")
    } catch {
      localStorage.removeItem(this.draftStorageKey())
    }
  },

  async saveDraft() {
    if (this.draftClearing) return
    const secret = getSecretKey(this.el.dataset.userId)
    if (!secret) return

    const text = this.el.querySelector("[data-role=text]")?.value || ""
    const ttl = this.el.querySelector("[data-role=ttl]")?.value || ""
    const maxDisplays = this.el.querySelector("[data-role=max-displays]")?.value || ""
    const deliverAt = this.el.querySelector("[data-role=deliver-at]")?.value || ""
    const files = [...(this.attachmentInput()?.files || [])]
    const media = [
      ...files.map((file) => ({file})),
      ...this.recordedAudio,
      ...this.recordedVideo,
    ]
    const hasDraft = text.trim() || ttl || maxDisplays || deliverAt || this.replyTo || media.length > 0

    if (!hasDraft) {
      this.clearDraft()
      return
    }

    localStorage.setItem(
      this.draftStorageKey(),
      JSON.stringify(
        sealLocal(
          {v: 2, text, ttl, maxDisplays, deliverAt, replyTo: this.replyTo || null, clientBatchId: this.clientBatchId},
          secret
        )
      )
    )
    this.mediaDraftWork = (this.mediaDraftWork || Promise.resolve())
      .then(() => saveDraftMedia(this.draftStorageKey(), media, secret))
      .catch(() => this.setDraftStatus("Text saved; media could not be stored on this device"))
    this.setDraftStatus("Draft saved on this device")
    this.renderExpirySummary()
    this.renderScheduleSummary()
  },

  clearDraft() {
    localStorage.removeItem(this.draftStorageKey())
    this.mediaDraftWork = (this.mediaDraftWork || Promise.resolve())
      .then(() => deleteDraftMedia(this.draftStorageKey()))
      .catch(() => {})
    this.setDraftStatus("")
  },

  setDraftStatus(message) {
    const status = this.el.querySelector("[data-role=draft-status]")
    if (!status) return
    status.textContent = message
    status.classList.toggle("hidden", !message)
  },

  renderReplyPreview() {
    const preview = this.el.querySelector("[data-role=reply-preview]")
    if (!preview) return
    preview.classList.toggle("hidden", !this.replyTo)
    const from = preview.querySelector("[data-role=reply-from]")
    const text = preview.querySelector("[data-role=reply-text]")
    if (from) from.textContent = this.replyTo?.from ? `Replying to ${this.replyTo.from}` : "Replying"
    if (text) text.textContent = this.replyTo?.text || "Encrypted message"
  },

  clearReply() {
    this.replyTo = null
    this.renderReplyPreview()
    this.saveDraft()
  },

  renderExpirySummary() {
    const summary = this.el.querySelector("[data-role=expiry-summary]")
    if (!summary) return
    const ttl = parseInt(this.el.querySelector("[data-role=ttl]")?.value || "", 10)
    const displays = parseInt(this.el.querySelector("[data-role=max-displays]")?.value || "", 10)
    const parts = []
    if (Number.isInteger(ttl) && ttl > 0) {
      const label = this.el.querySelector("[data-role=ttl]")?.selectedOptions?.[0]?.textContent
      parts.push(`expires after ${label?.toLowerCase() || "the selected time"}`)
    }
    if (Number.isInteger(displays) && displays > 0) {
      parts.push(`${displays} display${displays === 1 ? "" : "s"} per copy`)
    }
    summary.textContent = parts.length
      ? `This message ${parts.join(" and ")}. A recipient may still save what they see.`
      : "No expiry or display limit. Limits cannot revoke content a recipient has already saved."
  },

  renderScheduleSummary() {
    const summary = this.el.querySelector("[data-role=schedule-summary]")
    const input = this.el.querySelector("[data-role=deliver-at]")
    if (!summary || !input) return

    const iso = localDateTimeToIso(input.value)
    if (!iso) {
      summary.textContent =
        "Sends immediately. A scheduled message is encrypted now and held as ciphertext " +
        "until its time; the server never sees the text."
      delete summary.dataset.state
      return
    }

    const when = new Date(iso)
    if (when.getTime() <= Date.now()) {
      summary.textContent = "That time has already passed — pick a later one."
      summary.dataset.state = "invalid"
      return
    }

    summary.textContent =
      `Sends on ${when.toLocaleString()}. It is encrypted now; you can cancel it ` +
      "from the conversation until then."
    summary.dataset.state = "scheduled"
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

    if (this.mediaRecorder && this.mediaRecorder.state !== "inactive") {
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
      this.hideRecordingStage()
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
      this.saveDraft()
      this.setAudioStatus("Voice message ready to send.")
    })

    this.audioStream = stream
    this.mediaStream = stream
    this.activeRecordingKind = "audio"
    this.mediaRecorder = recorder
    recorder.start()
    this.showRecordingStage("audio", stream, startedAt)
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
    this.el.querySelectorAll(`[data-role="${role}"]`).forEach((button) => {
      button.setAttribute("aria-pressed", active ? "true" : "false")
      button.classList.toggle("bg-error", active)
      button.classList.toggle("text-error-content", active)
      button.classList.toggle("opacity-100", active)
    })
  },

  showRecordingStage(kind, stream, startedAt) {
    const stage = this.el.querySelector("[data-role=recording-stage]")
    const visual = stage?.querySelector("[data-role=recording-visual]")
    if (!stage || !visual) return
    stage.classList.remove("hidden")
    visual.textContent = ""
    if (kind === "video") {
      const video = document.createElement("video")
      video.srcObject = stream
      video.autoplay = true
      video.muted = true
      video.playsInline = true
      video.className = "max-h-[68svh] h-full w-full bg-black object-contain"
      visual.appendChild(video)
    } else {
      const audioState = document.createElement("div")
      audioState.className = "flex flex-col items-center gap-4 p-10 text-center"
      audioState.innerHTML = '<span class="grid size-20 place-items-center rounded-full bg-red-500/20 text-4xl" aria-hidden="true">●</span><span class="text-lg font-semibold">Voice recording in progress</span>'
      visual.appendChild(audioState)
    }
    const label = stage.querySelector("[data-role=recording-label]")
    if (label) label.textContent = kind === "video" ? "Recording video" : "Recording audio"
    const camera = stage.querySelector("[data-role=recording-camera]")
    camera?.classList.toggle("hidden", kind !== "video")
    this.recordingStartedAt = startedAt
    this.updateRecordingClock()
    clearInterval(this.recordingClock)
    this.recordingClock = setInterval(() => this.updateRecordingClock(), 1_000)
  },

  updateRecordingClock() {
    const clock = this.el.querySelector("[data-role=recording-time]")
    if (!clock || !this.recordingStartedAt) return
    const seconds = Math.max(0, Math.floor((Date.now() - this.recordingStartedAt) / 1_000))
    clock.textContent = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`
  },

  hideRecordingStage() {
    clearInterval(this.recordingClock)
    this.recordingClock = null
    this.recordingStartedAt = null
    const stage = this.el.querySelector("[data-role=recording-stage]")
    stage?.classList.add("hidden")
    stage?.querySelector("[data-role=recording-visual]")?.replaceChildren()
    const pause = stage?.querySelector("[data-role=recording-pause]")
    if (pause) pause.textContent = "Pause"
  },

  toggleRecordingPause() {
    const recorder = this.mediaRecorder
    if (!recorder || recorder.state === "inactive") return
    const button = this.el.querySelector("[data-role=recording-pause]")
    if (recorder.state === "paused") {
      recorder.resume()
      if (button) button.textContent = "Pause"
      if (this.activeRecordingKind === "audio") this.setAudioStatus("Recording resumed.")
      else this.setVideoStatus("Recording resumed.")
    } else {
      recorder.pause()
      if (button) button.textContent = "Resume"
      if (this.activeRecordingKind === "audio") this.setAudioStatus("Recording paused. Resume or stop when ready.")
      else this.setVideoStatus("Recording paused. Resume or stop when ready.")
    }
  },

  stopActiveRecording() {
    if (!this.mediaRecorder || this.mediaRecorder.state === "inactive") return
    this.recordingFinalizing = true
    this.mediaRecorder.stop()
    const message = "Finishing recording..."
    if (this.activeRecordingKind === "audio") this.setAudioStatus(message)
    else this.setVideoStatus(message)
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
    this.saveDraft()
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

    if (this.mediaRecorder && this.mediaRecorder.state !== "inactive") {
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
      this.hideRecordingStage()
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
      this.saveDraft()
      this.setVideoStatus("Video message ready to send.")
    })

    this.mediaStream = stream
    this.activeRecordingKind = "video"
    this.mediaRecorder = recorder
    recorder.start(1_000)
    this.showRecordingStage("video", stream, startedAt)
    this.setRecordingButton("video-toggle", true)
    this.videoDurationTimer = setTimeout(() => {
      if (recorder.state !== "inactive") {
        this.recordingFinalizing = true
        recorder.stop()
        this.setVideoStatus("Maximum recording length reached. Finishing recording...")
      }
    }, MAX_VIDEO_DURATION_MS)
    this.setVideoStatus("Recording... click the camera again to stop. Maximum 60 seconds.")
  },

  async toggleVideoFacing() {
    if (this.mediaRecorder && this.mediaRecorder.state !== "inactive") {
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
    this.saveDraft()
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
    if (this.mediaRecorder && this.mediaRecorder.state !== "inactive") {
      throw new Error("Stop recording before sending.")
    }
    if (this.recordingFinalizing) throw new Error("Wait for the recording to finish before sending.")
    if (!navigator.onLine) {
      this.saveDraft()
      throw new Error("You are offline. This draft is safe on this device and can be sent after reconnecting.")
    }

    // A locked tab used to be sent to /keys, which discarded the message and
    // its attachments — files cannot be restored from a draft. Unlock in
    // place instead and carry straight on with this same send.
    const mySecret = getSecretKey(userId) || (await this.unlockInPlace())
    if (!mySecret) return

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
        : {
            v: 1,
            kind,
            text,
            attachments,
            to,
            sent_at: new Date().toISOString(),
            ...(this.replyTo ? {reply_to: this.replyTo} : {}),
            ...extra,
          }
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
      // A scheduled message is sealed here and now, exactly like an immediate
      // one; only its release is deferred. The server holds ciphertext it
      // cannot read until the time arrives.
      const deliverAt = localDateTimeToIso(form.querySelector("[data-role=deliver-at]")?.value)
      if (deliverAt) messageOptions.deliver_at = deliverAt

      busy("Encrypting…")
      const envelopes = recipients.map((r) => ({
        recipient_id: r.id,
        ...sealFor(r.public_key, payload, mySecret),
      }))
      // Self-copy so our own history stays readable.
      if (!recipients.some((r) => String(r.id) === String(userId))) {
        envelopes.push({recipient_id: parseInt(userId), ...sealFor(myKey, payload, mySecret)})
      }

      busy(deliverAt ? "Scheduling…" : "Sending…")
      await this.pushWithReply("send_batch", {
        kind,
        envelopes,
        client_batch_id: this.clientBatchId,
        ...messageOptions,
      })

      this.draftClearing = true
      form.reset()
      this.clearReply()
      this.clearAudioRecordings()
      this.clearVideoRecordings()
      this.clearDraft()
      this.clientBatchId = crypto.randomUUID()
      this.draftClearing = false
      // reset() empties the file input without firing `change`.
      this.renderFilePreview()
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
