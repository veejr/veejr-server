// The message composer: gathers recipients, text, and attachments, encrypts
// everything in the browser, and pushes only ciphertext.
//
// Deliberately not a LiveView form — its inputs are read here, not sent as
// form params.

import {
  getSecretKey,
  sealFor,
  sealLocal,
  openLocal,
} from "../crypto.js"
import {MAX_VIDEO_DURATION_MS, currentLocationPath, encryptAndUpload, preferredAudioMime, preferredVideoMime, pushWithReply, showError} from "./shared.js"
import {noteDocument} from "./notes_document.js"
import {Decrypt} from "./messages.js"

export const Composer = {
  mounted() {
    this.recordedAudio = []
    this.recordedVideo = []
    this.videoFacingMode = "user"
    this.textEl = this.el.querySelector("[data-role=text]")
    this.restoreDraft()

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
    clearTimeout(this.draftTimer)
    clearTimeout(this.videoDurationTimer)
    if (this.mediaRecorder && this.mediaRecorder.state === "recording") this.mediaRecorder.stop()
    this.stopMediaTracks()
    if (this.onComposerClick) this.el.removeEventListener("click", this.onComposerClick)
    if (this.onDocumentClick) document.removeEventListener("click", this.onDocumentClick)
    if (this.onDocumentKeydown) document.removeEventListener("keydown", this.onDocumentKeydown)
    if (this.textEl) this.textEl.removeEventListener("keydown", this.onTextKeydown)
    if (this.onDraftInput) {
      this.el.removeEventListener("input", this.onDraftInput)
      this.el.removeEventListener("change", this.onDraftInput)
    }
    if (this.onReplyMessage) window.removeEventListener("veejr:reply-message", this.onReplyMessage)
    if (this.emojiMenu && this.emojiMenu.parentElement === document.body) this.emojiMenu.remove()
    this.recordedAudio.forEach((entry) => URL.revokeObjectURL(entry.url))
    this.recordedVideo.forEach((entry) => URL.revokeObjectURL(entry.url))
  },

  draftStorageKey() {
    const {userId, kind, draftKey} = this.el.dataset
    const context = draftKey || `${window.location.pathname}${window.location.search}`
    return `veejr:draft:${userId}:${kind}:${context}`
  },

  restoreDraft() {
    const secret = getSecretKey(this.el.dataset.userId)
    if (!secret) return

    try {
      const stored = JSON.parse(localStorage.getItem(this.draftStorageKey()) || "null")
      const draft = stored && openLocal(stored, secret)
      if (!draft) return

      const text = this.el.querySelector("[data-role=text]")
      const ttl = this.el.querySelector("[data-role=ttl]")
      const displays = this.el.querySelector("[data-role=max-displays]")
      if (text && typeof draft.text === "string") text.value = draft.text
      if (ttl && typeof draft.ttl === "string") ttl.value = draft.ttl
      if (displays && typeof draft.maxDisplays === "string") displays.value = draft.maxDisplays
      if (draft.replyTo?.id) this.replyTo = draft.replyTo
      this.renderReplyPreview()
      this.renderExpirySummary()
      this.setDraftStatus("Draft restored")
    } catch {
      localStorage.removeItem(this.draftStorageKey())
    }
  },

  saveDraft() {
    const secret = getSecretKey(this.el.dataset.userId)
    if (!secret) return

    const text = this.el.querySelector("[data-role=text]")?.value || ""
    const ttl = this.el.querySelector("[data-role=ttl]")?.value || ""
    const maxDisplays = this.el.querySelector("[data-role=max-displays]")?.value || ""
    const hasDraft = text.trim() || ttl || maxDisplays || this.replyTo

    if (!hasDraft) {
      this.clearDraft()
      return
    }

    localStorage.setItem(
      this.draftStorageKey(),
      JSON.stringify(
        sealLocal({v: 1, text, ttl, maxDisplays, replyTo: this.replyTo || null}, secret)
      )
    )
    this.setDraftStatus("Draft saved on this device")
    this.renderExpirySummary()
  },

  clearDraft() {
    localStorage.removeItem(this.draftStorageKey())
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
      this.clearReply()
      this.clearDraft()
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
