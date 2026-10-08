// Pure data logic for "notes to yourself": document shape, offline merge and
// conflict resolution, and search parsing.
//
// Split out because the composer creates note documents while the board edits
// and merges them, so neither owns this. No DOM access, which also makes it
// the part of the notes feature that is straightforward to test.

export const selfNoteColors = new Set(["default", "sand", "rose", "violet", "blue", "mint"])

// What each stored colour looks like as a pad of sticky notes, in the order the
// swatches are laid out. The stored values are older than the sticky view and
// are kept as they are, so notes written by any other client still open.
export const selfNoteColorNames = [
  ["default", "Yellow"],
  ["sand", "Orange"],
  ["rose", "Pink"],
  ["violet", "Purple"],
  ["blue", "Blue"],
  ["mint", "Green"],
]

export function normalizeSelfNoteColor(value) {
  return selfNoteColors.has(value) ? value : "default"
}

// The one line under the notes toolbar that says what is narrowing the list.
//
// It is empty — and the line hidden — when nothing is: "12 notes shown" over an
// unfiltered board is noise, and every other state the toolbar shows already
// says so (the pressed tab, the search box). It speaks only when a filter could
// be the reason notes are missing, which matters most for the ones the
// toolbar does not show: a date range set in the gear, or a label chip.
export function noteFilterSummary({count, filter = "active", label = null, dateFrom = "", dateTo = "", searching = false} = {}) {
  const lists = {archived: "Archive", trashed: "Trash", reminders: "Reminders"}
  const narrowed = searching || !!label || !!dateFrom || !!dateTo || filter !== "active"
  if (!narrowed) return ""

  const parts = [`${count} note${count === 1 ? "" : "s"} shown.`]
  if (filter !== "active" && lists[filter]) parts.push(`In ${lists[filter]}.`)
  if (searching) parts.push("Matching your search.")
  if (label) parts.push(`Label #${label}.`)
  if (dateFrom || dateTo) parts.push(`Updated ${dateFrom || "any time"} to ${dateTo || "today"}.`)

  return parts.join(" ")
}

// A note as the plain text of a message: its title, its body, and its checklist
// as ticked and unticked lines. What the sender sees here is what goes, and
// they can still edit it before sending.
export function noteAsMessageText(payload = {}) {
  const lines = []
  const title = String(payload.title || "").trim()
  const body = String(payload.body || "").trim()

  if (title) lines.push(title)
  if (title && body) lines.push("")
  if (body) lines.push(body)

  const items = Array.isArray(payload.checklist) ? payload.checklist : []
  const checklist = items
    .filter((item) => item && String(item.text || "").trim())
    .map((item) => `${item.checked ? "☑" : "☐"} ${String(item.text).trim()}`)

  if (checklist.length > 0) {
    if (lines.length > 0) lines.push("")
    lines.push(...checklist)
  }

  return lines.join("\n")
}

export function noteDocument(payload = {}) {
  const now = new Date().toISOString()
  return {
    v: 2,
    kind: "self_note",
    note_id: payload.note_id || crypto.randomUUID(),
    title: payload.title || "",
    body: payload.body || "",
    checklist: Array.isArray(payload.checklist) ? payload.checklist : [],
    labels: Array.isArray(payload.labels) ? payload.labels : [],
    color: normalizeSelfNoteColor(payload.color),
    pinned: !!payload.pinned,
    archived_at: payload.archived_at || null,
    trashed_at: payload.trashed_at || null,
    created_at: payload.created_at || now,
    updated_at: now,
    attachments: Array.isArray(payload.attachments) ? payload.attachments : [],
    settings: {move_checked_to_bottom: !!payload.settings?.move_checked_to_bottom},
    legacy_message_id: payload.legacy_message_id || null,
  }
}

