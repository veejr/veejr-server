// Client-side E2E crypto for veejr.
//
// Everything in this module runs in the browser. The server only ever sees:
//   - public keys
//   - the secret key encrypted under a passphrase-derived key (for roaming)
//   - message ciphertext + nonces
//
// Primitives (via tweetnacl):
//   - nacl.box        X25519 + XSalsa20-Poly1305 (messages, per recipient)
//   - nacl.secretbox  XSalsa20-Poly1305 (secret-key wrapping, attachments)
//   - PBKDF2-SHA256 (WebCrypto) for passphrase -> key derivation

import nacl from "../../vendor/tweetnacl.min.js"

const PBKDF2_ITERATIONS = 310_000

export function toB64(bytes) {
  let bin = ""
  for (const b of bytes) bin += String.fromCharCode(b)
  return btoa(bin)
}

export function fromB64(str) {
  const bin = atob(str)
  const bytes = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
  return bytes
}

const te = new TextEncoder()
const td = new TextDecoder()

async function deriveKey(passphrase, salt) {
  const material = await crypto.subtle.importKey("raw", te.encode(passphrase), "PBKDF2", false, [
    "deriveBits",
  ])
  const bits = await crypto.subtle.deriveBits(
    {name: "PBKDF2", hash: "SHA-256", salt, iterations: PBKDF2_ITERATIONS},
    material,
    256
  )
  return new Uint8Array(bits)
}

// Wraps an existing raw secret key under a (new) passphrase — used for both
// initial setup and passphrase changes.
export async function wrapSecretKey(secretKey, passphrase) {
  const salt = crypto.getRandomValues(new Uint8Array(16))
  const nonce = crypto.getRandomValues(new Uint8Array(nacl.secretbox.nonceLength))
  const kek = await deriveKey(passphrase, salt)
  const wrapped = nacl.secretbox(secretKey, nonce, kek)
  return {encSecretKey: toB64(wrapped), keySalt: toB64(salt), keyNonce: toB64(nonce)}
}

// Generates a fresh identity keypair and wraps the secret key with the
// passphrase. Returns everything the server may store, plus the raw secret
// key for the local session cache.
export async function generateIdentity(passphrase) {
  const pair = nacl.box.keyPair()
  const wrapped = await wrapSecretKey(pair.secretKey, passphrase)
  return {
    publicKey: toB64(pair.publicKey),
    ...wrapped,
    secretKey: pair.secretKey,
  }
}

// Guest calls use a tab-local identity that is never uploaded or wrapped for
// roaming. Only its public half is sent to the host for this conference.
export function generateEphemeralIdentity() {
  const pair = nacl.box.keyPair()
  return {publicKey: toB64(pair.publicKey), secretKey: pair.secretKey}
}

// Unwraps the roaming secret key with the passphrase. Returns null when the
// passphrase is wrong (secretbox authentication fails).
export async function unlockIdentity(passphrase, encSecretKeyB64, keySaltB64, keyNonceB64) {
  const kek = await deriveKey(passphrase, fromB64(keySaltB64))
  return nacl.secretbox.open(fromB64(encSecretKeyB64), fromB64(keyNonceB64), kek)
}

// Encrypts a JS object to one recipient. Authenticated: the recipient can
// verify it came from the holder of our secret key.
export function sealFor(recipientPublicKeyB64, payload, mySecretKey) {
  const nonce = crypto.getRandomValues(new Uint8Array(nacl.box.nonceLength))
  const box = nacl.box(te.encode(JSON.stringify(payload)), nonce, fromB64(recipientPublicKeyB64), mySecretKey)
  return {ciphertext: toB64(box), nonce: toB64(nonce)}
}

// Decrypts an envelope from a sender. Returns the payload object, or null if
// authentication fails (tampered, wrong keys).
export function openFrom(ciphertextB64, nonceB64, senderPublicKeyB64, mySecretKey) {
  const plain = nacl.box.open(fromB64(ciphertextB64), fromB64(nonceB64), fromB64(senderPublicKeyB64), mySecretKey)
  if (!plain) return null
  try {
    return JSON.parse(td.decode(plain))
  } catch {
    return null
  }
}

// Attachments: encrypted once with a random symmetric key; that key rides
// inside each recipient's envelope payload, so the blob is stored/shared once.
export function encryptBlob(bytes) {
  const key = crypto.getRandomValues(new Uint8Array(nacl.secretbox.keyLength))
  const nonce = crypto.getRandomValues(new Uint8Array(nacl.secretbox.nonceLength))
  return {data: nacl.secretbox(bytes, nonce, key), key: toB64(key), nonce: toB64(nonce)}
}

export function decryptBlob(cipherBytes, keyB64, nonceB64) {
  return nacl.secretbox.open(cipherBytes, fromB64(nonceB64), fromB64(keyB64))
}

// Encrypts small browser-local JSON documents, such as message drafts, with
// the unlocked identity secret. Persisted values remain opaque while locked.
export function sealLocal(payload, secretKey) {
  const nonce = crypto.getRandomValues(new Uint8Array(nacl.secretbox.nonceLength))
  const ciphertext = nacl.secretbox(te.encode(JSON.stringify(payload)), nonce, secretKey)
  return {ciphertext: toB64(ciphertext), nonce: toB64(nonce)}
}

export function openLocal(value, secretKey) {
  try {
    const plain = nacl.secretbox.open(
      fromB64(value.ciphertext),
      fromB64(value.nonce),
      secretKey
    )
    return plain ? JSON.parse(td.decode(plain)) : null
  } catch {
    return null
  }
}

// Large local drafts (recordings and attachments) stay in IndexedDB as
// encrypted binary rather than being squeezed into localStorage JSON.
export async function sealLocalBlob(blob, secretKey) {
  const nonce = crypto.getRandomValues(new Uint8Array(nacl.secretbox.nonceLength))
  const ciphertext = nacl.secretbox(new Uint8Array(await blob.arrayBuffer()), nonce, secretKey)
  return {ciphertext: new Blob([ciphertext]), nonce: toB64(nonce)}
}

export async function openLocalBlob(value, secretKey, mime = "application/octet-stream") {
  try {
    const ciphertext = new Uint8Array(await value.ciphertext.arrayBuffer())
    const plain = nacl.secretbox.open(ciphertext, fromB64(value.nonce), secretKey)
    return plain ? new Blob([plain], {type: mime}) : null
  } catch {
    return null
  }
}

// --- Session key cache -------------------------------------------------
//
// The unlocked secret key lives in sessionStorage only: it survives page
// navigation but is dropped when the tab closes.

const cacheKey = (userId) => `veejr:sk:${userId}`

export function cacheSecretKey(userId, secretKey) {
  sessionStorage.setItem(cacheKey(userId), toB64(secretKey))
}

export function getSecretKey(userId) {
  const b64 = sessionStorage.getItem(cacheKey(userId))
  return b64 ? fromB64(b64) : null
}

export function forgetSecretKey(userId) {
  sessionStorage.removeItem(cacheKey(userId))
}
