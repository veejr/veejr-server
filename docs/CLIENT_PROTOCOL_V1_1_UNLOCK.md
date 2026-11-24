# veejr client protocol v1.1 — one unlock (passkeys, key slots, device linking)

Status: **Draft**
Extends: [CLIENT_PROTOCOL_V1.md](CLIENT_PROTOCOL_V1.md) (sections 7, 8, 15, 17)
Capability flags: `extensions.passkeys: 1`, `extensions.key_slots: 1`, `extensions.device_link: 1`
Intended implementers: veejr-server, veejrcentral, the web client, the Android client

## 1. Purpose

Today a veejr user holds two secrets: a sign-in credential (magic link or
password) and a separate encryption passphrase that wraps their X25519
identity key. Users experience this as signing in twice, on every new tab and
every new device.

This extension lets one gesture — a passkey assertion — both authenticate the
device session **and** unwrap the identity key, while keeping the boundary in
v1 §1 intact:

> The server authenticates identities and stores ciphertext. Clients
> exclusively handle private identity keys and plaintext.

It does so with three additive pieces:

1. **Passkeys** (`passkeys: 1`) — WebAuthn sign-in and re-authentication.
2. **Key slots** (`key_slots: 1`) — the one identity secret, wrapped several
   times, each copy opened by a different factor: a passkey's PRF output, a
   high-entropy recovery code, or the v1 passphrase.
3. **Device linking** (`device_link: 1`) — a signed-in device hands the
   identity secret to a new device, sealed end to end, by QR code or short
   code plus verification words.

The identity keypair, envelope sealing (v1 §15.4), attachments (v1 §15.5) and
federation are unchanged. A friend on another instance cannot tell whether
you unlock with a passkey or a passphrase.

## 2. Goals and non-goals

### 2.1 Goals

- One tap to sign in and unlock on a device that has a passkey.
- No passphrase in the everyday flow; no "set up your keys" step at sign-up.
- Email compromise alone still yields **no** message content.
- A recovery path when every device is lost, without the server holding
  anything that opens the key.
- Full backward compatibility with v1.0 clients and v1.0 servers for accounts
  that keep a passphrase slot.

### 2.2 Non-goals

- Server-side key escrow or server-assisted content recovery.
- Changing the identity algorithm, envelope format, or federation protocol.
- Making passkeys portable across instances. A passkey is bound to its
  relying party (the instance host) and does not survive an account move.
- Removing the passphrase. It remains an optional slot.

## 3. Versioning and capability advertisement

All endpoints stay under `/api/v1`. Everything here is additive in the sense
of v1 §4.1. `GET /api/v1/capabilities` gains:

```json
{
  "api_versions": [1],
  "extensions": {
    "calls": 1,
    "passkeys": 1,
    "key_slots": 1,
    "device_link": 1
  },
  "webauthn": {
    "rp_id": "veejrcentral.example",
    "origins": ["https://veejrcentral.example"],
    "android_origins": ["android:apk-key-hash:BASE64URL"]
  }
}
```

A client MUST NOT call an endpoint in this document unless its flag is
present. `key_slots` requires `passkeys`; `device_link` requires `key_slots`.

## 4. Factors at a glance

| Factor | What the user does | Opens the identity key? | Signs in? | Portable across instances |
| --- | --- | --- | --- | --- |
| Passkey with PRF | Face, fingerprint, device PIN | Yes (its passkey slot) | Yes | No (rp-bound) |
| Passkey without PRF | Same | No | Yes | No |
| Recovery code | Types a saved 32-character code | Yes (recovery slot) | No | Yes |
| Passphrase (v1) | Types the passphrase | Yes (passphrase slot) | No | Yes |
| Email magic link (v1 §7.4) | Clicks a link | No | Yes | — |
| Linked device | Approves on another device | Receives the key | Yes (one-time grant) | — |

Sign-in and unlock are still separate concerns in the protocol; the passkey
is simply the one factor that does both in a single assertion.

## 5. Passkeys (`passkeys: 1`)

### 5.1 Relying party

The relying-party ID is the instance host as advertised in `webauthn.rp_id`.
Servers MUST verify the assertion origin against `webauthn.origins` (web) and
`webauthn.android_origins` (Android, via Digital Asset Links). Servers SHOULD
use a maintained WebAuthn verification library rather than a hand-written
verifier.

