// The `self_doc` payload: normalization, the page block/mark model, and CSV.
//
// `runsFor` carries the most weight here — it is what lets the editor render
// formatted text without ever handing decrypted content to an HTML parser.

import {test} from "node:test"
import assert from "node:assert/strict"

import {
  LIMITS,
  cellsToCsv,
  csvToCells,
  docDocument,
  documentCopy,
  docSearchText,
  makeBlock,
  normalizeLabels,
  normalizeMarks,
  normalizeSheet,
  pageToText,
  parseCsv,
  runsFor,
  sheetBounds,
  shiftMarks,
  textToPage,
  toggleMark,
} from "../../assets/js/veejr/docs/document.js"

test("an unknown doc_kind falls back to a page rather than an empty card", () => {
  const doc = docDocument({doc_kind: "hologram"})
  assert.equal(doc.doc_kind, "page")
  assert.equal(doc.kind, "self_doc")
  assert.equal(doc.v, 1)
  assert.ok(doc.doc_id)
  assert.equal(doc.page.blocks.length, 1)
})

test("saving a document copy gives it a fresh identity and creation time", () => {
  const source = docDocument({
    doc_kind: "sheet",
    title: "Budget",
    created_at: "2025-01-01T00:00:00.000Z",
    sheet: {cells: {A1: {v: "kept"}}},
  })
  const copy = documentCopy(source)

  assert.equal(copy.title, "Budget (copy)")
  assert.notEqual(copy.doc_id, source.doc_id)
  assert.notEqual(copy.created_at, source.created_at)
  assert.deepEqual(copy.sheet, source.sheet)
})

test("titles and labels are clamped and de-duplicated", () => {
  const doc = docDocument({
    doc_kind: "sheet",
    title: "x".repeat(LIMITS.title + 50),
    labels: ["Home", "home ", " HOME", "", "Work", ...Array(20).fill("Spam")],
  })

  assert.equal([...doc.title].length, LIMITS.title)
  assert.deepEqual(doc.labels, ["Home", "Work", "Spam"])
  assert.deepEqual(normalizeLabels("not an array"), [])
})

test("sheet cells normalize refs and reject junk keys", () => {
  const sheet = normalizeSheet({
    cells: {
      $b$2: {v: "kept"},
      a1: {v: 3},
      "not a ref": {v: "dropped"},
      B0: {v: "dropped"},
      C3: {f: "SUM(A1:A2)"},
      D4: {v: ""},
    },
  })

  assert.deepEqual(Object.keys(sheet.cells).sort(), ["A1", "B2", "C3"])
  assert.equal(sheet.cells.B2.v, "kept")
  // A formula is stored with its leading "=" whether or not it was typed.
  assert.equal(sheet.cells.C3.f, "=SUM(A1:A2)")
})

test("sheet bounds reach past the furthest used cell so there is room to type", () => {
  const sheet = normalizeSheet({rows: 10, columns: 4, cells: {Z90: {v: 1}}})
  const bounds = sheetBounds(sheet)
  assert.equal(bounds.rows, 91)
  assert.equal(bounds.columns, 27)

  // An empty sheet still opens at a comfortable working size.
  const empty = sheetBounds(normalizeSheet({}))
  assert.ok(empty.rows >= 20 && empty.columns >= 8)
})

test("CSV round-trips quotes, commas, and newlines", () => {
  const source = 'a,"b,c"\r\n"say ""hi""","two\nlines"'
  const rows = parseCsv(source)
  assert.deepEqual(rows, [
    ["a", "b,c"],
    ['say "hi"', "two\nlines"],
  ])

  const cells = csvToCells(source)
  assert.equal(cells.A1.v, "a")
  assert.equal(cells.B1.v, "b,c")
  assert.equal(cells.A2.v, 'say "hi"')

  const sheet = normalizeSheet({cells})
  const exported = cellsToCsv(sheet)
  assert.deepEqual(parseCsv(exported), rows)
})

test("CSV import treats a leading = as text, not a formula", () => {
  const cells = csvToCells("=1+1")
  assert.equal(cells.A1.v, "=1+1")
  assert.equal(cells.A1.f, undefined)
})

test("CSV export writes computed values, not formula source", () => {
  const sheet = normalizeSheet({cells: {A1: {v: 2}, B1: {f: "=A1*3"}}})
  const values = new Map([
    ["A1", 2],
    ["B1", 6],
  ])
  assert.equal(cellsToCsv(sheet, values), "2,6")
})

test("CSV import can be placed at an origin other than A1", () => {
  const cells = csvToCells("x,y", {origin: "C5"})
  assert.equal(cells.C5.v, "x")
  assert.equal(cells.D5.v, "y")
})

test("marks are clamped, de-inverted, and merged", () => {
  const marks = normalizeMarks(
    [
      {s: 0, e: 4, m: "b"},
      {s: 3, e: 8, m: "b"},
      {s: 5, e: 2, m: "i"},
      {s: 0, e: 3, m: "blink"},
      {s: 90, e: 200, m: "b"},
    ],
    10
  )

  // Two overlapping bolds become one; the inverted range, the unknown mark
  // type, and the range entirely past the end of the text are all dropped.
  assert.deepEqual(marks, [{s: 0, e: 8, m: "b"}])
})

