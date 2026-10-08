// Message cards: what a decrypted `card` is allowed to be.
//
// A card comes from another person's device, so the part worth testing is that
// nothing but registry ids ever gets through to the page.

import {test} from "node:test"
import assert from "node:assert/strict"

import {
  CARD_BACKGROUNDS,
  CARD_TEMPLATES,
  cardTemplate,
  isDecorated,
  normalizeCard,
} from "../../assets/js/veejr/cards.js"

test("the starter templates are birthday, congratulations and get well", () => {
  assert.deepEqual(
    CARD_TEMPLATES.map((template) => template.id),
    ["birthday", "congrats", "getwell"],
  )
})

test("every template has a heading and a background that exists", () => {
  const backgrounds = new Set(CARD_BACKGROUNDS.map((background) => background.id))

  for (const template of CARD_TEMPLATES) {
    assert.ok(template.heading.length > 0, template.id)
    assert.ok(backgrounds.has(template.background), `${template.id} -> ${template.background}`)
  }
})

test("ids are unique", () => {
  const templates = CARD_TEMPLATES.map((template) => template.id)
  const backgrounds = CARD_BACKGROUNDS.map((background) => background.id)

  assert.equal(new Set(templates).size, templates.length)
  assert.equal(new Set(backgrounds).size, backgrounds.length)
})

test("a template with no background wears its own", () => {
  assert.deepEqual(normalizeCard({template: "birthday"}), {template: "birthday", background: "confetti"})
  assert.deepEqual(normalizeCard({template: "getwell"}), {template: "getwell", background: "floral"})
})

test("the sender's background wins over the template's", () => {
  assert.deepEqual(normalizeCard({template: "birthday", background: "stars"}), {
    template: "birthday",
    background: "stars",
  })
})

test("a background alone is a card with no template", () => {
  assert.deepEqual(normalizeCard({background: "hearts"}), {template: null, background: "hearts"})
})

test("anything that is not a known id is ignored", () => {
  assert.equal(normalizeCard({template: "nope", background: "nope"}), null)
  assert.deepEqual(normalizeCard({template: "nope", background: "sky"}), {template: null, background: "sky"})
  assert.deepEqual(normalizeCard({template: "congrats", background: "javascript:alert(1)"}), {
    template: "congrats",
    background: "stars",
  })
})

test("a card that is not an object is no card", () => {
  for (const raw of [null, undefined, "birthday", 7, true, [], ["birthday"]]) {
    assert.equal(normalizeCard(raw), null, JSON.stringify(raw))
  }
})

test("extra fields never survive", () => {
  const card = normalizeCard({template: "birthday", background: "confetti", html: "<b>x</b>", url: "https://x"})

  assert.deepEqual(Object.keys(card).sort(), ["background", "template"])
})

test("prototype keys are not templates", () => {
  assert.equal(cardTemplate("constructor"), null)
  assert.equal(cardTemplate("__proto__"), null)
  assert.equal(normalizeCard({template: "constructor", background: "toString"}), null)
})

test("plain paper with no template does not count as decorated", () => {
  assert.equal(isDecorated(normalizeCard({background: "plain"})), false)
  assert.equal(isDecorated(normalizeCard({background: "hearts"})), true)
  assert.equal(isDecorated(normalizeCard({template: "birthday", background: "plain"})), true)
  assert.equal(isDecorated(null), false)
})
