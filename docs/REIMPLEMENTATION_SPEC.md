# Veejr reimplementation specification

Status: normative baseline for a compatible reimplementation  
Baseline: veejr-server v0.3.16 (commit `7731232`) and client protocol v1
Date: 2026-07-22

## 1. Purpose

This document specifies Veejr independently of its current Elixir, Phoenix,
LiveView, Kotlin, and SQLite implementation. It is intended to be sufficient
for rebuilding Veejr in another language, framework, database, operating
system, or deployment environment while preserving user-visible behavior,
stored data, security properties, federation, and client compatibility.

The words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are normative. A product
that changes a MUST requirement is a new protocol or product version, not a
drop-in Veejr implementation.

This specification describes the complete product. Exact native-client JSON
representations and cryptographic fixtures remain additionally governed by
[CLIENT_PROTOCOL_V1.md](CLIENT_PROTOCOL_V1.md) and
`protocol-fixtures/v1.json`.

## 2. Product definition

Veejr is a small, self-hosted, federated social messaging service. Users keep
contacts and private notes, organize contacts into local groups, exchange
end-to-end encrypted messages and media, share encrypted locations and map
notes, make consent-gated peer-to-peer calls, watch synchronized YouTube with
other users, and may move between independently operated Veejr instances.

The home server authenticates users, enforces social and delivery policy,
stores opaque ciphertext and encrypted files, and coordinates federation. It
MUST NOT receive message plaintext, attachment plaintext or keys, location
coordinates, or the user's encryption passphrase.

### 2.1 Primary goals

1. End-to-end encrypt shared content before it leaves a web or native client.
2. Require recipient consent before ciphertext retrieval, except during an
   explicitly active or configured auto-accept conversation.
3. Support local and cross-instance friendships with stable user addresses.
4. Remain practical for one person to install, operate, back up, and restore.
5. Provide account portability and an administrator-mediated move to a new
   instance without silently severing established friendships.
6. Preserve the same trust boundaries across browser and native clients.

### 2.2 Explicit non-goals and limitations

- Veejr does not hide account, friendship, sender/recipient, timestamp,
  content-kind, attachment-size, IP, or delivery-timing metadata.
- Browser end-to-end encryption does not protect against a compromised server
  that replaces the JavaScript client.
- Expiry, display limits, edits, and deletion cannot revoke plaintext or bytes
  already retained, recorded, or captured by a recipient.
- The current federation trust model is trust on first use (TOFU), not a global
  public-key infrastructure.
- Contact and group notes are private by authorization but are plaintext on the
  user's server. They are not end-to-end encrypted.
- The current account-export format cannot discover or include received
  attachment blobs because their identifiers are inside ciphertext.
- Peer-to-peer calls reveal network-address metadata to the peer unless TURN is
  used. TURN and YouTube operators still observe connection/request metadata.
- Call chat/files and watch-party state are ephemeral. They are not message
  history, survive neither disconnect nor restart, and cannot be recovered or
  exported by the server.

## 3. Actors and identities

### 3.1 Actors

| Actor | Description |
| --- | --- |
| Visitor | Unauthenticated person viewing the home, registration, login, or invitation flow. |
| Local user | Account whose credentials and home authority belong to this instance. |
| Remote user | Local address-book stub for a user hosted by another authority. |
| Instance administrator | Permanent first local account with instance-management powers. |
| Browser client | Server-delivered application using cookie sessions and client-side cryptography. |
| Native client | Independently distributed application using API device sessions. |
| Peer instance | Another Veejr authority communicating through signed federation requests. |
| Provisioner | Host-side trusted process that creates and verifies isolated Veejr instances. |

### 3.2 User and instance identity

- An instance is identified by a canonical authority: lowercase DNS host plus
  optional port. Production authorities MUST use HTTPS.
- A user is addressed as `username@authority`. Local UI MAY abbreviate a local
  user as `@username`.
- Usernames MUST be unique within one authority and treated case-insensitively
  for lookup.
- A local user has authentication credentials and wrapped encryption-key
  material. A remote-user row MUST NOT be usable for local authentication.
- Remote profile data is a cache. The remote home authority remains canonical.
- Every instance has one Ed25519 federation identity that must survive backups,
  restores, upgrades, and host moves.

## 4. Required system boundaries

A conforming deployment contains the following logical components. They MAY be
one process or many, but their trust and transaction boundaries must remain.

| Component | Responsibility |
| --- | --- |
| Web application | Authentication, HTML application shell, authenticated user workflows, administration. |
| Versioned client API | Bearer-authenticated native-client contract under `/api/v1`. |
| Cryptographic client | Key generation/unlock, payload encryption/decryption, attachment encryption, safe plaintext rendering. |
| Domain service | Authorization, friendships, groups, consent, envelope lifecycle, quotas, export/import. |
| Durable relational store | Accounts, metadata, ciphertext, credentials, policies, audit state, jobs. |
| Blob store | Opaque encrypted attachment bytes addressed by random capabilities. |
| Realtime event bus | Foreground notification and message refresh hints. |
| Peer-session coordinator | Consent/lifecycle and sealed signaling relay for calls and ephemeral watch-party voice. |
| Federation worker | Signed peer requests and durable retry processing. |
| Push adapters | Browser Web Push and optional Android FCM metadata-only notifications. |
| Mail adapter | Transactional confirmation, login, invitation, and administrative mail through a configured SMTP provider. |
| Reverse proxy/TLS edge | Canonical HTTPS host, certificate management, request forwarding, websocket support. |
| Optional provisioner | Isolated test import and creation of a new single-user instance during account move. |

The application MUST work with one authoritative writer. A database capable of
safe concurrent writers MAY be used, but the implementation must preserve the
atomic operations in section 12.

## 5. Account lifecycle and authentication

### 5.1 Registration policy

The instance has an immutable deployment mode and an administrator-configured
registration policy.

