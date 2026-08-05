// "Come and play" banner, raised when a friend invites you to the craps
// table from somewhere else in the app.
//
// Deliberately outside craps/: this listens on every page, so it must not
// drag the table's WebGL bundle in with it.

export function installCrapsBanner() {
  let banner

  const remove = () => {
    banner?.remove()
    banner = null
  }

  window.addEventListener("phx:craps:invite", ({detail}) => {
    if (window.location.pathname === "/craps") return
    remove()

    banner = document.createElement("aside")
    banner.id = "craps-invite"
    banner.className =
      "fixed inset-x-3 bottom-3 z-[70] mx-auto flex max-w-xl items-center gap-3 rounded-2xl border border-primary/30 bg-base-100/95 p-4 text-base-content shadow-2xl backdrop-blur sm:bottom-5"
    banner.innerHTML = `
      <div class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-primary/10 text-primary" aria-hidden="true">🎲</div>
      <div class="min-w-0 flex-1">
        <p class="font-semibold">${escapeHtml(detail.host)} asked you to the craps table</p>
        <p class="text-sm opacity-65">Play-money chips, no stakes.</p>
      </div>
      <a href="/craps" class="btn btn-primary btn-sm">Take a seat</a>
      <button type="button" class="btn btn-circle btn-ghost btn-sm" aria-label="Dismiss">×</button>
    `
    banner.querySelector("button")?.addEventListener("click", remove)
    document.body.appendChild(banner)
  })
}

function escapeHtml(value) {
  const span = document.createElement("span")
  span.textContent = String(value || "Someone")
  return span.innerHTML
}
