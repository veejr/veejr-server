// The control for a note's labels: the labels it has as chips with a × to take
// each off, a field that says what it is for, and the labels already used on
// other notes as one-click suggestions.
//
// It replaces a bare "Labels, separated by commas" text box, which gave no sign
// that labels were something you could add and no way to take one off short of
// editing the text. The rules for what a label may be live in notes_document.js.
//
// Text is only ever written with textContent, never parsed as markup.

import {LABEL_LIMIT, addLabel, normalizeLabel, removeLabel, suggestLabels} from "./notes_document.js"

const CHIP = "inline-flex items-center gap-1 rounded-full border border-current/25 bg-current/10 py-0.5 pr-1 pl-2.5 text-xs font-medium"
const REMOVE = "flex size-4 items-center justify-center rounded-full leading-none opacity-60 transition hover:bg-current/20 hover:opacity-100"
const SUGGESTION = "rounded-full border border-dashed border-current/30 px-2.5 py-0.5 text-xs opacity-70 transition hover:border-solid hover:opacity-100"

/**
 * `labels` are the note's labels, `suggestions` every label in use on the
 * board, and `onChange` is called with the new list whenever it changes.
 *
 * Returns `{el, input, get, set}`; `input` is the text field, for callers that
 * need to know when focus leaves the control.
 */
export function createLabelEditor(doc, {labels = [], suggestions = [], onChange = () => {}} = {}) {
  let current = labels.reduce((list, label) => addLabel(list, label), [])

  const root = doc.createElement("div")
  root.className = "space-y-2"
  root.dataset.role = "label-editor"

  const row = doc.createElement("div")
  row.className = "flex flex-wrap items-center gap-1.5"

  // The chips are redrawn on every change; the field is not, because removing
  // a focused field from the page would take the keyboard away from it.
  const chips = doc.createElement("span")
  chips.className = "contents"

  const input = doc.createElement("input")
  input.type = "text"
  input.setAttribute("aria-label", "Add a label")
  input.maxLength = 80
  input.autocomplete = "off"
  input.className = "min-w-[9rem] flex-1 bg-transparent py-1 text-xs outline-none placeholder:opacity-60"

  const hint = doc.createElement("p")
  hint.className = "text-xs opacity-60"

  const offered = doc.createElement("div")
  offered.className = "flex flex-wrap items-center gap-1.5"

  row.append(chips, input)
  root.append(row, offered, hint)

  const commit = (next) => {
    if (next === current) return
    current = next
    render()
    onChange([...current])
  }

  const addPending = () => {
    const pending = input.value
    input.value = ""
    commit(addLabel(current, pending))
    renderSuggestions()
  }

  function renderSuggestions() {
    offered.textContent = ""
    if (current.length >= LABEL_LIMIT) return

    suggestLabels(suggestions, current, input.value).forEach((label) => {
      const button = doc.createElement("button")
      button.type = "button"
      button.className = SUGGESTION
      button.textContent = `+ ${label}`
      button.setAttribute("aria-label", `Add label ${label}`)
      button.addEventListener("click", () => {
        commit(addLabel(current, label))
        input.focus()
      })
      offered.appendChild(button)
    })
  }

  function render() {
    chips.textContent = ""

    current.forEach((label) => {
      const chip = doc.createElement("span")
      chip.className = CHIP
      chip.dataset.label = label

      const text = doc.createElement("span")
      text.textContent = `#${label}`

      const remove = doc.createElement("button")
      remove.type = "button"
      remove.className = REMOVE
      remove.textContent = "×"
      remove.title = `Remove ${label}`
      remove.setAttribute("aria-label", `Remove label ${label}`)
      remove.addEventListener("click", () => {
        commit(removeLabel(current, label))
        input.focus()
      })

      chip.append(text, remove)
      chips.appendChild(chip)
    })

    const full = current.length >= LABEL_LIMIT
    input.disabled = full
    input.placeholder = full
      ? "That is the most labels a note can have"
      : current.length === 0
        ? "Add a label — type a word, press Enter"
        : "Add another label"
    hint.textContent = current.length > 0 ? `${current.length} of ${LABEL_LIMIT} labels` : ""
    hint.hidden = current.length < LABEL_LIMIT - 2
    renderSuggestions()
  }

  input.addEventListener("keydown", (event) => {
    if (event.isComposing) return

    if (event.key === "Enter" || event.key === ",") {
      // Enter must not also save or close the note it is typed in.
      event.preventDefault()
      event.stopPropagation()
      addPending()
    } else if (event.key === "Backspace" && input.value === "" && current.length > 0) {
      commit(current.slice(0, -1))
    }
  })

  // Pasting "a, b, c" makes three labels; typing narrows the suggestions.
  input.addEventListener("input", () => {
    if (input.value.includes(",")) {
      const parts = input.value.split(",")
      input.value = parts.pop()
      parts.forEach((part) => commit(addLabel(current, part)))
    }
    renderSuggestions()
  })

  // Typed text that was never confirmed still counts: clicking Save moves
  // focus away first, so this is what keeps the last label from being lost.
  input.addEventListener("blur", () => {
    if (normalizeLabel(input.value)) addPending()
  })

  render()

  return {
    el: root,
    input,
    get: () => [...current],
    // The labels including anything typed but not yet confirmed with Enter.
    flush() {
      if (normalizeLabel(input.value)) addPending()
      return [...current]
    },
    set(next) {
      current = next.reduce((list, label) => addLabel(list, label), [])
      render()
    },
  }
}
