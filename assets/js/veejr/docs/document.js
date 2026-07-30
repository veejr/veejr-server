// The `self_doc` encrypted payload: spreadsheets and pages.
//
// One envelope kind carries both, with `doc_kind` inside the *encrypted*
// payload, so the server never learns which sort of document a card is and a
// third format later costs no protocol change.
//
// The page model is the reason this file exists. Notes are plain text and the
// board never puts decrypted content through `innerHTML`; a word processor
// must not quietly become the exception. So a page is stored as blocks of
// plain text plus mark ranges — never a markup string — and `runsFor()` turns
// that into spans the editor creates with DOM APIs. There is no HTML to
// sanitize because none is ever produced.
//
// No DOM access here; see test/js/document.test.mjs.

export const DOC_KINDS = new Set(["sheet", "page"])

export const BLOCK_TYPES = new Set([
  "paragraph",
  "heading1",
  "heading2",
  "heading3",
  "quote",
  "code",
  "bullet",
  "number",
  "divider",
])

export const MARK_TYPES = new Set(["b", "i", "u", "s", "code"])

export const LIMITS = {
  title: 500,
  labels: 10,
  labelLength: 64,
  // A sheet larger than this stops being something you edit in a browser tab,
  // and the payload has to stay inside the envelope ciphertext ceiling.
  sheetCells: 20000,
  sheetRows: 5000,
  sheetColumns: 200,
  cellLength: 10000,
  blocks: 2000,
  blockLength: 20000,
  pageLength: 200000,
}

export const DEFAULT_SHEET_ROWS = 40
export const DEFAULT_SHEET_COLUMNS = 12

const DOC_COLORS = new Set(["default", "sand", "rose", "violet", "blue", "mint"])

function uuid() {
  return crypto.randomUUID()
}

function clampText(value, max) {
  return [...String(value ?? "")].slice(0, max).join("")
}

function isoOrNull(value) {
  if (!value) return null
  const parsed = new Date(value)
  return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString()
}

export function normalizeDocColor(value) {
  return DOC_COLORS.has(value) ? value : "default"
}

// ---------------------------------------------------------------------------
// Common envelope-payload shape
// ---------------------------------------------------------------------------

/**
 * Normalizes any `self_doc` payload, filling defaults and clamping anything a
 * corrupted or hostile payload could oversize. Always returns a usable
 * document — a board that throws on one bad card is a board you cannot open.
 */
export function docDocument(payload = {}) {
  const now = new Date().toISOString()
  const docKind = DOC_KINDS.has(payload.doc_kind) ? payload.doc_kind : "page"

  const base = {
    v: 1,
    kind: "self_doc",
    doc_kind: docKind,
    doc_id: payload.doc_id || uuid(),
    title: clampText(payload.title, LIMITS.title),
    labels: normalizeLabels(payload.labels),
    color: normalizeDocColor(payload.color),
    pinned: !!payload.pinned,
    archived_at: isoOrNull(payload.archived_at),
    trashed_at: isoOrNull(payload.trashed_at),
    created_at: isoOrNull(payload.created_at) || now,
    updated_at: now,
    attachments: Array.isArray(payload.attachments) ? payload.attachments : [],
  }

  return docKind === "sheet"
    ? {...base, sheet: normalizeSheet(payload.sheet)}
    : {...base, page: normalizePage(payload.page)}
}

export function normalizeLabels(labels) {
  if (!Array.isArray(labels)) return []
  const seen = new Set()
  const out = []

  for (const label of labels) {
    const text = String(label ?? "").trim().replace(/\s+/g, " ")
    if (!text) continue
    const key = text.toLocaleLowerCase()
    if (seen.has(key)) continue
    seen.add(key)
    out.push(clampText(text, LIMITS.labelLength))
    if (out.length >= LIMITS.labels) break
  }

  return out
}

// The searchable text of a document, for the board's local filter. Kept here
// so search never has to reach into either format's internals.
export function docSearchText(doc) {
  const parts = [doc.title, ...(doc.labels || [])]

  if (doc.doc_kind === "sheet") {
    for (const cell of Object.values(doc.sheet?.cells || {})) {
      parts.push(cell?.f ?? cell?.v ?? "")
    }
  } else {
    for (const block of doc.page?.blocks || []) parts.push(block.text)
  }

  return parts.join(" ")
}

// ---------------------------------------------------------------------------
// Spreadsheets
// ---------------------------------------------------------------------------

const REF_KEY = /^[A-Z]+[1-9][0-9]*$/

