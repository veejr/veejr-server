# Encrypted documents — spreadsheets and pages

**Status:** implemented web baseline (v0.3.62)
**Audience:** Phoenix/LiveView, web client, Android, QA, and security reviewers
**Primary surface:** the **Notes to yourself** board in `/messages`

Documents are encrypted personal spreadsheets and text documents living on the
same board as notes. They reuse the note board's card, search, organization, and
reminder model; what differs is the payload inside the envelope and the editor
that opens it. Read [SELF_NOTES_KEEP_SPEC.md](SELF_NOTES_KEEP_SPEC.md) first for
the board itself.

## 1. One kind for every format

Documents use a single envelope kind, `self_doc`, with the format named by
`doc_kind` **inside the encrypted payload**.

The alternative — `self_sheet`, `self_page`, and a new kind per format — was
rejected because the kind list is a cross-boundary contract. It appears in
`Veejr.Messaging.Envelope.kinds/0`, the `message_kinds` array of the
capabilities API, notification labels, protocol fixtures, and the Android
client. Every new kind is a protocol event; a payload field is not. As a
side-effect the server cannot tell a spreadsheet from a text document, which is
the correct privacy posture and comes for free.

`self_doc` obeys the same owner-only invariants as `self_note`
(`Envelope.self_kinds/0`): exactly one envelope, addressed to the sender, with
no expiry, no display limit, and no schedule. `Messaging.send_batch/4` rolls
back with `:invalid_self_item` otherwise.

## 2. Size

The whole document is one envelope, so it is bounded by the ciphertext ceiling
in `Envelope.changeset/2`: 350,000 base64 characters, roughly 256 KB of
payload. The limits in §4 and §5 sit inside that. A document that outgrows it
belongs in the encrypted blob path used by attachments, which is not implemented
for document bodies — the practical guidance is a few thousand cells or a long
chapter per document.

## 3. Common payload

```json
{
  "v": 1,
  "kind": "self_doc",
  "doc_kind": "sheet" | "page",
  "doc_id": "browser-generated UUID",
  "title": "July budget",
  "labels": ["Home"],
  "color": "default",
  "pinned": false,
  "archived_at": null,
  "trashed_at": null,
  "created_at": "2026-07-30T12:00:00.000Z",
  "updated_at": "2026-07-30T12:05:00.000Z",
  "attachments": [],
  "sheet": { },
  "page": { }
}
```

Exactly one of `sheet` or `page` is present, matching `doc_kind`. Validation is
in `assets/js/veejr/docs/document.js` and is **normalizing, not rejecting**: an
unknown `doc_kind` becomes `page`, oversized fields are clamped, junk cell keys
and mark ranges are dropped. A board that throws on one malformed card is a
board you cannot open.

Limits: title 500 code points; 10 labels of 64; `color` one of `default`,
`sand`, `rose`, `violet`, `blue`, `mint`.

## 4. Spreadsheets

```json
"sheet": {
  "rows": 40,
  "columns": 12,
  "widths": {"B": 180},
  "frozen": false,
  "cells": {
    "A1": {"v": "Rent"},
    "B1": {"v": 1200},
    "B3": {"f": "=SUM(B1:B2)"}
  }
}
```

- A cell is `{"v": literal}` or `{"f": "=formula"}`, never both. Keys are
  normalized A1 references (`$b$2` is stored as `B2`).
- Limits: 20,000 cells, 5,000 rows, 200 columns, 10,000 characters per cell.
- Only the formula *source* is stored. Computed values are derived on load, so a
  document can never disagree with itself about what a formula evaluates to.

### 4.1 The formula engine

`assets/js/veejr/docs/formula.js` is a tokenizer, a precedence-climbing parser,
and an evaluator. It is **an interpreter and must remain one**: the enforced
production Content-Security-Policy pins `script-src` to `'self'` with no
`'unsafe-eval'`, so a formula compiled to JavaScript would not execute in a
browser — and would have handed a spreadsheet cell the ability to run code.

- Operators: `+ - * / ^` (right-associative), `&` for text join, comparisons
  `= <> < > <= >=`, unary minus, parentheses, ranges `A1:B5`, absolute `$A$1`.
- About thirty functions: `SUM`, `PRODUCT`, `AVERAGE`, `MIN`, `MAX`, `MEDIAN`,
  `COUNT`, `COUNTA`, `COUNTIF`, `SUMIF`, `ABS`, `SQRT`, `INT`, `SIGN`, `ROUND`,
  `ROUNDUP`, `ROUNDDOWN`, `POWER`, `MOD`, `IF`, `AND`, `OR`, `NOT`, `CONCAT`,
  `CONCATENATE`, `LEN`, `UPPER`, `LOWER`, `TRIM`, `LEFT`, `RIGHT`, `MID`,
  `TODAY`, `NOW`.
- Errors are values, not exceptions: `#DIV/0!`, `#VALUE!`, `#REF!`, `#NAME?`,
  `#CIRCULAR`, `#N/A`, `#ERROR!`. An unknown function is `#NAME?`; a syntax
  error is `#ERROR!` in that cell only.