All WebAuthn options and credentials travel in the WebAuthn Level 3 JSON
forms (`PublicKeyCredentialCreationOptionsJSON`,
`PublicKeyCredentialRequestOptionsJSON`, `RegistrationResponseJSON`,
`AuthenticationResponseJSON`). These use **Base64URL** without padding,
unlike the rest of veejr (v1 §15.1). Fields defined by this document use
standard padded Base64.

### 5.2 The veejr PRF input

Every veejr PRF evaluation uses one fixed input:

```text
VEEJR_PRF_INPUT = SHA-256(UTF-8("veejr/prf/v1"))        # 32 bytes
```

Using one constant input lets a discoverable-credential sign-in request PRF
output before the client knows which credential will answer. The output is
still unique per credential, because the PRF is keyed by the authenticator's
per-credential secret. Per-slot uniqueness comes from the slot salt (§6.3).

Clients pass it as `extensions.prf.eval.first`. Clients MUST NOT send any
other PRF input for veejr slots.

### 5.3 Register a passkey

Requires an authenticated device session with recent authentication
(v1 §7.6).

`POST /api/v1/passkeys/registration/options`

```json
{"label": "Alex's iPhone"}
```

Response `200`:

```json
{
  "challenge_id": "opaque",
  "expires_at": "2026-11-24T12:05:00Z",
  "options": { "...": "PublicKeyCredentialCreationOptionsJSON" }
}
```

Server requirements for `options`:

- `authenticatorSelection.residentKey: "required"` and
  `userVerification: "required"`;
- `user.id` is a random 32-byte handle fixed per account, never the database
  ID, email, or username;
- `excludeCredentials` lists the account's existing passkeys;
- challenge is at least 32 random bytes, single use, and expires within five
  minutes.

The client adds `extensions.prf = {"eval": {"first": VEEJR_PRF_INPUT}}`
before calling `navigator.credentials.create`.

`POST /api/v1/passkeys/registration/verify`

```json
{
  "challenge_id": "opaque",
  "credential": { "...": "RegistrationResponseJSON" },
  "prf_enabled": true
}
```

`prf_enabled` is the client's reading of
`getClientExtensionResults().prf.enabled`. It is advisory only: it tells the
UI whether to offer "unlock with this passkey", and the server MUST NOT treat
it as security-relevant.

Response `201`:

```json
{
  "passkey": {
    "id": "opaque",
    "label": "Alex's iPhone",
    "prf_enabled": true,
    "created_at": "2026-11-24T12:01:00Z",
    "last_used_at": null
  }
}
```

Some authenticators return PRF results at creation time and some only at
assertion time. If creation did not return `prf.results.first`, the client
performs one assertion (§5.5, `purpose: "reauthenticate"`) to obtain the
output before it builds the passkey slot.

### 5.4 Sign in with a passkey

Unauthenticated, and rate-limited per client address like v1 password login.

`POST /api/v1/auth/passkey/options`

```json
{"identifier": null}
```

`identifier` is optional. When it is absent, `allowCredentials` is empty and
the platform offers its discoverable credentials. When it is present, the
server MUST return a response of identical shape whether or not the account
exists, and MUST NOT reveal account existence.

Response `200`: `{"challenge_id", "expires_at", "options"}` as in §5.3, with
`userVerification: "required"`. The client adds the PRF extension.

`POST /api/v1/auth/passkey/verify`

```json
{
  "challenge_id": "opaque",
  "credential": { "...": "AuthenticationResponseJSON" },
  "device": {"name": "Alex's iPhone", "platform": "ios", "app_version": "1.1.0"}
}
```

Response `200`:

```json
{
  "tokens": { "...": "SessionTokens (v1 §7.5)" },
  "account": { "...": "Account (§6.6)" },
  "key_slot": { "...": "KeySlot for this credential, or null" }
}
```

`key_slot` is the passkey slot bound to the asserting credential, so the
client can unwrap the key immediately with the PRF output it already holds:
one tap, one round trip. Invalid or unknown credentials return `401
passkey_not_recognized` with no further detail. The server MUST check that
the signature counter does not move backwards when the authenticator reports
a non-zero counter, and SHOULD treat a regression as a cloned credential by
revoking that passkey and recording an audit event.

