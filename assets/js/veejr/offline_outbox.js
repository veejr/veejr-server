import {getSecretKey, sealLocal, openLocal, sealLocalBlob, openLocalBlob, sealFor} from "./crypto.js"
import {csrfToken, encryptAndUpload} from "./hooks/shared.js"

async function transact(mode, work) {
  const db = await new Promise((resolve, reject) => {
    const request = indexedDB.open("veejr-outbox", 1)
    request.onupgradeneeded = () => request.result.createObjectStore("messages", {keyPath: "id"})
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })
  return new Promise((resolve, reject) => {
    const tx = db.transaction("messages", mode)
    const request = work(tx.objectStore("messages"))
    tx.oncomplete = () => { db.close(); resolve(request.result) }
    tx.onabort = () => { db.close(); reject(tx.error) }
    tx.onerror = () => reject(tx.error)
  })
}

const records = () => transact("readonly", (store) => store.getAll())
const put = (record) => transact("readwrite", (store) => store.put(record))
const remove = (id) => transact("readwrite", (store) => store.delete(id))

export async function enqueueMessage(userId, snapshot, files, secret) {
  const media = []
  for (const entry of files) {
    const file = entry.file || entry
    media.push({sealed: await sealLocalBlob(file, secret), metadata: sealLocal({name: file.name, mime: file.type, size: file.size, durationMs: entry.durationMs}, secret)})
  }
  await put({id: snapshot.id, userId: String(userId), sealed: sealLocal(snapshot, secret), media})
  window.dispatchEvent(new Event("veejr:outbox-change"))
}

async function post(url, payload) {
  const response = await fetch(url, {method: "POST", redirect: "error", headers: {"content-type": "application/json", "x-csrf-token": csrfToken()}, body: JSON.stringify(payload)})
  const result = await response.json()
  if (!response.ok || result.error) throw new Error(result.error || `Request failed (${response.status})`)
  return result
}

async function deliver(record, secret, myKey) {
  const draft = openLocal(record.sealed, secret)
  if (!draft) throw new Error("Unlock with the original identity key to send this message.")
  // Persist the exact sealed batch before sending. A lost response can then
  // retry the same batch id and ciphertext without creating another message.
  if (!draft.batch) {
    const result = await post("/outbox/recipients", draft.selection)
    if (result.missing_keys.length || !result.recipients.length) throw new Error("Some recipients have no encryption keys.")
    const expected = draft.recipients || []
    if (expected.length !== result.recipients.length || expected.some((r) => !result.recipients.some((fresh) => fresh.id === r.id && fresh.public_key === r.public_key))) {
      throw new Error("Recipients or encryption keys changed. Cancel this queued item and send it again after reviewing the recipients.")
    }
    const attachments = []
    for (const entry of record.media) {
      const meta = openLocal(entry.metadata, secret)
      const blob = meta && await openLocalBlob(entry.sealed, secret, meta.mime)
      if (!blob) throw new Error("A queued attachment could not be decrypted.")
      attachments.push(await encryptAndUpload(new File([blob], meta.name, {type: meta.mime}), meta))
    }
    const payload = {...draft.payload, attachments, to: result.recipients.map((r) => r.handle)}
    const recipients = result.recipients
    if (!recipients.some((r) => String(r.id) === record.userId)) recipients.push({id: record.userId, public_key: myKey})
    const options = {...draft.options}
    if (draft.ttl) options.expires_at = new Date(Date.now() + draft.ttl * 1000).toISOString()
    if (options.deliver_at && Date.parse(options.deliver_at) <= Date.now()) throw new Error("The scheduled send time has passed. Cancel this item and choose a new time.")
    draft.batch = {kind: draft.kind, client_batch_id: draft.id, envelopes: recipients.map((r) => ({recipient_id: Number(r.id), ...sealFor(r.public_key, payload, secret)})), ...options, attachment_ids: attachments.map((a) => a.id)}
    record.sealed = sealLocal(draft, secret)
    record.media = []
    await put(record)
  }
  await post("/outbox/messages", draft.batch)
  await remove(record.id)
}

export const OfflineOutbox = {
  mounted() {
    this.onChange = () => this.refresh()
    this.onOnline = () => this.flush()
    this.onClick = async (event) => {
      const cancel = event.target.closest("[data-cancel]")
      if (cancel) {
        await navigator.locks.request(`veejr:outbox:${this.el.dataset.userId}`, async () => remove(cancel.dataset.cancel))
        await this.refresh()
      }
      if (event.target.closest("[data-retry]")) await this.flush()
    }
    window.addEventListener("online", this.onOnline)
    window.addEventListener("veejr:connection-state", this.onOnline)
    window.addEventListener("veejr:outbox-change", this.onChange)
    this.el.addEventListener("click", this.onClick)
    this.timer = setInterval(() => this.flush(), 30_000)
    this.flush()
  },
  destroyed() {
    this.disposed = true
    clearInterval(this.timer)
    window.removeEventListener("online", this.onOnline)
    window.removeEventListener("veejr:connection-state", this.onOnline)
    window.removeEventListener("veejr:outbox-change", this.onChange)
    this.el.removeEventListener("click", this.onClick)
  },
  async refresh() {
    if (this.disposed) return
    const entries = (await records()).filter((r) => r.userId === this.el.dataset.userId)
    if (this.disposed) return
    this.el.replaceChildren()
    this.el.hidden = !entries.length
    if (!entries.length) return
    const summary = document.createElement("p")
    summary.textContent = `${entries.length} queued message${entries.length === 1 ? "" : "s"}${this.error ? ` · ${this.error}` : ""}`
    this.el.append(summary)
    const secret = getSecretKey(this.el.dataset.userId)
    for (const record of entries) {
      const row = document.createElement("div")
      row.className = "mt-2 flex items-center gap-3"
      const text = document.createElement("span")
      const draft = secret && openLocal(record.sealed, secret)
      text.textContent = draft ? (draft.payload.text || "Message with attachments").slice(0, 100) : "Encrypted queued message"
      const cancel = document.createElement("button")
      cancel.type = "button"
      cancel.dataset.cancel = record.id
      cancel.textContent = "Cancel"
      cancel.className = "ml-auto underline"
      row.append(text, cancel)
      this.el.append(row)
    }
    const retry = document.createElement("button")
    retry.type = "button"
    retry.dataset.retry = "true"
    retry.textContent = "Retry now"
    retry.className = "mt-2 underline"
    this.el.append(retry)
  },
  async flush() {
    if (this.busy || this.disposed || !navigator.onLine) return
    this.busy = true
    try {
      await navigator.locks.request(`veejr:outbox:${this.el.dataset.userId}`, {ifAvailable: true}, async (lock) => {
        if (!lock || this.disposed) return
        const secret = getSecretKey(this.el.dataset.userId)
        if (!secret) { this.error = "Unlock to send"; return }
        this.error = ""
        for (const record of (await records()).filter((r) => r.userId === this.el.dataset.userId)) {
          if (this.disposed || !getSecretKey(this.el.dataset.userId)) break
          try { await deliver(record, secret, this.el.dataset.publicKey) }
          catch (error) { this.error = error.message; break }
        }
      })
      await this.refresh()
    } catch (error) { this.error = error.message } finally { this.busy = false }
  },
}
