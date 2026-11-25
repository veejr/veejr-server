import nacl from "../../vendor/tweetnacl.min.js"
import {toB64, fromB64} from "./crypto.js"

const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
const encoder = new TextEncoder()
export const toUrl = (bytes) => toB64(new Uint8Array(bytes)).replace(/\+/gu, "-").replace(/\//gu, "_").replace(/=+$/u, "")
export const fromUrl = (value) => fromB64(value.replace(/-/gu, "+").replace(/_/gu, "/") + "=".repeat((4 - value.length % 4) % 4))

export function recoveryCode(bytes = crypto.getRandomValues(new Uint8Array(20))) {
  if (bytes.length !== 20) throw new Error("Recovery codes require 20 bytes.")
  let bits = ""
  for (const byte of bytes) bits += byte.toString(2).padStart(8, "0")
  return bits.match(/.{5}/gu).map((part) => alphabet[parseInt(part, 2)]).join("").match(/.{4}/gu).join("-")
}

export function recoveryBytes(value) {
  const code = String(value).toUpperCase().replace(/[\s-]/gu, "").replace(/O/gu, "0").replace(/[IL]/gu, "1")
  if (code.length !== 32 || [...code].some((c) => !alphabet.includes(c))) throw new Error("Enter the 32-character recovery code.")
  const bits = [...code].map((c) => alphabet.indexOf(c).toString(2).padStart(5, "0")).join("")
  return Uint8Array.from(bits.match(/.{8}/gu), (part) => parseInt(part, 2))
}

async function wrappingKey(material, salt, info) {
  const key = await crypto.subtle.importKey("raw", material, "HKDF", false, ["deriveBits"])
  return new Uint8Array(await crypto.subtle.deriveBits({name: "HKDF", hash: "SHA-256", salt, info: encoder.encode(info)}, key, 256))
}

export function matchesPublicKey(secret, publicKey) {
  return secret?.length === 32 && toB64(nacl.box.keyPair.fromSecretKey(secret).publicKey) === publicKey
}

export async function wrapSlot(secret, material, kind, publicKey) {
  if (!matchesPublicKey(secret, publicKey)) throw new Error("The unlocked identity does not match this account.")
  const salt = crypto.getRandomValues(new Uint8Array(16))
  const nonce = crypto.getRandomValues(new Uint8Array(24))
  const info = `veejr key-slot v1 ${kind.replaceAll("_", "-")}`
  const key = await wrappingKey(material, salt, info)
  const ciphertext = nacl.secretbox(secret, nonce, key)
  const slot = {salt: toB64(salt), nonce: toB64(nonce), ciphertext: toB64(ciphertext), info}
  await unwrapSlot(slot, material, kind, publicKey)
  return slot
}

export async function unwrapSlot(slot, material, kind, publicKey) {
  const info = `veejr key-slot v1 ${kind.replaceAll("_", "-")}`
  if (slot.info !== info) throw new Error("Unknown key wrapping method.")
  const key = await wrappingKey(material, fromB64(slot.salt), info)
  const secret = nacl.secretbox.open(fromB64(slot.ciphertext), fromB64(slot.nonce), key)
  if (!matchesPublicKey(secret, publicKey)) throw new Error("This unlock method could not open your current identity.")
  return secret
}

export async function credentialOptions(options, registration = false) {
  const result = {...options, challenge: fromUrl(options.challenge)}
  if (registration) {
    result.user = {...options.user, id: fromUrl(options.user.id)}
    result.excludeCredentials = options.excludeCredentials.map((entry) => ({...entry, id: fromUrl(entry.id)}))
  }
  result.extensions = {prf: {eval: {first: await crypto.subtle.digest("SHA-256", encoder.encode("veejr/prf/v1"))}}}
  return result
}

export function credentialJSON(credential) {
  const response = credential.response
  const encoded = {}
  for (const name of ["attestationObject", "clientDataJSON", "authenticatorData", "signature", "userHandle"]) {
    if (response[name]) encoded[name] = toUrl(response[name])
  }
  return {id: credential.id, type: credential.type, response: encoded}
}

export async function linkVerification(id, publicKey) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(`${id}:${publicKey}`)))
  return [...digest.slice(0, 6)].map((b) => b.toString(16).padStart(2, "0")).join(" ").toUpperCase()
}