export function normalizeSheet(sheet = {}) {
  const cells = {}
  let count = 0

  for (const [key, cell] of Object.entries(sheet?.cells || {})) {
    const ref = String(key).toUpperCase().replace(/\$/g, "")
    if (!REF_KEY.test(ref)) continue
    if (count >= LIMITS.sheetCells) break

    if (cell && typeof cell === "object" && typeof cell.f === "string") {
      const formula = clampText(cell.f, LIMITS.cellLength)
      if (!formula.trim()) continue
      cells[ref] = {f: formula.startsWith("=") ? formula : `=${formula}`}
      count++
    } else {
      const raw = cell && typeof cell === "object" ? cell.v : cell
      if (raw === null || raw === undefined || raw === "") continue
      cells[ref] = {v: typeof raw === "number" ? raw : clampText(raw, LIMITS.cellLength)}
      count++
    }
  }

  return {
    rows: clampCount(sheet?.rows, DEFAULT_SHEET_ROWS, LIMITS.sheetRows),
    columns: clampCount(sheet?.columns, DEFAULT_SHEET_COLUMNS, LIMITS.sheetColumns),
    widths: normalizeWidths(sheet?.widths),
    frozen: !!sheet?.frozen,
    cells,
  }
}

function clampCount(value, fallback, max) {
  const count = Number.parseInt(value, 10)
  if (!Number.isFinite(count) || count < 1) return fallback
  return Math.min(count, max)
}

function normalizeWidths(widths) {
  if (!widths || typeof widths !== "object") return {}
  const out = {}
  for (const [column, width] of Object.entries(widths)) {
    const size = Number.parseInt(width, 10)
    if (/^[A-Z]+$/.test(column) && Number.isFinite(size)) {
      out[column] = Math.min(Math.max(size, 48), 640)
    }
  }
  return out
}

// The rectangle a sheet actually occupies, so a document with one cell at Z90
// still opens showing it, and an empty one opens at a comfortable default.
export function sheetBounds(sheet) {
  let maxRow = 0
  let maxColumn = 0

  for (const ref of Object.keys(sheet?.cells || {})) {
    const match = /^([A-Z]+)([0-9]+)$/.exec(ref)
    if (!match) continue
    maxRow = Math.max(maxRow, Number(match[2]))
    let index = 0
    for (const character of match[1]) index = index * 26 + (character.charCodeAt(0) - 64)
    maxColumn = Math.max(maxColumn, index)
  }

  return {
    rows: Math.min(Math.max(sheet?.rows || DEFAULT_SHEET_ROWS, maxRow + 1), LIMITS.sheetRows),
    columns: Math.min(
      Math.max(sheet?.columns || DEFAULT_SHEET_COLUMNS, maxColumn + 1),
      LIMITS.sheetColumns
    ),
  }
}

// ---------------------------------------------------------------------------
// CSV
// ---------------------------------------------------------------------------

export function cellsToCsv(sheet, values = null) {
  const {rows, columns} = sheetBounds(sheet)
  const lines = []

  for (let row = 0; row < rows; row++) {
    const line = []
    let lastFilled = -1

    for (let column = 0; column < columns; column++) {
      const ref = `${indexToLetters(column)}${row + 1}`
      const cell = sheet.cells?.[ref]
      // Export what the sheet *shows*: a reader of the CSV wants the computed
      // number, not "=SUM(A1:A9)".
      const shown = values?.has(ref) ? values.get(ref) : cell?.v
      const text = shown === null || shown === undefined ? "" : String(shown?.err ?? shown)
      if (text !== "") lastFilled = column
      line.push(text)
    }

    lines.push(line.slice(0, lastFilled + 1).map(escapeCsv).join(","))
  }

  // Trailing empty rows are noise in an exported file.
  while (lines.length && lines[lines.length - 1] === "") lines.pop()
  return lines.join("\r\n")
}