### 5.5 Re-authenticate with a passkey

v1 §7.6 recent authentication may be satisfied with a passkey:

- `POST /api/v1/auth/reauthenticate/options` → `{"challenge_id", "options"}`,
  with `allowCredentials` restricted to the account's passkeys;
- `POST /api/v1/auth/reauthenticate/verify`
  `{"challenge_id", "credential"}` → `204`, which stamps the device session's
  authenticated-at time.

### 5.6 Manage passkeys

- `GET /api/v1/passkeys` → `{"items": [Passkey]}`
- `PATCH /api/v1/passkeys/{id}` `{"label"}` → `Passkey`
- `DELETE /api/v1/passkeys/{id}` → `204`. Requires recent authentication. It
  also deletes the passkey slot bound to that credential (§6.5 rules apply,
  including refusal to remove the last slot).

## 6. Key slots (`key_slots: 1`)

### 6.1 Model

An account has one identity keypair (v1 §15.2) and one or more **key slots**.
Each slot is an independent XSalsa20-Poly1305 wrap of the same 32-byte
identity secret, under a 32-byte wrapping key derived from one factor.

```text
identity_secret ──secretbox(K_passkey_1)──► slot (passkey_prf, credential A)
                ──secretbox(K_passkey_2)──► slot (passkey_prf, credential B)
                ──secretbox(K_recovery) ──► slot (recovery_code)
                ──secretbox(K_phrase)   ──► slot (passphrase)   ← identical to v1 wrapped_key
```

Invariants:

1. Every slot wraps the secret whose public key equals the account's current
   `public_key`.
2. An account with keys configured has at least one slot.
3. An account has at most one `recovery_code` slot and at most one
   `passphrase` slot. A passkey credential has at most one `passkey_prf` slot.
4. The server can read slot metadata but can open no slot.

### 6.2 KeySlot representation

```json
{
  "id": "opaque",
  "kind": "passkey_prf",
  "label": "Alex's iPhone",
  "public_key": "base64",
  "passkey_id": "opaque",
  "kdf": {
    "name": "HKDF-SHA256",
    "salt": "base64",
    "info": "veejr key-slot v1 passkey-prf"
  },
  "wrap": {
    "name": "XSalsa20-Poly1305",
    "nonce": "base64",
    "ciphertext": "base64"
  },
  "created_at": "2026-11-24T12:01:00Z",
  "last_used_at": "2026-11-24T12:01:00Z"
}
```

`passkey_id` is present only for `passkey_prf`. Responses containing `wrap`
MUST use `Cache-Control: no-store`, as v1 §8.1 already requires for
`wrapped_key`.

### 6.3 Derivations

All binary inputs are raw bytes. `HKDF` is RFC 5869 with SHA-256 and a
32-byte output length. Every slot salt is 16 fresh random bytes, and every
wrap nonce is 24 fresh random bytes.

| Kind | Input key material | KDF | `kdf.info` |
| --- | --- | --- | --- |
| `passkey_prf` | `prf.results.first` (32 bytes) for `VEEJR_PRF_INPUT` | HKDF-SHA256(ikm, salt, info) | `veejr key-slot v1 passkey-prf` |
| `recovery_code` | 20 code bytes (§6.4) | HKDF-SHA256(ikm, salt, info) | `veejr key-slot v1 recovery-code` |
| `passphrase` | UTF-8 passphrase, unnormalized | PBKDF2-HMAC-SHA256, 310,000 iterations, salt (v1 §15.3) | — |

Then `wrap.ciphertext = secretbox(identity_secret, nonce, K)`.

The PRF output and the recovery code already carry at least 160 bits of
entropy, so a fast KDF is sufficient. A stolen database is no easier to
attack through these slots than through the identity key itself. The
passphrase slot remains the only slot that can be attacked offline, as it is
in v1. A server SHOULD tell users that removing the passphrase slot removes
that exposure.

