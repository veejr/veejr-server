// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/veejr"
import topbar from "../vendor/topbar"
import veejrHooks from "./veejr/hooks.js"
import {
  CallSession,
  installCallExitGuard,
  installCallScheduleNotifications,
  installRingBanner,
} from "./veejr/call_hook.js"
import {YouTubeWatch, installWatchBanner} from "./veejr/watch_hook.js"
import {installCrapsBanner} from "./veejr/craps_banner.js"
import {WatchVoice} from "./veejr/watch_voice_hook.js"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
installCallExitGuard()
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...veejrHooks, CallSession, YouTubeWatch, WatchVoice},
})

let connectionStatusTimer
const setConnectionStatus = (state) => {
  clearTimeout(connectionStatusTimer)
  const banner = document.querySelector("#connection-status")
  if (!banner) return

  if (state === "connected") {
    banner.classList.add("hidden")
    banner.classList.remove("flex")
    return
  }

  connectionStatusTimer = setTimeout(() => {
    const text = banner.querySelector("[data-role='connection-status-text']")
    if (text) {
      text.textContent =
        state === "offline"
          ? "You are offline. Drafts remain encrypted on this device."
          : "Reconnecting… changes will continue when the connection returns."
    }
    banner.classList.remove("hidden")
    banner.classList.add("flex")
  }, state === "offline" ? 0 : 600)
}

window.addEventListener("offline", () => setConnectionStatus("offline"))
window.addEventListener("online", () => setConnectionStatus("reconnecting"))
liveSocket.socket.onOpen(() => setConnectionStatus("connected"))
liveSocket.socket.onError(() =>
  setConnectionStatus(navigator.onLine ? "reconnecting" : "offline")
)
liveSocket.socket.onClose(() =>
  setConnectionStatus(navigator.onLine ? "reconnecting" : "offline")
)

// Incoming-call banners can appear on any authenticated page.
installRingBanner()
installCallScheduleNotifications()
installWatchBanner()
installCrapsBanner()

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Browser notifications for incoming encrypted items. The event carries only
// what the server knows anyway: who sent something and what kind it is.
window.addEventListener("phx:veejr:notify", ({detail}) => {
  if (!("Notification" in window) || Notification.permission !== "granted") return
  const kind = {message: "message", location: "location share", note: "map note"}[detail.kind] || "item"
  new Notification("veejr", {
    body: `@${detail.from} sent you an encrypted ${kind}. Open veejr to request it.`,
    tag: `veejr-notification-${detail.from || "inbox"}`,
  })
})

// Keep the service worker registered on every visit (needed for push
// delivery and PWA installability, harmless otherwise).
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js").catch(() => {})
}

// Stash the browser's install prompt so Settings can offer an Install button.
window.addEventListener("beforeinstallprompt", (e) => {
  e.preventDefault()
  window.veejrInstallPrompt = e
  window.dispatchEvent(new CustomEvent("veejr:installable"))
})

// Ask for notification permission on the first interaction after login.
window.addEventListener(
  "click",
  () => {
    if ("Notification" in window && Notification.permission === "default") {
      Notification.requestPermission()
    }
  },
  {once: true}
)

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
