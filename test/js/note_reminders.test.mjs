import {test} from "node:test"
import assert from "node:assert/strict"
import {matchesNoteFilter, openNoteReminderDialog, reminderLabel} from "../../assets/js/veejr/hooks/note_reminders.js"
import {localDateTimeToIso} from "../../assets/js/veejr/schedule_time.js"

const remindAt = "2026-10-09T09:00:00Z"

test("reminders include archived cards but exclude trash and unscheduled cards", () => {
  assert.equal(matchesNoteFilter("reminders", {remindAt}), true)
  assert.equal(matchesNoteFilter("reminders", {remindAt, archived: true}), true)
  assert.equal(matchesNoteFilter("reminders", {remindAt, trashed: true}), false)
  for (const value of [null, "", undefined, "bad date"]) {
    assert.equal(matchesNoteFilter("reminders", {remindAt: value}), false)
  }
})

test("setting a reminder preserves membership in Notes, Archive and Trash", () => {
  assert.equal(matchesNoteFilter("active", {remindAt}), true)
  assert.equal(matchesNoteFilter("active", {remindAt, archived: true}), false)
  assert.equal(matchesNoteFilter("archived", {remindAt, archived: true}), true)
  assert.equal(matchesNoteFilter("archived", {remindAt, archived: true, trashed: true}), false)
  assert.equal(matchesNoteFilter("trashed", {remindAt, trashed: true}), true)
})

test("delivered reminders are distinguished from pending times and cleared reminders", () => {
  assert.equal(reminderLabel(null, null), "Remind me")
  assert.match(reminderLabel(remindAt, "2026-10-09T09:00:01Z"), /\(delivered\)$/)
  assert.doesNotMatch(reminderLabel(remindAt, null), /delivered/)
})

// The dialog's browser boundary; no keys or LiveView connection are needed.
function dialogDocument() {
  const nodes = []
  const doc = {
    createElement(tag) {
      const listeners = {}
      const node = {
        tag, children: [], className: "", attributes: {},
        append(...children) { this.children.push(...children) },
        appendChild(child) { this.append(child) },
        setAttribute(name, value) { this.attributes[name] = value },
        addEventListener(name, handler) { listeners[name] = handler },
        fire(name) { return listeners[name]?.({preventDefault() {}}) },
        querySelectorAll(tag) { return this.children.filter((child) => child.tag === tag) },
        close() { this.open = false },
        remove() { this.removed = true },
        showModal() { this.open = true },
      }
      node.classList = {
        add(value) { node.className += ` ${value}` },
        remove(value) { node.className = node.className.split(" ").filter((part) => part !== value).join(" ") },
        contains(value) { return node.className.split(" ").includes(value) },
      }
      nodes.push(node)
      return node
    },
  }
  doc.body = doc.createElement("body")
  return {doc, find: (predicate) => nodes.find(predicate)}
}

test("the date picker saves local time as UTC and closes on success", async () => {
  const {doc, find} = dialogDocument()
  const saved = []
  const dialog = openNoteReminderDialog({doc, save: async (value) => saved.push(value)})
  const input = find((node) => node.id === "self-note-reminder-time")
  input.value = "2099-10-09T09:30"
  await find((node) => node.tag === "form").fire("submit")
  assert.deepEqual(saved, [localDateTimeToIso(input.value)])
  assert.equal(dialog.removed, true)
})

test("clearing sends null while cancellation leaves the reminder unchanged", async () => {
  const {doc, find} = dialogDocument()
  const saved = []
  const dialog = openNoteReminderDialog({doc, current: remindAt, save: async (value) => saved.push(value)})
  await find((node) => node.textContent === "Clear reminder").fire("click")
  assert.deepEqual(saved, [null])
  assert.equal(dialog.removed, true)
  const second = openNoteReminderDialog({doc, current: remindAt, save: async (value) => saved.push(value)})
  second.fire("cancel")
  assert.deepEqual(saved, [null])
  assert.equal(second.removed, true)
})

test("server errors keep the picker open and allow a retry", async () => {
  const {doc, find} = dialogDocument()
  const dialog = openNoteReminderDialog({doc, save: async () => { throw new Error("Connection lost") }})
  find((node) => node.id === "self-note-reminder-time").value = "2099-10-09T09:30"
  await find((node) => node.tag === "form").fire("submit")
  const error = find((node) => node.attributes.role === "alert")
  assert.equal(error.textContent, "Connection lost")
  assert.equal(error.classList.contains("hidden"), false)
  assert.equal(dialog.open, true)
  assert.equal(find((node) => node.textContent === "Save reminder").disabled, false)
})

test("past dates never reach the server", async () => {
  const {doc, find} = dialogDocument()
  let saves = 0
  openNoteReminderDialog({doc, save: async () => { saves += 1 }})
  find((node) => node.id === "self-note-reminder-time").value = "2000-01-01T09:30"
  await find((node) => node.tag === "form").fire("submit")
  assert.equal(saves, 0)
  assert.match(find((node) => node.attributes.role === "alert").textContent, /future/)
})