export function mergeNoteDocuments(local, remote) {
  const checklist = [...(remote.checklist || []), ...(local.checklist || [])]
    .filter((item, index, all) =>
      all.findIndex((candidate) =>
        String(candidate.text || "").trim().toLowerCase() ===
          String(item.text || "").trim().toLowerCase()
      ) === index
    )
  const attachments = [...(remote.attachments || []), ...(local.attachments || [])]
    .filter((item, index, all) =>
      all.findIndex((candidate) => candidate.id === item.id) === index
    )
  const remoteBody = String(remote.body || "").trim()
  const localBody = String(local.body || "").trim()
  const body =
    remoteBody && localBody && remoteBody !== localBody
      ? `${remoteBody}\n\n--- Merged from this device ---\n\n${localBody}`
      : localBody || remoteBody

  return noteDocument({
    ...remote,
    ...local,
    title: local.title || remote.title,
    body,
    labels: [...new Set([...(remote.labels || []), ...(local.labels || [])])].slice(0, 10),
    checklist,
    attachments,
    updated_at: new Date().toISOString(),
  })
}

export function resolveNoteConflict(local, remote) {
  return new Promise((resolve) => {
    const dialog = document.createElement("dialog")
    dialog.className = "modal"

    const panel = document.createElement("div")
    panel.className = "modal-box max-w-3xl"
    const title = document.createElement("h3")
    title.className = "text-lg font-semibold"
    title.textContent = "This note changed on another device"
    const help = document.createElement("p")
    help.className = "mt-1 text-sm opacity-70"
    help.textContent = "Compare both encrypted versions. Nothing shown here is sent to the server."

    const comparison = document.createElement("div")
    comparison.className = "mt-4 grid gap-3 sm:grid-cols-2"
    ;[["Latest saved version", remote], ["Your unsaved version", local]].forEach(([label, note]) => {
      const card = document.createElement("section")
      card.className = "min-w-0 rounded-xl border border-base-300 bg-base-200/60 p-3"
      const heading = document.createElement("h4")
      heading.className = "text-xs font-semibold uppercase tracking-wide opacity-60"
      heading.textContent = label
      const noteTitle = document.createElement("p")
      noteTitle.className = "mt-2 truncate font-medium"
      noteTitle.textContent = note.title || "Untitled note"
      const body = document.createElement("p")
      body.className = "mt-1 max-h-40 overflow-y-auto whitespace-pre-wrap text-sm"
      body.textContent = note.body || "(No body text)"
      const details = document.createElement("p")
      details.className = "mt-2 text-xs opacity-60"
      details.textContent =
        `${(note.checklist || []).length} checklist item(s) · ` +
        `${(note.attachments || []).length} attachment(s)`
      card.append(heading, noteTitle, body, details)
      comparison.appendChild(card)
    })

    const actions = document.createElement("div")
    actions.className = "modal-action flex-wrap"
    const choice = (label, value, classes) => {
      const button = document.createElement("button")
      button.type = "button"
      button.className = classes
      button.textContent = label
      button.addEventListener("click", () => {
        dialog.close()
        dialog.remove()
        resolve(value)
      })
      actions.appendChild(button)
    }
    choice("Use latest", "latest", "btn btn-ghost")
    choice("Merge both", "merge", "btn btn-outline")
    choice("Keep mine", "local", "btn btn-primary")

    dialog.addEventListener("cancel", (event) => {
      event.preventDefault()
      dialog.close()
      dialog.remove()
      resolve("latest")
    })
    panel.append(title, help, comparison, actions)
    dialog.appendChild(panel)
    document.body.appendChild(dialog)
    dialog.showModal()
  })
}

export function normalizeNoteSearch(value) {
  return String(value ?? "")
    .normalize("NFKD")
    .replace(/\p{M}/gu, "")
    .toLocaleLowerCase()
    .replace(/\s+/g, " ")
    .trim()
}

