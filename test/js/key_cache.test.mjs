import assert from "node:assert/strict"
import test from "node:test"
import {cacheSecretKey, getSecretKey, forgetSecretKey, getUnlockMinutes, setUnlockMinutes} from "../../assets/js/veejr/key_cache.js"
import {KeyRemember, KeySession} from "../../assets/js/veejr/hooks/key_remember.js"

class Storage {
  values = new Map()
  getItem(key) { return this.values.get(key) ?? null }
  setItem(key, value) { this.values.set(key, String(value)) }
  removeItem(key) { this.values.delete(key) }
}
const secret = new Uint8Array(32).fill(42)

test.beforeEach(() => {
  globalThis.localStorage = new Storage()
  globalThis.sessionStorage = new Storage()
})

test("default unlock survives navigation but not a new tab", () => {
  assert.equal(getUnlockMinutes("a"), 0)
  cacheSecretKey("a", secret)
  assert.deepEqual(getSecretKey("a"), secret)
  assert.equal(localStorage.getItem("veejr:remembered-sk:a"), null)
  globalThis.sessionStorage = new Storage()
  assert.equal(getSecretKey("a"), null)
})

test("timed unlock survives a browser restart without extending its deadline", t => {
  t.mock.method(Date, "now", () => 1_000_000)
  setUnlockMinutes("a", 90)
  cacheSecretKey("a", secret)
  globalThis.sessionStorage = new Storage()
  Date.now.mock.mockImplementation(() => 1_000_000 + 90 * 60_000 - 1)
  assert.deepEqual(getSecretKey("a"), secret)
  Date.now.mock.mockImplementation(() => 1_000_000 + 90 * 60_000)
  assert.equal(getSecretKey("a"), null)
  assert.equal(localStorage.getItem("veejr:remembered-sk:a"), null)
})

test("unlock policy and secrets are isolated by account", () => {
  setUnlockMinutes("a", 60)
  cacheSecretKey("a", secret)
  assert.equal(getUnlockMinutes("b"), 0)
  assert.equal(getSecretKey("b"), null)
})

test("manual lock revokes remembered keys but preserves the preference", () => {
  setUnlockMinutes("a", 60)
  cacheSecretKey("a", secret)
  forgetSecretKey("a")
  assert.equal(getSecretKey("a"), null)
  assert.equal(getUnlockMinutes("a"), 60)
})

test("manual lock also revokes session-only copies in another tab", () => {
  cacheSecretKey("a", secret)
  const otherTab = sessionStorage
  globalThis.sessionStorage = new Storage()
  forgetSecretKey("a")
  globalThis.sessionStorage = otherTab
  assert.equal(getSecretKey("a"), null)
})

test("changing policy requires a fresh unlock and removes persistent secrets", () => {
  setUnlockMinutes("a", 60)
  cacheSecretKey("a", secret)
  setUnlockMinutes("a", 0)
  assert.equal(getSecretKey("a"), null)
  assert.equal(localStorage.getItem("veejr:remembered-sk:a"), null)
  cacheSecretKey("a", secret)
  assert.deepEqual(getSecretKey("a"), secret)
})

test("invalid preferences and malformed or obsolete cache entries fail closed", () => {
  for (const minutes of [-1, 0.5, NaN, Infinity, 43201, "60"]) {
    assert.throws(() => setUnlockMinutes("a", minutes))
  }
  for (const value of ["old-base64-secret", "null", "{}", '{"key":"!"}']) {
    sessionStorage.setItem("veejr:sk:a", value)
    assert.equal(getSecretKey("a"), null)
  }
  localStorage.setItem("veejr:unlock-minutes:a", "garbage")
  assert.equal(getUnlockMinutes("a"), 0)
})

test("unavailable browser storage does not bypass locking", () => {
  localStorage.getItem = () => { throw new Error("Storage blocked") }
  localStorage.setItem = () => { throw new Error("Storage blocked") }
  assert.equal(getSecretKey("a"), null)
  assert.throws(() => setUnlockMinutes("a", 60), /Storage blocked/)
})

test("active pages reload on expiration and remove lifecycle listeners on destruction", t => {
  const events = new Map()
  let reloads = 0
  let interval
  globalThis.window = {
    location: {reload() { reloads++ }},
    setInterval(fn) { interval = fn; return 123 },
    clearInterval(id) { assert.equal(id, 123) },
    addEventListener(name, fn) { events.set(name, fn) },
    removeEventListener(name) { events.delete(name) },
    dispatchEvent(event) { assert.equal(event.type, "veejr:keys-locked") },
  }
  globalThis.document = {
    addEventListener(name, fn) { events.set(name, fn) },
    removeEventListener(name) { events.delete(name) },
  }
  t.after(() => { delete globalThis.window; delete globalThis.document })
  t.mock.method(Date, "now", () => 1_000_000)
  setUnlockMinutes("a", 1)
  cacheSecretKey("a", secret)
  const hook = {el: {dataset: {userId: "a"}}}
  KeySession.mounted.call(hook)
  interval()
  assert.equal(reloads, 0)
  Date.now.mock.mockImplementation(() => 1_060_000)
  events.get("visibilitychange")()
  assert.equal(reloads, 1)
  assert.equal(getSecretKey("a"), null)
  KeySession.destroyed.call(hook)
  assert.equal(events.size, 0)
})

test("settings save a custom day duration and sign-out clears the remembered key", t => {
  let submit
  let change
  let logout
  let reloads = 0
  const fields = {
    "[name=unlock_mode]": {addEventListener(_, fn) { change = fn }},
    "[name=unlock_duration]": {},
    "[name=unlock_unit]": {},
    "[role=status]": {},
    "[data-role=duration-fields]": {},
  }
  globalThis.window = {
    location: {reload() { reloads++ }},
    setInterval() { return 1 }, clearInterval() {},
    addEventListener() {}, removeEventListener() {},
  }
  globalThis.document = {
    addEventListener(name, fn) { if (name === "click") logout = fn },
    removeEventListener() {},
  }
  t.after(() => { delete globalThis.window; delete globalThis.document })
  KeyRemember.mounted.call({el: {
    dataset: {userId: "a"},
    querySelector(name) { return fields[name] },
    addEventListener(_, fn) { submit = fn },
  }})
  assert.equal(fields["[name=unlock_duration]"].disabled, true)
  fields["[name=unlock_mode]"].value = "timed"
  change()
  assert.equal(fields["[name=unlock_duration]"].disabled, false)
  fields["[name=unlock_duration]"].value = "2"
  fields["[name=unlock_unit]"].value = "1440"
  submit({preventDefault() {}})
  assert.equal(getUnlockMinutes("a"), 2880)
  assert.equal(reloads, 1)
  cacheSecretKey("a", secret)
  const hook = {el: {dataset: {userId: "a"}}}
  KeySession.mounted.call(hook)
  logout({target: {closest() { return true }}})
  assert.equal(getSecretKey("a"), null)
  KeySession.destroyed.call(hook)
})
