// Turning URLs and email addresses inside decrypted text into clickable links.
//
// Everywhere else plaintext is written with textContent so a decrypted message
// can never be parsed as markup (see the security note in ./hooks.js). This is
// the one place message content becomes elements, so it keeps that promise a
// different way: the scan is a pure function over the string, the visible text
// of every link is still a text node, and each href is rebuilt from scratch
// and re-parsed against a scheme allowlist. Anything that fails stays text.
//
// Split from the rendering hooks because the parsing — where a URL ends, which
// candidates are safe — is the part worth testing, and it needs no DOM.

// A candidate is an explicit http(s) URL, a schemeless `www.` host, or an
// email address. Nothing else: `javascript:` and friends never match, so they
// cannot reach the allowlist in the first place.
const CANDIDATE =
  /(?:https?:\/\/|www\.)[^\s<>"'`]+|[a-z0-9._%+-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}/gi

const ALLOWED_PROTOCOLS = new Set(["http:", "https:", "mailto:"])

// Characters that end a sentence rather than a link. Closing brackets are
// handled separately since they are legitimate URL characters when balanced.
const TRAILING_PUNCTUATION = ".,;:!?…\"'’”»"
const CLOSERS = {")": "(", "]": "[", "}": "{"}

// A match starting right after one of these is part of a longer token, not a
// link of its own: the `alice@example.com` inside the federated handle
// `@alice@example.com`, or the tail of a word someone typed without a space.
const GLUED_TO_PREVIOUS = /[\w@.\-/]/

/**
 * Split text into plain and link segments.
 *
 * Returns `{type: "text", text}` and `{type: "link", text, href}` in source
 * order; concatenating every `text` reproduces the input exactly.
 */
export function splitLinkedText(value) {
  const source = typeof value === "string" ? value : ""
  const segments = []
  let plainFrom = 0

  for (const match of source.matchAll(CANDIDATE)) {
    const start = match.index
    const before = start > 0 ? source[start - 1] : ""
    if (GLUED_TO_PREVIOUS.test(before)) continue

    const text = trimTrailing(match[0])
    const href = linkHref(text)
    if (!href) continue

    if (start > plainFrom) segments.push({type: "text", text: source.slice(plainFrom, start)})
    segments.push({type: "link", text, href})
    plainFrom = start + text.length
  }

  if (plainFrom < source.length) segments.push({type: "text", text: source.slice(plainFrom)})

  return segments
}

/**
 * The destination for a candidate, or null when it is not a link we will open.
 */
export function linkHref(text) {
  const scheme = /^https?:\/\//i.test(text)
  const candidate = scheme ? text : text.includes("@") ? `mailto:${text}` : `https://${text}`

  let url
  try {
    url = new URL(candidate)
  } catch {
    return null
  }

  if (!ALLOWED_PROTOCOLS.has(url.protocol)) return null
  // A guessed scheme needs a hostname that actually looks like one, so a bare
  // `www.` is not promoted to a link. Typed-out schemes are taken at their
  // word, which keeps `http://localhost:4000` working.
  if (!scheme && url.protocol !== "mailto:") {
    const labels = url.hostname.split(".")
    if (labels.length < 2 || labels[labels.length - 1].length < 2) return null
  }

  return url.href
}

/**
 * Append text to an element, with any links inside it as real anchors.
 */
export function appendLinkedText(parent, value) {
  for (const segment of splitLinkedText(value)) {
    parent.appendChild(
      segment.type === "link" ? linkElement(segment) : document.createTextNode(segment.text)
    )
  }

  return parent
}

function linkElement({text, href}) {
  const a = document.createElement("a")
  a.href = href
  a.textContent = text
  a.className = "veejr-inline-link underline decoration-1 underline-offset-2 break-words hover:opacity-80"
  // The visible text is whatever the sender typed, which need not match where
  // it goes, so show the real destination on hover.
  a.title = href

  if (offsite(href)) {
    a.target = "_blank"
    // No referrer: which conversation a link was opened from is not the
    // destination's business.
    a.rel = "noopener noreferrer"
    a.referrerPolicy = "no-referrer"
  }

  return a
}

function offsite(href) {
  if (href.startsWith("mailto:")) return false
  if (typeof window === "undefined") return true

  try {
    return new URL(href).origin !== window.location.origin
  } catch {
    return true
  }
}

function trimTrailing(value) {
  let end = value.length

  while (end > 0) {
    const last = value[end - 1]
    const opener = CLOSERS[last]

    if (opener) {
      const slice = value.slice(0, end)
      if (count(slice, opener) >= count(slice, last)) break
    } else if (!TRAILING_PUNCTUATION.includes(last)) {
      break
    }

    end -= 1
  }

  return value.slice(0, end)
}

const count = (value, char) => value.split(char).length - 1
