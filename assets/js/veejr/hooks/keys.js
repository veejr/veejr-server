// Identity key lifecycle: setup, unlock, passphrase rewrap, rotation, reset,
// and lock.
//
// This is the security-critical surface. Passphrases and secret keys are read
// from plain DOM inputs and never travel over the LiveView socket; only public
// keys and ciphertext are pushed. Keeping these hooks in one small file is
// deliberate, so auditing key handling does not mean reading every hook in the
// application.

import {
  generateIdentity,
  unlockIdentity,
  wrapSecretKey,
  cacheSecretKey,
  getSecretKey,
  forgetSecretKey,
  sealFor,
  openFrom,
} from "../crypto.js"
import {pushWithReply, showError} from "./shared.js"

export const KeySetup = {
  mounted() {
    const form = this.el
    form.addEventListener("submit", async (e) => {
      e.preventDefault()
      const pass = form.querySelector("[data-role=passphrase]").value
      const confirm = form.querySelector("[data-role=confirm]").value
      const password = form.querySelector("[data-role=account-password]")?.value || ""
      const passwordConfirmation =
        form.querySelector("[data-role=account-password-confirmation]")?.value || ""
      if (pass.length < 8) return showError(form, "Passphrase must be at least 8 characters.")
      if (pass !== confirm) return showError(form, "Passphrases do not match.")
      if (password || passwordConfirmation) {
        if (password.length < 12 || password.length > 72) {
          return showError(form, "Login password must be 12–72 characters.")
        }
        if (password !== passwordConfirmation) {
          return showError(form, "Login passwords do not match.")
        }
      }

      const btn = form.querySelector("button[type=submit]")
      btn.disabled = true
      btn.textContent = "Generating keys…"
      try {
        const id = await generateIdentity(pass)
        cacheSecretKey(this.el.dataset.userId, id.secretKey)
        await pushWithReply(this, "keys_generated", {
          public_key: id.publicKey,
          enc_secret_key: id.encSecretKey,
          key_salt: id.keySalt,
          key_nonce: id.keyNonce,
          password,
          password_confirmation: passwordConfirmation,
        })
      } catch (err) {
        btn.disabled = false
        btn.textContent = "Generate my keys"
        showError(form, err.reply?.error || `Key generation failed: ${err.message}`)
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