test("runsFor splits text at every mark boundary", () => {
  const block = makeBlock("paragraph", "hello brave world")
  block.marks = normalizeMarks([{s: 6, e: 11, m: "b"}], 17)

  assert.deepEqual(runsFor(block), [
    {text: "hello ", marks: []},
    {text: "brave", marks: ["b"]},
    {text: " world", marks: []},
  ])
})

test("runsFor reports overlapping marks as one combined run", () => {
  const block = makeBlock("paragraph", "abcdef")
  block.marks = normalizeMarks(
    [
      {s: 0, e: 4, m: "b"},
      {s: 2, e: 6, m: "i"},
    ],
    6
  )

  assert.deepEqual(runsFor(block), [
    {text: "ab", marks: ["b"]},
    {text: "cd", marks: ["b", "i"]},
    {text: "ef", marks: ["i"]},
  ])
})

test("runsFor never produces markup, only text", () => {
  const block = makeBlock("paragraph", '<script>alert("x")</script> & more')
  const runs = runsFor(block)
  // The whole thing is one plain run: no parsing, no escaping, nothing to
  // execute. The editor sets this via textContent.
  assert.deepEqual(runs, [{text: '<script>alert("x")</script> & more', marks: []}])
})

test("toggleMark applies, splits, and removes", () => {
  let block = makeBlock("paragraph", "0123456789")

  block = toggleMark(block, 2, 6, "b")
  assert.deepEqual(block.marks, [{s: 2, e: 6, m: "b"}])

  // Re-toggling a fully covered selection removes it.
  block = toggleMark(block, 2, 6, "b")
  assert.deepEqual(block.marks, [])

  // Removing a middle slice splits the range in two.
  block = toggleMark(block, 0, 10, "b")
  block = toggleMark(block, 4, 6, "b")
  assert.deepEqual(block.marks, [
    {s: 0, e: 4, m: "b"},
    {s: 6, e: 10, m: "b"},
  ])

  // A zero-width or unknown mark changes nothing.
  assert.equal(toggleMark(block, 3, 3, "b"), block)
  assert.equal(toggleMark(block, 0, 4, "blink"), block)
})

test("shiftMarks keeps formatting attached across edits", () => {
  const marks = [{s: 5, e: 10, m: "b"}]

  // Typing before the mark pushes it right.
  assert.deepEqual(shiftMarks(marks, 0, 0, 3), [{s: 8, e: 13, m: "b"}])

  // Typing after it leaves it alone.
  assert.deepEqual(shiftMarks(marks, 12, 0, 3), [{s: 5, e: 10, m: "b"}])

  // Deleting inside it shrinks it.
  assert.deepEqual(shiftMarks(marks, 6, 2, 0), [{s: 5, e: 8, m: "b"}])

  // Deleting all of it drops it.
  assert.deepEqual(shiftMarks(marks, 0, 20, 0), [])
})

test("pages round-trip through text with their block types", () => {
  const page = textToPage("# Title\n\nA paragraph.\n\n- one\n- two\n\n> quoted")
  assert.deepEqual(
    page.blocks.map((block) => block.type),
    ["heading1", "paragraph", "bullet", "bullet", "quote"]
  )
  assert.equal(page.blocks[0].text, "Title")

  const text = pageToText(page)
  assert.match(text, /^# Title/)
  assert.deepEqual(
    textToPage(text).blocks.map((block) => block.type),
    ["heading1", "paragraph", "bullet", "bullet", "quote"]
  )
})

test("a page always has at least one block to type into", () => {
  assert.equal(textToPage("").blocks.length, 1)
  assert.equal(docDocument({doc_kind: "page", page: {blocks: []}}).page.blocks.length, 1)
})

test("search text covers titles, labels, cells, and blocks", () => {
  const sheetDoc = docDocument({
    doc_kind: "sheet",
    title: "Budget",
    labels: ["Home"],
    sheet: {cells: {A1: {v: "Rent"}, B1: {f: "=SUM(B2:B9)"}}},
  })
  const text = docSearchText(sheetDoc)
  assert.ok(text.includes("Budget") && text.includes("Home") && text.includes("Rent"))

  const pageDoc = docDocument({doc_kind: "page", page: {blocks: [makeBlock("paragraph", "needle")]}})
  assert.ok(docSearchText(pageDoc).includes("needle"))
})

test("oversized documents are truncated rather than rejected", () => {
  const blocks = Array.from({length: LIMITS.blocks + 50}, () => makeBlock("paragraph", "x"))
  assert.equal(docDocument({doc_kind: "page", page: {blocks}}).page.blocks.length, LIMITS.blocks)

  const cells = {}
  for (let row = 1; row <= LIMITS.sheetCells + 100; row++) cells[`A${row}`] = {v: row}
  const sheet = normalizeSheet({cells})
  assert.equal(Object.keys(sheet.cells).length, LIMITS.sheetCells)
})