| Mode/policy | Required behavior |
| --- | --- |
| Community default | Open registration. |
| Personal default | Only the first account is open; later registration requires a valid invitation. |
| `open` override | Anyone may register. |
| `invitation_only` override | A valid, unexpired, unrevoked invitation is required. |
| `closed` override | Registration is disabled. |

Registration requires a valid email and unique username. Display name is
optional. Password login is optional per account; email confirmation and
one-time magic-link login MUST remain available when mail is configured.
Responses requesting a magic link MUST not reveal whether an account exists.

### 5.2 Browser sessions

- Browser authentication uses secure, HTTP-only, same-site cookies and CSRF
  protection for state-changing requests.
- Session fixation protection MUST rotate the session identifier at login.
- Suspended users MUST be rejected even when an old session cookie is valid.
- Login, confirmation, email-change, and reset tokens MUST be random,
  single-purpose, hashed or otherwise protected at rest, expiring, and
  single-use where appropriate.

### 5.3 Native device sessions

- Access tokens are short-lived bearer tokens; the recommended lifetime is 15
  minutes.
- Refresh tokens are rotating, single-use credentials stored only as hashes.
- Reuse of an old refresh token MUST revoke its device-session family.
- Recommended refresh inactivity and absolute session lifetimes are 30 and 90
  days respectively.
- Device metadata includes name, platform, app version, authentication time,
  last-used time, and optional push token.
- Logout revokes the current device session. Administrators can revoke all
  sessions for a member.
- Concurrent client refreshes MUST be serialized by the client.

### 5.4 Suspension and deletion

- Suspension blocks login and authenticated activity without deleting data.
- Suspending a user revokes browser and native sessions.
- The instance administrator cannot be suspended, deleted, or moved.
- Ordinary account deletion removes the local account, dependent metadata, and
  owned blob files. It MUST not leave files whose database rows were cascaded.
- Managed account moves use the stricter workflow in section 11 and do not
  delete the source account until target verification and explicit finalization.

## 6. Client-side identity and cryptography

### 6.1 Identity-key setup

On first key setup, the client MUST:

1. Generate a TweetNaCl-compatible X25519 `box` keypair (32-byte public and
   secret keys).
2. Encode the passphrase as UTF-8 without normalization.
3. Generate a random 16-byte salt.
4. Derive 32 bytes with PBKDF2-HMAC-SHA256, 310,000 iterations.
5. Generate a random 24-byte nonce.
6. Wrap the raw identity secret using XSalsa20-Poly1305 `secretbox`.
7. Send only the public key, wrapped secret, salt, and nonce to the server.

Binary protocol fields use standard padded Base64, not Base64URL. All random
values MUST come from a cryptographically secure random source.

The unlocked secret key SHOULD remain memory-only. The web client MAY keep it
in tab-scoped `sessionStorage`; it MUST NOT persist the passphrase or unwrapped
key in server storage, logs, cookies, or ordinary local storage.

### 6.2 Payload encryption

Plaintext is compact UTF-8 JSON:

```json
{
  "v": 1,
  "kind": "message",
  "text": "Hello",
  "attachments": [],
  "to": ["@bob@other.example"],
  "sent_at": "2026-07-17T12:00:00.000Z"
}
```

Allowed kinds are `message`, `location`, `note`, and `self_note`. A `self_note`
is a single sender-to-self encrypted envelope and MUST NOT create delivery
notifications, expiry/display limits, or federation work. Its note title,
body, labels, checklist, attachments, and board state remain encrypted. Common
message/location/map-note payloads use `v: 1`; the self-note card document uses
`v: 2` as specified in [SELF_NOTES_KEEP_SPEC.md](SELF_NOTES_KEEP_SPEC.md).
Location payloads add
`lat`, `lng`, and `located_at`; map notes add `lat`, `lng`, and optional
`title`. Coordinates exist only inside ciphertext.

For each recipient, including the sender self-copy, the client generates a
random 24-byte nonce and computes:

```text
nacl.box(payload_bytes, nonce, recipient_public_key, sender_secret_key)
```

Every copy has its own unguessable `public_id`; all copies share one random
`batch_id`. The envelope stores a snapshot of the sender public key used to
seal it. Clients MUST validate decrypted types, bounds, version, and kind
before rendering. Text is plain text, never executable HTML or Markdown.

### 6.3 Attachments

For every attachment the client MUST:

1. Generate a random 32-byte secretbox key and 24-byte nonce.
2. Encrypt the complete file once with XSalsa20-Poly1305 secretbox.
3. Upload only ciphertext as `application/octet-stream`.
4. Include the returned capability ID in the outer send request solely for
   ownership and lifecycle tracking.
5. Include `{id, origin, key, nonce, name, mime, size, duration_ms}` only inside
   each encrypted payload.

The origin MUST be an HTTPS origin in production. A client fetching a remote
blob MUST NOT forward its home-instance bearer token or cookies. It must
authenticate secretbox before display and treat filename and MIME type as
untrusted hints.

Images, PDFs, audio, and video SHOULD open in an in-application viewer/player.
The UI MUST not offer a download or save command. This is a presentation
restriction, not a security guarantee: a recipient or browser can still retain
bytes or capture displayed content.

### 6.4 Key lifecycle

- **Unlock:** unwrap locally; a wrong passphrase produces no server request
  containing the passphrase.
- **Passphrase change:** rewrap the same secret key; public key and envelopes
  remain unchanged.
- **Rotation:** decrypt eligible history with the old key, generate a new
  keypair, reseal affected copies, and atomically replace key material. Send a
  signed key-update notice to established remote peers. Remote key changes are
  pending until the local user confirms them.
- **Reset:** create a new keypair and remove received copies that cannot be
  decrypted with it. Reset cannot revoke copies owned elsewhere.

## 7. Social model and profiles

### 7.1 Friendships and contacts

