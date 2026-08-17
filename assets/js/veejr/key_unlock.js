// One same-page passphrase prompt shared by every encrypted surface.
// The passphrase and unwrapped key never cross the LiveView socket: this hook
// only writes the secret key to this tab's sessionStorage, then reloads the
// current URL so every mounted decryptor can continue where the user was.

import {cacheSecretKey, getSecretKey, unlockIdentity} from "./crypto.js"

export function requestKeyUnlock() {
  window.dispatchEvent(new CustomEvent("veejr:request-key-unlock"))
}

export const InlineKeyUnlock = {
  mounted() {
    this.form = this.el.querySelector("#inline-key-unlock-form")
    this.input = this.el.querySelector("[data-role=passphrase]")
    this.error = this.el.querySelector("[data-role=unlock-error]")
    this.submit = this.form.querySelector("button[type=submit]")

    this.open = () => {
      if (getSecretKey(this.el.dataset.userId)) {
        window.location.reload()
        return
      }

      this.error.classList.add("hidden")
      this.error.textContent = ""
      this.el.showModal()
      requestAnimationFrame(() => this.input.focus())
    }

    this.cancel = () => {
      this.input.value = ""
      this.el.close()
    }

    this.onBackdrop = (event) => {
      if (event.target === this.el) this.cancel()
    }

    this.onSubmit = async (event) => {
      event.preventDefault()
      const {userId, encSecretKey, keySalt, keyNonce} = this.el.dataset

      this.submit.disabled = true
      this.submit.textContent = "Unlocking…"
      this.error.classList.add("hidden")

      try {
        const secretKey = await unlockIdentity(
          this.input.value,
          encSecretKey,
          keySalt,
          keyNonce,
        )

        if (!secretKey) {
          this.error.textContent = "That passphrase did not work. Try again."
          this.error.classList.remove("hidden")
          this.input.select()
          return
        }

        cacheSecretKey(userId, secretKey)
        window.location.reload()
      } catch {
        this.error.textContent = "Could not unlock on this device."
        this.error.classList.remove("hidden")
      } finally {
        this.submit.disabled = false
        this.submit.textContent = "Unlock and continue"
      }
    }

    window.addEventListener("veejr:request-key-unlock", this.open)
    this.form.addEventListener("submit", this.onSubmit)
    this.el.querySelector("[data-role=cancel]").addEventListener("click", this.cancel)
    this.el.addEventListener("click", this.onBackdrop)
  },

  destroyed() {
    window.removeEventListener("veejr:request-key-unlock", this.open)
    this.form?.removeEventListener("submit", this.onSubmit)
    this.el.querySelector("[data-role=cancel]")?.removeEventListener("click", this.cancel)
    this.el.removeEventListener("click", this.onBackdrop)
  },
}
