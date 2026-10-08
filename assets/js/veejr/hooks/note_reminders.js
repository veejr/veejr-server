import {describeScheduledTime, isoToLocalDateTime, localDateTimeIn, localDateTimeToIso} from "../schedule_time.js"

export function matchesNoteFilter(filter, {archived, trashed, remindAt}) {
  if (filter === "trashed") return trashed
  if (trashed) return false
  if (filter === "reminders") return !!remindAt && Number.isFinite(Date.parse(remindAt))
  return filter === "archived" ? archived : !archived
}

export function reminderLabel(remindAt, remindedAt) {
  if (!remindAt) return "Remind me"
  return remindedAt ? `${new Date(remindAt).toLocaleString()} (delivered)` : describeScheduledTime(remindAt)
}

// This dialog contains only timing metadata. Note content stays on the card.
export function openNoteReminderDialog({current, save, doc = document}) {
  const make = (tag, className, text) => {
    const node = doc.createElement(tag)
    node.className = className
    if (text) node.textContent = text
    return node
  }
  const dialog = make("dialog", "m-auto w-[min(28rem,calc(100vw-2rem))] rounded-3xl bg-base-100 p-6 text-base-content shadow-2xl backdrop:bg-black/50")
  dialog.id = "self-note-reminder-dialog"
  dialog.setAttribute("aria-labelledby", "self-note-reminder-heading")
  const heading = make("h2", "text-lg font-semibold", current ? "Change reminder" : "Remind me")
  heading.id = "self-note-reminder-heading"
  const form = make("form", "mt-4 space-y-4")
  const label = make("label", "block text-sm font-medium", "Date and time (your local time)")
  label.htmlFor = "self-note-reminder-time"
  const input = make("input", "mt-2 w-full rounded-xl border border-base-300 bg-base-100 p-3 text-sm outline-none transition focus:border-primary focus:ring-2 focus:ring-primary/20")
  input.id = "self-note-reminder-time"
  input.type = "datetime-local"
  input.required = true
  input.value = current ? isoToLocalDateTime(current) : localDateTimeIn(60)
  const privacy = make("p", "text-xs text-base-content/60", "The reminder time is stored unencrypted so it can be delivered. Your note stays encrypted. Enable device notifications to receive reminders when this page is closed.")
  const error = make("p", "hidden text-sm text-error")
  error.setAttribute("role", "alert")
  const actions = make("div", "flex flex-wrap justify-end gap-2")
  const button = (text, classes) => {
    const node = make("button", `rounded-xl px-4 py-2 text-sm font-semibold transition disabled:opacity-50 ${classes}`, text)
    node.type = "button"
    actions.appendChild(node)
    return node
  }
  const clear = current ? button("Clear reminder", "mr-auto text-error hover:bg-error/10") : null
  const cancel = button("Cancel", "hover:bg-base-200")
  const submit = button("Save reminder", "bg-primary text-primary-content hover:opacity-90")
  submit.type = "submit"
  form.append(label, input, privacy, error, actions)
  dialog.append(heading, form)
  const close = () => { dialog.close(); dialog.remove() }
  cancel.addEventListener("click", close)
  dialog.addEventListener("cancel", (event) => { event.preventDefault(); close() })
  let saving = false
  const persist = async (value) => {
    if (saving) return
    saving = true
    actions.querySelectorAll("button").forEach((node) => { node.disabled = true })
    error.classList.add("hidden")
    try {
      await save(value)
      close()
    } catch (failure) {
      error.textContent = failure.message || "The reminder could not be saved."
      error.classList.remove("hidden")
    } finally {
      saving = false
      actions.querySelectorAll("button").forEach((node) => { node.disabled = false })
    }
  }
  clear?.addEventListener("click", () => persist(null))
  form.addEventListener("submit", (event) => {
    event.preventDefault()
    const value = localDateTimeToIso(input.value)
    if (!value || Date.parse(value) <= Date.now()) {
      error.textContent = "Pick a date and time in the future."
      error.classList.remove("hidden")
      return
    }
    return persist(value)
  })
  doc.body.appendChild(dialog)
  dialog.showModal()
  return dialog
}
