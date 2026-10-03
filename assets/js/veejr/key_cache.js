// Browser-local unlock policy. Only an explicit timed policy persists a key
// across browser restarts. The passphrase is never stored.
const sessionKey = id => `veejr:sk:${id}`
const rememberedKey = id => `veejr:remembered-sk:${id}`
const policyKey = id => `veejr:unlock-minutes:${id}`
const revisionKey = id => `veejr:key-revision:${id}`
export const MAX_UNLOCK_MINUTES = 30 * 24 * 60

export function getUnlockMinutes(id) {
  try {
    const value = Number(localStorage.getItem(policyKey(id)))
    return Number.isInteger(value) && value >= 1 && value <= MAX_UNLOCK_MINUTES ? value : 0
  } catch { return 0 }
}

export function setUnlockMinutes(id, minutes) {
  if (!Number.isInteger(minutes) || minutes < 0 || minutes > MAX_UNLOCK_MINUTES) {
    throw new Error("Choose a duration between 1 minute and 30 days.")
  }
  // Storage failures are surfaced to the settings form, never reported as saved.
  localStorage.setItem(policyKey(id), String(minutes))
  // A policy change locks existing sessions. The next successful unlock starts
  // the new duration; simply visiting a page never extends the deadline.
  forgetSecretKey(id)
}

export function cacheSecretKey(id, secret) {
  const minutes = getUnlockMinutes(id)
  const record = JSON.stringify({
    key: btoa(String.fromCharCode(...secret)),
    expiresAt: minutes ? Date.now() + minutes * 60_000 : null,
    revision: localStorage.getItem(revisionKey(id)),
  })
  sessionStorage.removeItem(sessionKey(id))
  localStorage.removeItem(rememberedKey(id))
  const storage = minutes ? localStorage : sessionStorage
  storage.setItem(minutes ? rememberedKey(id) : sessionKey(id), record)
}

export function getSecretKey(id) {
  try {
    const minutes = getUnlockMinutes(id)
    const storage = minutes ? localStorage : sessionStorage
    const name = minutes ? rememberedKey(id) : sessionKey(id)
    const raw = storage.getItem(name)
    if (!raw) return null
    const record = JSON.parse(raw)
    if (record.revision !== localStorage.getItem(revisionKey(id)) ||
        (minutes && (!Number.isFinite(record.expiresAt) || record.expiresAt <= Date.now())) ||
        (!minutes && record.expiresAt !== null)) {
      storage.removeItem(name)
      return null
    }
    const secret = Uint8Array.from(atob(record.key), c => c.charCodeAt(0))
    if (secret.length !== 32) throw new Error("Invalid cached key")
    return secret
  } catch {
    // Old unbounded cache entries, malformed JSON and unavailable storage all
    // fail closed. A normal unlock will replace an obsolete cache entry.
    return null
  }
}

export function forgetSecretKey(id) {
  sessionStorage.removeItem(sessionKey(id))
  localStorage.removeItem(rememberedKey(id))
  // Invalidates session-only copies in other tabs too.
  localStorage.setItem(revisionKey(id), crypto.randomUUID())
}
