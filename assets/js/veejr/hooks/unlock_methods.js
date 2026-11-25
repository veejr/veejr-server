import {cacheSecretKey, getSecretKey, generateEphemeralIdentity, sealFor, openFrom} from "../crypto.js"
import {credentialJSON, credentialOptions, fromUrl, matchesPublicKey, recoveryBytes, recoveryCode, unwrapSlot, wrapSlot, linkVerification} from "../passkeys.js"
import {csrfToken} from "./shared.js"

async function request(path, data, method = "POST") {
  const response = await fetch(path, {method, redirect: "error", headers: {"content-type": "application/json", "x-csrf-token": csrfToken()},
    ...(data ? {body: JSON.stringify(data)} : {})})
  const result = await response.json()
  if (!response.ok) throw new Error(result.error || "The request failed.")
  return result
}

function node(tag, text, className = "") {
  const el = document.createElement(tag)
  el.textContent = text
  el.className = className
  return el
}
function action(parent, text, handler) {
  const button = node("button", text, "rounded-xl border border-base-300 px-4 py-2 text-sm font-medium transition hover:bg-base-200 disabled:opacity-50")
  button.type = "button"
  button.addEventListener("click", async () => {
    button.disabled = true
    const error = parent.closest("[data-unlock-root]").querySelector("[data-unlock-error]")
    error.textContent = ""
    try { await handler() } catch (failure) { error.textContent = failure.message } finally { button.disabled = false }
  })
  parent.append(button)
  return button
}

async function assertPasskey() {
  const options = await request("/unlock/options", {})
  const credential = await navigator.credentials.get({publicKey: await credentialOptions(options.options)})
  const result = await request("/unlock/verify", {challenge_id: options.challenge_id, credential: credentialJSON(credential)})
  return {result, material: credential.getClientExtensionResults().prf?.results?.first}
}

