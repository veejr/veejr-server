// The WebGL craps table hook.
//
// Everything the table needs — the scene, the felt artwork, the dice, and
// three.js itself — is fetched only once this mounts, so the page costs
// nothing to anyone who never opens it.
//
// Falls back to the CSS dice already in the page when WebGL is unavailable,
// which is also what happens if the download fails.

import {loadThree, webglAvailable} from "../three_loader.js"

let modulePromise = null

function loadCrapsScene() {
  if (!modulePromise) {
    modulePromise = import("../craps/index.js").catch((error) => {
      modulePromise = null
      throw error
    })
  }
  return modulePromise
}

// Keys that already mean something where the focus is: typing a space into a
// field, or pressing a focused button/link, must not also throw the dice.
const OWN_SPACE = "input, textarea, select, button, a[href], summary, [contenteditable], [role=button]"

// Space throws the dice, same as the Roll button. It clicks the button rather
// than pushing "roll" itself so the shortcut obeys exactly the same rules —
// shooter only, a line bet down, nothing already in the air — because a
// disabled or absent button is a no-op.
function rollOnSpace(event) {
  if (event.code !== "Space" || event.repeat) return
  if (event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return
  if (event.target instanceof Element && event.target.closest(OWN_SPACE)) return

  // In full screen the page underneath is hidden, so the HUD's button is the
  // one on screen.
  const ids = document.fullscreenElement ? ["craps-hud-roll", "craps-roll"] : ["craps-roll"]
  const button = ids.map((id) => document.getElementById(id)).find(Boolean)

  // Space scrolls the page; on the craps table it means roll.
  event.preventDefault()
  if (button && !button.disabled) button.click()
}

export const CrapsTable = {
  mounted() {
    this.table = null
    this.disposed = false

    // Bound before the WebGL check: the roll button exists with or without
    // the 3D table, and so should the shortcut.
    this.onKeydown = rollOnSpace
    window.addEventListener("keydown", this.onKeydown)

    if (!webglAvailable()) {
      this.fallback("This browser cannot draw the 3D table.")
      return
    }

    Promise.all([loadThree(this.el.dataset.threeSrc), loadCrapsScene()])
      .then(([THREE, mod]) => {
        if (this.disposed) return
        this.table = mod.createCrapsTable(THREE, this.el, {
          onBet: (bet, target) => this.pushEvent("felt_bet", {bet, target}),
          onComeOdds: (target, type) => this.pushEvent("felt_odds", {target, type}),
          // The server holds the outcome back until this reaches it.
          onSettled: (id) => this.pushEvent("dice_settled", {id}),
        })
        this.table.update(this.state())
        // Marks the document rather than this element: LiveView reconciles
        // the attributes of even an ignored container, so anything set here
        // would be stripped on the next patch.
        document.documentElement.classList.add("craps-webgl")
      })
      .catch(() => {
        if (!this.disposed) this.fallback("The 3D table could not be loaded.")
      })
  },

  updated() {
    if (this.table) this.table.update(this.state())
  },

  destroyed() {
    this.disposed = true
    window.removeEventListener("keydown", this.onKeydown)
    document.documentElement.classList.remove("craps-webgl")
    if (this.table) this.table.destroy()
    this.table = null
  },

  // The same public table state the HTML controls render, handed over as a
  // data attribute so the scene needs no channel of its own.
  state() {
    try {
      return JSON.parse(this.el.dataset.table)
    } catch (_error) {
      return {phase: "come_out", point: null, last_roll: null}
    }
  },

  fallback(message) {
    document.documentElement.classList.remove("craps-webgl")
    this.el.replaceChildren()
    const note = document.createElement("p")
    note.className = "grid h-full place-items-center p-6 text-center text-sm opacity-60"
    note.textContent = `${message} The dice below still show every roll.`
    this.el.appendChild(note)
  },
}
