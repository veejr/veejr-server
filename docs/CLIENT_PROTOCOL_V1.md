# veejr client protocol v1

Status: **Draft**  
Intended audience: veejr server, web-client, and native-client implementers  
API base path: `/api/v1`  
Common encrypted payload version: `1`; `self_note` document version: `2`

## 1. Purpose

This document defines the stable contract between a veejr instance and a
first-party client that performs content encryption locally. It extracts the
client-facing behavior currently implemented through Phoenix LiveView events
into a versioned HTTP API suitable for Android and future native clients.

The existing Phoenix contexts, database model, federation protocol, encrypted
blob storage, consent rules, and delivery outbox remain authoritative. The web
application may continue to use LiveView internally. LiveView event names and
rendered HTML are not part of this protocol.

The governing security boundary is:

> Phoenix authenticates identities, authorizes operations, stores ciphertext,
> and performs federation. Clients exclusively handle passphrases, private
> identity keys, content encryption, content decryption, and plaintext.

## 2. Goals and non-goals

### 2.1 Goals

- Allow a native client to use an existing veejr account and identity.
- Preserve interoperability with encrypted content produced by the current web
  client.
- Preserve consent-before-fetch, conversation windows, expiry/display limits,
  sender edits, sender deletion, and key rotation.
- Keep message text, attachment keys, coordinates, and other encrypted payload
  fields out of server-readable storage and logs.
- Give clients stable, typed JSON representations independent of Ecto schemas
  and LiveView assigns.
- Support safe retries, pagination, device-session revocation, and eventual
  background synchronization.

### 2.2 Non-goals

- Replacing the instance-to-instance federation API.
- Hiding traffic metadata from the server, federation peers, or push provider.
- Revoking plaintext or ciphertext already retained by a recipient.
- Providing a server-side plaintext search index.
- Making internal database IDs globally meaningful.
- Changing the version 1 cryptographic algorithms during the Android port.
- Making `/api/v1` federation endpoints. Native clients never hold instance
  federation-signing credentials and never impersonate remote instances.
- Standardizing member-to-member or email-capability guest WebRTC calls,
  ephemeral call-data-channel traffic, scheduled-call lifecycle, or
  instance-local watch-party signaling surfaces. These features exist in the
  web application, but their LiveView/federation events are not part of HTTP
  client protocol v1. A native client MUST NOT infer a stable contract from
  current internal event names; native call support requires an explicit,
  versioned extension.

## 3. Conformance language

The terms **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
used as normative requirements.

An implementation conforms to v1 when it:

1. obeys the authentication and authorization requirements in this document;
2. produces and consumes the specified encrypted payload and envelope formats;
3. passes the cross-client cryptographic vectors described in section 17; and
4. does not transmit client-only secrets to the server.

## 4. Versioning and compatibility

### 4.1 HTTP API version

All native-client endpoints are rooted at `/api/v1`. Backward-incompatible
changes require a new major path such as `/api/v2`.

Adding an optional response field, accepting an additional optional request
field, or adding a new error code is backward compatible. Clients MUST ignore
unknown response fields. Servers MUST reject unknown enum values when accepting
them would change authorization or cryptographic behavior.

### 4.2 Encrypted payload version

Every encrypted JSON payload contains integer field `v`. This document defines
`v: 1` for ordinary message, location, and map-note payloads. The `self_note`
kind uses its separate card-document contract at `v: 2`; see
[SELF_NOTES_KEEP_SPEC.md](SELF_NOTES_KEEP_SPEC.md). Payload/document versioning
is independent of HTTP API versioning. The current `payload_versions: [1]`
capability describes the common payload contract, not self-note document
versions; clients must also gate on `message_kinds` and the decrypted kind.

Clients MUST NOT attempt to render an unsupported payload version as plaintext.
They SHOULD retain the ciphertext and present an "update required" state.

### 4.3 Capability advertisement

`GET /api/v1/capabilities` returns server-supported API and payload versions so
clients can fail before login when incompatible.

```json
{
  "api_versions": [1],
  "payload_versions": [1],
  "max_blob_bytes": 26214400,
  "message_kinds": ["message", "location", "note", "self_note", "self_doc"],
  "instance_mode": "community"
}
```

## 5. Transport and common conventions

### 5.1 Transport security

Release clients MUST use HTTPS and MUST reject cleartext HTTP. A development
build MAY allow loopback or an explicitly user-approved local instance.

Clients MUST NOT silently follow an authenticated request to a different
origin. Redirect handling MUST NOT forward `Authorization` or refresh tokens to
another origin.

### 5.2 Media types

JSON requests use `Content-Type: application/json`. JSON responses use
`application/json`. Encrypted blob bodies use `application/octet-stream`.

UTF-8 is required. JSON object keys are lowercase `snake_case`.

### 5.3 Time

Timestamps are UTC RFC 3339 strings with a `Z` suffix and at least whole-second
precision, for example `2026-07-12T14:30:00Z`. Clients MUST treat server time as
authoritative for expiry and conversation-window behavior.

