// Autolinking decrypted message text.
//
// Two failures matter here and neither is visible in a screenshot: a candidate
// that is not really a link becoming a clickable href, and a federated handle
// (`@alice@example.com`) being mistaken for an email address.

import {test} from "node:test"
import assert from "node:assert/strict"

import {linkHref, splitLinkedText} from "../../assets/js/veejr/link_text.js"

const links = (text) => splitLinkedText(text).filter((segment) => segment.type === "link")
const only = (text) => {
  const found = links(text)
  assert.equal(found.length, 1, `expected exactly one link in ${JSON.stringify(text)}`)
  return found[0]
}

test("text with no link comes back as one plain segment", () => {
  assert.deepEqual(splitLinkedText("just a message"), [{type: "text", text: "just a message"}])
  assert.deepEqual(splitLinkedText(""), [])
  assert.deepEqual(splitLinkedText(null), [])
  assert.deepEqual(splitLinkedText(undefined), [])
})

test("http and https urls are linked to themselves", () => {
  assert.equal(only("see https://example.com/x?y=1#z").href, "https://example.com/x?y=1#z")
  assert.equal(only("http://localhost:4000/messages").href, "http://localhost:4000/messages")
})

test("a schemeless www host is linked over https", () => {
  const link = only("try www.example.com/docs")
  assert.equal(link.text, "www.example.com/docs")
  assert.equal(link.href, "https://www.example.com/docs")
})

test("an email address becomes a mailto", () => {
  assert.equal(only("write to jon@example.com").href, "mailto:jon@example.com")
})

test("a federated handle is not an email address", () => {
  assert.deepEqual(links("ping @alice@veejr.example.com about it"), [])
  assert.deepEqual(links("@alice@veejr.example.com"), [])
})

test("sentence punctuation is left out of the link", () => {
  assert.equal(only("go to https://example.com.").text, "https://example.com")
  assert.equal(only("https://example.com, then wait").text, "https://example.com")
  assert.equal(only("(see https://example.com)").text, "https://example.com")
  assert.equal(only('"https://example.com"').text, "https://example.com")
})

test("parentheses inside a url are kept when they balance", () => {
  const link = only("https://en.wikipedia.org/wiki/Elixir_(programming_language)")
  assert.equal(link.text, "https://en.wikipedia.org/wiki/Elixir_(programming_language)")
})

test("only http, https and mailto survive", () => {
  assert.deepEqual(links("javascript:alert(1)"), [])
  assert.deepEqual(links("data:text/html;base64,PHNjcmlwdD4="), [])
  assert.deepEqual(links("file:///etc/passwd"), [])
  assert.equal(linkHref("javascript:alert(1)"), null)
  assert.equal(linkHref("www."), null)
})

test("a url glued to the end of a word is not a link", () => {
  assert.deepEqual(links("xhttps://example.com"), [])
  assert.deepEqual(links("https://example.com/a?next=https://evil.example").length, 1)
})

test("several links in one message are all found, in order", () => {
  const found = links("first https://a.example then www.b.example and c@d.example last")
  assert.deepEqual(found.map((link) => link.href), [
    "https://a.example/",
    "https://www.b.example/",
    "mailto:c@d.example",
  ])
})

test("the segments reproduce the original text exactly", () => {
  for (const text of [
    "plain",
    "see https://example.com. thanks",
    "a@b.example and https://c.example/d) and @e@f.example",
    "https://example.com/wiki/A_(b) trailing",
    "multi\nline https://example.com\nmore",
  ]) {
    assert.equal(splitLinkedText(text).map((segment) => segment.text).join(""), text)
  }
})
