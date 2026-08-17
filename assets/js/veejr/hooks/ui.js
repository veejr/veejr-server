// Hooks with no cryptographic role: timestamps, theme pickers, scrolling,
// flash dismissal, push registration, avatar upload, and the guest-conference
// lobby.
//
// The guest lobby does generate an ephemeral keypair, but it is a tab-local
// identity that is never wrapped or uploaded — see generateEphemeralIdentity
// in ../crypto.js.

import {
  generateEphemeralIdentity,
  cacheSecretKey,
  getSecretKey,
  sealFor,
} from "../crypto.js"
import {csrfToken, pushWithReply, sameBytes, urlB64ToBytes} from "./shared.js"
import {Composer} from "./composer.js"
import {ConversationPreview} from "./messages.js"
import {requestKeyUnlock} from "../key_unlock.js"

export const ScheduleTime = {
  mounted() {
    this.bindInputs()
  },

  updated() {
    this.bindInputs()
  },

  bindInputs() {
    this.unbindInputs()
    this.localInput = this.el.querySelector("#scheduled-call-local-time")
    this.utcInput = this.el.querySelector("input[name='schedule[scheduled_for]']")
    this.syncUtc = () => {
      if (!this.localInput || !this.utcInput) return
      const parsed = new Date(this.localInput.value)
      this.utcInput.value = Number.isNaN(parsed.getTime()) ? "" : parsed.toISOString()
    }

    if (this.localInput && this.utcInput) {
      const initial = new Date(this.utcInput.value)
      if (!Number.isNaN(initial.getTime())) {
        const offset = initial.getTimezoneOffset() * 60_000
        this.localInput.value = new Date(initial.getTime() - offset).toISOString().slice(0, 16)
        this.localInput.min = new Date(Date.now() - new Date().getTimezoneOffset() * 60_000)
          .toISOString()
          .slice(0, 16)
      }
      this.localInput.addEventListener("input", this.syncUtc)
      this.localInput.addEventListener("change", this.syncUtc)
      this.syncUtc()
    }
  },

  unbindInputs() {
    if (!this.localInput || !this.syncUtc) return
    this.localInput.removeEventListener("input", this.syncUtc)
    this.localInput.removeEventListener("change", this.syncUtc)
  },

  destroyed() {
    this.unbindInputs()
  },
}

export const LocalTime = {
  mounted() {
    this.renderLocalTime()
  },

  updated() {
    this.renderLocalTime()
  },

  renderLocalTime() {
    const parsed = new Date(this.el.getAttribute("datetime"))
    if (Number.isNaN(parsed.getTime())) return
    this.el.textContent = parsed.toLocaleString([], {
      dateStyle: "medium",
      timeStyle: "short",
    })
    this.el.title = Intl.DateTimeFormat().resolvedOptions().timeZone
  },
}

export const MessageConsent = {
  mounted() {
    this.onClick = (event) => {
      const button = event.target.closest("[data-role=busy-later]")
      if (!button || !this.el.contains(button)) return

      event.preventDefault()
      this.sendBusyLater(button)
    }

    this.el.addEventListener("click", this.onClick)
  },

  destroyed() {
    if (this.onClick) this.el.removeEventListener("click", this.onClick)
  },

  async sendBusyLater(button) {
    if (button.disabled) return

    const {userId, myKey} = this.el.dataset
    const {notificationId, senderId, senderKey, senderHandle} = button.dataset
    const mySecret = getSecretKey(userId)

    if (!mySecret) {
      requestKeyUnlock()
      return
    }

    const error = button.closest("li")?.querySelector("[data-role=busy-error]")
    const original = button.textContent
    button.disabled = true
    button.textContent = "Sending..."
    if (error) error.classList.add("hidden")

    try {
      const payload = {
        v: 1,
        kind: "message",
        text: "Busy now, laters",
        attachments: [],
        to: [senderHandle],
        sent_at: new Date().toISOString(),
      }
      const envelopes = [
        {recipient_id: senderId, ...sealFor(senderKey, payload, mySecret)},
        {recipient_id: userId, ...sealFor(myKey, payload, mySecret)},
      ]

      await pushWithReply(this, "busy_later", {id: notificationId, envelopes})
    } catch (reason) {
      button.disabled = false
      button.textContent = original
      if (error) {
        error.textContent = reason.message || "The quick reply could not be sent."
        error.classList.remove("hidden")
      }
    }
  },
}