- A friendship joins exactly two canonical user identities and has `pending`
  or `accepted` state.
- Pair ordering MUST be canonical so duplicate reverse-direction friendships
  cannot exist.
- Sending requires accepted friendship unless the only recipient is self.
- Remote friend requests are mirrored to both instances through signed
  federation.
- A contact row is selectable across its full visible width; opening it starts
  or opens the relevant conversation.
- Contacts are the default authenticated landing page.
- Pending notifications and invitations must be visibly apparent there.

### 7.2 Groups

- Groups are private, owner-local recipient lists; they are not federated
  shared rooms.
- A group has one owner, a name unique for that owner, and accepted-friend
  members.
- Sending to a group resolves the current members and still authorizes every
  final recipient inside the send transaction.
- Group membership or name changes do not rewrite old encrypted payloads.

### 7.3 Private notes

- A user may keep one note per contact and one note per owned group.
- Notes are editable only by their owner and are server-readable plaintext.
- Profile and group-information panels default closed and can be opened and
  closed without losing unsaved UI state unexpectedly.

### 7.4 Avatars

- A local user may upload, replace, or remove one profile image.
- The client crops/resizes the image to a consistent square presentation
  before upload; the server validates an image size and supported format.
- Avatars are publicly readable by username to support federation and caches.
- A colorful initials placeholder is required when no avatar exists.
- Avatar URLs are versioned so replacement invalidates caches.
- Clicking a profile image anywhere in Contacts or Messages opens the same
  enlarged profile-and-notes dialog and MUST NOT navigate accidentally.
- Canvas/WebGL themes MUST render accepted federated friends' avatars without
  requiring the remote instance to support browser texture CORS. A compatible
  implementation may use an authenticated same-origin proxy, but it MUST derive
  the remote avatar URL from stored friend identity and version metadata rather
  than accept an arbitrary caller-supplied URL.
- A federated avatar proxy MUST authorize the requested user as an accepted
  friend of the current account, reject redirects, enforce the normal avatar
  size and image-format limits, and return a non-distinguishing not-found
  response for unauthorized or invalid fetches. Its cache key MUST change with
  the remote avatar version.

## 8. Messaging and consent

### 8.1 Conversation composition

- New conversation creation starts from a multi-select of existing
  conversations, friends, and groups.
- Recipient expansion is deduplicated. If the resulting participant set
  matches an existing active conversation, open it instead of creating a
  duplicate.
- Messages support Unicode text and emoji, encrypted file attachments,
  microphone-recorded audio, camera-recorded video, expiry, and display limits.
- The sender creates exactly one encrypted copy per unique recipient and one
  self-copy. When sending to self, only one copy exists.
- Pressing Enter sends; Shift+Enter inserts a newline on desktop.
- On phone widths, the text-entry box appears below the action icons.

### 8.2 Consent state machine

```text
pending --accept--> accepted --fetch/display--> accepted
   |
   +--decline---------------------------------> declined
```

- A new recipient copy creates metadata-only notification state.
- Pending metadata MAY identify sender handle, kind, and time, but never
  ciphertext, plaintext, blob capability, or attachment key in push payloads.
- A recipient cannot fetch ciphertext until acceptance.
- Decline makes that copy unavailable and must not fetch federated ciphertext.
- Pending consent MUST be displayed as a front-and-center dialog with explicit
  accept and reject actions. A **Busy now, laters** quick action rejects the
  pending copy and sends a normal browser-sealed message back to the sender;
  the plaintext MUST NOT pass through the LiveView or server.
- Acceptance opens or extends a rolling five-minute conversation window for
  that user/peer pair.
- Sends and accepted receives extend the window. Matching incoming messages
  during the window are auto-accepted.
- Per-contact, per-group, and per-conversation delivery policies may override
  manual acceptance and notification behavior. Removing an override restores
  inherited behavior.

### 8.3 History, edits, expiry, and deletion

- History contains sender self-copies and accepted recipient copies, ordered
  newest first and filtered by kind when requested.
- Conversation grouping is derived from participant identity and archival
  boundaries, not plaintext.
- A sender edit requires the client to reseal replacement ciphertext for every
  batch copy. The server replaces the batch atomically and records `edited_at`.
- Current clients do not edit messages containing attachments.
- Sender delete removes the complete sender-owned batch.
- Recipient delete/hide declines or hides only that recipient copy.
- `expires_at` and `max_displays` are server-enforced access metadata. Expired
  or exhausted content returns not-found behavior, avoiding an existence leak.
- A display count increments only after authenticated decryption and actual
  rendering, not background indexing, migration, rotation, or failed display.

### 8.4 Conversation threads and archives

- Every envelope copy carries a materialized thread key computed at insert
  from its viewer's perspective: a received copy threads by the sender's
  handle, a self-copy by the sorted handles of the batch's other recipients
  (or a notes-to-self sentinel). Conversation lists and pages are database
  queries over this key; no ciphertext is loaded to group history.
- Archiving hides a conversation without deleting envelopes: the member
  envelopes are stamped with a distinct instance key derived from the
  participant key, the conversation start timestamp, and the first envelope
  ID. Later messages with the same participants start a fresh thread under
  the original participant key.
- An archive record stores the instance key, participant identity, start
  timestamp, and archived state.
- The start timestamp is part of the instance key so unarchiving cannot
  overwrite or merge an unrelated later conversation with the same people.
- Archived conversations are restored from the account archive view.

### 8.5 Blob lifecycle

- Every new upload is marked reference-trackable.
- A send lists outer `attachment_ids`; all must belong to the sender.
- Blob-to-batch references are inserted in the same transaction as envelopes.
- One blob may be referenced by multiple sender batches.
- Sender batch deletion removes its references and deletes a blob row and file
  only when no references remain.
- Recipient hide never releases sender-owned blob references.
- Trackable uploads still unreferenced after 24 hours are abandoned and may be
  reclaimed. Cleanup may be periodic or opportunistic.
