import {getSecretKey, openFrom, sealFor, sealLocal} from "../crypto.js"
import {pushWithReply} from "./shared.js"
import {collaborationState, searchableText} from "../collaboration.js"
import {requestKeyUnlock} from "../key_unlock.js"

function element(tag, text, className = "") {
  const node = document.createElement(tag)
  node.textContent = text
  node.className = className
  return node
}
function button(parent, text, action) {
  const node = element("button", text, "rounded-xl border border-base-300 px-3 py-2 text-sm transition hover:bg-base-200 disabled:opacity-50")
  node.type = "button"
  node.addEventListener("click", async () => {
    node.disabled = true
    try { await action() } finally { node.disabled = false }
  })
  parent.append(node)
  return node
}
function input(parent, label, type = "text") {
  const wrapper = element("label", label, "block space-y-1 text-sm font-medium")
  const node = document.createElement("input")
  node.type = type
  node.className = "block w-full rounded-xl border border-base-300 bg-base-100 px-3 py-2 outline-none focus:border-primary"
  wrapper.append(node)
  parent.append(wrapper)
  return node
}

export const PrivateWorkspace = {
  mounted() {
    this.entries = []
    this.tab = "search"
    this.content = this.el.querySelector("[data-content]")
    this.status = this.el.querySelector("[data-status]")
    this.onClick = (event) => {
      const tab = event.target.closest("[data-tab]")
      if (tab) { this.tab = tab.dataset.tab; this.render() }
      if (event.target.closest("[data-action=refresh]")) this.load()
    }
    this.el.addEventListener("click", this.onClick)
    this.handleEvent("workspace:refresh", () => {
      if (this.content.contains(document.activeElement) && document.activeElement.matches("input")) {
        this.status.textContent = "New shared updates are available. Refresh when you have finished editing."
      } else this.load()
    })
    this.load()
  },
  destroyed() {
    this.disposed = true
    this.entries = []
    this.el.removeEventListener("click", this.onClick)
  },
  async load() {
    if (this.loading) { this.refreshAgain = true; return }
    const secret = getSecretKey(this.el.dataset.userId)
    if (!secret) {
      this.status.textContent = "Unlock your private space to search and collaborate."
      this.content.replaceChildren()
      button(this.content, "Unlock", requestKeyUnlock)
      return
    }
    this.loading = true
    this.entries = []
    this.content.replaceChildren()
    try {
      let cursor = null
      do {
        this.status.textContent = `Reading encrypted history… ${this.entries.length} items`
        const page = await pushWithReply(this, "workspace_page", {cursor})
        if (this.disposed) return
        for (const entry of page.items) {
          // Searching must not spend or bypass view-limited messages.
          if (entry.max_displays !== null || entry.expires_at) continue
          const payload = openFrom(entry.ciphertext, entry.nonce, entry.peer_key, secret)
          if (payload) this.entries.push({...entry, payload})
        }
        cursor = page.cursor
      } while (cursor)
      const result = await pushWithReply(this, "workspace_recipients", {})
      if (this.disposed) return
      this.recipients = result.recipients
      this.status.textContent = `${this.entries.length} readable items. Search excludes expiring and view-limited messages. Shared updates appear after their message is accepted. Refresh to load new updates.`
      this.render()
    } catch (error) {
      this.status.textContent = error.message
    } finally {
      this.loading = false
      if (this.refreshAgain && !this.disposed) { this.refreshAgain = false; this.load() }
    }
  },
  render() {
    if (!this.recipients) return
    this.content.replaceChildren()
    this.el.querySelectorAll("[data-tab]").forEach((node) => node.setAttribute("aria-pressed", String(node.dataset.tab === this.tab)))
    if (this.tab === "search") return this.renderSearch()
    this.renderCreate()
    const active = this.entries.filter((e) => !e.expires_at || Date.parse(e.expires_at) > Date.now())
    const rooms = collaborationState(active).filter((room) => room.type === this.tab && room.members.some((m) => m.key === this.el.dataset.publicKey))
    for (const room of rooms) this.renderRoom(room)
    if (!rooms.length) this.content.append(element("p", "Nothing shared here yet.", "text-sm text-base-content/60"))
  },
  renderSearch() {
    const controls = element("div", "", "grid gap-3 sm:grid-cols-2")
    this.content.append(controls)
    const query = input(controls, "Search messages, notes and attachments")
    const person = input(controls, "Person (handle)")
    const after = input(controls, "From date", "date")
    const before = input(controls, "Through date", "date")
    const label = input(controls, "Note label")
    const attachment = input(controls, "Only items with attachments", "checkbox")
    attachment.className = "ml-2"
    const results = element("div", "", "space-y-3")
    results.setAttribute("aria-live", "polite")
    this.content.append(results)
    const search = () => {
      results.replaceChildren()
      const terms = query.value.toLocaleLowerCase().trim().split(/\s+/u).filter(Boolean)
      const matches = this.entries.filter((entry) => {
        if (entry.expires_at && Date.parse(entry.expires_at) <= Date.now()) return false
        const text = searchableText(entry.payload).toLocaleLowerCase()
        const date = entry.created_at.slice(0, 10)
        const people = [entry.sender, ...(Array.isArray(entry.payload.to) ? entry.payload.to : [])].join(" ").toLocaleLowerCase()
        return terms.every((term) => text.includes(term)) && (!person.value || people.includes(person.value.toLocaleLowerCase())) &&
          (!after.value || date >= after.value) && (!before.value || date <= before.value) &&
          (!label.value || (Array.isArray(entry.payload.labels) && entry.payload.labels.some((value) => typeof value === "string" && value.toLocaleLowerCase() === label.value.toLocaleLowerCase()))) &&
          (!attachment.checked || entry.payload.attachments?.length > 0)
      })
      results.append(element("p", `${matches.length} results`, "text-sm text-base-content/60"))
      for (const entry of matches.slice(0, 100)) {
        const card = element("article", "", "rounded-2xl border border-base-300 p-4")
        card.append(element("p", `${entry.sender} · ${new Date(entry.created_at).toLocaleString()}`, "text-xs text-base-content/60"))
        card.append(element("p", searchableText(entry.payload).slice(0, 600), "mt-2 whitespace-pre-wrap break-words"))
        const link = element("a", "Open", "mt-2 inline-block text-sm text-primary underline")
        link.href = entry.kind.startsWith("self_") ? "/messages?self_notes=true" : `/messages?conversation=${encodeURIComponent(entry.thread || "")}`
        card.append(link)
        results.append(card)
      }
      if (matches.length > 100) results.append(element("p", "Showing the first 100 matches. Narrow your search to see more.", "text-sm"))
    }
    controls.addEventListener("input", search)
    search()
  },
  renderCreate() {
    const form = element("form", "", "space-y-3 rounded-2xl border border-base-300 p-5")
    form.id = "workspace-create"
    form.append(element("h2", this.tab === "list" ? "Share a checklist" : "Ask your group", "text-lg font-semibold"))
    const title = input(form, this.tab === "list" ? "List title" : "Question")
    title.required = true
    title.maxLength = 200
    const choices = this.tab === "poll" ? input(form, "Choices (separate with commas)") : null
    const members = element("fieldset", "", "flex flex-wrap gap-3")
    members.append(element("legend", "Share with", "mb-2 text-sm font-medium"))
    for (const recipient of this.recipients.filter((r) => String(r.id) !== this.el.dataset.userId)) {
      const node = input(members, recipient.handle, "checkbox")
      node.className = "ml-2"
      node.value = recipient.id
    }
    form.append(members)
    const submit = element("button", "Share", "rounded-xl bg-primary px-4 py-2 font-semibold text-primary-content transition hover:opacity-90 disabled:opacity-50")
    form.append(submit)
    form.addEventListener("submit", async (event) => {
      event.preventDefault()
      const selected = [...members.querySelectorAll("input:checked")].map((n) => n.value)
      const recipients = this.recipients.filter((r) => selected.includes(r.id) || String(r.id) === this.el.dataset.userId)
      const options = choices ? [...new Set(choices.value.split(",").map((s) => s.trim()).filter(Boolean))] : []
      if (recipients.length < 2) { this.status.textContent = "Choose at least one friend."; return }
      if (recipients.length > 50) { this.status.textContent = "Share with at most 49 friends."; return }
      if (choices && (options.length < 2 || options.length > 20)) { this.status.textContent = "Enter between 2 and 20 distinct choices."; return }
      if (options.some((choice) => choice.length > 200)) { this.status.textContent = "Keep each poll choice within 200 characters."; return }
      submit.disabled = true
      try {
        await this.send({v: 1, id: `${this.el.dataset.publicKey}:${crypto.randomUUID()}`, action: "create", type: this.tab,
          title: title.value, choices: options, members: recipients.map((r) => ({handle: r.handle, key: r.public_key})), clock: 0, op_id: crypto.randomUUID()})
      } catch (error) { this.status.textContent = error.message } finally { submit.disabled = false }
    })
    this.content.append(form)
  },
  renderRoom(room) {
    const card = element("article", "", "space-y-3 rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm")
    card.append(element("h2", room.title, "text-lg font-semibold"))
    card.append(element("p", room.members.map((m) => m.handle).join(", "), "text-xs text-base-content/60"))
    const update = async (op) => {
      try { await this.send({v: 1, id: room.id, clock: room.clock + 1, op_id: crypto.randomUUID(), ...op}, room) }
      catch (error) { this.status.textContent = error.message }
    }
    if (room.type === "list") {
      for (const item of [...room.items.values()].filter((i) => !i.deleted).sort((a, b) => a.id.localeCompare(b.id))) {
        const row = element("div", "", "flex items-center gap-3")
        const check = input(row, item.text, "checkbox")
        check.className = "ml-2"
        check.checked = item.checked
        check.addEventListener("change", () => update({action: "item", item_id: item.id, text: item.text, checked: check.checked}))
        button(row, "Remove", () => update({action: "item", item_id: item.id, text: item.text, deleted: true}))
        card.append(row)
      }
      const text = input(card, "New item")
      text.maxLength = 1000
      button(card, "Add item", async () => { if (text.value.trim()) await update({action: "item", item_id: crypto.randomUUID(), text: text.value.trim(), checked: false}) })
    } else {
      for (const choice of room.choices || []) {
        const count = [...room.votes.values()].filter((v) => v.choice === choice).length
        const mine = room.votes.get(this.el.dataset.publicKey)?.choice === choice
        button(card, `${mine ? "✓ " : ""}${choice} · ${count}`, () => update({action: "vote", choice}))
      }
      const call = element("a", "Schedule a one-to-one call", "block text-sm text-primary underline")
      const friend = room.members.map((m) => this.recipients.find((r) => r.handle === m.handle))
        .find((r) => r && String(r.id) !== this.el.dataset.userId)
      call.href = friend ? `/calls?friend_id=${encodeURIComponent(friend.id)}` : "/calls"
      call.addEventListener("click", () => {
        const secret = getSecretKey(this.el.dataset.userId)
        if (!secret) return
        const counts = room.choices.map((choice) => ({choice, count: [...room.votes.values()].filter((v) => v.choice === choice).length}))
        const highest = Math.max(0, ...counts.map((c) => c.count))
        const winners = counts.filter((c) => c.count === highest && highest > 0).map((c) => c.choice)
        sessionStorage.setItem(`veejr:poll-call:${this.el.dataset.userId}`, JSON.stringify(sealLocal({title: room.title, choices: winners, createdAt: Date.now()}, secret)))
      })
      card.append(call)
    }
    this.content.append(card)
  },
  async send(operation, room = operation) {
    const secret = getSecretKey(this.el.dataset.userId)
    if (!secret) throw new Error("Unlock your private space first.")
    const recipients = room.members.map((member) => this.recipients.find((r) => r.handle === member.handle && r.public_key === member.key))
    if (recipients.some((r) => !r)) throw new Error("Every participant must be your friend with the same verified key before you can send an update.")
    const payload = {v: 1, kind: "message", text: `${room.type === "poll" ? "Poll" : "Shared list"}: ${room.title || "Update"} — open Private workspace`,
      to: room.members.map((m) => m.handle), collaboration: operation, sent_at: new Date().toISOString()}
    const envelopes = recipients.map((r) => ({recipient_id: Number(r.id), ...sealFor(r.public_key, payload, secret)}))
    await pushWithReply(this, "workspace_send", {envelopes, client_batch_id: operation.op_id})
    await this.load()
  },
}