### 5.4 Identifiers

- `public_id` and `batch_id` are opaque strings.
- Contact, group, friendship, and notification IDs are JSON strings even when
  the current server stores them as integers.
- Clients MUST NOT infer ordering or ownership from an ID.
- Capability IDs MUST be treated as secrets.

### 5.5 Pagination

Collection endpoints use opaque cursor pagination:

```json
{
  "items": [],
  "page": {
    "next_cursor": null,
    "has_more": false
  }
}
```

Clients pass `?cursor=...&limit=50`. Default limit is 50; maximum is 100. A
cursor is scoped to the authenticated user, endpoint, and filters. Invalid or
expired cursors return `invalid_cursor`.

### 5.6 Request IDs and logs

The server SHOULD return `X-Request-ID`. Clients MAY send one. Neither side may
log passphrases, raw private keys, attachment keys, refresh tokens, access
tokens, full ciphertext, or capability URLs.

## 6. Error format

Non-success responses use:

```json
{
  "error": {
    "code": "notification_not_found",
    "message": "The notification was not found.",
    "request_id": "01J...",
    "details": {}
  }
}
```

`code` is stable and intended for client logic. `message` is diagnostic and
MUST NOT be used as a programmatic key. `details` is optional and MUST NOT
contain secrets.

Common status mappings:

| Status | Codes |
| --- | --- |
| 400 | `invalid_request`, `invalid_cursor`, `unsupported_payload_version` |
| 401 | `authentication_required`, `invalid_access_token` |
| 403 | `forbidden`, `key_setup_required`, `recent_authentication_required` |
| 404 | `not_found`, resource-specific `*_not_found` |
| 409 | `conflict`, `key_changed`, `idempotency_conflict` |
| 413 | `blob_too_large`, `ciphertext_too_large` |
| 422 | `validation_failed`, `missing_recipient_key`, `not_friends` |
| 429 | `rate_limited` |
| 502 | `origin_unreachable` |

Validation errors use field arrays:

```json
{
  "error": {
    "code": "validation_failed",
    "message": "The request is invalid.",
    "details": {
      "fields": {"username": ["has already been taken"]}
    }
  }
}
```

## 7. Authentication and device sessions

### 7.1 Model

The native API uses revocable device sessions rather than browser cookies and
CSRF tokens. Access tokens are short-lived bearer credentials. Refresh tokens
are rotating, single-use credentials stored only as hashes by the server.

Recommended initial policy:

- access-token lifetime: 15 minutes;
- refresh-token inactivity lifetime: 30 days;
- absolute device-session lifetime: 90 days;
- refresh-token reuse: revoke the entire device-session family.

The exact durations are server policy and SHOULD be advertised in login and
refresh responses.

### 7.2 Authorization header

Authenticated requests use:

```text
Authorization: Bearer <access_token>
```

The server authenticates the token and constructs `Veejr.Accounts.Scope` for
the owning user. API-facing context functions MUST receive that `current_scope`
as their first argument and MUST preserve existing ownership filters. Existing
context functions that currently accept a bare user should be wrapped or
extended deliberately rather than letting controllers bypass the scope.

### 7.3 Password login

`POST /api/v1/auth/login`

```json
{
  "identifier": "alice@example.com",
  "password": "correct horse battery staple",
  "device": {
    "name": "Alice's Pixel",
    "platform": "android",
    "app_version": "1.0.0"
  }
}
```

Success returns `SessionTokens` and the current account. Invalid credentials
MUST use one generic error and MUST NOT reveal account existence.

### 7.4 Magic-link login

`POST /api/v1/auth/magic-link` requests a one-time login token by username or
email and always returns 202.

```json
{"identifier": "alice"}
```

An HTTPS Android App Link contains a one-time login token. The app exchanges it
using `POST /api/v1/auth/magic-link/exchange` with the same `device` object used
for password login:

```json
{
  "token": "one-time-token-from-the-app-link",
  "device": {
    "name": "Alice's Pixel",
    "platform": "android",
    "app_version": "1.0.0"
  }
}
```

The token MUST be single-use and short-lived. Opening the same link in the web
client remains supported. Android should treat this token as a one-time
passcode and never persist it after the exchange.

### 7.5 Refresh and logout

- `POST /api/v1/auth/refresh` rotates a refresh token and returns a new token
  pair.
- `DELETE /api/v1/auth/session` revokes the current device session.
- `GET /api/v1/devices` lists the user's device sessions without token values.
- `DELETE /api/v1/devices/{device_id}` revokes a selected device session.

`SessionTokens`:

```json
{
  "access_token": "opaque",
  "access_token_expires_at": "2026-07-12T14:45:00Z",
  "refresh_token": "opaque",
  "refresh_token_expires_at": "2026-10-10T14:30:00Z",
  "device_session_id": "opaque"
}
```

