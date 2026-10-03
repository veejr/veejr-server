import {getUnlockMinutes, setUnlockMinutes, getSecretKey, forgetSecretKey} from "../key_cache.js"

export const KeyRemember = {
  mounted() {
    const id = this.el.dataset.userId
    const mode = this.el.querySelector("[name=unlock_mode]")
    const duration = this.el.querySelector("[name=unlock_duration]")
    const unit = this.el.querySelector("[name=unlock_unit]")
    const status = this.el.querySelector("[role=status]")
    const minutes = getUnlockMinutes(id)
    mode.value = minutes ? "timed" : "session"
    unit.value = minutes && minutes % 1440 === 0 ? "1440" : minutes && minutes % 60 === 0 ? "60" : "1"
    duration.value = minutes ? minutes / Number(unit.value) : 8
    if (!minutes) unit.value = "60"
    const update = () => {
      duration.disabled = unit.disabled = mode.value !== "timed"
      this.el.querySelector("[data-role=duration-fields]").hidden = mode.value !== "timed"
    }
    mode.addEventListener("change", update)
    update()
    this.el.addEventListener("submit", event => {
      event.preventDefault()
      try {
        const value = mode.value === "timed" ? Number(duration.value) * Number(unit.value) : 0
        if (mode.value === "timed" && value < 1) throw new Error("Choose at least 1 minute.")
        setUnlockMinutes(id, value)
        window.location.reload()
      } catch (error) {
        status.textContent = error.message || "Your browser could not save this setting."
      }
    })
  },
}

// Reload on expiry to discard decrypted DOM and keys held by long-lived call,
// note and composer hooks. Recheck after sleep, tab switching and bfcache use.
export const KeySession = {
  mounted() {
    const id = this.el.dataset.userId
    this.wasUnlocked = !!getSecretKey(id)
    this.check = () => {
      const unlocked = !!getSecretKey(id)
      if (this.wasUnlocked && !unlocked) {
        window.dispatchEvent(new Event("veejr:keys-locked"))
        window.location.reload()
      }
      this.wasUnlocked = unlocked
    }
    this.logout = event => {
      if (event.target.closest?.("a[href='/users/log-out']")) forgetSecretKey(id)
    }
    this.timer = window.setInterval(this.check, 1000)
    window.addEventListener("storage", this.check)
    window.addEventListener("pageshow", this.check)
    document.addEventListener("visibilitychange", this.check)
    document.addEventListener("click", this.logout, true)
  },
  destroyed() {
    window.clearInterval(this.timer)
    window.removeEventListener("storage", this.check)
    window.removeEventListener("pageshow", this.check)
    document.removeEventListener("visibilitychange", this.check)
    document.removeEventListener("click", this.logout, true)
  },
}