- Legacy blobs created before explicit tracking MUST remain protected unless an
  operator explicitly verifies and removes one.
- Database/file failures MUST be observable and retryable; no successful delete
  may silently leave an ordinary tracked file orphaned.

### 8.6 Calls, ephemeral data, and shared YouTube

- Only accepted friends may start a 1:1 call. The callee receives a
  front-and-center consent dialog and explicitly accepts, rejects, or chooses
  **Busy now, laters**; unanswered rings expire after 60 seconds. The busy
  outcome is distinct to the caller but persists the call itself as declined.
- A caller MUST be able to cancel a still-ringing invitation. Cancellation is
  distinct from a missed call, removes the callee's pending ring UI, and is
  relayed to a federated participant.
- A local call row records random public ID, caller, callee, lifecycle state,
  and timestamps. Federated peers mirror the same public ID.
- SDP offers/answers and ICE candidates MUST be sealed client-side with
  `nacl.box` between pinned participant identity keys. Instances synchronously
  relay ciphertext and MUST NOT persist signaling history or enqueue it in the
  durable message outbox.
- WebRTC media uses DTLS-SRTP and the data channel uses DTLS/SCTP. Call chat
  text, HTTP/HTTPS links, files up to 25 MB, media-state hints, and synchronized
  YouTube directions are ephemeral and MUST NOT become envelopes, history,
  exports, logs, or server-readable plaintext.
- Both participants may unlock their wrapped identity key locally on the call
  page. The passphrase and raw secret key MUST NOT be submitted to the server.
- Clients provide device preview/selection, audio/video toggles, screen share,
  fit/fill, full screen where available, and clear connection/relay state.
- Clients attempt two ICE restarts for an interrupted peer connection. The
  server allows a 25-second page-presence grace. After a callee remains absent,
  the call ends and the original caller MAY create a fresh call ID/re-invite;
  explicit hangup and decline remain final.
- A still-ringing invitation SHOULD be replayed when an offline local callee
  returns to an authenticated page. Reconnect MUST NOT silently accept a call.
- An authenticated user may schedule a future call with an accepted friend,
  choose a reminder lead time, add shared call notes, start the call early, and
  cancel it. Every schedule display includes the notes field; only the
  organizer edits it and federated updates mirror it to the invitee. The
  schedule is visible to both participants; starting it creates an ordinary
  consent-gated realtime ring.
- Schedules and reminder delivery state MUST persist across application
  restarts. A background worker dispatches each due reminder at most once to
  foreground tabs and registered push devices. Push payloads MUST remain
  content-free and MUST NOT include the optional note.
- The invitee's home instance MUST email an initial schedule invitation. At
  two minutes before start, each participant's home instance MUST email its
  local participant and persist an at-most-once checkpoint independent of the
  configurable device reminder. Email shows UTC explicitly and links to the
  Calls page for device-local rendering. Instances MUST NOT use a federated
  user's placeholder email address.
- Federated schedules use a signed, durable, retryable mirror operation. Each
  home instance reminds only its local participant. The schedule timestamp,
  reminder lead time, participant identities, lifecycle state, shared notes,
  and reminder checkpoints are server-readable metadata.
- A 1:1 YouTube share is controlled only by the participant who starts it and
  is transported over the WebRTC data channel. It is mutually exclusive with
  screen sharing.
- Each instance supports at most one general YouTube watch party. It is
  instance-local, memory-only, visible to authenticated users, controlled only
  by its initiator, and expires after 90 seconds without a host control update.
- Watch-party voice is opt-in per participant and uses pairwise sealed
  signaling plus a WebRTC audio mesh. A participant can listen without
  granting microphone access and can stop their transmitted track at any time.

## 9. Maps, notifications, and realtime behavior

- The map renders decrypted locations and geo-notes using an OpenStreetMap-
  compatible provider or equivalent implementation selected by the operator.
- Coordinates MUST never appear in server-rendered markup, logs, push payloads,
  or unencrypted API metadata.
- Map recipient selection uses dropdowns for friends and groups.
- Foreground clients receive user-scoped realtime hints and then reconcile
  from authoritative server state. A hint is never the sole durable event.
- Browser push uses RFC 8291 `aes128gcm` and RFC 8292 VAPID ES256.
- Android push uses an optional FCM service account. Instances without it
  advertise `android_push: false`; foreground and manual synchronization still
  work.
- Push subscriptions returning 404 or 410 are removed.
- Push failures use durable retry records and never expose secrets in errors.

## 10. Federation

### 10.1 Public discovery and capability reads

| Method and path | Purpose |
| --- | --- |
| `GET /api/instance` | Authority, instance metadata, and Ed25519 signing public key. |
| `GET /api/directory/{username}` | Local user's public encryption key, display name, and avatar metadata. |
| `GET /api/envelopes/{public_id}` | Capability fetch of accepted federated ciphertext. |
| `GET /api/blobs/{public_id}` | Capability fetch of opaque encrypted bytes. |

Public capability IDs require at least 128 bits of randomness and are secrets.
They MUST NOT appear in push payloads or routine logs.

### 10.2 Signed writes

| Method and path | Purpose |
| --- | --- |
| `POST /api/federation/friend_request` | Mirror a remote friend request. |
| `POST /api/federation/friend_response` | Mirror acceptance or decline. |
| `POST /api/federation/notify` | Announce available ciphertext without sending it. |
| `POST /api/federation/key_update` | Announce a changed user encryption key. |
| `POST /api/federation/account_move` | Announce a verified new home authority. |
| `POST /api/federation/call_invite` | Mirror a current call invitation and ring the local callee. |
| `POST /api/federation/call_update` | Relay joined, declined, busy, cancelled, ended, or disconnected state. |
| `POST /api/federation/call_signal` | Relay one sealed SDP/ICE payload synchronously. |
| `POST /api/federation/call_schedule` | Durably mirror scheduled, cancelled, or started call-plan state. |

