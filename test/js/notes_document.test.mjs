// The note document, offline merge, and search parsing.
//
// This module was split out of the notes board precisely because it is pure
// and testable, and then went untested. Merge in particular decides what
// happens to a note edited on two devices, so a silent regression here loses
// somebody's writing.

import {test} from "node:test"
import assert from "node:assert/strict"

import {
  compareSelfNotes,
  mergeNoteDocuments,
  noteDocument,
  noteSearchClauses,
  normalizeNoteSearch,
  normalizeSelfNoteColor,
} from "../../assets/js/veejr/hooks/notes_document.js"

const sortableNotes = [
  {
    title: "Zulu",
    createdAt: "2026-01-01T00:00:00Z",
    updatedAt: "2026-03-01T00:00:00Z",
    pinned: false,
  },
  {
    title: "alpha",
    createdAt: "2026-02-01T00:00:00Z",
    updatedAt: "2026-02-15T00:00:00Z",
    pinned: false,
  },
  {
    title: "Pinned",
    createdAt: "2025-01-01T00:00:00Z",
    updatedAt: "2025-01-01T00:00:00Z",
    pinned: true,
  },
]

test("self notes default to last edited while keeping pinned notes first", () => {
  assert.deepEqual(
    [...sortableNotes].sort(compareSelfNotes).map((note) => note.title),
    ["Pinned", "Zulu", "alpha"]
  )
})

test("self notes can sort by creation date or title", () => {
  assert.deepEqual(
    [...sortableNotes].sort((left, right) => compareSelfNotes(left, right, "created")).map((note) => note.title),
    ["Pinned", "alpha", "Zulu"]
  )
  assert.deepEqual(
    [...sortableNotes].sort((left, right) => compareSelfNotes(left, right, "title")).map((note) => note.title),
    ["Pinned", "alpha", "Zulu"]
  )
})

test("a new note gets defaults and a fresh id", () => {
  const note = noteDocument()
  assert.equal(note.v, 2)
  assert.equal(note.kind, "self_note")
  assert.ok(note.note_id)
  assert.deepEqual(note.checklist, [])
  assert.equal(note.pinned, false)
  assert.equal(note.archived_at, null)
  assert.notEqual(noteDocument().note_id, note.note_id)
})

test("an existing note keeps its id and creation time but is re-stamped", () => {
  const original = noteDocument({note_id: "abc", created_at: "2026-01-01T00:00:00.000Z"})
  const edited = noteDocument({...original, title: "changed"})

  assert.equal(edited.note_id, "abc")
  assert.equal(edited.created_at, "2026-01-01T00:00:00.000Z")
  assert.ok(edited.updated_at >= original.updated_at)
})

test("unknown colors fall back rather than rendering an unstyled card", () => {
  assert.equal(normalizeSelfNoteColor("mint"), "mint")
  assert.equal(normalizeSelfNoteColor("chartreuse"), "default")
  assert.equal(normalizeSelfNoteColor(undefined), "default")
})

test("merge keeps both bodies when they diverge", () => {
  const remote = noteDocument({note_id: "n", body: "from phone"})
  const local = noteDocument({note_id: "n", body: "from laptop"})
  const merged = mergeNoteDocuments(local, remote)

  assert.match(merged.body, /from phone/)
  assert.match(merged.body, /from laptop/)
  assert.match(merged.body, /Merged from this device/)
})

test("merge does not duplicate an unchanged body", () => {
  const remote = noteDocument({note_id: "n", body: "same"})
  const local = noteDocument({note_id: "n", body: "same"})
  assert.equal(mergeNoteDocuments(local, remote).body, "same")

  // One side empty keeps the other side's text exactly once.
  const empty = noteDocument({note_id: "n", body: ""})
  assert.equal(mergeNoteDocuments(empty, remote).body, "same")
  assert.equal(mergeNoteDocuments(remote, empty).body, "same")
})

test("merge de-duplicates checklist items case-insensitively", () => {
  const remote = noteDocument({note_id: "n", checklist: [{id: "1", text: "Milk", checked: false}]})
  const local = noteDocument({
    note_id: "n",
    checklist: [
      {id: "2", text: " milk ", checked: true},
      {id: "3", text: "Bread", checked: false},
    ],
  })

  const merged = mergeNoteDocuments(local, remote)
  assert.deepEqual(
    merged.checklist.map((item) => item.text),
    ["Milk", "Bread"]
  )
})

test("merge unions labels and attachments without exceeding the label cap", () => {
  const remote = noteDocument({
    note_id: "n",
    labels: ["a", "b"],
    attachments: [{id: "x"}],
  })
  const local = noteDocument({
    note_id: "n",
    labels: ["b", "c", ...Array.from({length: 12}, (_, index) => `extra${index}`)],
    attachments: [{id: "x"}, {id: "y"}],
  })

  const merged = mergeNoteDocuments(local, remote)
  assert.equal(merged.labels.length, 10)
  assert.ok(merged.labels.includes("a") && merged.labels.includes("c"))
  assert.deepEqual(
    merged.attachments.map((attachment) => attachment.id),
    ["x", "y"]
  )
})

test("search normalization ignores case, accents, and spacing", () => {
  assert.equal(normalizeNoteSearch("  Café   AU  Lait "), "cafe au lait")
  assert.equal(normalizeNoteSearch(null), "")
  assert.equal(normalizeNoteSearch("ÉCOLE"), "ecole")
})

test("search splits bare words into separate required clauses", () => {
  assert.deepEqual(noteSearchClauses("milk bread"), ["milk", "bread"])
  assert.deepEqual(noteSearchClauses("   "), [])
})

test("quoted search terms stay one phrase, including curly quotes", () => {
  assert.deepEqual(noteSearchClauses('"shopping list" milk'), ["shopping list", "milk"])
  assert.deepEqual(noteSearchClauses("“shopping list”"), ["shopping list"])
})

test("an unclosed quote treats the remainder as one phrase", () => {
  // Typed mid-search, this must not throw or silently drop the text.
  assert.deepEqual(noteSearchClauses('"shopping list'), ["shopping list"])
})