The client MUST serialize refresh operations so concurrent requests do not
reuse a rotated refresh token.

### 7.6 Recent authentication

Key rotation/reset, password changes, email changes, export, and account
deletion require recent authentication. The server returns
`recent_authentication_required` when the access token is valid but too old.
A reauthentication endpoint records a new authenticated-at value for the
device session.

## 8. Account and key material

### 8.1 Current account

`GET /api/v1/me`

```json
{
  "account": {
    "id": "42",
    "email": "alice@example.com",
    "username": "alice",
    "display_name": "Alice",
    "handle": "@alice",
    "avatar_url": "/avatars/alice?v=3",
    "confirmed": true,
    "keys_configured": true,
    "public_key": "base64",
    "wrapped_key": {
      "ciphertext": "base64",
      "salt": "base64",
      "nonce": "base64",
      "kdf": {
        "name": "PBKDF2-SHA256",
        "iterations": 310000
      },
      "wrap": "XSalsa20-Poly1305"
    }
  }
}
```

The wrapped secret key is sensitive even though it is encrypted. Responses
containing it MUST use `Cache-Control: no-store`.

### 8.2 Local key storage

The server remains the roaming source for the passphrase-wrapped X25519 secret
key. A native client MAY keep an additional device-local copy encrypted by an
Android Keystore key. That device copy MUST NOT replace or alter the portable
wire format.

The raw identity secret and passphrase MUST NOT be placed in Room, DataStore,
saved UI state, Android backups, crash reports, analytics, notifications, or
API requests. A client SHOULD allow biometric/device-credential gating of the
local Keystore wrapper.

### 8.3 Key operations

- `PUT /api/v1/keys` performs initial key setup.
- `PUT /api/v1/keys/wrapped` changes only wrapping material.
- `GET /api/v1/keys/resealable` returns the current user's decryptable envelope
  copies with `peer_key`.
- `POST /api/v1/keys/rotate` atomically replaces key material and reseals the
  supplied user-addressed envelope copies.
- `POST /api/v1/keys/reset` atomically purges user-addressed envelope copies and
  installs a new key.

Initial setup accepts the portable wrapper representation returned by
`GET /api/v1/me`:

```json
{
  "public_key": "base64",
  "wrapped_key": {
    "ciphertext": "base64",
    "salt": "base64",
    "nonce": "base64",
    "kdf": {"name": "PBKDF2-SHA256", "iterations": 310000},
    "wrap": "XSalsa20-Poly1305"
  }
}
```

Success returns `201` with the updated `Account` representation. Initial setup
is create-only; an account that already has keys receives `409
keys_already_configured`.

All supplied key fields are standard padded Base64. Rotation/reset require
recent authentication. The server MUST validate lengths and ownership but MUST
NOT attempt to decrypt key material.

## 9. Resource representations

### 9.1 User summary

```json
{
  "id": "7",
  "username": "bob",
  "display_name": "Bob",
  "avatar_url": "/avatars/bob?v=2",
  "host": "other.example",
  "handle": "@bob@other.example",
  "public_key": "base64",
  "pending_key_change": false
}
```

`host` is `null` for a local user. `public_key` appears only where the caller is
authorized to encrypt to that user. `avatar_url` is nullable and identifies a
public, cache-versioned JPEG; clients resolve relative URLs against the instance
origin and render their own placeholder when it is `null`.

### 9.2 Notification

```json
{
  "id": "91",
  "state": "pending",
  "kind": "message",
  "sender": {"id": "7", "handle": "@bob@other.example"},
  "envelope_public_id": "opaque",
  "created_at": "2026-07-12T14:00:00Z",
  "expires_at": null,
  "max_displays": null
}
```

Pending notification responses contain metadata only and MUST NOT include
ciphertext, nonce, blob IDs, attachment descriptors, message text, or
coordinates.

### 9.3 Envelope

```json
{
  "public_id": "opaque",
  "batch_id": "opaque",
  "kind": "message",
  "ciphertext": "base64",
  "nonce": "base64",
  "peer_key": "base64",
  "sender": {"id": "7", "handle": "@bob@other.example"},
  "sent_by_me": false,
  "resealed": false,
  "created_at": "2026-07-12T14:00:00Z",
  "edited_at": null,
  "delivered_at": "2026-07-12T14:02:00Z",
  "expires_at": null,
  "max_displays": null,
  "display_count": 0
}
```

`peer_key` is the exact public key the client MUST use with its current secret
key to open this copy. It follows the existing sender-key snapshot and resealed
envelope rules.

## 10. Contacts, friendships, and groups

The following endpoints are authenticated and ownership scoped:

| Method and path | Purpose |
| --- | --- |
| `GET /contacts` | Accepted friends, requests, notes, and pending key changes |
| `POST /friend-requests` | Request local or federated address |
| `POST /friend-requests/{id}/accept` | Accept an incoming request |
| `POST /friend-requests/{id}/decline` | Decline an incoming request |
| `DELETE /friends/{id}` | Remove an accepted friend |
| `POST /friends/{id}/confirm-key` | Confirm a pinned remote key change |
| `PUT /contacts/{id}/note` | Upsert the owner's plaintext contact note |
| `GET /groups` | List owned groups with members and notes |
| `POST /groups` | Create a group |
| `PATCH /groups/{id}` | Rename an owned group |
| `DELETE /groups/{id}` | Delete an owned group |
| `POST /groups/{id}/members` | Add an accepted friend |
| `DELETE /groups/{id}/members/{user_id}` | Remove a member |
| `PUT /groups/{id}/note` | Upsert the owner's plaintext group note |

Contact and group notes are server-readable plaintext, as in the existing web
application. Clients MUST label this distinction clearly and MUST NOT imply
that these notes are end-to-end encrypted.

For native policy controls, `GET /groups` returns only caller-owned groups:

```json
{
  "groups": [
    {
      "id": "3",
      "name": "Inner circle",
      "members": [{"id": "7", "handle": "@bob"}]
    }
  ]
}
```

The `GET /contacts` recipient summary includes `avatar_url` and `auto_accept`,
the effective result after conversation, contact, and group precedence.
Explicit overrides remain distinguishable through
`GET /message-delivery-policies`.

Contact and group summaries also include the caller-owned plaintext `note`.
`PUT /contacts/{id}/note` and `PUT /groups/{id}/note` accept `{"body":"..."}`.
These private notes are readable by the caller's server and MUST be labelled
as not end-to-end encrypted in native clients.

## 11. Recipient resolution

`POST /api/v1/recipients/resolve`

```json
{
  "friend_ids": ["7"],
  "group_ids": ["3"],
  "include_self": false
}
```

Response:

```json
{
  "recipients": [
    {
      "id": "7",
      "username": "bob",
      "handle": "@bob@other.example",
      "public_key": "base64"
    }
  ],
  "missing_keys": []
}
```

The server MUST expand only groups owned by the caller, include only the caller
or accepted friends, and deduplicate recipients. The client MUST stop before
sending when `missing_keys` is non-empty.

Recipient resolution is a convenience, not an authorization grant. The server
MUST revalidate every recipient atomically when storing a batch.

## 12. Consent and envelope flow

### 12.1 List pending metadata

`GET /api/v1/notifications?state=pending` returns non-expired pending
notifications newest first.

```json
{
  "notifications": [
    {
      "id": "17",
      "kind": "message",
      "sender": {"id": "7", "handle": "@bob@other.example"},
      "created_at": "2026-07-12T14:00:00Z",
      "expires_at": null,
      "max_displays": null
    }
  ]
}
```

This representation intentionally excludes envelope IDs, ciphertext, nonces,
and keys. Those fields are released only after acceptance.

### 12.2 Accept

`POST /api/v1/notifications/{id}/accept`

Acceptance opens or extends the existing five-minute conversation window. For
a federated stub, the server fetches ciphertext from the pinned origin at this
point. If the origin cannot be reached, the server returns 502
`origin_unreachable` and MUST leave the notification pending.

On success the response SHOULD include the accepted `Envelope`, avoiding a
second round trip. No ciphertext may be returned before acceptance.

The v1 response is `{"envelope": Envelope}` using the representation in
section 9.3.

### 12.3 Decline

`POST /api/v1/notifications/{id}/decline` changes only a caller-owned pending
notification. Declined remote content is never fetched for that recipient.
Success returns `204 No Content`.

### 12.4 Automatic delivery policies

Users may explicitly allow encrypted messages from accepted friends to bypass
the per-message consent prompt. This changes when ciphertext is released; it
does not give the server access to plaintext and does not authorize background
identity-key unlocking.

Policies have `subject_type` (`contact`, `group`, or `conversation`), a
string `subject_id`, `acceptance` (`ask` or `automatic`), and `notification`
(`normal`, `preview`, or `silent`). The authenticated owner may manage only
accepted contacts, owned groups, and conversations with accepted contacts.

Precedence is conversation, then contact, then matching recipient-owned
groups, then the default `ask`. When multiple matching group policies exist,
`ask` wins. A pending unconfirmed contact key change always forces `ask`.
Deleting an override restores inheritance.

| Method and path | Purpose |
| --- | --- |
| `GET /message-delivery-policies` | List explicit caller-owned overrides |
| `PUT /contacts/{id}/message-delivery-policy` | Set a contact override |
| `PUT /groups/{id}/message-delivery-policy` | Set a group override |
| `PUT /conversations/{peer_id}/message-delivery-policy` | Set a conversation override |
| `DELETE` on any policy path | Restore inherited behavior |

An automatically accepted message enters encrypted history immediately. A
client may decrypt it only while the identity secret is already available or
through a separately enabled, device-protected key. Background decryption MUST
NOT record a display. Notification previews MUST NOT contain plaintext unless
the user separately enables device-protected background decryption.

