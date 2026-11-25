import test from "node:test"
import assert from "node:assert/strict"
import nacl from "../../assets/vendor/tweetnacl.min.js"
import {toB64} from "../../assets/js/veejr/crypto.js"
import {recoveryCode, recoveryBytes, wrapSlot, unwrapSlot} from "../../assets/js/veejr/passkeys.js"

test("recovery codes round-trip 160 bits and normalize ambiguous characters", () => {
  const bytes = new Uint8Array(20)
  const code = recoveryCode(bytes)
  assert.equal(code, "0000-0000-0000-0000-0000-0000-0000-0000")
  assert.deepEqual(recoveryBytes(code.replaceAll("0", "o")), bytes)
  assert.throws(() => recoveryBytes("U".repeat(32)))
  const random = crypto.getRandomValues(new Uint8Array(20))
  assert.deepEqual(recoveryBytes(recoveryCode(random)), random)
})

test("factor slots verify the identity and reject a wrong factor or purpose", async () => {
  const secret = crypto.getRandomValues(new Uint8Array(32))
  const publicKey = toB64(nacl.box.keyPair.fromSecretKey(secret).publicKey)
  const material = crypto.getRandomValues(new Uint8Array(32))
  const slot = await wrapSlot(secret, material, "passkey_prf", publicKey)
  assert.deepEqual(await unwrapSlot(slot, material, "passkey_prf", publicKey), secret)
  await assert.rejects(unwrapSlot(slot, crypto.getRandomValues(new Uint8Array(32)), "passkey_prf", publicKey))
  await assert.rejects(unwrapSlot(slot, material, "recovery_code", publicKey))
  await assert.rejects(wrapSlot(secret, material, "passkey_prf", toB64(new Uint8Array(32))))
})