A `passphrase` slot's `kdf` is `{"name": "PBKDF2-SHA256", "iterations":
310000, "salt": "base64"}`, which makes it byte-for-byte the v1
`wrapped_key`.

### 6.4 Recovery code format

- 20 random bytes, encoded as Crockford Base32 (no padding): exactly 32
  characters.
- Display: eight groups of four, separated by hyphens, for example
  `7KQ4-9MXR-2D8H-TV0C-PA61-Q3ZN-WB5E-JG4F`.
- Input normalization: uppercase; remove spaces and hyphens; map `O`→`0`,
  `I`/`L`→`1`; reject `U` and any other character outside the alphabet;
  require exactly 32 characters.
- The client generates the code and shows it exactly once. The code never
  reaches the server; only the wrapped slot does.
- The recovery code is **not** a sign-in credential. Recovering on a new device
  is a two-step flow: sign in (email magic link, v1 §7.4), then unlock with the
  code, then enroll a passkey.

### 6.5 Endpoints

- `GET /api/v1/keys/slots` → `{"items": [KeySlot]}`. Authenticated.
- `POST /api/v1/keys/slots` → `201 KeySlot`. Authenticated, recent
  authentication. Body: `kind`, `label`, `public_key`, `kdf`, `wrap`, and
  `passkey_id` for `passkey_prf`. Adding a `recovery_code` or `passphrase`
  slot when one exists **replaces** it atomically, so regenerating a recovery
  code invalidates the old one.
- `PATCH /api/v1/keys/slots/{id}` `{"label"}` → `KeySlot`.
- `DELETE /api/v1/keys/slots/{id}` → `204`. Recent authentication required.
  Returns `409 last_key_slot` if this is the only slot. Returns `409
  last_recovery_path` when the slot is the account's only non-passkey slot
  and the request omits `?confirm=no_recovery`; this makes the client show
  "you will have no way back if you lose your devices".
- `POST /api/v1/keys/slots/{id}/used` → `204`. Stamps `last_used_at`, so the
  user can see which unlock methods are actually in use. Clients SHOULD call
  it after each successful unwrap other than the passkey sign-in in §5.4,
  which the server stamps itself.

Server validation for slot writes:

- `public_key` MUST equal the account's current public key; otherwise `422
  slot_key_mismatch`;
- every Base64 field MUST decode to its stated length (salt 16, nonce 24,
  ciphertext 48 bytes);
- `passkey_id` MUST name a passkey on this account with no existing slot;
- `kdf.name`, `kdf.info` and `wrap.name` MUST be exactly the values in §6.3.
  Unknown values are rejected, following v1 §4.1's rule for cryptographic
  enums.

The server cannot verify that a slot actually opens. Clients MUST therefore
unwrap every slot they build, locally and before upload, and confirm that
`nacl.box.keyPair.fromSecretKey(result).publicKey` equals `public_key`.

### 6.6 Account representation changes

`GET /api/v1/me` gains:

```json
{
  "account": {
    "keys_configured": true,
    "public_key": "base64",
    "wrapped_key": null,
    "unlock": {
      "slots": [
        {"id": "opaque", "kind": "passkey_prf", "label": "Alex's iPhone", "last_used_at": "..."},
        {"id": "opaque", "kind": "recovery_code", "label": "Recovery code", "last_used_at": null}
      ],
      "has_passphrase": false,
      "has_recovery_code": true
    }
  }
}
```

`wrapped_key` keeps its v1 meaning: it is the passphrase slot when one exists,
and `null` otherwise. `unlock.slots` carries metadata only, never `wrap`.

### 6.7 Key setup at sign-up

`PUT /api/v1/keys` (v1 §8.3) accepts an alternative body:

```json
{
  "public_key": "base64",
  "slots": [
    {"kind": "passkey_prf", "passkey_id": "opaque", "label": "Alex's iPhone", "kdf": {}, "wrap": {}},
    {"kind": "recovery_code", "label": "Recovery code", "kdf": {}, "wrap": {}}
  ]
}
```

At least one slot is required, and `wrapped_key` is optional once `slots` is
present. The operation remains create-only (`409 keys_already_configured`).

Recommended sign-up sequence:

1. account creation and email confirmation (unchanged);
2. passkey registration (§5.3);
3. key generation on the client, then building the passkey slot and the
   recovery slot;
4. `PUT /api/v1/keys` with both slots;
5. showing the recovery code, with a mandatory "I saved it" confirmation.

If the platform has no PRF support, the client builds a recovery slot plus a
passphrase slot instead. That is today's model, with the passphrase framed
as the fallback.

### 6.8 Rotation, reset and passphrase change

Rotating or resetting the key (v1 §8.3) invalidates every slot, because every
slot wraps the old secret. `POST /api/v1/keys/rotate` and
`POST /api/v1/keys/reset` gain a required `slots` array: the complete
replacement slot set for the new key, validated as in §6.5 against the
**new** public key. Within the same transaction, the server deletes every old
slot not present in the new set.

The client can only rebuild slots whose factor it holds at that moment:

- its own passkey slot, from a fresh assertion;
- a new recovery code — the client MUST generate and show a new one, because
  the old code is gone;
- the passphrase slot, only if the user types the passphrase.

Passkeys on other devices lose their slots. Each of those devices re-links
(§7) or unlocks with the new recovery code, then rebuilds its slot. The
server SHOULD list the passkeys that lost unlock capability so the UI can say
so plainly.

`PUT /api/v1/keys/wrapped` (passphrase change) continues to update the
passphrase slot only.

## 7. Device linking (`device_link: 1`)

### 7.1 Flow

```text
New device N (no session)              Server                 Existing device E (signed in)
------------------------------------   --------------------   --------------------------------
generate ephemeral X25519 (nPk, nSk)
POST /link-requests {nPk, device} ───► store, issue
                                       link_id, code,