### 12.5 Fetch

`GET /api/v1/envelopes/{public_id}` returns an envelope only when the caller is:

- the sender reading its self-copy; or
- the addressed recipient with an accepted notification.

Expired or exhausted envelopes return 404 so callers cannot distinguish them
from nonexistent IDs.

## 13. Sending encrypted content

### 13.1 Compose algorithm

For every send, a conforming client:

1. resolves recipients;
2. encrypts each attachment once and uploads only encrypted bytes;
3. builds one encrypted payload shared logically by all copies;
4. seals that payload independently to every recipient public key;
5. creates a self-copy sealed to the sender's public key unless self is already
   present; and
6. submits all copies in one batch request.

### 13.2 Send endpoint

`POST /api/v1/message-batches`

The client MUST send an `Idempotency-Key` header containing a random value with
at least 128 bits of entropy. The server stores the key scoped to the device
session and operation. Retrying an identical request returns the original
result. Reusing it with a different body returns 409 `idempotency_conflict`.

```json
{
  "kind": "message",
  "expires_at": null,
  "max_displays": null,
  "attachment_ids": ["opaque-capability"],
  "envelopes": [
    {
      "recipient_id": "7",
      "ciphertext": "base64",
      "nonce": "base64"
    },
    {
      "recipient_id": "42",
      "ciphertext": "base64",
      "nonce": "base64"
    }
  ]
}
```

Success:

```json
{
  "batch_id": "opaque",
  "copies": [
    {"recipient_id": "7", "public_id": "opaque"},
    {"recipient_id": "42", "public_id": "opaque"}
  ],
  "queued_recipients": []
}
```

`queued_recipients` is always an empty list: notifications to remote
instances are queued for background delivery with automatic retries, so no
recipient is known-unreachable at request time. The field is retained for v1
compatibility and clients MUST tolerate entries appearing in it.

The server MUST atomically validate that every recipient is the sender or an
accepted friend. It MUST reject the entire batch on failure. It MUST require
exactly one sender self-copy in v1. It MUST NOT synthesize encrypted copies.
Each `attachment_ids` entry MUST identify a blob owned by the sender. The
server links those opaque IDs to the batch atomically without learning file
names, media types, keys, or other encrypted descriptor fields.

Allowed kinds are `message`, `location`, `note`, `self_note`, and `self_doc`. A
`self_note` or `self_doc` batch MUST contain exactly one envelope addressed to
its sender, MUST NOT carry an expiry, display limit, or `deliver_at`, and MUST
NOT produce a notification or federation delivery. Its decrypted payload is a
versioned document; title, body, labels, checklist items, cells, blocks,
attachment descriptors, and card state remain inside the ciphertext.

This version of the native batch endpoint accepts `kind: "message"` only.
`self_note` and `self_doc` are listed in `message_kinds` so a client can
recognize items it receives but does not create.

`max_displays` is either
null or 1 through 100. `expires_at` is null or a future timestamp within the
server's maximum allowed horizon. Invalid options MUST be rejected rather than
silently normalized by the API.

### 13.3 History

`GET /api/v1/envelopes?kind=message&cursor=...` returns the caller's self-copies
and accepted received copies, newest first. `kind` is optional. Expired and
display-exhausted content is omitted.

Responses contain at most 50 encrypted envelopes and a nullable `next_cursor`.
Passing that cursor returns the next older page. Cursors are scoped to the
authenticated owner; an unknown or foreign cursor returns 400 `invalid_cursor`.

The API returns encrypted copies; conversation grouping remains client
presentation logic in v1.

### 13.4 Record display

After successful authenticated decryption and actual display, the client calls
`POST /api/v1/envelopes/{public_id}/displays` with an idempotency key unique to
that local display event. It MUST NOT call this for decryption used only for
background indexing, migration, key rotation, or a failed render.

Display limits are a cooperative server access control and cannot revoke
content already retained by a client.

### 13.5 Edit and delete

- `GET /api/v1/envelopes/{public_id}/editable-batch` returns every copy ID,
  recipient ID, public key, and handle for a caller-owned batch.
- `PUT /api/v1/envelopes/{public_id}/batch` atomically replaces caller-owned
  ciphertext copies and sets `edited_at`.
- `DELETE /api/v1/envelopes/{public_id}` deletes the complete batch when called
  by its sender; for a recipient it hides only that recipient's copy by
  declining its notification.

Sender batch deletion releases its blob references and removes each encrypted
blob whose final reference disappeared. Recipient hide never removes blobs.

Clients MUST decrypt and re-encrypt edits locally for every copy. The initial
web client does not edit messages containing attachments; v1 clients SHOULD
preserve that restriction until attachment lifecycle semantics are specified.

## 14. Encrypted payload format

### 14.1 Serialization