export const UnlockMethods = {
  mounted() {
    const {userId, publicKey, mode} = this.el.dataset
    this.el.setAttribute("data-unlock-root", "")
    this.el.replaceChildren()
    const controls = node("div", "", "flex flex-wrap gap-2")
    const content = node("div", "", "mt-4 space-y-3")
    const error = node("p", "", "mt-3 text-sm text-error")
    error.dataset.unlockError = "true"
    error.setAttribute("role", "alert")
    this.el.append(controls, content, error)
    const requireSecret = () => {
      const secret = getSecretKey(userId)
      if (!secret) throw new Error("Unlock with your privacy key first, then add an unlock method.")
      return secret
    }
    action(controls, mode === "login" ? "Sign in with a passkey" : "Unlock with a passkey", async () => {
      const {result, material} = await assertPasskey()
      if (result.slot && material) cacheSecretKey(result.user_id, await unwrapSlot(result.slot, material, "passkey_prf", result.public_key))
      const target = new URLSearchParams(window.location.search).get("return_to")
      const safeTarget = target?.startsWith("/") && !target.startsWith("//") && !target.includes("\\") ? target : "/messages"
      window.location.assign(result.slot && material ? safeTarget : "/keys")
    })
    if (mode === "login") {
      action(controls, "Link from another device", async () => {
        clearInterval(this.poll)
        const identity = generateEphemeralIdentity()
        const link = await request("/unlock/links", {public_key: identity.publicKey})
        content.replaceChildren(node("p", "On an unlocked device, scan this code or open the link. Compare the verification code on both devices before approving.", "text-sm"))
        const image = document.createElement("img")
        image.src = `data:image/svg+xml;base64,${link.qr}`
        image.alt = "Device linking QR code"
        image.className = "size-48 rounded-xl bg-white p-3"
        const anchor = node("a", link.url, "block break-all text-sm underline")
        anchor.href = link.url
        const code = node("strong", await linkVerification(link.id, identity.publicKey), "block font-mono")
        content.append(image, anchor, code)
        const expiry = Date.now() + 300_000
        this.poll = setInterval(async () => {
          if (this.polling || this.disposed) return
          if (Date.now() > expiry) { clearInterval(this.poll); error.textContent = "Link expired. Start again."; return }
          this.polling = true
          try {
            const result = await request(`/unlock/links/${encodeURIComponent(link.id)}/claim`, {token: link.token})
            if (result.pending) return
            clearInterval(this.poll)
            const payload = openFrom(result.sealed.ciphertext, result.sealed.nonce, result.sealed.sender_key, identity.secretKey)
            const secret = payload && fromUrl(payload.secret)
            if (!matchesPublicKey(secret, result.public_key)) throw new Error("The linked identity could not be verified.")
            cacheSecretKey(result.user_id, secret)
            window.location.assign("/messages")
          } catch (failure) { error.textContent = failure.message; clearInterval(this.poll) }
          finally { this.polling = false }
        }, 4000)
      })
      return
    }

    const reauthenticate = node("a", "Confirm your sign-in", "self-center text-sm text-primary underline")
    reauthenticate.href = `/users/log-in?return_to=${encodeURIComponent(window.location.pathname + window.location.search)}`
    controls.append(reauthenticate)
    action(controls, "Add a passkey", async () => {
      const secret = requireSecret()
      const options = await request("/unlock/registration/options", {})
      const credential = await navigator.credentials.create({publicKey: await credentialOptions(options.options, true)})
      const registered = await request("/unlock/registration/verify", {challenge_id: options.challenge_id, credential: credentialJSON(credential), label: "Passkey"})
      let material = credential.getClientExtensionResults().prf?.results?.first
      if (!material) {
        // A credential may only evaluate its PRF on an assertion. Restrict
        // this assertion so another registered passkey cannot supply its PRF.
        const auth = await request("/unlock/options", {})
        const publicKeyOptions = await credentialOptions(auth.options)
        publicKeyOptions.allowCredentials = [{id: credential.rawId, type: "public-key"}]
        const assertion = await navigator.credentials.get({publicKey: publicKeyOptions})
        await request("/unlock/verify", {challenge_id: auth.challenge_id, credential: credentialJSON(assertion)})
        material = assertion.getClientExtensionResults().prf?.results?.first
      }
      if (material) {
        const wrapped = await wrapSlot(secret, material, "passkey_prf", publicKey)
        await request("/unlock/slots", {kind: "passkey_prf", passkey_id: registered.id, public_key: publicKey, wrapped})
        content.replaceChildren(node("p", "Passkey added. You can now sign in and unlock with one gesture.", "text-sm text-success"))
      } else content.replaceChildren(node("p", "Passkey added for sign-in. This authenticator has no encryption PRF support, so use your privacy key or recovery code to unlock.", "text-sm"))
    })
    action(controls, "Create a recovery code", async () => {
      const secret = requireSecret()
      const code = recoveryCode()
      const wrapped = await wrapSlot(secret, recoveryBytes(code), "recovery_code", publicKey)
      content.replaceChildren(node("p", "Save this code somewhere safe. Saving it replaces your previous recovery code. Anyone with this code and account access can unlock your encrypted history.", "text-sm"), node("code", code, "block break-all text-lg"))
      action(content, "I saved this code — activate it", async () => {
        await request("/unlock/slots", {kind: "recovery_code", public_key: publicKey, wrapped})
        content.replaceChildren(node("p", "Recovery code activated.", "text-sm text-success"))
      })
    })
    action(controls, "Use a recovery code", async () => {
      content.replaceChildren()
      const label = node("label", "Recovery code", "block text-sm font-medium")
      const input = document.createElement("input")
      input.type = "password"
      input.autocomplete = "off"
      input.className = "mt-2 block w-full rounded-xl border border-base-300 bg-base-100 p-3"
      label.append(input)
      content.append(label)
      action(content, "Unlock", async () => {
        const methods = await request("/unlock/methods", null, "GET")
        const slot = methods.slots.find((s) => s.kind === "recovery_code")
        if (!slot) throw new Error("This account has no recovery code.")
        cacheSecretKey(userId, await unwrapSlot(slot.wrapped, recoveryBytes(input.value), "recovery_code", publicKey))
        window.location.reload()
      })
    })
    action(controls, "Manage passkeys", async () => {
      const methods = await request("/unlock/methods", null, "GET")
      content.replaceChildren()
      if (!methods.passkeys.length) content.append(node("p", "No passkeys enrolled.", "text-sm"))
      for (const passkey of methods.passkeys) {
        const row = node("div", "", "flex items-center justify-between gap-3 text-sm")
        row.append(node("span", `${passkey.label} · last used ${passkey.last_used_at ? new Date(passkey.last_used_at).toLocaleString() : "never"}`))
        action(row, "Remove", async () => {
          if (!window.confirm("Remove this passkey and its encryption unlock method? Your privacy key remains available.")) return
          await request(`/unlock/passkeys/${encodeURIComponent(passkey.id)}`, null, "DELETE")
          row.remove()
        })
        content.append(row)
      }
    })
    const linkId = new URLSearchParams(window.location.search).get("link")
    if (linkId) {
      request(`/unlock/links/${encodeURIComponent(linkId)}`, null, "GET").then(async (link) => {
        if (this.disposed) return
        content.replaceChildren(node("h3", "Approve another device", "font-semibold"),
          node("p", "Compare this code with the device you are linking. Approving gives that device access to your account and encrypted history.", "text-sm"),
          node("strong", await linkVerification(link.id, link.public_key), "block font-mono"))
        action(content, "The codes match — approve device", async () => {
          const {toUrl} = await import("../passkeys.js")
          const sealed = sealFor(link.public_key, {secret: toUrl(requireSecret())}, requireSecret())
          await request(`/unlock/links/${encodeURIComponent(link.id)}/approve`, {sealed: {...sealed, sender_key: publicKey}})
          content.replaceChildren(node("p", "Device approved.", "text-sm text-success"))
        })
      }).catch((failure) => { error.textContent = failure.message })
    }
  },
  destroyed() { this.disposed = true; clearInterval(this.poll) },
}