- `recalculate/1` builds the dependency graph and evaluates in topological
  order, so evaluation never recurses through references. Cells in or downstream
  of a cycle get `#CIRCULAR`; the rest of the sheet still computes. A
  5,000-cell dependency chain is covered by a test because a recursive
  evaluator would overflow the stack on one.
- A range larger than 20,000 cells is `#REF!` rather than an expansion that
  hangs the tab.
- `IF` evaluates its own arguments so it can return a live branch when the other
  branch errors.

### 4.2 CSV

Import replaces the sheet. A leading `=` in imported data is stored as text, not
promoted to a formula — imported bytes are data, not something the exporter
meant to run. Export writes what the sheet *shows* (computed values), because a
CSV reader wants the number, not `=SUM(B1:B9)`. Both directions handle quotes,
embedded commas, and embedded newlines.

## 5. Pages

```json
"page": {
  "blocks": [
    {"id": "UUID", "type": "heading1", "text": "Quarterly review", "marks": []},
    {"id": "UUID", "type": "paragraph", "text": "Revenue grew sharply.",
     "marks": [{"s": 8, "e": 20, "m": "b"}]}
  ]
}
```

- `type` is one of `paragraph`, `heading1`, `heading2`, `heading3`, `quote`,
  `code`, `bullet`, `number`, `divider`.
- `text` is **plain text**. Inline formatting is a separate list of ranges
  `{s, e, m}` over code-point offsets, with `m` one of `b`, `i`, `u`, `s`,
  `code`.
- Limits: 2,000 blocks, 20,000 characters per block, 200,000 per document.
- A page always has at least one block, so there is always somewhere to type.

### 5.1 Why ranges and not markup

The notes board's standing rule is that decrypted content never reaches
`innerHTML` (SELF_NOTES_KEEP_SPEC §10). A word processor is exactly where that
rule is tempting to break, so the model is built to keep it:

- Storing plain text plus ranges means the payload contains no markup, so there
  is nothing to sanitize on the way in.
- `runsFor(block)` converts text and marks into `[{text, marks}]` runs. The
  editor creates one element per run and sets `textContent`. Nothing is ever
  parsed as HTML.
- Editing uses a plain `<textarea>` per block, **not `contenteditable`**.
  `contenteditable` returns browser-generated HTML that would then have to be
  parsed and sanitized — reintroducing precisely the risk the rule exists to
  prevent. The cost is that the block being edited shows its plain text; every
  other block renders formatted.
- Marks are shifted by `shiftMarks/4` as text is edited so formatting follows
  its text, and offsets are code points rather than UTF-16 indices so an emoji
  does not displace every mark after it.

## 6. Loading on demand

`assets/js/veejr/docs/` is reached through exactly one dynamic import, in
`self_notes.js`:

```js
const {openDocumentEditor} = await import("../docs/editor.js")
```

`--splitting --format=esm` in the esbuild configuration turns that into a
separate chunk; the entry point is loaded as `<script type="module">`. Without
splitting, esbuild inlines a dynamic import into the bundle and every session
pays for the editors. Verify after any build change that
`priv/static/assets/js/chunks/editor-*.js` exists and that the board does not
request it until a document is opened.

Consequently the board must not statically import anything from `docs/`. Card
titles, previews, and the search index are computed from the raw decrypted
payload by `documentSummary()` in `self_notes.js`.

## 7. Server surface

Documents need no endpoints of their own. They reuse:

| Operation | Path |
| --- | --- |
| Create | `send_batch` with `kind: "self_doc"` |
| List | `Messaging.list_self_envelopes/2`, optionally `kinds: ["self_doc"]` |
| Edit | `prepare_edit` then `edit_batch`, with `expected_updated_at` |
| Delete | `Messaging.delete_self_item/2` |
| Remind | `Messaging.set_reminder/3` |

The server validates ownership, kind, and copy ids. It never inspects the
payload, and no column holds a title, cell, block, or formula.

`self_doc` is advertised in the capabilities API's `message_kinds` so an older
client can recognize an item it does not support. The v1 native message-batch
endpoint accepts `kind: "message"` only, so `self_doc` is web-only until Android
implements the payload contract; an Android client must show an unsupported
encrypted item rather than treat it as a message.

## 8. Test coverage

- `test/js/formula.test.mjs` — tokenizer, precedence and associativity, error
  values, dependency ordering, cycles, deep chains, coercion, formatting.
- `test/js/document.test.mjs` — normalization and clamping, CSV round trips,
  mark normalization, `runsFor` boundaries, `toggleMark`, `shiftMarks`, page
  text round trips.
- `test/veejr/messaging_schedule_test.exs` — the owner-only invariants, kind
  filtering, and owner-scoped deletion.

Run the browser modules with `mix js.test`; both suites run in CI.

## 9. Not implemented

Sharing or co-editing a document with another person, blob-backed bodies for
documents beyond the envelope ceiling, cell formatting (number formats, colors,
borders), charts, multiple sheets per spreadsheet, images inside pages, tables
inside pages, and Android parity.

Sharing in particular is a larger project than it appears: two people editing
one encrypted document needs a conflict model beyond the notes board's
keep-mine/keep-theirs prompt. Sending a snapshot as an attachment is the honest
current answer.