Each write is signed with the sending instance's Ed25519 key. The signed bytes
bind the exact request path, timestamp, and SHA-256 digest of the raw body.
Headers identify the authority, timestamp, and signature. Receivers accept a
maximum five-minute clock skew and bind claimed users to the authenticated
authority.

Peer keys are pinned on first successful contact. A changed instance signing
key is rejected until an explicit trust-recovery operation. Administrators may
block a peer; blocked inbound and outbound federation must fail closed.

### 10.3 Federated pull delivery

1. Sender instance stores all envelope copies.
2. It sends the recipient instance a signed metadata-only notification.
3. Recipient instance stores a stub envelope and pending notification.
4. Acceptance causes the recipient instance to construct a fetch URL from the
   pinned sender authority, never from an arbitrary request-supplied URL.
5. Recipient instance fetches and stores ciphertext; the client then decrypts.
6. Decline leaves ciphertext on the sender instance only.

Friend requests are synchronous. Notifications, move notices, and friend
responses use a durable outbox for transient errors. Retry uses exponential
backoff from approximately 30 seconds to six hours for up to roughly one week.
Definitive 4xx errors are not retried automatically.

## 11. Invitations, administration, export, and account moves

### 11.1 Invitations

- Any permitted local user may create a random, expiring invitation rendered
  as a URL and QR code.
- The landing page states the instance and inviter identity and offers
  registration.
- Default validity is seven days and is administrator-configurable.
- Tokens are stored as hashes and may be seen, accepted once, revoked, or
  expired immediately.
- After successful registration, the inviter receives a notification that the
  invited friend joined. The implementation SHOULD establish or offer the
  expected friendship without exposing the invitee's email.

### 11.2 Permanent administrator

The first local account is atomically recorded as the one permanent instance
administrator. The assignment is write-once and cannot be transferred through
normal application operations. If importing an intentionally new instance,
the imported owner may be established as its first administrator.

Only the administrator may:

- change registration, invitation, upload, storage, retention, public-instance,
  and mail-sender settings;
- inspect/revoke invitations and view who accepted them;
- suspend/reactivate members and revoke their sessions;
- inspect/block federation peers and retry outbox operations;
- review operational failures and the append-only admin audit trail;
- test, approve, provision, retry, cancel, and finalize account moves.

Audit events record actor, action, target type/id, safe structured details, and
time. They MUST NOT contain message or attachment content, notes, coordinates,
passwords, keys, recipient email addresses, tokens, or capability URLs.

### 11.3 Export/import format

An export is a private ZIP containing `export.json`, an optional normalized
profile image, and encrypted blobs owned by the user. Manifest version 1
contains profile identity, wrapped key material, accepted friends, groups,
encrypted envelope history with sender-key snapshots, owned blobs, and blob
batch references.

Imports MUST validate format version, file paths, archive expansion limits,
hashes, uniqueness, and ownership before committing. Import preserves public
IDs and original timestamps where required for history compatibility. It
creates remote contact stubs needed to attribute historical envelopes.

An authenticated in-place restore MUST be additive and MUST require the
archive username and complete wrapped-key identity to match the current
account. It MUST NOT replace email, password, username, or key material.
Repeated restores skip existing account-owned public IDs, while a public ID
already owned by another account is a hard failure.

The package remains encrypted at content level but exposes social metadata and
must be handled as sensitive personal data. Version 1 does not guarantee
contact/group notes, every newer message option, or received attachment blobs.

### 11.4 Administrator-managed move

Only a non-admin local user may be moved. Required state progression:

```text
awaiting_test -> testing -> test_verified -> awaiting_final_import
-> provisioning -> target_verified -> finalized
```

`testing` may enter `test_failed`, and `provisioning` may enter
`provision_failed`; both failure states are retryable. Cancellation returns a
cutover-suspended user to active status. The workflow is:

1. Administrator selects user, unique target HTTPS host, instance name, and
   personal/community mode.
2. Source creates a private export and records expected envelope, blob, and
   friend counts plus SHA-256 and size.
3. Provisioner claims the job using an external bearer token, imports into an
   isolated disposable database, and returns a verification receipt.
4. Administrator reviews the test and explicitly approves cutover.
5. Source suspends the user, revokes sessions, and creates a fresh final export.
6. Provisioner creates an isolated database/blob directory, imports the final
   package, makes the moved user permanent admin, starts one application
   instance, configures HTTPS routing, and verifies readiness.
7. Source verifies the target directory publishes the same user encryption
   public key and verifies expected counts.
8. Administrator explicitly finalizes.
9. Source replaces the departing local contact with a remote contact at the
   new authority, rewrites local friendship/address-book references, sends
   signed account-move notices to federated friends, deletes the source user,
   and removes private export files.

Application code MUST NOT receive Docker/host control. The separate provisioner
has the minimum host privilege needed and authenticates through
`/api/provisioner/v1/jobs/claim`, package download, and result endpoints.
Every step is idempotent and resumable after process or host failure.

## 12. Required atomic operations and invariants

The database technology is replaceable; these semantics are not.

1. **First administrator:** first local account creation and singleton admin
   assignment cannot race into zero or multiple administrators.
2. **Friendship:** one canonical pair; both users distinct; accepted state is
   required at send time.
3. **Send batch:** authorize sender, every recipient, exactly one copy per
   recipient, exactly one self-copy, options, attachment ownership, envelope
   inserts, notification inserts, and blob references in one transaction.
4. **Idempotent API mutation:** an idempotency key is scoped to device session
   and operation. Same request returns stored response; changed body returns
   conflict.
5. **Acceptance:** notification transition, federated fetch state, envelope
   availability, and conversation-window update cannot create unauthorized
   readable ciphertext.
6. **Edit:** all sender-owned copies are replaced together or not at all.
7. **Sender delete:** all batch copies and blob-reference releases are one
   logical operation; physical-file failure is retried or recorded.
