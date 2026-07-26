# veejr architecture

## System goals

veejr is designed around three goals:

1. Encrypt shared content in the browser and keep server-side content storage
   opaque.
2. Make delivery consent-based: notification precedes ciphertext retrieval.
3. Keep self-hosting small: one BEAM application, one SQLite database, and one
   blob directory.

It does not hide traffic metadata, and its browser client is delivered by the
server it is meant to distrust for content. The consequences of that boundary
are described under [Security boundaries](#security-boundaries).

## Runtime structure

`Veejr.Application` starts a `:one_for_one` supervision tree:

```text
Veejr.Supervisor
├── VeejrWeb.Telemetry
├── Veejr.Repo (SQLite)
├── Ecto.Migrator (release and prod startup — boot-time migrations)
├── DNSCluster
├── Phoenix.PubSub (Veejr.PubSub)
├── Veejr.WatchParties (ephemeral, instance-local state)
├── Veejr.Federation.Outbox
├── Veejr.Push.Outbox
├── Veejr.Janitor
├── Veejr.CallRegistry (duplicate registry for call-page presence)
├── Veejr.TaskSupervisor
└── VeejrWeb.Endpoint (Bandit)
```

The main domain contexts are:

| Context | Responsibility |
| --- | --- |
| `Veejr.Accounts` | Registration, authentication, profiles, invites, and identity-key lifecycle. |
| `Veejr.Social` | Friendships, remote contacts, groups, and personal contact/group notes. |
| `Veejr.Messaging` | Envelopes, consent notifications, conversation windows, edits, expiry/display limits, and blobs. |
| `Veejr.Calls` | 1:1 call consent/lifecycle, schedules and reminders, sealed signaling relay, presence grace, and federated call updates. |
| `Veejr.WatchParties` | One ephemeral, instance-local, host-controlled YouTube party and voice-signaling membership. |
| `Veejr.Federation` | Remote discovery, friendship and delivery protocol, signed requests, peers, and retry outbox. |
| `Veejr.Push` | Push subscriptions and RFC 8291/8292 Web Push delivery. |
| `Veejr.Export` / `Veejr.Import` | Account portability. |

Phoenix LiveViews coordinate UI state and send only ciphertext-related data for
encrypted content. JavaScript hooks in `assets/js/veejr/` own key access,
encryption, decryption, attachment crypto, and map plaintext.

## Authentication and route boundaries

- The public browser route serves the landing page.
- Registration and login LiveViews use the optional-current-user session.
- Settings and key setup require authentication.
- Contacts, friends, groups, messages, map, history, calls, and watch parties
  require authentication plus configured identity keys;
  `VeejrWeb.LiveNotify` subscribes them to user notifications, incoming rings,
  and active watch-party hints.
- Authenticated controller routes handle private blob upload/download, export,
  and push subscriptions.
- `/api/instance`, `/api/directory/:username`, envelope capability fetches, and
  blob capability fetches are public federation surfaces.
- Federation write endpoints pass through `VeejrWeb.FederationAuth`.

Authentication (email magic link and optional password) is independent of the
encryption passphrase.

## Browser cryptography

All content cryptography is implemented with TweetNaCl and WebCrypto in
`assets/js/veejr/crypto.js`.

### Identity key storage

On key setup the browser generates an X25519 keypair with
`nacl.box.keyPair()`. It derives a 256-bit wrapping key from the encryption
passphrase using PBKDF2-SHA256 with 310,000 iterations and a random 16-byte
salt. The X25519 secret key is wrapped using XSalsa20-Poly1305
(`nacl.secretbox`) with a random nonce.

The server stores `public_key`, `enc_secret_key`, `key_salt`, and `key_nonce`.
The unlocked secret key is cached in `sessionStorage`, scoped to the browser
tab session. A user can therefore roam with the wrapped key, but must supply
the passphrase on each new browser session.

### Envelope encryption

For N recipients, the browser creates N recipient envelopes plus a self-copy:

```text
payload  = {v, kind, text, attachments, sent_at, lat?, lng?, ...}
envelope = nacl.box(payload, nonce, recipient_public_key, sender_secret_key)
self     = nacl.box(payload, nonce, sender_public_key, sender_secret_key)
```

Each envelope has an unguessable `public_id`; copies share a `batch_id`.
`sender_public_key` snapshots the key used at send time. `resealed` marks an
envelope re-encrypted to its owner's current key during rotation.

Optional `expires_at` and `max_displays` constraints are stored as metadata and
enforced by server queries/fetches. They remove normal application access after
the limit; they cannot revoke plaintext or ciphertext a recipient already
copied. Sender edits replace every ciphertext copy in the owned batch after the
browser re-encrypts the revised payload for each recipient. Sender deletion
removes the owned envelope batch and its no-longer-referenced attachment bytes.

### Attachments

The browser encrypts each file once with a random `nacl.secretbox` key. The
opaque blob is uploaded separately; its `{blob_id, key, nonce, name, mime,
size}` descriptor is included inside every encrypted envelope payload.
The send request also carries only the opaque blob IDs outside the ciphertext.
The server validates that the sender owns them and records batch references in
the same transaction as the envelopes. Sender deletion removes a blob after
its final batch reference disappears; recipient hide does not. Uploads created
after reference tracking was introduced are reclaimed if still unattached
after 24 hours. Legacy blobs remain untracked and protected from automatic
deletion because their references cannot be recovered from ciphertext.

Authenticated blob routes serve local application users. `/api/blobs/:id` is
an unauthenticated capability endpoint used for federation: possession of the
128-bit unguessable identifier authorizes access to already-encrypted bytes.
Consequently, blob IDs must be treated as secrets even though the content also
has cryptographic protection.

## Consent and delivery

```text
sender browser -> encrypt -> sender instance stores envelope
                              |
                              +-> pending metadata notification
                                   -> PubSub / Web Push

recipient accepts -> ciphertext becomes fetchable -> browser decrypts
recipient declines -> ciphertext is not served to that recipient
```

Notifications contain metadata only and move from `pending` to `accepted` or
`declined`. `Veejr.Messaging.fetch_envelope/2` permits a sender to fetch their
self-copy and a recipient to fetch only after acceptance.

Acceptance opens a rolling five-minute `conversation_windows` entry for the
user/peer pair. Sends and accepted receives extend it. New messages from that
peer are auto-accepted while the window is active, avoiding a consent click for
every message in an active conversation.

## Federation

An instance is identified by its authority (`host` or `host:port`), and a user
by `username@authority`. Remote contacts are rows in `users` with `host` set;
they have no usable local credentials. Directory lookups synchronize public
display names and avatar metadata; avatar images remain hosted by the user's
home instance.

### Federated avatar textures

Ordinary HTML images may display a remote avatar directly, but the Orbit and
Soiree Three.js themes upload avatars into a WebGL canvas. Browsers require
cross-origin image responses to opt into that use, and older federated
instances may not send the required CORS header.

For those themes, the authenticated home instance exposes
`GET /avatar-textures/:id`. The route accepts a local remote-user ID rather than
an arbitrary URL. It serves an image only when that row represents an accepted
federated friend of the signed-in user with current avatar metadata. The server
then fetches the canonical, versioned `/avatars/:username` path from the
friend's recorded home authority, rejects redirects, bounds the response size,
and validates the response as an accepted JPEG before returning it. Failures
and unauthorized lookups return `404` without distinguishing the cause.
The upstream request advertises both HTML and JPEG support because deployed
peers route public avatars through Phoenix's browser pipeline, which rejects a
narrow image-only `Accept` header before reaching the avatar controller.

The proxy response is same-origin and privately, immutably cached by avatar
version. Public `GET /avatars/:username` responses also include
`Access-Control-Allow-Origin: *`, allowing upgraded peers to use an avatar
directly as a canvas texture. The proxy remains the compatibility path for
older peers.

### API

| Method and path | Purpose |
| --- | --- |
| `GET /api/instance` | Instance identity and signing key discovery. |
| `GET /api/directory/:username` | Local-user public key, display name, and avatar discovery. |
| `POST /api/federation/friend_request` | Mirror a remote friend request. |
| `POST /api/federation/friend_response` | Accept or decline a request. |
| `POST /api/federation/notify` | Announce an available envelope without sending its ciphertext. |
| `POST /api/federation/key_update` | Announce a rotated user key for manual confirmation. |
| `POST /api/federation/call_invite` | Mirror a current, consent-gated call invitation. |
| `POST /api/federation/call_update` | Relay joined/declined/cancelled/ended/disconnected lifecycle state. |
| `POST /api/federation/call_signal` | Relay one sealed SDP/ICE payload synchronously. |
| `POST /api/federation/call_schedule` | Durably mirror scheduled-call creation and state. |
| `GET /api/envelopes/:public_id` | Fetch envelope ciphertext by capability. |
| `GET /api/blobs/:id` | Fetch encrypted blob bytes by capability. |

### Pull flow across instances

When Alice on A sends to Carol on B, A retains the ciphertext and sends B a
content-free notify. B creates a stub envelope and pending notification. Only
after Carol accepts does B fetch `/api/envelopes/:public_id` from A and fill the
stub. Declining means the ciphertext never leaves A.

### Instance authentication and pinning

Each instance generates an Ed25519 signing keypair. Federation POST signatures
cover the request path, timestamp, and SHA-256 hash of the raw body. Requests
include authority, timestamp, and signature headers; timestamps have a
five-minute acceptance window.

Peer signing keys use trust on first use and are stored in `peers`. A later key
change is rejected. Handlers bind user-origin claims to the authenticated
instance authority. Remote user encryption keys are also pinned; a key update
is held in `pending_public_key` until a local user confirms it. Envelope fetch
URLs are constructed from the pinned sender authority rather than accepted
from payload input.

TOFU protects continuity after first contact but does not authenticate that
first contact against an external source such as DNSSEC or a transparency log.

### Reliability

Friend requests are synchronous so the initiator immediately learns whether an
address resolves. Envelope notifies, friend responses, key updates, and
account-move notices go through `Veejr.Federation.Outbox` enqueue-first: the
delivery row is written in the same database transaction as the local state it
announces (no network I/O inside the transaction, and a crash cannot lose the
announcement), then the outbox process is kicked after commit to attempt
delivery immediately. Failures are retried with exponential backoff (30
seconds to six hours) for roughly a week. Definitive 4xx responses are not
retried.

## Calls

1:1 audio/video calls use WebRTC: DTLS-SRTP media and the DTLS/SCTP call data
channel flow peer-to-peer and never touch an instance. The server's role is
consent, lifecycle, presence, and signaling relay:

- Ringing reuses the consent model — the callee's open tabs show an
  incoming-call banner (`{:veejr_call_ring, call}` on the user topic) and
  nothing connects until they accept. Only accepted friends can ring.
- A caller may explicitly cancel a still-ringing invitation. Cancellation has
  its own lifecycle state and user-topic event so stale ring banners disappear;
  federated peers relay it synchronously with other active-call updates.
- Signaling payloads (SDP offers/answers, ICE candidates) are sealed
  browser-side with `nacl.box` between the participants' pinned identity
  keys. Instances relay opaque ciphertext, so a compromised server cannot
  substitute DTLS fingerprints to man-in-the-middle a call.
- Federated calls mirror one `calls` row per instance under a shared public
  id; invites, state updates, and sealed signals relay over the signed
  instance-to-instance channel synchronously (`/api/federation/call_*`) —
  a call is now or never, so the retry outbox is not involved.
- Scheduled calls are separate persistent rows. Creation, cancellation, and
  start state are mirrored to a remote participant through the durable signed
  `/api/federation/call_schedule` path. `Veejr.Calls.Reminders` polls every 30
  seconds, stamps `reminded_at`, publishes a user-scoped foreground event, and
  sends content-free browser/Android push alerts to local participants.
  Schedule metadata and the optional note are server-readable.
- The device-preview gate and in-call passphrase prompt keep camera/microphone
  selection and key unwrap in the browser. The passphrase and raw secret key
  are never sent through LiveView.
- The data channel carries ephemeral text, clickable HTTP/HTTPS links, files
  up to 25 MB, screen-share state, media-state hints, and synchronized YouTube
  directions. These items are memory-only and disappear when the peer
  connection closes; they are not envelopes or history.
- Video capture begins at up to 720p/30fps. Browser WebRTC statistics drive
  HD/Balanced/Data saver sender profiles, with audio prioritized during
  degradation. Screen capture uses a separate profile.
- Calls attempt two ICE restarts after a connection failure. Call-page
  presence has a 25-second server grace so LiveView reconnects do not end a
  call. If recovery fails, the original caller may create a fresh call ID and
  ring the callee again; a still-ringing invite is replayed when an offline
  local callee returns to an authenticated page.
- ICE servers default to public STUN; operators can add a TURN relay
  (encrypted SRTP only) via environment configuration.
- The peers learn each other's IP addresses when connecting directly, as in
  any peer-to-peer call; a TURN relay hides addresses at the cost of
  relaying through the configured server.

Leaving an active call is guarded in the browser, but browser close/refresh
warnings use native, non-customizable text. Explicit hangup/decline is final;
only an involuntary callee disconnect exposes caller re-invite. See
[CALLS_AND_WATCH_PARTIES.md](CALLS_AND_WATCH_PARTIES.md) for user-visible
behavior and operational limits.

## YouTube watch parties

`Veejr.WatchParties` holds at most one party in process memory. It stores the
random party ID, initiating local user, YouTube video ID, playback direction,
and position. The host alone may control/end playback; all authenticated users
on the same instance receive a join hint. Control refreshes a 90-second timer,
so an abandoned host causes the party to expire. State is neither durable nor
federated and disappears on application restart.

Optional voice uses a peer-to-peer WebRTC mesh. Every page joins receive-only;
a participant explicitly grants microphone access to start transmitting and
may stop their track independently. SDP/ICE signaling is sealed pairwise with
participant identity keys before LiveView relays it. The server observes
membership and encrypted signaling sizes/timing but not voice. Mesh upload
cost grows with participant count, so the feature targets small communities.

The YouTube iframe runs in each browser against `youtube-nocookie.com`.
Instances do not proxy video, but YouTube sees each viewer's request metadata.
Playback directions are not content-encrypted in a general watch party; the
video ID and state are server-readable. In a 1:1 call, the same directions use
the authenticated WebRTC data channel instead.

## Web Push

Each browser/device can register a Push API subscription. Push payloads are
encrypted with RFC 8291 `aes128gcm`; VAPID authentication uses RFC 8292 ES256
and a per-instance P-256 key. Gone subscriptions (HTTP 404/410) are pruned.
Payloads contain notification metadata such as sender handle and kind, not
message plaintext. Push services still observe endpoint and timing metadata.

## Key lifecycle

- **Passphrase change:** unwrap and rewrap the same secret key in the browser.
  The public key and existing envelopes do not change.
- **Rotation:** decrypt local history with the old key, generate a new keypair,
  reseal relevant envelopes, atomically replace stored key material, and send
  signed key-update announcements. Friends must manually confirm the new key.
- **Reset:** generate a new keypair and purge received envelopes that are no
  longer decryptable. Copies owned by other senders or recipients are not
  cryptographically revoked.

## Data model

| Table | Important fields / role |
| --- | --- |
| `users` | Local accounts and remote-contact stubs; profile, host, wrapped identity key, current/pending public keys. |
| `user_tokens` | Session, login, confirmation, and email-change tokens. |
| `friendships` | Canonical user pair and `pending`/`accepted` state. |
| `groups`, `group_members` | Owner-local organization of accepted friends. |
| `contact_notes`, `group_notes` | Owner-private but server-readable plaintext notes. |
| `envelopes` | Per-recipient ciphertext, nonce, sender-key snapshot, delivery/edit/expiry/display metadata, and a materialized per-viewer thread key so conversation lists and pages are index queries that load no ciphertext. |
| `conversation_archives` | Archived/preserved conversation instances; archiving stamps member envelopes with the instance key. |
| `notifications` | Per-envelope consent state. |
| `conversation_windows` | Rolling user/peer auto-accept expiry. |
| `calls` | 1:1 call consent/lifecycle state (ringing/accepted/…); signaling itself is relayed, never stored. |
| `scheduled_calls` | Persistent organizer/invitee plans, UTC time, reminder lead time, note, lifecycle state, and reminder stamp. |
| `blobs` | Opaque encrypted file location, owner, size, and public capability ID. |
| `instance_credentials` | Server-side Ed25519 federation and P-256 VAPID keypairs. |
| `peers` | TOFU-pinned remote instance signing keys. |
| `outbound_deliveries` | Retriable signed federation operations. |
| `push_subscriptions` | Per-device Push API endpoint and public subscription keys. |

SQLite foreign keys and ownership-scoped context queries enforce most local
relationships. Sending validates accepted friendship for every recipient
inside the database transaction.

## Account portability

`GET /export` builds an in-memory zip containing `export.json`, the user's
normalized profile image when present, and owned encrypted blobs. The manifest
includes profile and wrapped keys, friends, groups, and decryptable encrypted
history with sender-key snapshots. It exposes social metadata despite retaining
content encryption.

`mix veejr.import export.zip` creates the owner, restores their profile image,
accepted remote friendships, remote ghost contacts needed to identify
historical senders, envelopes with
original IDs/timestamps, and owned blobs. Received envelopes are imported as
accepted. During a managed move, source finalization verifies that the target
directory publishes the same user key, replaces local address-book references
with the new remote contact, and sends signed move notices to other federated
servers. Import does not include received attachments because the server cannot
discover blob IDs inside encrypted payloads. Contact/group notes and newer
envelope expiry/edit metadata are not currently part of export format version 1.

Account deletion removes owned blob files and the user row; foreign-key
cascades remove associated rows, including envelopes sent by that user.

## Security boundaries

The server can observe or control:

- account identifiers, friend graph, groups, contact/group notes, and login
  activity;
- sender/recipient relationships, item kinds, timestamps, expiry/display
  policy, attachment sizes, notification decisions, and delivery timing;
- ciphertext and capability identifiers;
- instance signing/VAPID private keys stored in SQLite;
- the JavaScript delivered to browsers.

The intended honest-server design keeps message text, decrypted attachments,
and coordinates out of LiveView payloads and persistent server storage.
Decrypted UI is written with `textContent` by client hooks.

A malicious or compromised server can alter the JavaScript client and capture
passphrases, keys, or plaintext. E2E encryption also cannot prevent recipients
from retaining content they have decrypted, and capability URLs may leak via
logs or clients. Operational security therefore depends on TLS, restricted
database/blob access, protected backups, prompt updates, and verification of
the deployed client build.
