const faviconActivities = new Map()

export const faviconHrefs = {
  default: "/images/favicon-veejr.svg",
  call: "/images/favicon-phone.svg",
  youtube: "/images/favicon-projector.svg",
}

export function faviconStateFor(activities) {
  const states = [...activities]
  if (states.includes("youtube")) return "youtube"
  if (states.includes("call")) return "call"
  return "default"
}

export function faviconHrefFor(state) {
  return faviconHrefs[state] || faviconHrefs.default
}

export function setFaviconActivity(source, state) {
  if (!source) return

  if (state === "call" || state === "youtube") {
    faviconActivities.set(source, state)
  } else {
    faviconActivities.delete(source)
  }

  applyFaviconState(faviconStateFor(faviconActivities.values()))
}

export function clearFaviconActivity(source) {
  setFaviconActivity(source, null)
}

export function applyFaviconState(state, root = document) {
  let favicon = root.querySelector("#favicon")
  if (!favicon) {
    favicon = root.createElement("link")
    favicon.id = "favicon"
    favicon.rel = "icon"
    favicon.type = "image/svg+xml"
    root.head?.appendChild(favicon)
  }

  favicon.dataset.state = state
  favicon.setAttribute("href", faviconHrefFor(state))
}