8. **Key rotation/reset:** key replacement and corresponding reseal/purge are
   atomic.
9. **Refresh:** token rotation and old-token history insertion are atomic.
10. **Move cutover/finalize:** suspension, session revocation, final package,
    address repair, notices, and deletion follow durable state transitions and
    never infer success merely from a running process.

## 13. Logical data model

Implementations may rename or normalize tables, but imports and behavior must
represent these entities and constraints.

### 13.1 Accounts and administration

| Entity | Required data and constraints |
| --- | --- |
| User | ID, email, password hash, confirmation/suspension state, username, display name, host, avatar state/version, current and pending public key, wrapped secret, salt, nonce, timestamps. Unique local email and username. |
| User token | User, token digest/value, purpose context, destination, authentication time, timestamps; unique by context/token. |
| Device session | User, device metadata, access/refresh hashes and expiries, authenticated/last-used times, optional push token. Token hashes and non-null push tokens unique. |
| Refresh history | Device session and spent refresh-token hash; hash unique. |
| Idempotency record | Device session, operation, key, request hash, serialized response; tuple unique. |
| Invitation | Token hash, inviter, expiry, seen/accepted/revoked state, accepting and revoking users. Token hash unique. |
| Instance administration | Singleton row referencing immutable admin user. |
| Instance settings | Singleton public metadata, registration policy, invitation hours, max upload, total quota, retention, mail sender. |
| Audit event | Actor, action, target, safe details, immutable timestamp. |
| Operational failure | Channel, operation, sanitized error, timestamp. |
| Account move | Public ID, source user, actor, target, mode, status, package metadata, expected counts, receipt/error, lifecycle times. Active target host unique. |

### 13.2 Social and messaging

| Entity | Required data and constraints |
| --- | --- |
| Friendship | Canonical requester/addressee pair and status; pair unique. |
| Group | Owner and name; owner/name unique. |
| Group member | Group and user; pair unique. |
| Contact note | Owner, contact, body; owner/contact unique. |
| Group note | Owner, group, body; owner/group unique. |
| Envelope | Public ID, batch ID, kind, ciphertext, nonce, sender, recipient, sender-key snapshot, delivered/edited/expiry times, max/display count, resealed flag, thread key and participant-handle list, timestamps. Public ID unique; batch/recipient unique; recipient/thread-key indexed. |
| Notification | Envelope, recipient user, pending/accepted/declined state; one per relevant envelope/user. |
| Conversation window | User, peer, active-until; pair unique. |
| Delivery policy | User, subject type/id, acceptance and notification behavior; subject tuple unique. |
| Conversation archive | User, unique conversation (instance) key, participant key/list, start time, archived state, timestamps. Membership lives on the envelopes' thread keys. |
| Blob | Random public ID, owner, exact byte size, storage key/path, reference-tracking flag, timestamps. Public ID unique. |
| Blob reference | Blob and batch ID; pair unique. |
| Call | Random public ID, caller, callee, ringing/accepted/terminal state, and timestamps. Public ID unique; signaling is not stored. |

### 13.3 Federation and push

| Entity | Required data and constraints |
| --- | --- |
| Instance credential | Kind, public key, protected secret key; kind unique. At least federation Ed25519 and Web Push VAPID P-256. |
| Peer | Authority, pinned public key, optional block state/actor; authority unique. |
| Outbound delivery | Authority, path, serialized safe payload, attempts, next attempt, sanitized last error. |
| Push subscription | User, endpoint, P-256 DH key, authentication secret, timestamps; endpoint unique. |
| Push delivery | Notification, browser subscription or device session, channel, attempts, next attempt, sanitized error; target pair unique. |

Foreign keys should cascade only where lifecycle ownership is clear. Audit
events and the permanent admin reference MUST resist accidental user cascade.
File deletion is explicit because relational cascades cannot remove blob-store
objects.

## 14. HTTP and client API surface

All release traffic uses HTTPS. JSON uses UTF-8, `application/json`, lowercase
`snake_case`, RFC 3339 UTC timestamps, stable machine-readable errors, opaque
IDs, and cursor pagination. Authenticated requests MUST NOT follow redirects to
another origin with credentials attached.

### 14.1 Public API

- `GET /api/v1/capabilities`
- `POST /api/v1/auth/login`
- `POST /api/v1/auth/magic-link`
- `POST /api/v1/auth/magic-link/exchange`
- `POST /api/v1/auth/refresh`
- Federation discovery and capability reads listed in section 10

### 14.2 Authenticated native API

- `DELETE /api/v1/auth/session`
- `PUT|DELETE /api/v1/devices/current/push-token`
- `GET /api/v1/me`
- `PUT /api/v1/keys`
- `GET /api/v1/notifications`
- `POST /api/v1/notifications/{id}/accept|decline`
- `GET /api/v1/contacts`; `PUT /api/v1/contacts/{id}/note`
- `GET /api/v1/groups`; `PUT /api/v1/groups/{id}/note`
- `POST /api/v1/recipients/resolve`
- `POST /api/v1/message-batches`
- `POST /api/v1/blobs`
- `GET /api/v1/envelopes`
- `GET /api/v1/message-delivery-policies`
- `PUT|DELETE` delivery policy for contact, group, or conversation

The current route set is the compatibility floor. Additional versioned routes
needed for full native parity must use the same authorization and error model.
Do not expose persistence objects directly from serializers.

### 14.3 Error and pagination contract

Errors have stable code, diagnostic message, request ID, and optional safe
details. Standard codes include `invalid_request`, `authentication_required`,
`forbidden`, `key_setup_required`, `not_found`, `key_changed`,
`idempotency_conflict`, `blob_too_large`, `validation_failed`, `not_friends`,
`rate_limited`, and `origin_unreachable`.