The plaintext input to `nacl.box` is the UTF-8 encoding of a compact JSON
object. Object member ordering and insignificant whitespace are not
cryptographically canonical in payload v1 because each ciphertext carries its
own authenticated bytes. Test vectors MUST nevertheless specify the exact JSON
byte string used to make deterministic fixtures possible.

Clients MUST validate decrypted values before rendering or using them. Text is
plain text, never HTML or Markdown. Native clients MUST NOT execute or interpret
decrypted content as code.

### 14.2 Common payload

```json
{
  "v": 1,
  "kind": "message",
  "text": "Hello",
  "attachments": [],
  "to": ["@bob@other.example"],
  "sent_at": "2026-07-12T14:00:00.000Z"
}
```

Required fields:

| Field | Type | Rule |
| --- | --- | --- |
| `v` | integer | Exactly `1` |
| `kind` | string | Matches envelope metadata |
| `text` | string | Plain UTF-8 text; may be empty |
| `attachments` | array | May be empty |
| `to` | string array | Recipient handles for decrypted group context |
| `sent_at` | timestamp | Client composition time |

The server does not inspect these fields because they exist only inside
ciphertext. Clients SHOULD flag, but need not reject, a decrypted `kind` that
does not match server metadata.

### 14.3 Location and note extensions

A `location` payload additionally contains numeric `lat`, numeric `lng`, and
`located_at`. A `note` payload contains numeric `lat` and `lng`, and MAY contain
`title`. Coordinates MUST remain inside encrypted payloads.

Latitude is between -90 and 90. Longitude is between -180 and 180. Clients MUST
reject non-finite values.

### 14.4 Self-note document

A `self_note` envelope contains document `v: 2`, `kind: "self_note"`, a random
`note_id`, title/body, checklist, labels, color, pin/archive/trash state,
created/updated timestamps, attachment descriptors, and card settings. All
fields remain inside ciphertext. Clients that do not implement this document
MUST retain or safely omit the encrypted item and MUST NOT reinterpret it as a
version-1 message.

### 14.5 Self-document

A `self_doc` envelope contains document `v: 1`, `kind: "self_doc"`, a random
`doc_id`, a `doc_kind` of `"sheet"` or `"page"`, title, labels, color, card
state, timestamps, and exactly one of a `sheet` or `page` body. The format is
named inside the ciphertext, so a server distinguishes documents from each
other no more than it distinguishes two notes. Clients that do not implement it
MUST retain the encrypted item unchanged and MUST NOT reinterpret it. The
payload contract is in [DOCUMENTS.md](DOCUMENTS.md).

