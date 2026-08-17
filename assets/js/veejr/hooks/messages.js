// Rendering decrypted content: full envelopes, conversation previews, and
// message bubbles.
//
// Plaintext is written with textContent so a decrypted message can never be
// parsed as markup. Message bodies go through ../link_text.js instead, which
// keeps the same guarantee: it appends text nodes and anchors it builds
// itself, never markup parsed out of the message.

import {
  getSecretKey,
  sealFor,
  openFrom,
} from "../crypto.js"
import {appendLinkedText} from "../link_text.js"
import {requestKeyUnlock} from "../key_unlock.js"
import {attachmentMime, decryptAttachmentBlob, downloadAttachment, previewableMedia, pushWithReply, showLocationModal, showMediaModal} from "./shared.js"

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
      const button = document.createElement("button")
      button.type = "button"
      button.className = "link text-left text-sm opacity-70"
      button.textContent = "🔒 Locked — unlock here to read"
      button.addEventListener("click", requestKeyUnlock)
      this.el.appendChild(button)
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

    if (payload.reply_to && typeof payload.reply_to === "object") {
      const quote = document.createElement("blockquote")
      quote.className =
        "mb-2 rounded-lg border-l-2 border-current/40 bg-black/5 px-3 py-2 text-xs opacity-80"
      const from = document.createElement("strong")
      from.className = "block truncate"
      from.textContent = payload.reply_to.from || "Earlier message"
      const excerpt = document.createElement("span")
      excerpt.className = "block whitespace-pre-wrap"
      excerpt.textContent = payload.reply_to.text || "Encrypted message"
      quote.append(from, excerpt)
      this.el.appendChild(quote)
    }

    if (kind === "note" && payload.title) {
      const h = document.createElement("p")
      h.className = "font-semibold"
      h.textContent = payload.title
      this.el.appendChild(h)
    }

    if (payload.text) {
      const p = document.createElement("p")
      p.className = "whitespace-pre-wrap"
      appendLinkedText(p, payload.text)
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
      const button = document.createElement("button")
      button.type = "button"
      button.className = "link text-left"
      button.textContent = "Unlock here to preview"
      button.addEventListener("click", requestKeyUnlock)
      this.el.replaceChildren(button)
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
    if (edit) {
      edit.addEventListener("click", () => {
        this.openEditor().catch((err) => window.alert(err.message))
      })
    }

    const reply = this.el.querySelector("[data-role=reply-message]")
    if (reply) {
      reply.addEventListener("click", () => {
        const decryptEl = this.el.querySelector("[phx-hook='Decrypt'], [data-peer-key]")
        const payload = decryptEl?.veejrPayload
        if (!payload) return window.alert("Unlock this message before replying.")

        window.dispatchEvent(
          new CustomEvent("veejr:reply-message", {
            detail: {
              publicId: decryptEl.dataset.publicId,
              from: this.el.dataset.messageSender,
              text: payload.text || payload.title || "Encrypted message",
            },
          })
        )
      })
    }
  },

  async openEditor() {
    if (this.editor) {
      this.editor.querySelector("textarea").focus()
      return
    }

    const decryptEl = this.el.querySelector("[phx-hook='Decrypt'], [data-peer-key]")
    const payload = decryptEl && decryptEl.veejrPayload
    if (!payload) throw new Error("Unlock this message before editing it.")
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
      if (!mySecret) {
        requestKeyUnlock()
        return
      }

      save.disabled = true
      save.textContent = "Saving..."

      try {
        const nextPayload = {...payload, text, edited_at: new Date().toISOString()}
        const envelopes = copies.map((copy) => ({
          public_id: copy.public_id,
          ...sealFor(copy.public_key, nextPayload, mySecret),
        }))
        await pushWithReply(this, "edit_batch", {
          id: publicId,
          envelopes,
          attachment_ids: (payload.attachments || []).map((attachment) => attachment.id),
        })
        decryptEl.dataset.ciphertext = envelopes.find((entry) => entry.public_id === publicId)?.ciphertext || decryptEl.dataset.ciphertext
        decryptEl.dataset.nonce = envelopes.find((entry) => entry.public_id === publicId)?.nonce || decryptEl.dataset.nonce
        decryptEl.veejrPayload = nextPayload
        decryptEl.textContent = ""
        const p = document.createElement("p")
        p.className = "whitespace-pre-wrap"
        appendLinkedText(p, text)
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