export function noteSearchClauses(value) {
  const clauses = []
  const query = normalizeNoteSearch(value).replace(/[“”„‟«»]/g, "\"")

  for (const match of query.matchAll(/"([^"]*)"|"([^"]*)$|([^"\s]+)/g)) {
    const clause = normalizeNoteSearch(match[1] ?? match[2] ?? match[3])
    if (clause) clauses.push(clause)
  }

  return clauses
}

export function compareSelfNotes(left, right, sortBy = "updated") {
  const pinned =
    Number(!!right.pinned) - Number(!!left.pinned)

  if (pinned !== 0) return pinned

  if (sortBy === "title") {
    const title =
      normalizeNoteSearch(left.title || "Untitled note")
        .localeCompare(normalizeNoteSearch(right.title || "Untitled note"))

    if (title !== 0) return title
  }

  const dateField = sortBy === "created" ? "createdAt" : "updatedAt"
  const date =
    String(right[dateField] || "")
      .localeCompare(String(left[dateField] || ""))

  if (date !== 0) return date

  return normalizeNoteSearch(left.title || "Untitled note")
    .localeCompare(normalizeNoteSearch(right.title || "Untitled note"))
}

// --- When a note was written and last changed ---------------------------------
//
// Used by the timeline view. Notes carry their own created_at / updated_at
// inside the encrypted payload; older or imported notes may lack them, so the
// server's timestamps for the envelope stand in rather than showing nothing.

// An edit within this long of creation is the same sitting, not a revision.
const EDITED_AFTER_MS = 60_000

function validDate(value) {
  if (!value) return null
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? null : date
}

export function noteTimes({createdAt, updatedAt, serverCreatedAt, serverUpdatedAt} = {}) {
  const lastChange = validDate(updatedAt) || validDate(serverUpdatedAt)
  const created = validDate(createdAt) || validDate(serverCreatedAt) || lastChange
  const updated = lastChange || created
  const edited = !!(created && updated && updated.getTime() - created.getTime() > EDITED_AFTER_MS)
  return {created, updated, edited}
}

export function formatNoteTime(date, {locale, timeZone} = {}) {
  if (!date) return ""
  return new Intl.DateTimeFormat(locale, {dateStyle: "medium", timeStyle: "short", timeZone}).format(date)
}

export function relativeNoteTime(date, now = new Date(), {locale} = {}) {
  if (!date) return ""
  const seconds = Math.round((now.getTime() - date.getTime()) / 1000)
  if (seconds < 45) return "just now"
  const rtf = new Intl.RelativeTimeFormat(locale, {numeric: "auto"})
  const steps = [
    ["minute", 60, 3600],
    ["hour", 3600, 86400],
    ["day", 86400, 86400 * 30],
    ["month", 86400 * 30, 86400 * 365],
  ]
  for (const [unit, size, limit] of steps) {
    if (seconds < limit) return rtf.format(-Math.max(1, Math.round(seconds / size)), unit)
  }
  return rtf.format(-Math.max(1, Math.round(seconds / (86400 * 365))), "year")
}

// The heading a note falls under on the timeline: its month.
export function timelineGroupLabel(date, {locale, timeZone} = {}) {
  if (!date) return "Undated"
  return new Intl.DateTimeFormat(locale, {month: "long", year: "numeric", timeZone}).format(date)
}

// Newest first by creation or last edit. Pinning does not reorder a timeline,
// since the point of it is the order things happened in.
export function compareTimeline(left, right, sortBy = "updated") {
  const field = sortBy === "created" ? "createdAt" : "updatedAt"
  const a = validDate(left[field])?.getTime() ?? Number.NEGATIVE_INFINITY
  const b = validDate(right[field])?.getTime() ?? Number.NEGATIVE_INFINITY
  if (a !== b) return b > a ? 1 : -1
  return normalizeNoteSearch(left.title || "Untitled note")
    .localeCompare(normalizeNoteSearch(right.title || "Untitled note"))
}

export const selfNoteSearchIndex = new WeakMap()
