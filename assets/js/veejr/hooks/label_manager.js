// Managing labels across every note: see each label and how many notes use it,
// rename one, or delete one.
//
// A label lives inside each note's own encrypted document, so a rename or a
// delete is a save of every note that carries it. The board does that work;
// this is only the dialog, and it asks the board for the current counts each
// time it draws, so what it shows is always what is on the notes.
//
// Text is only ever written with textContent, never parsed as markup.

import {normalizeLabel} from "./notes_document.js"

const BUTTON = "btn btn-xs"

function el(doc, tag, className, text) {
  const node = doc.createElement(tag)
  if (className) node.className = className
  if (text !== undefined) node.textContent = text
  return node
}

const noteCount = (count) => `${count} note${count === 1 ? "" : "s"}`

/**
 * Opens the dialog.
 *
 * `counts()` returns `[{label, count}]` for the notes as they are now.
 * `rename(from, to, progress)` and `remove(label, progress)` change every note
 * that has the label, calling `progress(done, total)` as they go, and resolve
 * with how many notes were changed.
 */
export function openLabelManager({counts, rename, remove, doc = document}) {
  const dialog = el(doc, "dialog", "m-auto w-[min(32rem,calc(100vw-2rem))] rounded-3xl bg-transparent p-0 backdrop:bg-black/50")
  dialog.dataset.role = "label-manager"

  const panel = el(doc, "div", "max-h-[85vh] space-y-3 overflow-y-auto rounded-3xl bg-base-100 p-5 text-base-content shadow-2xl")
  dialog.appendChild(panel)

  const header = el(doc, "div", "flex items-center justify-between gap-3")
  header.appendChild(el(doc, "h2", "text-lg font-semibold", "Labels"))
  const close = el(doc, "button", "btn btn-ghost btn-sm btn-circle")
  close.type = "button"
  close.textContent = "×"
  close.setAttribute("aria-label", "Close")
  header.appendChild(close)
  panel.appendChild(header)

  panel.appendChild(
    el(doc, "p", "text-sm opacity-70", "Rename or delete a label on every note that has it. Deleting a label keeps the notes."),
  )

  const list = el(doc, "ul", "divide-y divide-base-300")
  list.dataset.role = "label-list"
  panel.appendChild(list)

  const status = el(doc, "p", "min-h-5 text-sm opacity-70")
  status.setAttribute("aria-live", "polite")
  panel.appendChild(status)

  panel.appendChild(
    el(doc, "p", "text-xs opacity-60", "Labels on spreadsheets and documents are not changed here."),
  )

  let busy = false

  const setBusy = (value) => {
    busy = value
    list.querySelectorAll("button, input").forEach((control) => { control.disabled = value })
  }

  async function run(work, doneMessage) {
    if (busy) return
    setBusy(true)
    try {
      const changed = await work((done, total) => {
        status.textContent = `Updating ${done} of ${total}…`
      })
      status.textContent = doneMessage(changed)
    } catch (failure) {
      status.textContent = failure.message || "Something went wrong. Some notes may not have been changed."
    } finally {
      busy = false
      render()
    }
  }

  function renameRow(item, name) {
    const form = el(doc, "form", "flex flex-1 items-center gap-2")
    const input = el(doc, "input", "input input-bordered input-sm min-w-0 flex-1")
    input.type = "text"
    input.value = item.label
    input.maxLength = 80
    input.setAttribute("aria-label", `New name for ${item.label}`)

    const save = el(doc, "button", `${BUTTON} btn-primary`, "Rename")
    save.type = "submit"
    const cancel = el(doc, "button", `${BUTTON} btn-ghost`, "Cancel")
    cancel.type = "button"
    cancel.addEventListener("click", () => render())

    // Escape cancels the rename, not the whole dialog.
    input.addEventListener("keydown", (event) => {
      if (event.key !== "Escape") return
      event.preventDefault()
      event.stopPropagation()
      render()
    })

    form.addEventListener("submit", (event) => {
      event.preventDefault()
      const next = normalizeLabel(input.value)
      if (!next || next === item.label) return render()

      const existing = counts().find((other) => other.label.toLocaleLowerCase() === next.toLocaleLowerCase() && other.label.toLocaleLowerCase() !== item.label.toLocaleLowerCase())
      const merging = existing
        ? ` “${item.label}” and “${existing.label}” will become one label.`
        : ""
      if (merging && !doc.defaultView.confirm(`Rename “${item.label}” to “${next}”?${merging}`)) return

      run((progress) => rename(item.label, next, progress), (changed) => `Renamed on ${noteCount(changed)}.`)
    })

    form.append(input, save, cancel)
    name.replaceChildren(form)
    input.focus()
    input.select()
  }

  function render() {
    list.textContent = ""
    const items = counts()

    if (items.length === 0) {
      list.appendChild(el(doc, "li", "py-6 text-center text-sm opacity-70", "No labels yet. Add one from a note's Label button."))
      return
    }

    items.forEach((item) => {
      const row = el(doc, "li", "flex flex-wrap items-center gap-3 py-2")
      row.dataset.label = item.label

      const name = el(doc, "div", "flex min-w-0 flex-1 items-center gap-2")
      name.appendChild(el(doc, "span", "truncate font-medium", `#${item.label}`))
      name.appendChild(el(doc, "span", "shrink-0 text-xs opacity-60", noteCount(item.count)))

      const actions = el(doc, "div", "flex shrink-0 items-center gap-1")
      const renameButton = el(doc, "button", `${BUTTON} btn-ghost`, "Rename")
      renameButton.type = "button"
      renameButton.setAttribute("aria-label", `Rename label ${item.label}`)
      renameButton.addEventListener("click", () => renameRow(item, name))

      const deleteButton = el(doc, "button", `${BUTTON} btn-ghost text-error`, "Delete")
      deleteButton.type = "button"
      deleteButton.setAttribute("aria-label", `Delete label ${item.label}`)
      deleteButton.addEventListener("click", () => {
        if (!doc.defaultView.confirm(`Remove the label “${item.label}” from ${noteCount(item.count)}? The notes themselves are kept.`)) return
        run((progress) => remove(item.label, progress), (changed) => `Removed from ${noteCount(changed)}.`)
      })

      actions.append(renameButton, deleteButton)
      row.append(name, actions)
      list.appendChild(row)
    })
  }

  const finish = () => {
    dialog.close()
    dialog.remove()
  }
  close.addEventListener("click", finish)
  dialog.addEventListener("cancel", (event) => {
    // The browser would close it mid-save; wait until the work is done.
    event.preventDefault()
    if (!busy) finish()
  })

  render()
  doc.body.appendChild(dialog)
  dialog.showModal()
  return dialog
}
