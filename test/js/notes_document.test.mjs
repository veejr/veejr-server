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
  compareTimeline,
  formatNoteTime,
  noteTimes,
  relativeNoteTime,
  timelineGroupLabel,
  mergeNoteDocuments,
  noteDocument,
  noteSearchClauses,
  normalizeNoteSearch,
  normalizeSelfNoteColor,
  noteAsMessageText,
  selfNoteColorNames,
  selfNoteColors,
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

test("noteTimes uses the note's own timestamps and flags a real edit", () => {
  const times = noteTimes({createdAt: "2026-10-04T10:00:00Z", updatedAt: "2026-10-08T12:30:00Z"})
  assert.equal(times.created.toISOString(), "2026-10-04T10:00:00.000Z")
  assert.equal(times.updated.toISOString(), "2026-10-08T12:30:00.000Z")
  assert.equal(times.edited, true)
})

test("noteTimes does not call a save in the same minute an edit", () => {
  const times = noteTimes({createdAt: "2026-10-04T10:00:00Z", updatedAt: "2026-10-04T10:00:40Z"})
  assert.equal(times.edited, false)
})

test("noteTimes falls back to the server timestamps for notes without their own", () => {
  const times = noteTimes({
    createdAt: "",
    updatedAt: undefined,
    serverCreatedAt: "2026-09-01T08:00:00Z",
    serverUpdatedAt: "2026-09-02T09:00:00Z",
  })
  assert.equal(times.created.toISOString(), "2026-09-01T08:00:00.000Z")
  assert.equal(times.updated.toISOString(), "2026-09-02T09:00:00.000Z")
  assert.equal(times.edited, true)
})

test("noteTimes survives garbage and missing dates", () => {
  assert.deepEqual(noteTimes({createdAt: "nope", updatedAt: "also nope"}), {created: null, updated: null, edited: false})
  assert.deepEqual(noteTimes(), {created: null, updated: null, edited: false})
  const onlyUpdated = noteTimes({updatedAt: "2026-10-08T12:30:00Z"})
  assert.equal(onlyUpdated.created.toISOString(), onlyUpdated.updated.toISOString())
  assert.equal(onlyUpdated.edited, false)
})

test("formatNoteTime and timelineGroupLabel honour the time zone", () => {
  const date = new Date("2026-10-31T23:30:00Z")
  assert.equal(timelineGroupLabel(date, {locale: "en-US", timeZone: "UTC"}), "October 2026")
  assert.equal(timelineGroupLabel(date, {locale: "en-US", timeZone: "Pacific/Auckland"}), "November 2026")
  assert.match(formatNoteTime(date, {locale: "en-US", timeZone: "UTC"}), /Oct 31, 2026/)
  assert.equal(formatNoteTime(null), "")
  assert.equal(timelineGroupLabel(null), "Undated")
})

test("relativeNoteTime picks a sensible unit", () => {
  const now = new Date("2026-10-08T12:00:00Z")
  const ago = (ms) => new Date(now.getTime() - ms)
  assert.equal(relativeNoteTime(ago(10_000), now, {locale: "en"}), "just now")
  assert.equal(relativeNoteTime(ago(5 * 60_000), now, {locale: "en"}), "5 minutes ago")
  assert.equal(relativeNoteTime(ago(3 * 3_600_000), now, {locale: "en"}), "3 hours ago")
  assert.equal(relativeNoteTime(ago(4 * 86_400_000), now, {locale: "en"}), "4 days ago")
  assert.equal(relativeNoteTime(ago(90 * 86_400_000), now, {locale: "en"}), "3 months ago")
  assert.equal(relativeNoteTime(ago(800 * 86_400_000), now, {locale: "en"}), "2 years ago")
  assert.equal(relativeNoteTime(null, now), "")
})

test("compareTimeline orders newest first, ignores pinning, and puts undated last", () => {
  const notes = [
    {title: "old", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-02T00:00:00Z", pinned: true},
    {title: "new", createdAt: "2026-05-01T00:00:00Z", updatedAt: "2026-06-01T00:00:00Z"},
    {title: "undated", createdAt: "", updatedAt: ""},
    {title: "mid", createdAt: "2026-03-01T00:00:00Z", updatedAt: "2026-09-01T00:00:00Z"},
  ]
  assert.deepEqual([...notes].sort((a, b) => compareTimeline(a, b, "updated")).map((n) => n.title),
    ["mid", "new", "old", "undated"])
  assert.deepEqual([...notes].sort((a, b) => compareTimeline(a, b, "created")).map((n) => n.title),
    ["new", "mid", "old", "undated"])
})

test("every stored note colour has a sticky-pad name, and nothing else does", () => {
  const named = selfNoteColorNames.map(([value]) => value)

  assert.deepEqual([...named].sort(), [...selfNoteColors].sort())
  assert.equal(new Set(named).size, named.length)
  assert.ok(selfNoteColorNames.every(([, name]) => name.length > 0))
})

test("a note becomes a message: title, body, then the checklist", () => {
  assert.equal(
    noteAsMessageText({
      title: "Shopping",
      body: "For the weekend",
      checklist: [
        {text: "Milk", checked: true},
        {text: "Eggs", checked: false},
      ],
    }),
    "Shopping\n\nFor the weekend\n\n☑ Milk\n☐ Eggs",
  )
})

test("a note with only some parts has no stray blank lines", () => {
  assert.equal(noteAsMessageText({body: "Just text"}), "Just text")
  assert.equal(noteAsMessageText({title: "Only a title"}), "Only a title")
  assert.equal(noteAsMessageText({checklist: [{text: "One", checked: false}]}), "☐ One")
  assert.equal(noteAsMessageText({}), "")
  assert.equal(noteAsMessageText(), "")
})

test("blank checklist rows are left out", () => {
  assert.equal(
    noteAsMessageText({body: "x", checklist: [{text: "  ", checked: false}, {text: "Real", checked: true}, null]}),
    "x\n\n☑ Real",
  )
})
