// Operations travel as ordinary authenticated encrypted messages. Membership
// is fixed by the creator. Per-item Lamport clocks make delivery order irrelevant.
export function collaborationState(entries) {
  const rooms = new Map()
  const valid = entries.filter(({payload}) => payload?.collaboration?.v === 1)
    .sort((a, b) => String(a.payload.collaboration.op_id).localeCompare(String(b.payload.collaboration.op_id)))
  for (const entry of valid) {
    const op = entry.payload.collaboration
    if (op.action !== "create" || !["list", "poll"].includes(op.type)) continue
    if (typeof op.title !== "string" || op.title.length > 200) continue
    if (op.type === "poll" && (!Array.isArray(op.choices) || op.choices.length < 2 || op.choices.length > 20 || !op.choices.every((c) => typeof c === "string" && c.length <= 200))) continue
    if (typeof op.id !== "string" || !op.id.startsWith(`${entry.peer_key}:`)) continue
    if (!Array.isArray(op.members) || op.members.length < 2 || op.members.length > 50) continue
    if (!op.members.every((m) => m && typeof m.key === "string" && typeof m.handle === "string")) continue
    if (!op.members.some((m) => m.key === entry.peer_key)) continue
    if (rooms.has(op.id)) continue
    rooms.set(op.id, {...op, items: new Map(), votes: new Map(), clock: 0})
  }
  for (const entry of valid) {
    const op = entry.payload.collaboration
    const room = rooms.get(op.id)
    if (!room || !room.members.some((m) => m.key === entry.peer_key)) continue
    if (!Number.isSafeInteger(op.clock) || op.clock < 0 || op.clock > 1e12 || typeof op.op_id !== "string") continue
    room.clock = Math.max(room.clock, op.clock)
    const stamp = [op.clock, op.op_id]
    const newer = (old) => !old || stamp[0] > old.stamp[0] || (stamp[0] === old.stamp[0] && stamp[1] > old.stamp[1])
    if (room.type === "list" && op.action === "item" && typeof op.item_id === "string" && typeof op.text === "string") {
      const old = room.items.get(op.item_id)
      if (newer(old)) room.items.set(op.item_id, {id: op.item_id, text: op.text.slice(0, 1000), checked: op.checked === true, deleted: op.deleted === true, stamp})
    }
    if (room.type === "poll" && op.action === "vote" && Array.isArray(room.choices) && room.choices.includes(op.choice)) {
      const old = room.votes.get(entry.peer_key)
      if (newer(old)) room.votes.set(entry.peer_key, {choice: op.choice, stamp})
    }
  }
  return [...rooms.values()]
}

export function searchableText(payload) {
  const items = Array.isArray(payload.items) ? payload.items.map((item) => item?.text) : []
  const blocks = Array.isArray(payload.page?.blocks) ? payload.page.blocks.map((block) => block?.text) : []
  const cells = Object.values(payload.sheet?.cells || {}).map((cell) => cell?.v ?? cell?.f ?? "")
  return [payload.text, payload.title, payload.body, ...items, ...blocks, ...cells,
    ...(Array.isArray(payload.labels) ? payload.labels : []),
    ...(Array.isArray(payload.attachments) ? payload.attachments.map((a) => a.name) : [])]
    .filter((v) => typeof v === "string" || typeof v === "number").join(" ")
}