function escapeCsv(value) {
  return /[",\r\n]/.test(value) ? `"${value.replace(/"/g, '""')}"` : value
}

export function parseCsv(text) {
  const rows = []
  let row = []
  let field = ""
  let quoted = false
  const source = String(text ?? "").replace(/\r\n?/g, "\n")

  for (let index = 0; index < source.length; index++) {
    const character = source[index]

    if (quoted) {
      if (character === '"' && source[index + 1] === '"') {
        field += '"'
        index++
      } else if (character === '"') {
        quoted = false
      } else {
        field += character
      }
      continue
    }

    if (character === '"') {
      quoted = true
    } else if (character === ",") {
      row.push(field)
      field = ""
    } else if (character === "\n") {
      row.push(field)
      rows.push(row)
      row = []
      field = ""
    } else {
      field += character
    }
  }

  if (field !== "" || row.length) {
    row.push(field)
    rows.push(row)
  }

  return rows
}

export function csvToCells(text, {origin = "A1"} = {}) {
  const rows = parseCsv(text)
  const cells = {}
  const match = /^([A-Z]+)([0-9]+)$/.exec(String(origin).toUpperCase())
  const startColumn = match ? lettersToIndex(match[1]) : 0
  const startRow = match ? Number(match[2]) - 1 : 0
  let count = 0

  rows.forEach((row, rowOffset) => {
    row.forEach((value, columnOffset) => {
      if (value === "" || count >= LIMITS.sheetCells) return
      const ref = `${indexToLetters(startColumn + columnOffset)}${startRow + rowOffset + 1}`
      // An imported "=..." is data, not a formula the exporter meant to run.
      cells[ref] = {v: clampText(value, LIMITS.cellLength)}
      count++
    })
  })

  return cells
}

function indexToLetters(index) {
  let letters = ""
  let remaining = index + 1
  while (remaining > 0) {
    const remainder = (remaining - 1) % 26
    letters = String.fromCharCode(65 + remainder) + letters
    remaining = Math.floor((remaining - 1) / 26)
  }
  return letters
}

function lettersToIndex(letters) {
  let index = 0
  for (const character of letters) index = index * 26 + (character.charCodeAt(0) - 64)
  return index - 1
}

// ---------------------------------------------------------------------------
// Pages
// ---------------------------------------------------------------------------

export function makeBlock(type = "paragraph", text = "", marks = []) {
  return {
    id: uuid(),
    type: BLOCK_TYPES.has(type) ? type : "paragraph",
    text: clampText(text, LIMITS.blockLength),
    marks: normalizeMarks(marks, [...String(text ?? "")].length),
  }
}

export function normalizePage(page = {}) {
  const blocks = Array.isArray(page?.blocks) ? page.blocks : []
  const out = []
  let total = 0

  for (const block of blocks) {
    if (out.length >= LIMITS.blocks || total >= LIMITS.pageLength) break
    const text = clampText(block?.text, LIMITS.blockLength)
    total += text.length
    out.push({
      id: typeof block?.id === "string" && block.id ? block.id : uuid(),
      type: BLOCK_TYPES.has(block?.type) ? block.type : "paragraph",
      text,
      marks: normalizeMarks(block?.marks, [...text].length),
    })
  }

  return {blocks: out.length ? out : [makeBlock("paragraph", "")]}
}

/**
 * Cleans a block's mark ranges: drops unknown types and empty or inverted
 * ranges, clamps to the text, then merges touching ranges of the same type so
 * repeated bolding cannot grow the payload without bound.
 */
export function normalizeMarks(marks, textLength) {
  if (!Array.isArray(marks)) return []

  const cleaned = marks
    .map((mark) => ({
      s: Math.max(0, Math.min(Number(mark?.s) || 0, textLength)),
      e: Math.max(0, Math.min(Number(mark?.e) || 0, textLength)),
      m: mark?.m,
    }))
    .filter((mark) => MARK_TYPES.has(mark.m) && mark.e > mark.s)
    .sort((a, b) => a.s - b.s || a.e - b.e || a.m.localeCompare(b.m))

  const merged = []
  for (const mark of cleaned) {
    const previous = merged.find(
      (candidate) => candidate.m === mark.m && candidate.e >= mark.s && candidate.s <= mark.e
    )
    if (previous) {
      previous.s = Math.min(previous.s, mark.s)
      previous.e = Math.max(previous.e, mark.e)
    } else {
      merged.push({...mark})
    }
  }

  return merged.sort((a, b) => a.s - b.s || a.m.localeCompare(b.m))
}

/**
 * Splits a block into the runs an editor renders: `[{text, marks: [...]}]`,
 * each run a maximal span over which the active mark set does not change.
 *
 * This is what replaces "build an HTML string": the caller creates one element
 * per run and sets `textContent`, so decrypted text is never parsed as markup.
 */
export function runsFor(block) {
  const characters = [...String(block?.text ?? "")]
  const marks = normalizeMarks(block?.marks, characters.length)
  if (!characters.length) return []
  if (!marks.length) return [{text: characters.join(""), marks: []}]

  // Every mark boundary is a possible run boundary.
  const boundaries = new Set([0, characters.length])
  for (const mark of marks) {
    boundaries.add(mark.s)
    boundaries.add(mark.e)
  }

  const points = [...boundaries].sort((a, b) => a - b)
  const runs = []

  for (let index = 0; index < points.length - 1; index++) {
    const start = points[index]
    const end = points[index + 1]
    if (end <= start) continue

    const active = marks
      .filter((mark) => mark.s <= start && mark.e >= end)
      .map((mark) => mark.m)
      .sort()

    const text = characters.slice(start, end).join("")
    const previous = runs[runs.length - 1]

    // Merge adjacent runs that ended up with the same mark set.
    if (previous && previous.marks.join(",") === active.join(",")) {
      previous.text += text
    } else {
      runs.push({text, marks: active})
    }
  }

  return runs
}

/**
 * Applies (or removes) a mark over a selection, the way a toolbar button does:
 * if the whole selection already carries the mark, the button turns it off.
 */
export function toggleMark(block, start, end, mark) {
  const length = [...String(block?.text ?? "")].length
  const from = Math.max(0, Math.min(start, length))
  const to = Math.max(0, Math.min(end, length))
  if (to <= from || !MARK_TYPES.has(mark)) return block

  const marks = normalizeMarks(block.marks, length)
  const covered = marks.some(
    (candidate) => candidate.m === mark && candidate.s <= from && candidate.e >= to
  )

  const remaining = []
  for (const candidate of marks) {
    if (candidate.m !== mark) {
      remaining.push(candidate)
      continue
    }
    // Split any overlap out of the existing range.
    if (candidate.e <= from || candidate.s >= to) {
      remaining.push(candidate)
      continue
    }
    if (candidate.s < from) remaining.push({...candidate, e: from})
    if (candidate.e > to) remaining.push({...candidate, s: to})
  }

  if (!covered) remaining.push({s: from, e: to, m: mark})
  return {...block, marks: normalizeMarks(remaining, length)}
}

// Shifts mark ranges to follow an edit at `at` that replaced `removed`
// characters with `added`, so formatting stays attached to its text.
export function shiftMarks(marks, at, removed, added) {
  const delta = added - removed
  const out = []

  for (const mark of marks || []) {
    let {s, e} = mark
    if (e <= at) {
      out.push({...mark})
      continue
    }
    if (s >= at + removed) {
      out.push({...mark, s: s + delta, e: e + delta})
      continue
    }
    // The edit landed inside the mark: keep the surviving part.
    s = s < at ? s : at
    e = Math.max(at, e + delta)
    if (e > s) out.push({...mark, s, e})
  }

  return out
}

// Plain text of a page, for export, print, and the search index.
export function pageToText(page) {
  return (page?.blocks || [])
    .map((block) => {
      switch (block.type) {
        case "heading1": return `# ${block.text}`
        case "heading2": return `## ${block.text}`
        case "heading3": return `### ${block.text}`
        case "quote": return `> ${block.text}`
        case "bullet": return `- ${block.text}`
        case "number": return `1. ${block.text}`
        case "divider": return "---"
        default: return block.text
      }
    })
    .join("\n\n")
}