// Encrypts one file with a fresh symmetric key and uploads the ciphertext.
// Returns the attachment descriptor that rides inside the envelope payload.

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
    this.allowedThemes = new Set(["classic", "salon", "party", "comic"])
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
// under [data-contacts-theme="..."] in app.css.
//
// Appearance is only a look. It does not decide which sections are open —
// the flat themes used to force all of them open on every render, which made
// Friends and Groups permanently expanded and, with their arrow hidden,
// impossible to collapse.

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
    this.resetSections()
    this.applyTheme(localStorage.getItem(this.storageKey) || "classic", false)
  },

  updated() {
    this.applyTheme(this.currentTheme || "classic", false)
  },

  destroyed() {
    this.el.removeEventListener("change", this.onThemeChange)
    window.removeEventListener("storage", this.onThemeStorage)
  },

  // Arriving at Contacts starts from the server's own layout, so Friends and
  // Groups are closed however the page got here — a fresh render, a live
  // navigation, or a back-button restore that handed back a <details> still
  // open from last time.
  //
  // Only on arrival. Doing this on updated() or on a theme change would slam
  // shut a section the reader had just expanded.
  resetSections() {
    this.el.querySelectorAll(".contacts-section").forEach((section) => {
      section.open = section.hasAttribute("data-default-open")
    })
  },

  applyTheme(theme, persist) {
    const selected = this.allowedThemes.has(theme) ? theme : "classic"
    this.currentTheme = selected
    this.el.dataset.contactsTheme = selected

    const select = this.el.querySelector("[data-contacts-theme-select]")
    if (select && select.value !== selected) select.value = selected

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

export const ScrollBottom = {
  mounted() {
    this.loadingMore = false
    this.beforeLoadHeight = 0
    this.threadId = this.el.id
    this.pinnedToBottom = true
    this.knownMessageIds = new Set(
      [...this.el.querySelectorAll("[id^='message-shell-']")].map((node) => node.id),
    )
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
      if (this.threadId !== this.el.id) {
        this.threadId = this.el.id
        this.knownMessageIds = new Set(
          [...this.el.querySelectorAll("[id^='message-shell-']")].map((node) => node.id),
        )
        return
      }

      const incoming = [...this.el.querySelectorAll("[id^='message-shell-']")].filter(
        (node) => !this.knownMessageIds.has(node.id),
      )
      incoming.forEach((node) => this.knownMessageIds.add(node.id))

      if (!this.loadingMore) {
        const received = incoming.filter((node) => node.dataset.messageMine === "false")
        received.forEach((node) => {
          node.classList.remove("message-arrival")
          void node.offsetWidth
          node.classList.add("message-arrival")
        })
        if (received.length > 0) this.celebrateIncomingMessage()
      }

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
      this.knownMessageIds = new Set(
        [...this.el.querySelectorAll("[id^='message-shell-']")].map((node) => node.id),
      )
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
    clearTimeout(this.celebrationTimer)
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
  celebrateIncomingMessage() {
    const workspace = this.el.closest("#messages-workspace")
    const celebration = workspace?.querySelector("[data-role='new-message-celebration']")
    if (!celebration) return

    const announcement = celebration.querySelector("[data-role='arrival-announcement']")
    if (announcement) {
      announcement.textContent = ""
      requestAnimationFrame(() => {
        announcement.textContent = "New message received."
      })
    }

    clearTimeout(this.celebrationTimer)
    celebration.classList.remove("is-visible")
    void celebration.offsetWidth
    celebration.classList.add("is-visible")
    this.celebrationTimer = setTimeout(() => {
      celebration.classList.remove("is-visible")
    }, 2200)
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

export async function decodeAvatarImage(file) {
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

export const GuestConferenceLobby = {
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
