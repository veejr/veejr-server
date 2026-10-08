// Message cards: a template and/or background a message is shown on.
//
// A card travels inside the encrypted payload, as the optional `card` field of
// an ordinary `message`:
//
//   {"v": 1, "kind": "message", "text": "...", "card": {"template": "birthday", "background": "confetti"}}
//
// so the server never learns that a message is a card, or which. The payload
// carries only ids. What each id looks like lives here and in the stylesheet,
// which means a card can never smuggle markup, a URL or a style into the
// recipient's page: an id that is not in the registry is simply ignored, and
// the message shows as plain text. A client that has never heard of cards
// ignores the field and shows the same plain text.
//
// This module is shared by everything that shows a card — the received
// message, the composer's preview, the note-to-message dialog — so they cannot
// drift apart.

import {appendLinkedText} from "./link_text.js"

// `heading` is what the card says above the message. `background` is what it
// sits on unless the sender chose otherwise.
export const CARD_TEMPLATES = [
  {id: "birthday", label: "Birthday", heading: "Happy Birthday!", ornament: "🎂 🎈 🎁", background: "confetti"},
  {id: "congrats", label: "Congratulations", heading: "Congratulations!", ornament: "🎉 🏆 ✨", background: "stars"},
  {id: "getwell", label: "Get well soon", heading: "Get well soon", ornament: "💐 🌼 ☀️", background: "floral"},
]

export const CARD_BACKGROUNDS = [
  {id: "plain", label: "Plain"},
  {id: "confetti", label: "Confetti"},
  {id: "balloons", label: "Balloons"},
  {id: "stars", label: "Stars"},
  {id: "hearts", label: "Hearts"},
  {id: "floral", label: "Floral"},
  {id: "sky", label: "Sky"},
]

const TEMPLATES = new Map(CARD_TEMPLATES.map((template) => [template.id, template]))
const BACKGROUNDS = new Set(CARD_BACKGROUNDS.map((background) => background.id))

export function cardTemplate(id) {
  return TEMPLATES.get(id) || null
}

/**
 * Makes a decrypted `card` safe to use, or returns null.
 *
 * A decrypted payload is data from another person's device. Only ids in the
 * registry survive, and anything else — a wrong type, an unknown id, extra
 * fields — is dropped. A card with neither a known template nor a known
 * background is no card at all.
 */
export function normalizeCard(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null

  const template = TEMPLATES.has(raw.template) ? raw.template : null
  let background = BACKGROUNDS.has(raw.background) ? raw.background : null

  // A template with no background of its own choosing wears its default.
  if (template && !background) background = TEMPLATES.get(template).background
  if (!template && !background) return null

  return {template, background}
}

/** Whether a card changes how the message looks at all. */
export function isDecorated(card) {
  return !!card && (card.template !== null || card.background !== "plain")
}

/**
 * Builds the card for a message: a patterned sheet with the template's heading
 * and ornament over a readable panel holding the text.
 *
 * Everything is created as elements and set with textContent, never parsed
 * from a string; the message text goes through the same link-aware writer the
 * plain bubble uses.
 */
export function renderCard(doc, card, text) {
  const template = cardTemplate(card.template)

  const sheet = doc.createElement("div")
  sheet.className = "msg-card"
  sheet.dataset.cardBg = card.background
  if (template) sheet.dataset.cardTemplate = template.id

  if (template) {
    const ornament = doc.createElement("p")
    ornament.className = "msg-card-ornament"
    ornament.setAttribute("aria-hidden", "true")
    ornament.textContent = template.ornament

    const heading = doc.createElement("h3")
    heading.className = "msg-card-heading"
    heading.textContent = template.heading

    sheet.append(ornament, heading)
  }

  const panel = doc.createElement("div")
  panel.className = "msg-card-panel"

  const body = doc.createElement("p")
  body.className = "msg-card-text"
  appendLinkedText(body, text || "")
  panel.appendChild(body)

  sheet.appendChild(panel)
  return sheet
}

const CHIP =
  "rounded-full border px-3 py-1 text-xs font-medium transition hover:bg-base-200 aria-checked:border-primary aria-checked:bg-primary/10 aria-checked:text-primary"

/**
 * The control for choosing a card: template chips, background swatches and a
 * live preview, so the sender sees the card before it goes.
 *
 * Returns `{el, value, setText, reset}`. `value()` is the card to put in the
 * payload, or null when nothing is chosen. `onChange` fires after any change.
 */
export function createCardPicker(doc, {onChange = () => {}, sampleText = "Your message appears here."} = {}) {
  let template = null
  let background = null
  let text = ""

  const root = doc.createElement("div")
  root.className = "space-y-3"

  const group = (label) => {
    const wrapper = doc.createElement("div")
    const title = doc.createElement("p")
    title.className = "mb-1.5 text-xs font-medium uppercase tracking-wide opacity-70"
    title.textContent = label
    const row = doc.createElement("div")
    row.className = "flex flex-wrap gap-2"
    row.setAttribute("role", "radiogroup")
    row.setAttribute("aria-label", label)
    wrapper.append(title, row)
    root.appendChild(wrapper)
    return row
  }

  const templateRow = group("Template")
  const backgroundRow = group("Background")

  const preview = doc.createElement("div")
  preview.dataset.role = "card-preview"
  preview.className = "overflow-hidden rounded-2xl"
  root.appendChild(preview)

  const templateButton = (id, label) => {
    const button = doc.createElement("button")
    button.type = "button"
    button.className = CHIP
    button.dataset.cardTemplateChoice = id || "none"
    button.setAttribute("role", "radio")
    button.textContent = label
    button.addEventListener("click", () => {
      template = id
      // A template brings its own background, which the sender can then change.
      background = id ? TEMPLATES.get(id).background : null
      refresh()
    })
    templateRow.appendChild(button)
  }

  templateButton(null, "None")
  CARD_TEMPLATES.forEach((entry) => templateButton(entry.id, entry.label))

  CARD_BACKGROUNDS.forEach((entry) => {
    const button = doc.createElement("button")
    button.type = "button"
    button.className =
      "msg-card-swatch size-9 rounded-xl border border-base-300 transition aria-checked:ring-2 aria-checked:ring-primary"
    button.dataset.cardBg = entry.id
    button.dataset.cardBackgroundChoice = entry.id
    button.title = entry.label
    button.setAttribute("role", "radio")
    button.setAttribute("aria-label", `${entry.label} background`)
    button.addEventListener("click", () => {
      background = entry.id
      refresh()
    })
    backgroundRow.appendChild(button)
  })

  const current = () => normalizeCard({template, background})

  function refresh() {
    const card = current()

    templateRow.querySelectorAll("button").forEach((button) => {
      const id = button.dataset.cardTemplateChoice
      button.setAttribute("aria-checked", String((template || "none") === id))
    })
    backgroundRow.querySelectorAll("button").forEach((button) => {
      button.setAttribute("aria-checked", String(!!card && card.background === button.dataset.cardBackgroundChoice))
    })

    preview.textContent = ""
    if (card) preview.appendChild(renderCard(doc, card, text.trim() || sampleText))
    preview.hidden = !card

    onChange(card)
  }

  refresh()

  return {
    el: root,
    value: current,
    setText(next) {
      text = String(next || "")
      const card = current()
      if (!card) return
      preview.textContent = ""
      preview.appendChild(renderCard(doc, card, text.trim() || sampleText))
    },
    reset() {
      template = null
      background = null
      refresh()
    },
  }
}
