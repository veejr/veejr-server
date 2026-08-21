import {openLocalBlob, sealLocalBlob} from "./crypto.js"

const DB_NAME = "veejr-local-drafts"
const STORE_NAME = "media"

function database() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, 1)
    request.addEventListener("upgradeneeded", () => {
      if (!request.result.objectStoreNames.contains(STORE_NAME)) {
        request.result.createObjectStore(STORE_NAME, {keyPath: "id"})
      }
    })
    request.addEventListener("success", () => resolve(request.result))
    request.addEventListener("error", () => reject(request.error))
  })
}

function transaction(mode, operation) {
  return database().then((db) => new Promise((resolve, reject) => {
    const tx = db.transaction(STORE_NAME, mode)
    const result = operation(tx.objectStore(STORE_NAME))
    tx.addEventListener("complete", () => { db.close(); resolve(result) })
    tx.addEventListener("abort", () => { db.close(); reject(tx.error) })
    tx.addEventListener("error", () => reject(tx.error))
  }))
}

export async function saveDraftMedia(draftKey, entries, secretKey) {
  if (!("indexedDB" in window)) return []
  const records = []
  for (const [index, entry] of entries.entries()) {
    const file = entry.file || entry
    const id = `${draftKey}:${index}:${file.name}:${file.lastModified || 0}`
    const sealed = await sealLocalBlob(file, secretKey)
    records.push({
      id,
      draftKey,
      name: file.name,
      mime: file.type,
      size: file.size,
      lastModified: file.lastModified || Date.now(),
      durationMs: entry.durationMs || null,
      ...sealed,
    })
  }
  await deleteDraftMedia(draftKey)
  if (records.length) await transaction("readwrite", (store) => records.forEach((record) => store.put(record)))
  return records.map(({id}) => id)
}

export async function loadDraftMedia(draftKey, secretKey) {
  if (!("indexedDB" in window)) return []
  const records = await transaction("readonly", (store) => new Promise((resolve, reject) => {
    const request = store.getAll()
    request.addEventListener("success", () => resolve(request.result.filter((record) => record.draftKey === draftKey)))
    request.addEventListener("error", () => reject(request.error))
  }))
  const entries = []
  for (const record of await records) {
    const blob = await openLocalBlob(record, secretKey, record.mime)
    if (!blob) continue
    const file = new File([blob], record.name, {type: record.mime, lastModified: record.lastModified})
    entries.push({file, durationMs: record.durationMs, kind: record.mime.startsWith("audio/") ? "audio" : record.mime.startsWith("video/") ? "video" : "file"})
  }
  return entries
}

export async function deleteDraftMedia(draftKey) {
  if (!("indexedDB" in window)) return
  const keys = await transaction("readonly", (store) => new Promise((resolve, reject) => {
    const request = store.getAllKeys()
    request.addEventListener("success", () => resolve(request.result))
    request.addEventListener("error", () => reject(request.error))
  }))
  await transaction("readwrite", (store) => keys.filter((key) => String(key).startsWith(`${draftKey}:`)).forEach((key) => store.delete(key)))
}