Collections return `items` plus `{next_cursor, has_more}`. Default limit is 50,
maximum 100. Cursors are opaque and scoped to user, endpoint, and filters.

## 15. User-interface requirements

The exact visual design may change, but a compatible first-party UI provides:

- Contacts as the post-login landing page, with separately collapsible
  Conversations, Groups, and Friends sections and Add Friend at the bottom.
- A sticky responsive header. On smaller widths, Messages, Calls, Map, Friends,
  Groups, and History live in a hamburger menu.
- Accessible light and dark modes across all pages, including Messages.
- Full-row contact activation, consistent avatar dialogs, visible pending
  notifications, and keyboard-accessible controls.
- Messages with a clear Back to Contacts affordance, profile image, history,
  emoji picker, media controls, pinned composer, and responsive mobile layout.
- In-app image, PDF, audio, and video viewing with dialogs that fit phone and
  desktop viewports and do not overlap controls.
- Map recipient dropdowns for friends and groups.
- A call device-check gate; responsive audio/video controls; screen sharing;
  full-screen/Picture-in-Picture/pop-out views where supported; ephemeral call
  chat/files; synchronized YouTube; connection quality and recovery status;
  and confirmation before navigation that would end an active call.
- A caller-only re-invite action after unrecovered callee disconnect, and an
  incoming ring replay when a still-pending local callee reconnects.
- A Calls page for creating, reviewing, starting, and cancelling persistent
  one-to-one schedules with local-time display and configurable reminders.
- An instance-local Watch page where the host controls synchronized YouTube
  and every participant independently opts into or out of microphone audio.
- Account pages for settings, key management, avatar, export, and archives.
- Admin pages for health, settings, invitations, users, moves, peers, retries,
  failures, and audit history.
- QR invitation presentation that remains scannable on phone and desktop.

All actions require visible loading, empty, success, and error states. Icon
buttons have accessible names/tooltips. Decrypted text is inserted as text,
never interpreted HTML. Touch targets and dialogs must be usable at common
phone widths without horizontal scrolling.

## 16. Configuration and deployment contract

### 16.1 Required configuration

| Setting | Purpose |
| --- | --- |
| Public authority/URL | Canonical HTTPS identity and link/federation origin. |
| Database connection/path | Durable relational state. |
| Blob-store path/bucket | Durable encrypted attachment state. |
| Session signing secret | Browser session integrity. |
| SMTP host and sender address | Authentication and invitation mail. |
| Instance mode | Community or personal default behavior. |

Optional settings include port/bind address, database pool, upload and storage
limits, retention, SMTP port/auth/TLS, STUN/TURN URLs and credentials, cluster
discovery, provisioner token, and FCM service-account path. Secrets MUST come
from a secret manager, protected file, or equivalent runtime injection, never
source control or a client build.

### 16.2 Production topology

- TLS terminates at the application or a trusted reverse proxy that preserves
  the original host and supports websocket/realtime upgrades.
- DNS authority, certificate name, application canonical host, and federation
  identity MUST agree.
- The application and supporting services restart automatically after host or
  process failure.
- SQLite deployments run exactly one application replica and keep the live
  database on a filesystem with reliable locking.
- Immutable release images are preferred. Every rollout applies migrations,
  builds matching static assets, restarts, and performs public health checks.
- A public capabilities endpoint reports instance mode, protocol version,
  upload limit, and optional push support without secrets.

### 16.3 Mail

Production uses authenticated professional SMTP directly or a correctly
secured relay. It MUST NOT use a local development mailbox adapter. Operators
configure SPF, DKIM, and DMARC when using their own sending domain. Mail errors
are sanitized and visible to the administrator without revealing credentials.

### 16.4 Backup and recovery

A complete backup includes database, blob store, runtime configuration,
federation/VAPID identity, FCM credential when enabled, and TLS state when the
proxy manages it. Database and blob snapshots must be mutually consistent.

Restoration preserves the public authority and instance keys unless executing
a deliberate identity migration. Restoration testing is part of operations.
Backups are encrypted, kept off-host in multiple generations, and never added
to source control.

## 17. Security and privacy requirements

- Use modern TLS and secure headers; reject production cleartext clients.
- Rate-limit login, magic-link, registration, directory, invitation, upload,
  and federation endpoints.
- Validate body sizes before parsing and enforce per-upload and total quotas.
- Prevent archive path traversal, decompression bombs, MIME confusion, stored
  script execution, SSRF, open redirects, and credential forwarding.
- Federation and attachment origins are canonicalized and allow only expected
  HTTPS authority syntax.
- Compare tokens, hashes, and signatures in constant time where applicable.
- Never log passwords, passphrases, private keys, wrapping/attachment keys,
  access/refresh/invitation tokens, full ciphertext, capability URLs, SMTP/FCM
  credentials, decrypted content, or raw call SDP/ICE candidates.
- Protect database, blobs, packages, backups, provisioner token, SMTP secret,
  Firebase key, and proxy state with least-privilege filesystem/service access.
- Operational and audit errors are sanitized before persistence.
- Dependencies, base images, proxy, runtime, and host receive regular security
  updates with rollback and backup preparation.

## 18. Background processing and observability

At minimum, workers perform federation retries, browser/Android push retries,
expired token/session cleanup, invitation expiry evaluation, abandoned tracked
blob cleanup, and account-move job coordination.

Jobs are idempotent, durable where loss changes behavior, bounded in retries,
and safe after process death. Realtime and push events are hints; clients
reconcile durable state after gaps.

Health reporting covers application reachability, database access, migration
version, blob read/write and quota, mail configuration/failures, outbox depth,
push configuration/failures, account-move jobs, and software version. Metrics
and logs must not violate section 17.

## 19. Reimplementation and migration procedure

A replacement implementation SHOULD be developed in this order:

1. Implement the logical schema and an importer for a copy of the current
   SQLite database and blob directory, preserving all opaque IDs and bytes.
