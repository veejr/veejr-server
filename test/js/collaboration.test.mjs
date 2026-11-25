import test from "node:test"
import assert from "node:assert/strict"
import {collaborationState, searchableText} from "../../assets/js/veejr/collaboration.js"

const members = [{key: "alice", handle: "alice@home"}, {key: "bob", handle: "bob@home"}]
const entry = (key, operation) => ({peer_key: key, payload: {collaboration: {v: 1, id: "alice:room", op_id: "create", clock: 0, ...operation}}})
const create = entry("alice", {action: "create", type: "list", title: "Shopping", members})

test("checklist changes converge across delivery orders and reject outsiders", () => {
  const first = entry("alice", {action: "item", item_id: "milk", text: "Milk", checked: false, clock: 1, op_id: "one"})
  const checked = entry("bob", {action: "item", item_id: "milk", text: "Milk", checked: true, clock: 2, op_id: "two"})
  const outsider = entry("eve", {action: "item", item_id: "milk", text: "Stolen", checked: false, clock: 100, op_id: "three"})
  const a = collaborationState([create, first, checked, outsider])[0]
  const b = collaborationState([outsider, checked, first, create])[0]
  assert.deepEqual(a.items.get("milk"), b.items.get("milk"))
  assert.equal(a.items.get("milk").checked, true)
  assert.equal(a.items.get("milk").text, "Milk")
})

test("a forged creator cannot take over another identity's room", () => {
  assert.deepEqual(collaborationState([entry("eve", {...create.payload.collaboration})]), [])
})

test("poll changes replace a member's vote and ignore invalid options", () => {
  const poll = entry("alice", {action: "create", type: "poll", title: "When?", members, choices: ["Monday", "Tuesday"]})
  const vote = (choice, clock) => entry("bob", {action: "vote", choice, clock, op_id: `v${clock}`})
  const room = collaborationState([poll, vote("Monday", 1), vote("Tuesday", 2), vote("Never", 3)])[0]
  assert.equal(room.votes.size, 1)
  assert.equal(room.votes.get("bob").choice, "Tuesday")
})

test("search includes document cells, note checklists, labels and filenames", () => {
  const text = searchableText({title: "Trip", items: [{text: "Hotel"}], labels: ["travel"],
    sheet: {cells: {A1: {v: "Berlin"}}}, page: {blocks: [{text: "Packing"}]}, attachments: [{name: "ticket.pdf"}]})
  for (const term of ["Trip", "Hotel", "travel", "Berlin", "Packing", "ticket.pdf"]) assert.ok(text.includes(term))
})
