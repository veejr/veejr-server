import assert from "node:assert/strict"
import crypto from "node:crypto"
import fs from "node:fs"
import {createRequire} from "node:module"
import path from "node:path"
import {fileURLToPath} from "node:url"

const require = createRequire(import.meta.url)
const nacl = require("../assets/vendor/tweetnacl.min.js")
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const fixturePath = path.join(root, "protocol-fixtures", "v1.json")
const te = new TextEncoder()
const td = new TextDecoder()

// The fixture above is rebuilt from raw tweetnacl calls, which proves the
// recorded values are internally consistent but says nothing about the code
// that actually ships to browsers. `verifyShippedModule` closes that gap by
// replaying the same fixture through assets/js/veejr/crypto.js itself, so a
// regression in the real module (changed KDF iterations, swapped key/nonce
// arguments, broken base64) fails `mix precommit` instead of passing silently.
const shipped = await import("../assets/js/veejr/crypto.js")

const bytes = (hex) => new Uint8Array(Buffer.from(hex, "hex"))
const b64 = (value) => Buffer.from(value).toString("base64")

const senderSecret = bytes("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
const recipientSecret = bytes("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")
const wrapSalt = bytes("404142434445464748494a4b4c4d4e4f")
const wrapNonce = bytes("505152535455565758595a5b5c5d5e5f6061626364656667")
const boxNonce = bytes("707172737475767778797a7b7c7d7e7f8081828384858687")
const attachmentKey = bytes("909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeaf")
const attachmentNonce = bytes("b0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7")
const passphrase = "veejr fixture 🔐"
const payloadJson =
  '{"v":1,"kind":"message","text":"Hello, Bob 👋","attachments":[],"to":["@bob@example.test"],"sent_at":"2026-07-12T14:00:00.000Z"}'
const attachmentPlaintext = te.encode("fixture attachment\n")

function buildFixture() {
  const sender = nacl.box.keyPair.fromSecretKey(senderSecret)
  const recipient = nacl.box.keyPair.fromSecretKey(recipientSecret)
  const wrappingKey = crypto.pbkdf2Sync(passphrase, wrapSalt, 310_000, 32, "sha256")
  const wrappedSecret = nacl.secretbox(sender.secretKey, wrapNonce, wrappingKey)
  const ciphertext = nacl.box(te.encode(payloadJson), boxNonce, recipient.publicKey, sender.secretKey)
  const attachmentCiphertext = nacl.secretbox(attachmentPlaintext, attachmentNonce, attachmentKey)

  return {
    schema: "org.veejr.protocol-fixtures",
    schema_version: 1,
    protocol: {api_version: 1, payload_version: 1},
    encoding: "standard-padded-base64",
    identity: {
      sender_secret_key: b64(sender.secretKey),
      sender_public_key: b64(sender.publicKey),
      recipient_secret_key: b64(recipient.secretKey),
      recipient_public_key: b64(recipient.publicKey),
    },
    wrapping: {
      passphrase,
      kdf: "PBKDF2-HMAC-SHA256",
      iterations: 310_000,
      salt: b64(wrapSalt),
      derived_key: b64(wrappingKey),
      algorithm: "XSalsa20-Poly1305",
      nonce: b64(wrapNonce),
      plaintext_secret_key: b64(sender.secretKey),
      wrapped_secret_key: b64(wrappedSecret),
    },
    envelope: {
      algorithm: "nacl.box",
      payload_json: payloadJson,
      nonce: b64(boxNonce),
      sender_secret_key: b64(sender.secretKey),
      sender_public_key: b64(sender.publicKey),
      recipient_secret_key: b64(recipient.secretKey),
      recipient_public_key: b64(recipient.publicKey),
      ciphertext: b64(ciphertext),
    },
    attachment: {
      algorithm: "nacl.secretbox",
      plaintext_utf8: "fixture attachment\n",
      key: b64(attachmentKey),
      nonce: b64(attachmentNonce),
      ciphertext: b64(attachmentCiphertext),
    },
  }
}

function verifyFixture(actual) {
  const expected = buildFixture()
  assert.deepEqual(actual, expected, "protocol fixture differs from deterministic source values")

  const fromB64 = (value) => new Uint8Array(Buffer.from(value, "base64"))
  const unwrapped = nacl.secretbox.open(
    fromB64(actual.wrapping.wrapped_secret_key),
    fromB64(actual.wrapping.nonce),
    fromB64(actual.wrapping.derived_key),
  )
  assert.equal(b64(unwrapped), actual.wrapping.plaintext_secret_key)

  const opened = nacl.box.open(
    fromB64(actual.envelope.ciphertext),
    fromB64(actual.envelope.nonce),
    fromB64(actual.envelope.sender_public_key),
    fromB64(actual.envelope.recipient_secret_key),
  )
  assert.equal(new TextDecoder().decode(opened), actual.envelope.payload_json)

  const attachment = nacl.secretbox.open(
    fromB64(actual.attachment.ciphertext),
    fromB64(actual.attachment.nonce),
    fromB64(actual.attachment.key),
  )
  assert.equal(new TextDecoder().decode(attachment), actual.attachment.plaintext_utf8)
}

// --- Shipped-module verification ---------------------------------------
//
// Everything below drives assets/js/veejr/crypto.js — the module the browser
// loads — rather than reconstructing its behaviour from tweetnacl.

function verifyEncoding(fixture) {
  const wrapped = fixture.wrapping.wrapped_secret_key

  assert.deepEqual(
    Array.from(shipped.fromB64(wrapped)),
    Array.from(new Uint8Array(Buffer.from(wrapped, "base64"))),
    "crypto.js fromB64 disagrees with standard base64 decoding",
  )
  assert.equal(
    shipped.toB64(shipped.fromB64(wrapped)),
    wrapped,
    "crypto.js toB64/fromB64 do not round-trip the fixture encoding",
  )

  // Non-ASCII must survive the byte-wise base64 helpers unchanged.
  const utf8 = te.encode("attachment ünïcode 🔐")
  assert.equal(
    td.decode(shipped.fromB64(shipped.toB64(utf8))),
    "attachment ünïcode 🔐",
    "crypto.js base64 helpers corrupt multi-byte UTF-8",
  )
}

async function verifyKeyWrapping(fixture) {
  const {passphrase, wrapped_secret_key, salt, nonce, plaintext_secret_key} = fixture.wrapping

  // The load-bearing assertion: this fails if PBKDF2 iterations, hash, or the
  // secretbox wrapping in crypto.js ever drift from the published contract.
  const unwrapped = await shipped.unlockIdentity(passphrase, wrapped_secret_key, salt, nonce)
  assert.notEqual(unwrapped, null, "crypto.js unlockIdentity could not open the fixture key")
  assert.equal(
    shipped.toB64(unwrapped),
    plaintext_secret_key,
    "crypto.js unlockIdentity produced the wrong secret key",
  )

  assert.equal(
    await shipped.unlockIdentity("wrong passphrase", wrapped_secret_key, salt, nonce),
    null,
    "crypto.js unlockIdentity accepted an incorrect passphrase",
  )

  // Fresh wrap under a random salt/nonce must still be openable.
  const rewrapped = await shipped.wrapSecretKey(shipped.fromB64(plaintext_secret_key), "another pass")
  const reopened = await shipped.unlockIdentity(
    "another pass",
    rewrapped.encSecretKey,
    rewrapped.keySalt,
    rewrapped.keyNonce,
  )
  assert.equal(
    shipped.toB64(reopened),
    plaintext_secret_key,
    "crypto.js wrapSecretKey/unlockIdentity do not round-trip",
  )

  const identity = await shipped.generateIdentity("setup pass")
  assert.equal(
    identity.publicKey,
    shipped.toB64(nacl.box.keyPair.fromSecretKey(identity.secretKey).publicKey),
    "crypto.js generateIdentity returned a mismatched keypair",
  )
}

function verifyEnvelope(fixture) {
  const env = fixture.envelope
  const expected = JSON.parse(env.payload_json)

  const opened = shipped.openFrom(
    env.ciphertext,
    env.nonce,
    env.sender_public_key,
    shipped.fromB64(env.recipient_secret_key),
  )
  assert.deepEqual(opened, expected, "crypto.js openFrom could not read the fixture envelope")

  // Authentication must actually be enforced, not just decryption attempted.
  const tampered = shipped.fromB64(env.ciphertext)
  tampered[tampered.length - 1] ^= 0x01
  assert.equal(
    shipped.openFrom(
      shipped.toB64(tampered),
      env.nonce,
      env.sender_public_key,
      shipped.fromB64(env.recipient_secret_key),
    ),
    null,
    "crypto.js openFrom accepted a tampered ciphertext",
  )

  assert.equal(
    shipped.openFrom(
      env.ciphertext,
      env.nonce,
      env.recipient_public_key,
      shipped.fromB64(env.recipient_secret_key),
    ),
    null,
    "crypto.js openFrom accepted a wrong sender key",
  )

  // Seal with the shipped module and read it back from the other side.
  const sealed = shipped.sealFor(
    env.recipient_public_key,
    expected,
    shipped.fromB64(env.sender_secret_key),
  )
  assert.deepEqual(
    shipped.openFrom(
      sealed.ciphertext,
      sealed.nonce,
      env.sender_public_key,
      shipped.fromB64(env.recipient_secret_key),
    ),
    expected,
    "crypto.js sealFor/openFrom do not round-trip sender to recipient",
  )
}

function verifyAttachment(fixture) {
  const att = fixture.attachment

  const plaintext = shipped.decryptBlob(shipped.fromB64(att.ciphertext), att.key, att.nonce)
  assert.notEqual(plaintext, null, "crypto.js decryptBlob could not open the fixture attachment")
  assert.equal(
    td.decode(plaintext),
    att.plaintext_utf8,
    "crypto.js decryptBlob produced the wrong attachment bytes",
  )

  // Guards the key/nonce argument order, which is silently swappable. A
  // transposed call must not yield plaintext; tweetnacl rejects the mismatched
  // key length by throwing, so either outcome is acceptable.
  let transposed = null
  try {
    transposed = shipped.decryptBlob(shipped.fromB64(att.ciphertext), att.nonce, att.key)
  } catch {
    transposed = null
  }
  assert.equal(
    transposed,
    null,
    "crypto.js decryptBlob opened an attachment with key and nonce transposed",
  )

  const bytes = te.encode(att.plaintext_utf8)
  const encrypted = shipped.encryptBlob(bytes)
  assert.equal(
    td.decode(shipped.decryptBlob(encrypted.data, encrypted.key, encrypted.nonce)),
    att.plaintext_utf8,
    "crypto.js encryptBlob/decryptBlob do not round-trip",
  )
}

function verifyLocalDocuments() {
  const secret = nacl.box.keyPair().secretKey
  const other = nacl.box.keyPair().secretKey
  const document = {draft: "notes to self 🔐", items: [1, 2, 3]}

  const sealed = shipped.sealLocal(document, secret)
  assert.deepEqual(
    shipped.openLocal(sealed, secret),
    document,
    "crypto.js sealLocal/openLocal do not round-trip",
  )
  assert.equal(
    shipped.openLocal(sealed, other),
    null,
    "crypto.js openLocal decrypted a document under the wrong key",
  )
}

async function verifyShippedModule(fixture) {
  verifyEncoding(fixture)
  await verifyKeyWrapping(fixture)
  verifyEnvelope(fixture)
  verifyAttachment(fixture)
  verifyLocalDocuments()
}

const mode = process.argv[2] || "verify"

if (mode === "generate") {
  fs.mkdirSync(path.dirname(fixturePath), {recursive: true})
  fs.writeFileSync(fixturePath, `${JSON.stringify(buildFixture(), null, 2)}\n`)
  console.log(`generated ${path.relative(root, fixturePath)}`)
} else if (mode === "verify") {
  const fixture = JSON.parse(fs.readFileSync(fixturePath, "utf8"))
  verifyFixture(fixture)
  await verifyShippedModule(fixture)
  console.log(`verified ${path.relative(root, fixturePath)} against assets/js/veejr/crypto.js`)
} else {
  throw new Error(`unknown mode: ${mode}`)
}
