// The spreadsheet surface: a grid, a formula bar, and CSV in and out.
//
// Cells are rendered with textContent, and the formula engine is an
// interpreter (see formula.js) — a spreadsheet cell is untrusted input that
// happens to be your own, and it still never becomes code or markup.

import {
  cellsToCsv,
  csvToCells,
  docDocument,
  sheetBounds,
} from "./document.js"

import {
  formatValue,
  indexToColumn,
  isError,
  recalculate,
  refName,
} from "./formula.js"

import {downloadText, safeFilename, toolbarButton} from "./editor.js"

// Rendered window. The document may describe more, and "Add rows"/"Add
// columns" extend it; drawing 5,000 rows of DOM up front would cost more than
// it is ever worth.
const VIEW_ROWS = 60
const VIEW_COLUMNS = 18
const ROW_STEP = 30
const COLUMN_STEP = 6

export function mountSheet({container, doc, onChange, onStatus}) {
  let sheet = doc.sheet
  let cells = {...sheet.cells}
  let values = recalculate(cells)
  let selection = {row: 0, column: 0}
  let editing = null

  const bounds = sheetBounds(sheet)
  let viewRows = Math.max(VIEW_ROWS, Math.min(bounds.rows, VIEW_ROWS))
  let viewColumns = Math.max(VIEW_COLUMNS, Math.min(bounds.columns, VIEW_COLUMNS))

  // --- chrome --------------------------------------------------------------
  const toolbar = document.createElement("div")
  toolbar.className = "veejr-doc-toolbar"

  const formulaLabel = document.createElement("span")
  formulaLabel.className = "veejr-sheet-ref"

  const formulaInput = document.createElement("input")
  formulaInput.className = "veejr-sheet-formula"
  formulaInput.setAttribute("aria-label", "Cell contents")
  formulaInput.placeholder = "Value or =FORMULA()"

  formulaInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault()
      commitCell(selection.row, selection.column, formulaInput.value)
      focusGrid()
    } else if (event.key === "Escape") {
      event.preventDefault()
      syncFormulaBar()
      focusGrid()
    }
  })

  const importInput = document.createElement("input")
  importInput.type = "file"
  importInput.accept = ".csv,.tsv,text/csv,text/plain"
  importInput.className = "sr-only"
  importInput.addEventListener("change", async (event) => {
    const file = event.target.files?.[0]
    event.target.value = ""
    if (file) await importCsv(file)
  })

  const importLabel = document.createElement("label")
  importLabel.className = "veejr-doc-tool"
  importLabel.title = "Replace the sheet with a CSV file"
  importLabel.textContent = "Import CSV"
  importLabel.appendChild(importInput)

  toolbar.append(
    formulaLabel,
    formulaInput,
    toolbarButton({
      label: "Export CSV",
      title: "Download the computed values as CSV",
      onClick: () =>
        downloadText(
          safeFilename(doc.title, "spreadsheet", "csv"),
          cellsToCsv({...sheet, cells}, values),
          "text/csv"
        ),
    }),
    importLabel,
    toolbarButton({
      label: "Add rows",
      title: `Add ${ROW_STEP} more rows`,
      onClick: () => {
        viewRows += ROW_STEP
        render()
      },
    }),
    toolbarButton({
      label: "Add columns",
      title: `Add ${COLUMN_STEP} more columns`,
      onClick: () => {
        viewColumns = Math.min(viewColumns + COLUMN_STEP, 200)
        render()
      },
    })
  )

  const scroller = document.createElement("div")
  scroller.className = "veejr-sheet-scroller"

  const table = document.createElement("table")
  table.className = "veejr-sheet"
  table.tabIndex = 0
  scroller.appendChild(table)

  container.append(toolbar, scroller)

  // --- rendering -----------------------------------------------------------

  function render() {
    table.textContent = ""

    const head = document.createElement("thead")
    const headRow = document.createElement("tr")
    headRow.appendChild(cornerCell())

    for (let column = 0; column < viewColumns; column++) {
      const th = document.createElement("th")
      th.scope = "col"
      th.textContent = indexToColumn(column)
      headRow.appendChild(th)
    }

    head.appendChild(headRow)
    table.appendChild(head)

    const tbody = document.createElement("tbody")

    for (let row = 0; row < viewRows; row++) {
      const tr = document.createElement("tr")
      const rowHeader = document.createElement("th")
      rowHeader.scope = "row"
      rowHeader.textContent = String(row + 1)
      tr.appendChild(rowHeader)

      for (let column = 0; column < viewColumns; column++) {
        tr.appendChild(renderCell(row, column))
      }

      tbody.appendChild(tr)
    }

    table.appendChild(tbody)
    highlight()
    syncFormulaBar()
  }

  function cornerCell() {
    const th = document.createElement("th")
    th.className = "veejr-sheet-corner"
    th.setAttribute("aria-label", "Select nothing")
    return th
  }

  function renderCell(row, column) {
    const ref = refName(column, row)
    const td = document.createElement("td")
    td.dataset.ref = ref
    td.dataset.row = String(row)
    td.dataset.column = String(column)

    const value = values.get(ref)
    const cell = cells[ref]

    td.textContent = formatValue(value ?? cell?.v ?? "")
    if (isError(value)) td.dataset.error = "true"
    // Numbers right-align, the way every spreadsheet does, so columns read.
    if (typeof value === "number") td.dataset.numeric = "true"
    if (cell?.f) td.dataset.formula = "true"

    td.addEventListener("mousedown", (event) => {
      if (editing && editing.ref !== ref) commitEditor()
      event.preventDefault()
      selection = {row, column}
      highlight()
      syncFormulaBar()
      focusGrid()
    })

    td.addEventListener("dblclick", () => beginEdit(row, column, ""))

    return td
  }

  function cellAt(row, column) {
    return table.querySelector(`td[data-ref="${refName(column, row)}"]`)
  }

  function highlight() {
    table.querySelectorAll("td[data-selected]").forEach((td) => delete td.dataset.selected)
    const current = cellAt(selection.row, selection.column)
    if (current) {
      current.dataset.selected = "true"
      current.scrollIntoView({block: "nearest", inline: "nearest"})
    }
  }

  function syncFormulaBar() {
    const ref = refName(selection.column, selection.row)
    formulaLabel.textContent = ref
    const cell = cells[ref]
    formulaInput.value = cell?.f ?? (cell?.v ?? "")
  }

  // --- editing -------------------------------------------------------------

  function beginEdit(row, column, seed) {
    const td = cellAt(row, column)
    if (!td || editing) return

    const ref = refName(column, row)
    const input = document.createElement("input")
    input.className = "veejr-sheet-input"
    input.setAttribute("aria-label", `Cell ${ref}`)
    input.value = seed !== "" ? seed : (cells[ref]?.f ?? cells[ref]?.v ?? "")

    editing = {ref, row, column, input, td}
    td.textContent = ""
    td.appendChild(input)
    input.focus()
    // Typing over a cell replaces it; F2/double-click keeps the caret at the end.
    input.setSelectionRange(input.value.length, input.value.length)

    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault()
        commitEditor()
        move(1, 0)
      } else if (event.key === "Tab") {
        event.preventDefault()
        commitEditor()
        move(0, event.shiftKey ? -1 : 1)
      } else if (event.key === "Escape") {
        event.preventDefault()
        cancelEditor()
      }
      event.stopPropagation()
    })

    input.addEventListener("blur", () => {
      if (editing?.input === input) commitEditor()
    })
  }

  function cancelEditor() {
    if (!editing) return
    const {row, column} = editing
    editing = null
    replaceCell(row, column)
    focusGrid()
  }

  function commitEditor() {
    if (!editing) return
    const {ref, row, column, input} = editing
    editing = null
    commitCell(row, column, input.value, {ref})
    focusGrid()
  }

  function commitCell(row, column, raw, {ref = refName(column, row)} = {}) {
    const text = String(raw ?? "")
    const previous = cells[ref]

    if (text.trim() === "") {
      if (previous === undefined) {
        replaceCell(row, column)
        return
      }
      delete cells[ref]
    } else if (text.startsWith("=")) {
      cells[ref] = {f: text}
    } else {
      cells[ref] = {v: text}
    }

    recompute()
  }

  function recompute() {
    values = recalculate(cells)
    // A formula anywhere can change any other cell, so redraw the window
    // rather than trying to work out which cells moved.
    render()
    publish()
  }

  function replaceCell(row, column) {
    const td = cellAt(row, column)
    if (!td) return
    const fresh = renderCell(row, column)
    td.replaceWith(fresh)
    highlight()
  }

  function publish() {
    sheet = {...sheet, cells, rows: Math.max(sheet.rows, viewRows), columns: Math.max(sheet.columns, viewColumns)}
    onChange(docDocument({...doc, sheet}))
  }

  function move(rowDelta, columnDelta) {
    selection = {
      row: Math.max(0, Math.min(selection.row + rowDelta, viewRows - 1)),
      column: Math.max(0, Math.min(selection.column + columnDelta, viewColumns - 1)),
    }
    highlight()
    syncFormulaBar()
  }

  function focusGrid() {
    table.focus({preventScroll: true})
  }

  // --- keyboard ------------------------------------------------------------

  table.addEventListener("keydown", (event) => {
    if (editing) return

    switch (event.key) {
      case "ArrowUp": event.preventDefault(); return move(-1, 0)
      case "ArrowDown": event.preventDefault(); return move(1, 0)
      case "ArrowLeft": event.preventDefault(); return move(0, -1)
      case "ArrowRight": event.preventDefault(); return move(0, 1)
      case "Enter":
      case "F2":
        event.preventDefault()
        return beginEdit(selection.row, selection.column, "")
      case "Tab":
        event.preventDefault()
        return move(0, event.shiftKey ? -1 : 1)
      case "Home":
        event.preventDefault()
        selection = {row: selection.row, column: 0}
        highlight()
        return syncFormulaBar()
      case "Delete":
      case "Backspace": {
        event.preventDefault()
        const ref = refName(selection.column, selection.row)
        if (cells[ref] !== undefined) {
          delete cells[ref]
          recompute()
        }
        return
      }
    }

    // Any printable character starts an edit with that character, which is
    // what makes a grid feel like a spreadsheet rather than a form.
    if (event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey) {
      event.preventDefault()
      beginEdit(selection.row, selection.column, event.key)
    }
  })

  async function importCsv(file) {
    try {
      const text = await file.text()
      const imported = csvToCells(text)
      const count = Object.keys(imported).length
      if (!count) {
        onStatus?.("That file had no cells to import.")
        return
      }
      cells = imported
      const grown = sheetBounds({...sheet, cells})
      viewRows = Math.max(viewRows, Math.min(grown.rows, 500))
      viewColumns = Math.max(viewColumns, Math.min(grown.columns, 60))
      recompute()
      onStatus?.(`Imported ${count} cell${count === 1 ? "" : "s"}.`)
    } catch (error) {
      onStatus?.(error?.message || "That file could not be read.")
    }
  }

  render()

  return {
    focus: focusGrid,
    // Commit an open cell editor before the shell serializes the document, so
    // Ctrl+S in the middle of typing does not drop the cell being typed.
    flush() {
      if (editing) commitEditor()
      return docDocument({...doc, sheet: {...sheet, cells}})
    },
    destroy() {
      editing = null
    },
  }
}