2. Pass protocol fixture tests for Base64, PBKDF2, secretbox wrapping,
   `nacl.box`, attachment encryption, Unicode, key snapshots, and tamper cases.
3. Implement authentication, current account, capabilities, contacts, recipient
   resolution, consent, history, send, and blob APIs.
4. Run browser-to-new-server and Android-to-new-server compatibility tests.
5. Implement federation discovery, signatures, TOFU pinning, pull delivery,
   retries, key updates, blocking, and account-move notices.
6. Implement browser UI/native parity, administration, export/import, and
   provisioner integration.
7. Rehearse a full backup, offline database/blob migration, integrity audit,
   start, client unlock, local send, federated send, media view/delete, and
   rollback using production-like copies.

During cutover, stop all writers, take a consistent final backup, migrate both
metadata and blobs, run integrity checks, and start only one authoritative
implementation. Do not run old and new writers against copied identities at
the same time: duplicate federation identities can produce divergent state.

## 20. Acceptance test suite

A reimplementation is conforming only when automated tests cover the following.

### 20.1 Cryptography and secrecy

- Browser and native clients decrypt each other's text, Unicode, locations,
  notes, image, PDF, audio, and video payloads.
- Wrong passphrase/key/nonce and tampered ciphertext never render plaintext.
- Server requests, database, logs, push, and mail contain no forbidden
  plaintext or key material.
- Key rewrap, rotation, remote-key confirmation, and reset preserve their
  specified readable history.

### 20.2 Domain behavior

- Registration policies, invitations, permanent first admin, suspension, and
  session revocation behave under races and retries.
- Friendship pairs cannot duplicate; groups authorize current members.
- A send is all-or-nothing, has one copy per recipient, and self-send does not
  duplicate.
- Pending recipients cannot fetch; accept/decline and five-minute windows work.
- Delivery-policy inheritance and overrides work for contact/group/conversation.
- Edits are atomic; expiry/display limits hide exhausted content.
- Archive/unarchive preserves distinct same-participant conversations.
- Contact/group notes are owner-only and avatars are consistent everywhere.

### 20.3 Attachments

- Failed/oversized uploads do not create usable blob records.
- Send rejects foreign attachment IDs and links all owned IDs atomically.
- Reused blobs survive until their last sender batch is deleted.
- Recipient hide retains blobs; sender deletion reclaims final unreferenced
  bytes; abandoned tracked uploads age out; legacy blobs remain protected.
- In-app media viewers work on desktop and phone without a product download
  action.

### 20.4 Federation and moves

- Two authorities complete friend request/response, pending notify, accept,
  pull, decrypt, reply, key update, and blocked-peer scenarios.
- Invalid signature/body/path/time/authority and changed pinned key fail closed.
- Retry survives restart and does not retry definitive failures forever.
- Export/import preserves avatar, owned blobs/references, encrypted history,
  sender snapshots, and accepted contact addresses.
- Test import failure leaves source active. Cutover failure is resumable.
  Finalization requires target HTTPS, same user public key, expected counts,
  repaired local/remote friendships, signed move notices, and explicit admin
  approval.

### 20.5 Operations and UI

- Fresh install, migration, upgrade, restart, backup, restore, and rollback are
  rehearsed on supported platforms.
- Public HTTPS, websocket/realtime, mail, browser push, and optional FCM are
  health checked.
- Responsive UI is visually tested at phone and desktop sizes in light/dark
  modes, with no overlap and keyboard/screen-reader coverage for core flows.
- Full regression, static analysis, dependency audit, and production asset
  build pass before release.

### 20.6 Calls and shared viewing

- Local and federated friends complete ring, accept, sealed offer/answer/ICE,
  media connection, explicit decline, and explicit hangup flows.
- A non-participant cannot read or relay call state/signals; a forged or
  cross-instance call update fails closed.
- Wrong passphrase/key and tampered signaling do not establish a call or expose
  plaintext signaling to the server.
- Audio-only join, device switching, mute/camera state, adaptive video, screen
  share, full-screen/Picture-in-Picture/pop-out fallbacks, direct call chat,
  clickable safe links, and 25 MB file limits are browser-tested.
- Temporary page/network interruption recovers within the ICE/presence grace.
  Exhausted callee recovery offers the original caller a fresh re-invite;
  hangup/decline does not. A pending ring reappears after local callee reconnect.
- 1:1 YouTube playback follows only the initiating participant and remains
  mutually exclusive with screen sharing.
- A general watch party permits only its host to control/end playback, expires
  after host loss, resets on application restart, and never crosses instances.
- Watch-party voice permits listen-only join and independent microphone
  opt-in/out. Pairwise signaling remains sealed and media is peer-to-peer.
- Tests assert call chat/files and watch-party state never enter envelopes,
  exports, durable outbox rows, push payloads, or server logs.

## 21. Definition of done

The recreation is complete when:

1. All normative requirements and acceptance tests above pass.
2. Existing browser and Android clients can use it without a protocol downgrade.
3. Two independently deployed recreated instances federate successfully with
   each other and with the current Veejr server.
4. A production-data copy migrates with matching entity counts, IDs, ciphertext
   hashes, blob hashes/sizes, account keys, and federation identity.
5. Operators can install, configure, upgrade, back up, restore, monitor, and
   recover it using reviewed documentation without framework-specific tribal
   knowledge.
6. Security review confirms the new stack has not moved cryptography or
   plaintext across the client/server boundary.

## 22. Reference material

- [Architecture and trust boundaries](ARCHITECTURE.md)
- [Client protocol v1](CLIENT_PROTOCOL_V1.md)
- [Installation and server setup](INSTALLATION.md)
- [Production operations](OPERATIONS.md)
- [Calls and YouTube watch parties](CALLS_AND_WATCH_PARTIES.md)
- `protocol-fixtures/v1.json`
- `priv/repo/migrations/` for the historical SQLite migration sequence
