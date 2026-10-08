// Sending a note as a message.
//
// The dialog lets someone pick who to send to, tidy the text, and choose a card
// (see ../cards.js). It then does exactly what the composer does for a message —
// resolve the recipients, seal the payload to each of them and to the sender —
// so the server sees the same kind of encrypted envelope it would for any
// message, and nothing about the note it came from.

import {getSecretKey, sealFor} from "../crypto.js"
import {createCardPicker} from "../cards.js"
import {noteAsMessageText} from "./notes_document.js"
import {pushWithReply} from "./shared.js"

const BUTTON = "btn btn-sm"

function el(doc, tag, className, text) {
  const node = doc.createElement(tag)
  if (className) node.className = className
  if (text !== undefined) node.textContent = text
  return node
}

/**
 * Opens the "send as a message" dialog for a note.
 *
 * `hook` is the LiveView hook used to talk to the server, `targets` the
 * friends and groups the sender can pick, and `myKey` the sender's own public
 * key, which receives a copy so their history shows what they sent.
 */
export function openNoteSendDialog({hook, payload, targets, userId, myKey, doc = document}) {
  const dialog = el(doc, "dialog", "m-auto w-[min(34rem,calc(100vw-2rem))] rounded-3xl bg-transparent p-0 backdrop:bg-black/50")
  dialog.dataset.role = "note-send-dialog"

  const panel = el(doc, "form", "max-h-[88vh] space-y-4 overflow-y-auto rounded-3xl bg-base-100 p-5 text-base-content shadow-2xl")
  panel.method = "dialog"
  dialog.appendChild(panel)

  panel.appendChild(el(doc, "h2", "text-lg font-semibold", "Send as a message"))

  // ── Who to ──
  const toBlock = el(doc, "fieldset", "space-y-2")
  toBlock.appendChild(el(doc, "legend", "mb-1 text-xs font-medium uppercase tracking-wide opacity-70", "To"))

  const picks = []
  if (targets.length === 0) {
    toBlock.appendChild(el(doc, "p", "text-sm opacity-70", "You have no friends or groups to send to yet."))
  }

  const list = el(doc, "div", "flex max-h-40 flex-wrap gap-2 overflow-y-auto")
  for (const target of targets) {
    const label = el(doc, "label", "flex cursor-pointer items-center gap-2 rounded-full border border-base-300 px-3 py-1 text-sm has-[:checked]:border-primary has-[:checked]:bg-primary/10")
    const box = el(doc, "input", "checkbox checkbox-xs")
    box.type = "checkbox"
    box.dataset.targetType = target.type
    box.value = String(target.id)
    label.append(box, el(doc, "span", "", target.type === "group" ? `👥 ${target.label}` : target.label))
    list.appendChild(label)
    picks.push(box)
  }
  toBlock.appendChild(list)
  panel.appendChild(toBlock)

  // ── The text ──
  const textLabel = el(doc, "label", "block text-xs font-medium uppercase tracking-wide opacity-70", "Message")
  const text = el(doc, "textarea", "textarea textarea-bordered mt-1 min-h-32 w-full text-sm font-normal normal-case tracking-normal")
  text.value = noteAsMessageText(payload)
  textLabel.appendChild(text)
  panel.appendChild(textLabel)

  if ((payload.attachments || []).length > 0) {
    panel.appendChild(el(doc, "p", "text-xs opacity-70", "Attachments on the note are not sent."))
  }

  // ── The card ──
  const picker = createCardPicker(doc)
  picker.setText(text.value)
  text.addEventListener("input", () => picker.setText(text.value))
  panel.appendChild(picker.el)

  const error = el(doc, "p", "hidden text-sm text-error")
  error.setAttribute("role", "alert")
  panel.appendChild(error)

  // ── Buttons ──
  const buttons = el(doc, "div", "flex justify-end gap-2")
  const cancel = el(doc, "button", `${BUTTON} btn-ghost`, "Cancel")
  cancel.type = "button"
  const send = el(doc, "button", `${BUTTON} btn-primary`, "Send")
  send.type = "submit"
  buttons.append(cancel, send)
  panel.appendChild(buttons)

  const close = () => {
    dialog.close()
    dialog.remove()
  }
  cancel.addEventListener("click", close)
  dialog.addEventListener("cancel", (event) => {
    event.preventDefault()
    close()
  })

  panel.addEventListener("submit", async (event) => {
    event.preventDefault()
    error.classList.add("hidden")
    send.disabled = true
    send.textContent = "Sending…"

    try {
      await sendNoteAsMessage({
        hook,
        userId,
        myKey,
        text: text.value.trim(),
        card: picker.value(),
        friendIds: picks.filter((box) => box.checked && box.dataset.targetType === "friend").map((box) => box.value),
        groupIds: picks.filter((box) => box.checked && box.dataset.targetType === "group").map((box) => box.value),
      })
      close()
    } catch (failure) {
      error.textContent = failure.message
      error.classList.remove("hidden")
      send.disabled = false
      send.textContent = "Send"
    }
  })

  doc.body.appendChild(dialog)
  dialog.showModal()
  return dialog
}

/**
 * Resolves the recipients, seals one payload to each of them and to the
 * sender, and sends the batch. Throws an error with a message fit to show.
 */
export async function sendNoteAsMessage({hook, userId, myKey, text, card, friendIds, groupIds}) {
  if (!text) throw new Error("There is nothing to send.")
  if (friendIds.length + groupIds.length === 0) throw new Error("Pick at least one recipient.")

  const secret = getSecretKey(userId)
  if (!secret) throw new Error("Unlock your keys before sending.")

  const {recipients, missing_keys} = await pushWithReply(hook, "resolve_recipients", {
    friend_ids: friendIds,
    group_ids: groupIds,
    include_self: false,
  })
  if (missing_keys.length > 0) {
    throw new Error(`No encryption keys yet: ${missing_keys.join(", ")}. They must finish key setup first.`)
  }
  if (recipients.length === 0) throw new Error("Nobody to send to.")

  const payload = {
    v: 1,
    kind: "message",
    text,
    attachments: [],
    to: recipients.map((r) => r.handle || `@${r.username}`),
    sent_at: new Date().toISOString(),
    ...(card ? {card} : {}),
  }

  const envelopes = recipients.map((r) => ({recipient_id: r.id, ...sealFor(r.public_key, payload, secret)}))
  // Our own copy, so the conversation shows what we sent.
  if (!recipients.some((r) => String(r.id) === String(userId))) {
    envelopes.push({recipient_id: parseInt(userId, 10), ...sealFor(myKey, payload, secret)})
  }

  await pushWithReply(hook, "send_batch", {
    kind: "message",
    envelopes,
    client_batch_id: crypto.randomUUID(),
  })
}