◄───────────────────────────────────── poll_token
show QR(origin, link_id, nPk) + code
show words(link_id, nPk)
                                                              scan QR (or type code → GET by code)
                                                              show words(link_id, nPk); user compares
                                                              recent auth (passkey tap)
                                                              generate ephemeral (ePk, eSk)
                                                              box(LinkPayload, nonce, nPk, eSk)
                                       ◄───────────────────── POST /link-requests/{id}/approve
poll GET /link-requests/{id} ────────► approved: {ePk, nonce,
◄───────────────────────────────────── ciphertext, grant, username}
confirm "Sign in as @alex?"
POST /auth/link/exchange {grant} ────► SessionTokens
open box; check derived public key
offer: create a passkey on this device (§5.3 + §6.5)
```

### 7.2 Endpoints

`POST /api/v1/link-requests` (unauthenticated, rate-limited per client address)

```json
{"ephemeral_public_key": "base64", "device": {"name": "Work laptop", "platform": "web", "app_version": "1.1.0"}}
```

Response `201`:

```json
{
  "link_id": "opaque",
  "code": "K7Q49MXR",
  "poll_token": "opaque",
  "expires_at": "2026-11-24T12:05:00Z"
}
```

- `code`: 8 Crockford Base32 characters (40 bits), displayed as `K7Q4·9MXR`.
- `poll_token`: at least 32 random bytes, stored hashed. It is N's only
  credential for this request.
- The request lifetime MUST NOT exceed five minutes, and the request is single
  use.

QR payload (a URL, so a phone camera can open the app):

```text
https://{host}/link#v=1&id={link_id}&k={base64url(ephemeral_public_key)}
```

The key travels in the fragment, so it never appears in server or proxy logs.

`GET /api/v1/link-requests/{link_id}` (authenticated as E) or
`GET /api/v1/link-requests/by-code/{code}` (authenticated as E; at most 5
failed lookups per user per 10 minutes) → `200`:

```json
{"link_id": "opaque", "ephemeral_public_key": "base64", "device": {"name": "Work laptop", "platform": "web"}, "expires_at": "..."}
```

`POST /api/v1/link-requests/{link_id}/approve` (authenticated as E, recent
authentication)

```json
{"ephemeral_public_key": "base64", "nonce": "base64", "ciphertext": "base64"}
```

→ `204`. Approval binds the request to E's account. A second approval returns
`409 link_request_not_pending`.

`DELETE /api/v1/link-requests/{link_id}` (E, or N with `poll_token`) →
`204`; the request is cancelled.

`GET /api/v1/link-requests/{link_id}/status` with header
`Veejr-Link-Poll-Token: {poll_token}`:

- `202 {"state": "pending"}`;
- `200 {"state": "approved", "username": "alex", "ephemeral_public_key", "nonce", "ciphertext", "grant": "opaque"}`;
- `410 {"error": {"code": "link_request_expired"}}` once the request is
  expired, cancelled or consumed.

The server MUST delete the approval ciphertext once it has been delivered.
Servers MAY offer the same status as a WebSocket push. Polling is the
baseline, at most once every two seconds.

`POST /api/v1/auth/link/exchange`

```json
{"grant": "opaque", "device": {"name": "Work laptop", "platform": "web", "app_version": "1.1.0"}}
```

→ `200 SessionTokens` plus `account`. The grant is single use, expires within
two minutes of delivery, and creates an ordinary device session (v1 §7.1)
with authenticated-at set to now.

### 7.3 Link payload and sealing

```json
{"v": 1, "kind": "device_link", "link_id": "opaque", "origin": "https://veejrcentral.example", "username": "alex", "identity_secret": "base64"}
```

It is sealed as `nacl.box(utf8(json), nonce, nPk, eSk)` with fresh `ePk/eSk`
and a fresh 24-byte nonce. N MUST:

1. open the box with `nSk` and `ePk`;
2. check that `link_id` and `origin` match its own request;
3. derive the public key from `identity_secret` and check that it equals
   `account.public_key` returned by the exchange;
4. show the username and require confirmation before it stores anything;
5. erase `nSk` after the open succeeds.

### 7.4 Verification words

Both devices display four words:

```text
h     = SHA-256(UTF-8("veejr/link/v1") || UTF-8(link_id) || nPk)
words = BIP-39 English wordlist[ first 44 bits of h, as four 11-bit big-endian indices ]
```

The words protect the typed-code path. If the server swaps `nPk` for its own
key, E computes words over a different key than N shows, and the user sees the
mismatch. On the QR path `nPk` travels out of band, but the words are shown
anyway so that both paths look and behave the same. E's UI MUST make "they
don't match" as prominent as "approve".

### 7.5 Threats specific to linking

- **Server substitutes N's key on the code path:** detected by the words
  (§7.4).
- **Attacker approves a stranger's code with the attacker's own account,**
  trying to sign the victim into an attacker-controlled account: N shows
  "Sign in as @username?" before finishing (§7.3 step 4), and the 40-bit code
  with lookup limits makes guessing impractical.
- **Shoulder-surfed QR code:** the observer gets `nPk`, which is useless
  without `nSk`. The observer would need an account on the victim's own
  identity to approve.
- **Replay:** requests and grants are single use and short lived, and the
  ciphertext is deleted on delivery.

## 8. Client storage guidance (non-normative)

With re-unlock reduced to one tap, web clients SHOULD stop offering the v1
"keep unlocked for up to 30 days" `localStorage` mode. Instead:

- import the unwrapped secret as a **non-extractable** WebCrypto X25519
  `CryptoKey` and keep it in IndexedDB. WebCrypto does not accept a raw
  X25519 private key, so wrap the 32 bytes in the fixed 16-byte PKCS#8
  prefix (`302e020100300506032b656e04220420`) or use JWK;
- compute `box` as WebCrypto `deriveBits` (X25519, 256 bits), then HSalsa20
  over that shared secret with a zero 16-byte input and the standard sigma
  constant (TweetNaCl `lowlevel.crypto_core_hsalsa20`), then `secretbox`.
  This reproduces `nacl.box.before`, and vector 4 in v1 §17 MUST still pass;
- drop the raw secret bytes as soon as the import succeeds.

A script injected into the page could still *use* the key while the page is
open, but it could not *copy* it. Android keeps using a Keystore-wrapped local
copy (v1 §8.2), unlocked biometrically.

## 9. Compatibility

| Situation | Behavior |
| --- | --- |
| v1.0 client, account has a passphrase slot | Unchanged: `wrapped_key` is that slot. |
| v1.0 client, account has no passphrase slot | `wrapped_key` is `null` while `keys_configured` is `true`. The client can sign in but cannot unlock. Its `PUT /keys` gets `409 keys_already_configured`, so nothing is damaged. The web UI SHOULD offer "add a passphrase to use older apps". |
| Federation peer on v1.0 | Unaffected. Only public keys cross instances. |
| Export (`GET /export`) | `export.json` gains `key_slots` containing the `passphrase` and `recovery_code` slots. Passkey slots are omitted because they are bound to the relying party. |
| Account move to a v1.0 target | The target needs a v1 `wrapped_key`. The source MUST refuse to start a move for an account without a passphrase slot and MUST explain how to add one. |
| Account move to a `key_slots` target | Passphrase and recovery slots move. The user re-enrolls passkeys on the new instance, unlocking there once with the recovery code or passphrase. |

## 10. New error codes

| Status | Code | Meaning |
| --- | --- | --- |
| 400 | `challenge_expired` | WebAuthn challenge unknown, used or expired. |
| 401 | `passkey_not_recognized` | Assertion did not verify. Deliberately generic. |
| 409 | `last_key_slot` | Refused to remove the only slot. |
| 409 | `last_recovery_path` | Removing this slot leaves only passkeys; confirm with `?confirm=no_recovery`. |
| 409 | `link_request_not_pending` | Already approved, cancelled or consumed. |
| 410 | `link_request_expired` | Link request or grant is gone. |
| 422 | `slot_key_mismatch` | Slot `public_key` is not the account's current key. |
| 422 | `passkey_slot_exists` | That passkey already has a slot. |

## 11. Interoperability vectors

Add to `protocol-fixtures/` (alongside `v1.json`) before a client or server
claims these extensions:

1. `VEEJR_PRF_INPUT` bytes;
2. HKDF derivations for `passkey_prf` and `recovery_code`, with fixed ikm and
   salt;
3. wrapping and unwrapping a slot with a fixed key, nonce and secret, for
   each kind;
4. recovery-code encoding, display grouping, normalization, and rejection of
   bad input;
5. link code encoding, and the verification words for a fixed `link_id` and
   `nPk`;
6. link payload sealing and opening with fixed ephemeral keys and nonce;
7. failures: a tampered slot, a wrong PRF output, a wrong recovery code, a
   `link_id` mismatch, and a derived-public-key mismatch.

Required directions: browser ↔ Android for 2–6, and veejr-server ↔
veejrcentral for slot storage round trips.

## 12. Implementation notes

**veejr-server (Elixir):**

- Treat the existing `users.enc_secret_key / key_salt / key_nonce` columns as
  the passphrase slot, surfaced as a virtual slot. That needs no data
  migration, and `wrapped_key` stays exactly as it is.
- New tables: `passkeys` (credential ID, COSE public key, sign count, AAGUID,
  transports, label, user handle), `key_slots` (all non-passphrase kinds),
  `link_requests` (hashed poll token, code, both ephemeral keys, ciphertext,
  state, expiry), and `webauthn_challenges`. Expiry sweeps belong in
  `Veejr.Janitor`.
- WebAuthn verification needs a library (for example `wax_`), which adds a
  new dependency and so needs explicit approval under the project rules.
- The browser routes for these flows sit in the existing
  `live_session :current_user` scope (sign-in, link-request creation) and
  `live_session :require_authenticated_user` scope (registration, slots,
  approval), following the router guidance in AGENTS.md.

**veejrcentral (Workers):**

- Store passkeys, slots and link requests in D1. A link request's status can
  live in a Durable Object keyed by `link_id`, so N's poll (or WebSocket) and
  E's approval meet in one place, and an alarm handles expiry.
- `@simplewebauthn/server` runs on Workers.
- The Ed25519, P-256 and HKDF work this extension needs is all available in
  WebCrypto. PBKDF2 never runs server-side in this extension.

## 13. Open questions

1. **Should the email magic link stay as a sign-in factor once passkeys
   exist?** Keeping it makes account recovery easy. Removing it shrinks the
   phishing surface but makes recovery harder. The proposal keeps it: it
   signs in but never unlocks.
2. **Should a non-PRF passkey plus a passphrase be an accepted end state,**
   or should the client keep nudging such users toward PRF-capable
   authenticators?
3. **Does `last_recovery_path` need server enforcement,** or is it enough for
   the client to warn?
4. **Should linking also be allowed between two signed-in devices,** for
   example to push the key to a second browser profile? This draft covers
   only new, unauthenticated devices.
5. **Should passkey slots record which device they live on,** for "this
   passkey is on your iPhone" labels, using AAGUID metadata? That improves
   the UI and leaks a little more device metadata to the server.