// Accepts pasted text as blocks, recognizing the few markdown-ish prefixes the
// editor itself writes so a copy-paste round trip keeps its shape.
export function textToPage(text) {
  const blocks = []

  for (const chunk of String(text ?? "").split(/\n{2,}/)) {
    const line = chunk.trim()
    if (!line) continue

    const heading = /^(#{1,3})\s+(.*)$/s.exec(line)
    if (heading) {
      blocks.push(makeBlock(`heading${heading[1].length}`, heading[2]))
      continue
    }
    if (/^>\s+/.test(line)) {
      blocks.push(makeBlock("quote", line.replace(/^>\s+/, "")))
      continue
    }
    if (/^[-*]\s+/.test(line)) {
      for (const item of line.split("\n")) {
        blocks.push(makeBlock("bullet", item.replace(/^[-*]\s+/, "")))
      }
      continue
    }
    if (/^\d+[.)]\s+/.test(line)) {
      for (const item of line.split("\n")) {
        blocks.push(makeBlock("number", item.replace(/^\d+[.)]\s+/, "")))
      }
      continue
    }
    if (/^-{3,}$/.test(line)) {
      blocks.push(makeBlock("divider", ""))
      continue
    }

    blocks.push(makeBlock("paragraph", line))
  }

  return {blocks: blocks.length ? blocks : [makeBlock("paragraph", "")]}
}
