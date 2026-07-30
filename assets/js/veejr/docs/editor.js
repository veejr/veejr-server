// The document editor shell — the single module the notes board imports on
// demand.
//
// Everything under docs/ is behind one `await import("../docs/editor.js")` in
// self_notes.js, so a session that never opens a document never downloads the
// grid, the block editor, or the formula engine. That is the whole reason this
// file exists as a separate entry point rather than more of self_notes.js.
//
// Nothing here builds markup from decrypted content: elements are created and
// filled with textContent. The static chrome below (toolbar, buttons) is
// author-written and safe, but document text never travels through innerHTML.

import {docDocument} from "./document.js"
import {mountSheet} from "./sheet.js"
import {mountPage} from "./page.js"

const KIND_LABELS = {sheet: "Spreadsheet", page: "Document"}

/**
 * Opens a document in a full-screen dialog.
 *
 * `save(doc)` must persist and resolve; rejecting leaves the editor open with
 * the user's work intact and shows the failure. Resolves when the editor
 * closes, with the last saved document or null if nothing was saved.
 */
export function openDocumentEditor({payload, save, title: initialTitle} = {}) {
  return new Promise((resolve) => {
    let doc = docDocument(payload || {})
    if (initialTitle && !doc.title) doc.title = initialTitle

    let saved = null
    let dirty = false
    let saving = false

    const dialog = document.createElement("dialog")
    dialog.className = "veejr-doc-dialog"
    dialog.setAttribute("aria-label", `${KIND_LABELS[doc.doc_kind]} editor`)

    const shell = document.createElement("div")
    shell.className = "veejr-doc-shell"

    // --- header ------------------------------------------------------------
    const header = document.createElement("header")
    header.className = "veejr-doc-header"

    const badge = document.createElement("span")
    badge.className = "badge badge-sm badge-ghost shrink-0"
    badge.textContent = KIND_LABELS[doc.doc_kind] || "Document"

    const title = document.createElement("input")
    title.className = "veejr-doc-title"
    title.value = doc.title
    title.placeholder = doc.doc_kind === "sheet" ? "Untitled spreadsheet" : "Untitled document"
    title.setAttribute("aria-label", "Document title")
    title.addEventListener("input", () => {
      doc.title = title.value
      markDirty()
    })

    const status = document.createElement("span")
    status.className = "veejr-doc-status"
    status.setAttribute("aria-live", "polite")

    const actions = document.createElement("div")
    actions.className = "veejr-doc-actions"

    const saveButton = button("Save", "btn btn-primary btn-sm", () => commit())
    const closeButton = button("Close", "btn btn-ghost btn-sm", () => requestClose())

    actions.append(saveButton, closeButton)
    header.append(badge, title, status, actions)

    // --- body --------------------------------------------------------------
    const body = document.createElement("div")
    body.className = "veejr-doc-body"

    const error = document.createElement("p")
    error.className = "veejr-doc-error hidden"
    error.setAttribute("role", "alert")

    shell.append(header, error, body)
    dialog.appendChild(shell)
    document.body.appendChild(dialog)

    function markDirty() {
      dirty = true
      status.textContent = "Unsaved changes"
      status.dataset.state = "dirty"
    }

    function showError(message) {
      error.textContent = message
      error.classList.toggle("hidden", !message)
    }

    // The editor owns the document's own section; it calls back on any change.
    const surface = doc.doc_kind === "sheet" ? mountSheet : mountPage
    const controller = surface({
      container: body,
      doc,
      onChange: (next) => {
        doc = next
        markDirty()
      },
      onStatus: (message) => {
        status.textContent = message
        status.dataset.state = "info"
      },
    })

    async function commit() {
      if (saving) return true
      saving = true
      saveButton.disabled = true
      showError("")
      status.textContent = "Saving…"
      status.dataset.state = "saving"

      try {
        // Take whatever the surface has in flight (a half-typed cell, an open
        // block) before serializing, so Save never loses the current edit.
        doc = controller.flush() || doc
        const next = docDocument({...doc, title: title.value})
        await save(next)
        doc = next
        saved = next
        dirty = false
        status.textContent = "Saved"
        status.dataset.state = "saved"
        return true
      } catch (failure) {
        showError(failure?.message || "Could not save. Your work is still here.")
        status.textContent = "Not saved"
        status.dataset.state = "dirty"
        return false
      } finally {
        saving = false
        saveButton.disabled = false
      }
    }

    async function requestClose({force = false} = {}) {
      if (dirty && !force) {
        // Deliberately a plain confirm: losing a document to a missed dialog
        // is worse than the interruption.
        if (!window.confirm("Close without saving your changes?")) return
      }
      controller.destroy?.()
      dialog.close()
      dialog.remove()
      document.removeEventListener("keydown", onKeydown, true)
      resolve(saved)
    }

    function onKeydown(event) {
      if (!dialog.isConnected) return

      // Ctrl/Cmd+S saves without closing, the way every editor does.
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "s") {
        event.preventDefault()
        commit()
      }
    }

    document.addEventListener("keydown", onKeydown, true)

    // Escape must not discard work silently, so route it through the same
    // confirmation as the Close button.
    dialog.addEventListener("cancel", (event) => {
      event.preventDefault()
      requestClose()
    })

    dialog.showModal()
    if (!doc.title) title.focus()
    else controller.focus?.()
  })
}

function button(label, className, onClick) {
  const element = document.createElement("button")
  element.type = "button"
  element.className = className
  element.textContent = label
  element.addEventListener("click", onClick)
  return element
}

// Shared by both surfaces: a labelled toolbar button.
export function toolbarButton({label, title: hint, onClick, icon = null}) {
  const element = document.createElement("button")
  element.type = "button"
  element.className = "veejr-doc-tool"
  element.title = hint || label
  element.setAttribute("aria-label", hint || label)
  element.textContent = icon || label
  element.addEventListener("click", onClick)
  return element
}

// Downloads generated text (CSV, plain text) without leaving the page. The
// blob is same-origin and revoked immediately; no server round trip, so
// exported document content never reaches the instance.
export function downloadText(filename, text, mime = "text/plain") {
  const blob = new Blob([text], {type: `${mime};charset=utf-8`})
  const url = URL.createObjectURL(blob)
  const link = document.createElement("a")
  link.href = url
  link.download = filename
  document.body.appendChild(link)
  link.click()
  link.remove()
  URL.revokeObjectURL(url)
}

export function safeFilename(title, fallback, extension) {
  const base = String(title || "").trim().replace(/[^\w \-.]+/g, "").slice(0, 60)
  return `${base || fallback}.${extension}`
}
