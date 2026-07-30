// The word-processor surface: a block editor.
//
// Two rules shape the whole design. Decrypted content never goes through
// innerHTML, and no `contenteditable` — contenteditable hands you HTML the
// browser generated, which you would then have to parse and sanitize, which is
// exactly the thing the board's rule exists to avoid.
//
// So: a block displays as elements built from `runsFor()` and filled with
// textContent, and editing a block swaps in a plain <textarea>. Bold, italic
// and friends apply to the textarea's selection as *ranges* (see toggleMark),
// never as characters in the text. Formatting is real and WYSIWYG when the
// block is not being edited; while you are typing in a block you see its plain
// text, which is also the only honest thing a textarea can show.

import {
  docDocument,
  makeBlock,
  normalizeMarks,
  runsFor,
  shiftMarks,
  toggleMark,
  pageToText,
  textToPage,
} from "./document.js"

import {downloadText, safeFilename, toolbarButton} from "./editor.js"

const BLOCK_LABELS = [
  ["paragraph", "Body"],
  ["heading1", "Title"],
  ["heading2", "Heading"],
  ["heading3", "Subheading"],
  ["quote", "Quote"],
  ["code", "Code"],
  ["bullet", "Bulleted"],
  ["number", "Numbered"],
]

const MARK_BUTTONS = [
  ["b", "B", "Bold"],
  ["i", "I", "Italic"],
  ["u", "U", "Underline"],
  ["s", "S", "Strikethrough"],
  ["code", "</>", "Inline code"],
]

