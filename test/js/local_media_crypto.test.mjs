import assert from "node:assert/strict"
import test from "node:test"

import {openLocalBlob, sealLocalBlob} from "../../assets/js/veejr/crypto.js"

test("large local draft blobs round-trip under the device key", async () => {
  const secret = crypto.getRandomValues(new Uint8Array(32))
  const original = new Blob(["private video bytes"], {type: "video/webm"})

  const sealed = await sealLocalBlob(original, secret)
  const restored = await openLocalBlob(sealed, secret, original.type)

  assert.equal(restored.type, "video/webm")
  assert.equal(await restored.text(), "private video bytes")
  assert.notEqual(await sealed.ciphertext.text(), "private video bytes")
})

test("a local draft blob cannot be opened with another key", async () => {
  const sealed = await sealLocalBlob(
    new Blob(["voice note"]),
    crypto.getRandomValues(new Uint8Array(32)),
  )

  const restored = await openLocalBlob(
    sealed,
    crypto.getRandomValues(new Uint8Array(32)),
    "audio/webm",
  )

  assert.equal(restored, null)
})