The complete validation and privacy rules are in
[SELF_NOTES_KEEP_SPEC.md](SELF_NOTES_KEEP_SPEC.md#7-encrypted-payload-contract).

### 14.5 Attachment descriptor

```json
{
  "id": "opaque-capability",
  "origin": "https://alice.example",
  "key": "base64",
  "nonce": "base64",
  "name": "photo.jpg",
  "mime": "image/jpeg",
  "size": 123456,
  "duration_ms": null
}
```

The entire descriptor is encrypted inside the payload. `origin` identifies the
instance storing the blob. Clients MUST validate it as an HTTPS origin in
release builds, MUST NOT attach credentials when fetching from it, and MUST NOT
forward a local instance access token across origins.

`name` and `mime` are untrusted display hints after decryption. Clients MUST
sanitize filenames, select safe viewers, and never execute downloaded content.

## 15. Cryptographic wire format

### 15.1 Encoding

Binary fields use standard padded Base64 as produced by the current browser
`btoa` implementation. They are not Base64URL.

### 15.2 Identity keys

- algorithm: X25519-compatible keypair exposed by TweetNaCl `box`;
- public key: 32 bytes;
- secret key: 32 bytes.

### 15.3 Wrapping

1. Encode the passphrase as UTF-8 without normalization.
2. Generate a random 16-byte salt.
3. Derive 32 bytes using PBKDF2-HMAC-SHA256 with 310,000 iterations.
4. Generate a random 24-byte nonce.
5. Wrap the raw 32-byte identity secret with XSalsa20-Poly1305 secretbox.

Clients MUST use a cryptographically secure random source. Passphrase handling
MUST remain entirely client-side.

### 15.4 Envelope sealing

For each recipient:

1. serialize the payload JSON to UTF-8 bytes;
2. generate a random 24-byte nonce;
3. compute TweetNaCl `box(payload, nonce, recipient_public_key,
   sender_secret_key)`;
4. Base64-encode ciphertext and nonce.

Opening uses the envelope's `peer_key` and the reader's current secret key.
Authentication failure MUST produce a non-rendering error state.

### 15.5 Attachment sealing

For each attachment:

1. generate a random 32-byte secretbox key;
2. generate a random 24-byte nonce;
3. secretbox the complete file bytes once;
4. upload only the authenticated ciphertext; and
5. place key, nonce, metadata, capability ID, and origin in the encrypted
   payload descriptor.

## 16. Blob API

### 16.1 Upload

`POST /api/v1/blobs` is authenticated, accepts `application/octet-stream`, and
requires `Idempotency-Key`. The body is already encrypted.

```json
{"id": "opaque-capability", "size": 123472}
```

The server enforces its advertised maximum ciphertext size. A client SHOULD
upload blobs before sending the batch and MUST include every successful upload
ID in the batch's `attachment_ids`. New unreferenced uploads are treated as
abandoned after 24 hours. Servers MUST preserve legacy blobs whose references
predate explicit tracking.

### 16.2 Download

Same-instance clients MAY use authenticated `GET /api/v1/blobs/{id}`. Federated
attachments use unauthenticated capability fetch
`GET {origin}/api/blobs/{id}` as already defined by veejr federation.

The client MUST authenticate the secretbox before exposing bytes to another
app or renderer. It MUST compare the decrypted size with descriptor metadata
only as an informational integrity check; secretbox authentication is
authoritative.

## 17. Cryptographic interoperability vectors

Before `/api/v1` or Android messaging is considered complete, the repository
MUST contain machine-readable fixtures for:

1. UTF-8 and standard Base64 encoding;
2. PBKDF2-SHA256 with fixed passphrase, salt, and 310,000 iterations;
3. secret-key wrapping and unwrapping with fixed key and nonce;
4. message sealing/opening with fixed sender/recipient keys and nonce;
5. attachment secretbox with fixed bytes, key, and nonce;
6. all v1 payload kinds;
7. Unicode text and filenames;
8. sender-key snapshots after rotation;
9. resealed self/received envelopes; and
10. tampered ciphertext, nonce, wrong passphrase, and wrong peer-key failures.

Randomized production APIs SHOULD be wrapped by deterministic test helpers that
accept fixed nonces and keys only in test code.

Required interoperability directions:

- browser encrypts, Android decrypts;
- Android encrypts, browser decrypts;
- Android uploads, browser downloads/decrypts;
- browser uploads, Android downloads/decrypts; and
- Android rotation output remains readable by the browser.

Fixture generation MUST NOT rely on production secrets.

The canonical v1 fixture is `protocol-fixtures/v1.json`. Regenerate it with
`node scripts/protocol_fixtures.mjs generate` and verify it with
`mix protocol.verify`. The fixture intentionally contains fixed test-only
private keys and MUST never be reused for an account or production content.

Verification runs in two stages. The first rebuilds the fixture from raw
tweetnacl calls, proving the recorded values are internally consistent. The
second replays the same fixture through `assets/js/veejr/crypto.js` — the
module browsers actually load — using its real `unlockIdentity`, `openFrom`,
and `decryptBlob`. Without the second stage a regression in the shipped module
(changed KDF iterations, transposed key/nonce arguments, a broken base64
helper) would leave the fixture matching and the check passing. Any client
claiming v1 compatibility SHOULD verify against its own shipping crypto code
rather than against a reimplementation of it.

## 18. Synchronization and idempotency

v1 uses server-authoritative metadata and a client ciphertext cache.

- Clients SHOULD store contacts, groups, notification metadata, envelopes, and
  sync cursors locally.
- Clients SHOULD NOT persist decrypted message bodies by default.
- Foreground entry, push receipt, and manual refresh trigger incremental sync.
- Background work MUST tolerate process death and repeated execution.
- A push notification is a hint, never the sole record of an event.
- On a push gap or invalid cursor, the client performs a bounded full sync.

Mutating endpoints that can be retried after an ambiguous network result MUST
accept `Idempotency-Key`, including send, blob upload, display recording, key
rotation, and device-token registration.

The server SHOULD expose `ETag`/`If-None-Match` for slowly changing resources
such as capabilities, current account, contacts, and groups.

## 19. Android push

Web Push remains supported for browsers. Android devices register an FCM token
through:

- `PUT /api/v1/devices/{device_id}/push-token`
- `DELETE /api/v1/devices/{device_id}/push-token`

The server stores each token against the authenticated device session and
dispatches through an Android push adapter. Token refresh replaces the prior
token idempotently.

Push payloads MUST NOT contain plaintext, ciphertext, envelope/blob capability
IDs, attachment keys, passphrases, private keys, access tokens, or refresh
tokens. They MAY contain a generic event type, notification count, sender
handle, and content kind. The client uses the authenticated API to synchronize.

FCM is optional instance functionality. `GET /capabilities` SHOULD advertise
`android_push: true|false`. Clients MUST remain usable with foreground/manual
sync when it is false.

## 20. Routing and Phoenix boundaries

The server implementation places native routes in a dedicated scope:

```elixir
scope "/api/v1", VeejrWeb.Api.V1 do
  pipe_through [:api, :fetch_api_scope, :require_api_user]

  # authenticated native-client routes
end
```

Public capabilities and login endpoints use an API pipeline without
`:require_api_user`. Authenticated endpoints use a bearer-token plug that
assigns `current_scope`.

These routes MUST NOT be placed in `live_session :current_user`,
`live_session :require_authenticated_user`, or `live_session :app`: those
sessions exist for browser LiveViews, while native clients have no LiveView
mount lifecycle. They also MUST NOT be added to the signed `:federation`
pipeline, which authenticates instances rather than users.

Controller modules SHOULD be namespaced under `VeejrWeb.Api.V1`. The API layer
performs parsing and representation only; authorization and domain invariants
remain in the existing contexts. JSON views/serializers MUST use explicit maps
and MUST NOT expose Ecto structs directly.

## 21. Security invariants

A conforming implementation preserves all of the following:

- Passphrases and raw identity secrets never leave the client.
- The server receives only public keys, wrapped secret keys, ciphertext,
  nonces, encrypted blobs, and permitted metadata.
- Ciphertext is unavailable to a recipient before acceptance, except during an
  already-active server conversation window.
- Every submitted recipient is reauthorized inside the send transaction.
- A sender self-copy is present for every batch.
- Remote identity-key changes remain pinned until manually confirmed.
- Capability identifiers are never included in push messages or logs.
- Bearer credentials are never sent to attachment origins other than the
  authenticated home instance.
- Expired or display-exhausted resources do not reveal whether an ID existed.
- Key rotation is atomic with resealing; reset is atomic with received-copy
  purging.
- Existing web and federation authorization behavior does not regress when the
  native API is introduced.

## 22. MVP vertical slice

The first implementation milestone includes only the endpoints necessary to
prove the complete trust boundary:

1. `GET /capabilities`
2. `POST /auth/login`
3. `POST /auth/refresh`
4. `DELETE /auth/session`
5. `GET /me`
6. `GET /contacts` (read-only accepted friends)
7. `POST /recipients/resolve`
8. `GET /notifications?state=pending`
9. `POST /notifications/{id}/accept`
10. `POST /notifications/{id}/decline`
11. `GET /envelopes/{public_id}`
12. `GET /envelopes?kind=message`
13. `POST /message-batches`

The vertical-slice acceptance scenario is:

1. Android logs into an existing account.
2. Android retrieves and locally unlocks the existing wrapped identity key.
3. A web client sends an encrypted text message.
4. Android sees metadata only while the notification is pending.
5. Android accepts, fetches, and decrypts the envelope.
6. Android resolves the sender and creates a reply plus self-copy.
7. Phoenix stores and delivers the batch without seeing plaintext.
8. The existing web client decrypts the Android reply.
9. The same flow succeeds across two federated instances.

No MVP endpoint is complete without authorization tests and cross-client crypto
tests.

## 23. Deferred v1 surface

The following remain part of the intended v1 contract but may follow the MVP:

- registration, confirmation, and full magic-link UX;
- friendship and group mutations;
- contact and group notes;
- encrypted attachments and audio capture;
- message editing, deletion, expiry, and display limits;
- location sharing and geo-notes;
- push registration and background sync;
- rewrap, rotation, reset, and remote-key confirmation;
- settings, export download, and account deletion.

Browser member and guest calls (up to three participants), scheduled calls, and
instance-local watch parties are implemented product features but are outside
this HTTP API version. Native parity for calls, ephemeral call chat/files,
synchronized YouTube, and watch-party voice remains deferred until a separate
signaling/lifecycle contract is specified. That contract must carry per-call
membership and an explicit signal target, not a caller/callee pair: the browser
mesh already depends on both.

Deferral does not permit an incompatible provisional format. Implemented v1
endpoints must follow this document.

## 24. Remaining implementation decisions

The following product/platform decisions still require explicit resolution and
a spec update:

1. **Map provider:** whether the Android client may depend on Google Play
   Services or must use an OpenStreetMap-compatible native renderer.
2. **Minimum Android API:** determines Keystore, biometric, notification, and
   media compatibility policy.
3. **Offline plaintext policy:** v1 recommends memory-only plaintext; any
   encrypted local plaintext cache needs a separate threat model.
4. **Registration scope:** whether the first Android release supports new
   accounts or only existing-account login.

Resolved decisions:

- Each self-hosted instance optionally supplies its own FCM service-account
  credential. Android push is disabled when it is absent.
- Native device and refresh-token state uses dedicated device-session,
  refresh-history, and idempotency tables rather than `user_tokens`.
- New uploads carry explicit batch references. Unreferenced tracked uploads are
  abandoned after 24 hours, while pre-tracking legacy blobs remain protected.

## 25. Definition of done

The protocol foundation is ready for Android feature work when:

- this document has been reviewed against current Phoenix context behavior;
- all MVP endpoints have request/response contract tests;
- device token rotation and revocation tests pass;
- browser/Android golden crypto vectors pass in both directions;
- two-instance federation end-to-end messaging passes;
- sensitive-value logging tests or assertions cover API boundaries;
- the existing LiveView and federation test suites remain green; and
- `mix precommit` passes.