export function mountPage({container, doc, onChange, onStatus}) {
  let blocks = doc.page.blocks.map((block) => ({...block}))
  let activeId = null
  let textarea = null

  // --- chrome --------------------------------------------------------------
  const toolbar = document.createElement("div")
  toolbar.className = "veejr-doc-toolbar"

  const blockType = document.createElement("select")
  blockType.className = "veejr-doc-select"
  blockType.setAttribute("aria-label", "Block style")
  for (const [value, label] of BLOCK_LABELS) {
    const option = document.createElement("option")
    option.value = value
    option.textContent = label
    blockType.appendChild(option)
  }
  blockType.addEventListener("change", () => {
    const block = activeBlock()
    if (!block) return
    block.type = blockType.value
    const id = block.id
    // Commit first: re-rendering replaces the textarea's element, and
    // beginEdit would otherwise see this block as still active and decline to
    // reopen it, leaving the block unfocused and activeId pointing at nothing.
    commitEdit()
    render()
    beginEdit(id)
  })

  toolbar.appendChild(blockType)

  for (const [mark, glyph, label] of MARK_BUTTONS) {
    toolbar.appendChild(
      toolbarButton({
        label: glyph,
        title: `${label} (select text first)`,
        onClick: () => applyMark(mark),
      })
    )
  }

  toolbar.append(
    toolbarButton({
      label: "Divider",
      title: "Insert a horizontal rule",
      onClick: () => {
        insertAfter(activeBlock(), makeBlock("divider", ""))
        render()
      },
    }),
    toolbarButton({
      label: "Export text",
      title: "Download this document as plain text",
      onClick: () =>
        downloadText(safeFilename(doc.title, "document", "txt"), pageToText({blocks})),
    }),
    toolbarButton({
      label: "Print",
      title: "Print or save as PDF",
      onClick: () => window.print(),
    })
  )

  const surface = document.createElement("div")
  surface.className = "veejr-page"
  surface.setAttribute("role", "list")

  container.append(toolbar, surface)

  // --- rendering -----------------------------------------------------------

  function render() {
    surface.textContent = ""
    blocks.forEach((block) => surface.appendChild(renderBlock(block)))
  }

  function renderBlock(block) {
    const wrapper = document.createElement("div")
    wrapper.className = "veejr-page-block"
    wrapper.dataset.id = block.id
    wrapper.dataset.type = block.type
    wrapper.setAttribute("role", "listitem")

    if (block.type === "divider") {
      const rule = document.createElement("hr")
      rule.className = "veejr-page-divider"
      wrapper.appendChild(rule)
      wrapper.tabIndex = 0
      wrapper.addEventListener("keydown", (event) => {
        if (event.key === "Backspace" || event.key === "Delete") {
          event.preventDefault()
          removeBlock(block)
        }
      })
      return wrapper
    }

    const display = document.createElement(elementFor(block.type))
    display.className = "veejr-page-text"
    display.tabIndex = 0

    const runs = runsFor(block)
    if (!runs.length) {
      const placeholder = document.createElement("span")
      placeholder.className = "veejr-page-placeholder"
      placeholder.textContent = block.type === "paragraph" ? "Write something…" : "Empty"
      display.appendChild(placeholder)
    } else {
      for (const run of runs) {
        if (!run.marks.length) {
          // textContent, not innerHTML: this is decrypted document text.
          display.appendChild(document.createTextNode(run.text))
          continue
        }
        const span = document.createElement("span")
        span.className = run.marks.map((mark) => `veejr-mark-${mark}`).join(" ")
        span.textContent = run.text
        display.appendChild(span)
      }
    }

    display.addEventListener("click", () => beginEdit(block.id))
    display.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault()
        beginEdit(block.id)
      }
    })

    wrapper.appendChild(display)
    return wrapper
  }

  function elementFor(type) {
    switch (type) {
      case "heading1": return "h1"
      case "heading2": return "h2"
      case "heading3": return "h3"
      case "quote": return "blockquote"
      case "code": return "pre"
      case "bullet":
      case "number": return "li"
      default: return "p"
    }
  }

  // --- editing -------------------------------------------------------------

  function beginEdit(id, caret = null) {
    if (activeId === id) return
    commitEdit()

    const block = blocks.find((candidate) => candidate.id === id)
    const wrapper = surface.querySelector(`[data-id="${id}"]`)
    if (!block || !wrapper || block.type === "divider") return

    activeId = id
    blockType.value = block.type

    textarea = document.createElement("textarea")
    textarea.className = "veejr-page-input"
    textarea.value = block.text
    textarea.rows = 1
    textarea.setAttribute("aria-label", `${BLOCK_LABELS.find(([type]) => type === block.type)?.[1] || "Block"} text`)

    // Track edits so mark ranges follow the text they were applied to.
    let previous = block.text

    textarea.addEventListener("input", () => {
      const next = textarea.value
      const {at, removed, added} = diff(previous, next)
      block.marks = normalizeMarks(shiftMarks(block.marks, at, removed, added), [...next].length)
      block.text = next
      previous = next
      autosize()
      publish()
    })

    textarea.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && !event.shiftKey && block.type !== "code") {
        event.preventDefault()
        splitBlock(block)
        return
      }
      if (event.key === "Backspace" && textarea.selectionStart === 0 && textarea.selectionEnd === 0) {
        event.preventDefault()
        mergeWithPrevious(block)
        return
      }
      if (event.key === "Escape") {
        event.preventDefault()
        commitEdit()
        render()
      }
      // Ctrl/Cmd+B and friends, so formatting does not require the mouse.
      if (event.ctrlKey || event.metaKey) {
        const shortcut = {b: "b", i: "i", u: "u"}[event.key.toLowerCase()]
        if (shortcut) {
          event.preventDefault()
          applyMark(shortcut)
        }
      }
    })

    textarea.addEventListener("blur", () => {
      // Blurring onto a toolbar button must not tear the editor down before
      // the button's click handler can act on the selection.
      setTimeout(() => {
        if (activeId === id && !toolbar.contains(document.activeElement)) {
          commitEdit()
          render()
        }
      }, 0)
    })

    wrapper.textContent = ""
    wrapper.appendChild(textarea)
    autosize()
    textarea.focus()
    const position = caret === null ? textarea.value.length : caret
    textarea.setSelectionRange(position, position)
  }

  function autosize() {
    if (!textarea) return
    textarea.style.height = "auto"
    textarea.style.height = `${textarea.scrollHeight}px`
  }

  function commitEdit() {
    if (!activeId) return
    activeId = null
    textarea = null
    publish()
  }

  function activeBlock() {
    return blocks.find((block) => block.id === activeId) || blocks[blocks.length - 1]
  }

  function applyMark(mark) {
    const block = blocks.find((candidate) => candidate.id === activeId)
    if (!block || !textarea) {
      onStatus?.("Select some text inside a block first.")
      return
    }

    // Textarea offsets are UTF-16; the mark model counts code points, so an
    // emoji in the text would otherwise shift every mark after it.
    const start = codePointOffset(textarea.value, textarea.selectionStart)
    const end = codePointOffset(textarea.value, textarea.selectionEnd)
    if (end <= start) {
      onStatus?.("Select some text to format.")
      return
    }

    const updated = toggleMark(block, start, end, mark)
    block.marks = updated.marks
    publish()
    onStatus?.("Formatting applied.")
  }

  function splitBlock(block) {
    const caret = textarea.selectionStart
    const before = textarea.value.slice(0, caret)
    const after = textarea.value.slice(caret)
    const length = [...before].length

    block.text = before
    block.marks = normalizeMarks(block.marks, length)

    // A new paragraph after a heading; a list continues as a list.
    const nextType = ["bullet", "number"].includes(block.type) ? block.type : "paragraph"
    const fresh = makeBlock(nextType, after)
    insertAfter(block, fresh)
    render()
    beginEdit(fresh.id, 0)
  }

  function mergeWithPrevious(block) {
    const index = blocks.indexOf(block)
    if (index <= 0) return
    const previous = blocks[index - 1]
    if (previous.type === "divider") {
      blocks.splice(index - 1, 1)
      render()
      beginEdit(block.id, 0)
      return
    }

    const offset = [...previous.text].length
    previous.text += block.text
    previous.marks = normalizeMarks(
      [...previous.marks, ...shiftMarks(block.marks, 0, 0, offset)],
      [...previous.text].length
    )
    blocks.splice(index, 1)
    if (!blocks.length) blocks.push(makeBlock("paragraph", ""))
    render()
    beginEdit(previous.id, offset)
  }

  function insertAfter(block, fresh) {
    const index = block ? blocks.indexOf(block) : blocks.length - 1
    blocks.splice(index + 1, 0, fresh)
    publish()
  }

  function removeBlock(block) {
    blocks = blocks.filter((candidate) => candidate !== block)
    if (!blocks.length) blocks.push(makeBlock("paragraph", ""))
    render()
    publish()
  }

  function publish() {
    onChange(docDocument({...doc, page: {blocks}}))
  }

  // Pasting many paragraphs should become many blocks, not one wall of text.
  surface.addEventListener("paste", (event) => {
    const text = event.clipboardData?.getData("text/plain")
    if (!text || !text.includes("\n\n") || !activeId) return
    event.preventDefault()

    const block = blocks.find((candidate) => candidate.id === activeId)
    const pasted = textToPage(text).blocks
    const index = blocks.indexOf(block)
    blocks.splice(index + 1, 0, ...pasted)
    render()
    beginEdit(pasted[pasted.length - 1].id)
    publish()
  })

  render()

  return {
    focus() {
      const first = blocks.find((block) => block.type !== "divider")
      if (!first) return
      // A new, empty document should be ready to type into. An existing one
      // should be readable first — dropping straight into a textarea hides the
      // formatting of the block you landed on.
      const empty = blocks.length === 1 && !blocks[0].text
      if (empty) beginEdit(first.id)
      else surface.querySelector(".veejr-page-text")?.focus()
    },
    flush() {
      commitEdit()
      return docDocument({...doc, page: {blocks}})
    },
    destroy() {
      activeId = null
      textarea = null
    },
  }
}

// Where two strings first and last differ, expressed in code points, so mark
// ranges can be shifted by an edit without re-deriving them.
function diff(before, after) {
  const previous = [...before]
  const next = [...after]

  let start = 0
  while (start < previous.length && start < next.length && previous[start] === next[start]) start++

  let endBefore = previous.length
  let endAfter = next.length
  while (
    endBefore > start &&
    endAfter > start &&
    previous[endBefore - 1] === next[endAfter - 1]
  ) {
    endBefore--
    endAfter--
  }

  return {at: start, removed: endBefore - start, added: endAfter - start}
}

// UTF-16 index (what a textarea reports) to code-point index (what the mark
// model uses).
function codePointOffset(text, utf16Index) {
  return [...text.slice(0, utf16Index)].length
}
