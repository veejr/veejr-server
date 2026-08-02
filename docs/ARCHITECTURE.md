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
| `Veejr.Calls` | Call membership, consent and lifecycle for up to three participants, schedules and reminders, addressed sealed signaling relay, presence grace, and federated call updates. |
| `Veejr.GuestConferences` | Expiring email-capability invitations, host admission, and temporary guest-call identity/lifecycle. |
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
- `/guest/:token` and `/guest/:token/call` use a dedicated public LiveView
  session. The hashed, expiring email capability is the only authorization for
  the guest side; it grants no account, contacts, message, or history access.
- `/watch/guest/:token` similarly uses a dedicated playback-only guest session.
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

Surfaces that need a key mid-action unwrap it where they stand rather than
navigating to the keys page: the call page does this, and so does the message
composer, which would otherwise discard a written message and its attachments
on the way. Each such surface is served the same already-encrypted key
material and unwraps it locally; the passphrase and the raw secret key never
become a LiveView event or a request.

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

### Owner-only items: notes and documents

Two kinds are a single copy addressed to yourself, never notified and never
federated: `self_note` (a card on the Notes to yourself board) and `self_doc`
(a spreadsheet or a text document). They are refused if given more than one
recipient, a recipient other than the sender, an expiry, a display limit, or a
schedule — there is no second party for any of those to mean anything to.

`self_doc` is one envelope kind for every document format, with the format
named by `doc_kind` *inside* the encrypted payload. The server therefore cannot
distinguish a spreadsheet from a text document, and adding a third format later
requires no protocol change.

A text document is stored as blocks of plain text plus mark ranges
(`{s, e, m}`) — never as a markup string. The editor turns those into spans it
creates with DOM APIs, so the board's rule that decrypted content never reaches
`innerHTML` holds for formatted text too: there is no HTML to sanitize because
none is ever produced. Spreadsheet formulas are evaluated by an interpreter,
not compiled to JavaScript; the enforced `script-src 'self'` policy carries no
`'unsafe-eval'`, so the alternative would not run in a browser anyway.

Because the whole document lives in one envelope, it is bounded by the
ciphertext ceiling (350,000 base64 characters, ~256 KB of payload). Large
attachments continue to use the encrypted blob path.

### Attachments

Files reach the composer from the picker, a paste, or a drop anywhere on the
conversation. All three write into the same `<input type="file">` through a
`DataTransfer`, so that input stays the one source of truth the send path
reads and a form reset still clears everything. The instance's upload limit is
served as a data attribute so an oversize file is refused before it is
encrypted, and attachments are deliberately never written to the draft: drafts
are sealed into `localStorage`, which is no place for file bytes.

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

Accepted incoming envelopes have a nullable `read_at`. Conversation summaries
count unread accepted incoming copies without loading ciphertext and preload
only the latest encrypted envelope so a browser hook can decrypt its preview.
Opening a Messages thread stamps its accepted incoming copies read. These
read/unread markers are server-readable presentation metadata; preview
plaintext remains browser-only.

### Scheduled sends

A scheduled message is an ordinary envelope. The browser seals it for each
recipient at compose time, exactly as for an immediate send, and the server
stores that ciphertext with a `deliver_at`. What is deferred is only the
*release*: no notification row exists until the message is due, for local and
remote recipients alike, which is what makes it unreachable rather than merely
hidden — both `fetch_envelope/2` and `list_history/2` require an accepted
notification, so there is no id to guess and nothing to enumerate.

```text
compose -> encrypt -> envelope stored with deliver_at (no notification)
                          |
        Messaging.Scheduler tick, deliver_at reached
                          |
        +-- recipient key unchanged -> notification created (consent evaluated
        |                              now, against the conversation as it
        |                              stands) / federation notify enqueued
        |
        +-- recipient key rotated ---> release refused, release_error set,
                                       sender told to send it again
```

Two consequences are deliberate. **Consent is decided at release**, not at
compose: whether the message auto-accepts depends on the conversation window
when it actually arrives. And **a rotated recipient key blocks delivery**. Key
rotation re-encrypts history through `Messaging.list_resealable/1`, which walks
`list_history/2` and therefore cannot see an unreleased scheduled envelope —
including it would hand the recipient the message early. Without the
`recipient_public_key` snapshot taken at compose time, a recipient who rotated
while the message waited would receive ciphertext that looks intact and never
opens. Release compares the snapshot with the recipient's current key and
refuses rather than delivering something undecryptable.

The server learns that a scheduled message exists, for whom, and when it is
due. It does not learn its content at any point.

### Reminders

A self-note or self-document may carry one `remind_at`. This time is
necessarily server-readable — something has to know when to fire — but the
reminder that fires is content-free: it names no title, body, label, or
attachment, only that a reminder is due and which encrypted card it belongs to.
The browser opens the board and decrypts the card itself. Setting a new time
re-arms an already-fired reminder.

Contacts and Messages appearance preferences are browser-local `localStorage`
choices and do not alter stored content. Contacts supports Classic, Quiet, six
flat playful palettes, and the Orbit/Soiree WebGL views. Messages supports
Classic, Salon, Party, and Comic; new-message animation and explicit control
states change with the choice. Message bubbles render a semantic UTC date/time
from the envelope timestamp.

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
| `POST /api/federation/call_update` | Relay joined/declined/busy/cancelled/ended/disconnected lifecycle state. |
| `POST /api/federation/call_signal` | Relay one sealed SDP/ICE payload synchronously. |
| `POST /api/federation/call_schedule` | Durably mirror scheduled-call creation and state. |
| `POST /api/federation/presence` | Assert coarse online state for the sending instance's own users. |
| `GET /api/envelopes/:public_id` | Fetch envelope ciphertext by capability. |
| `GET /api/blobs/:id` | Fetch encrypted blob bytes by capability. |

### Pull flow across instances

When Alice on A sends to Carol on B, A retains the ciphertext and sends B a
content-free notify. B creates a stub envelope and pending notification. Only
after Carol accepts does B fetch `/api/envelopes/:public_id` from A and fill the
stub. Declining means the ciphertext never leaves A.

### Contact presence

`Veejr.Presence` answers whether a contact currently has veejr open, in four
coarse states: `online`, `recently`, `offline`, and `unknown`. Local presence
falls out of the LiveView processes that already exist — every authenticated
page registers through `VeejrWeb.TrackPresence` and the monitored process
releases its slot when the tab closes. State lives in ETS, never the database:
it is ephemeral, a write per transition would be WAL traffic for data that is
worthless after a restart, and an empty table on boot is the honest answer.

A dropped socket is not treated as a departure until a grace period expires,
for the same reason call-page presence has one — mobile browsers reconnect
constantly and a reconnect is not a hangup.

Across instances presence is pushed, not polled. When a user's state changes,
their instance groups that user's remote friends by authority and posts one
`/api/federation/presence` assertion per peer, carrying every affected user
rather than one request per contact. Polling would scale with viewers ×
contacts and would leak *when someone opens their contacts page* to every
server their friends use. Delivery is synchronous and best-effort and never
enters `Veejr.Federation.Outbox`: a presence update redelivered hours later is
not late, it is false. Only the HTTP call is detached to a task, so an
unreachable peer cannot stall a page mount.

Every assertion carries a TTL and is re-asserted on a slower heartbeat, so a
peer that crashes mid-session decays to `unknown` rather than leaving a contact
lit indefinitely. `unknown` is deliberately distinct from `offline`: silence
from a peer says something about the link, not about the person, and a dot that
guesses is a dot people learn to ignore. Peers that answer 404 predate the
endpoint and are parked for an hour, since instances upgrade on their own
schedule.

Sharing is per user (`users.presence_sharing`, default on) and enforced where
presence is recorded, so switching it off stops the state existing rather than
asking peers not to display it. Nothing finer than the four states crosses the
wire — no timestamps, and therefore no federated record of when someone is at
their computer. Receivers store presence only for contacts a local user is
already friends with, and never create an account from an assertion.

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

Audio/video calls use WebRTC: DTLS-SRTP media and the DTLS/SCTP call data
channel flow peer-to-peer and never touch an instance. A call is a full mesh
of up to three participants (`:max_call_participants`), and a two-person call
is a mesh of one pair rather than a separate implementation. The server's role
is consent, lifecycle, presence, and signaling relay:

- Membership lives in `call_participants`, one row per person per call, each
  with its own lifecycle state. Authorization for a call page is that row, not
  the `calls.caller_id`/`callee_id` pair — those are retained because a
  federated invite is strictly 1:1, with the caller acting as host.
- Only the caller may add someone, and only an accepted local friend: with
  three people, "who let them in?" needs exactly one answer. The invitee is
  rung exactly as a first invitee is and must accept.
- A participant leaving is a departure, not an ending. The call ends once
  fewer than two participants remain, so one invitee declining leaves the
  others talking.
- Signaling is addressed (`{:call_signal, id, from, target, ct, nonce}`).
  Without a target, three participants receive each other's offers with no way
  to tell which pairing an SDP belongs to; a pair infers its target and
  federated or guest calls address "the other side".
- Each browser holds one `RTCPeerConnection`, data channel, and video tile per
  other participant, using *perfect negotiation* (the peer with the lower id
  is polite) so either side may author an offer or an ICE restart without
  glare. Mesh upload grows with participant count, so video caps at the
  Balanced sender profile from three participants up.
- The peer roster reaches the browser as an assign — first paint via
  `data-peers`, thereafter a `call:peers` push, because the hook's element is
  `phx-update="ignore"`. Holding a connection to every joined roster entry is
  what makes late arrivals, departures, and page reloads one code path.
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
  Either participant may cancel; the signed cancellation carries its actor and
  optional reason, and the recipient's home instance emails its own local user.
  Schedule metadata, optional note, cancellation actor, and cancellation reason
  are server-readable.
- The device-preview gate and in-call passphrase prompt keep camera/microphone
  selection and key unwrap in the browser. The passphrase and raw secret key
  are never sent through LiveView.
- The data channel carries ephemeral text, clickable HTTP/HTTPS links, and
  files up to 25 MB; screen-share state, media-state hints, and synchronized
  YouTube directions travel the same pairwise channels. With three people each
  item is sent once per pair — there is no server copy to fan out — and
  incoming chat is attributed to the peer whose channel delivered it. These
  items are memory-only and disappear when the peer connection closes; they are
  not envelopes or history.
- Video capture begins at up to 720p/30fps. Browser WebRTC statistics drive
  HD/Balanced/Data saver sender profiles, with audio prioritized during
  degradation; the worst leg of the mesh decides, because averaging would hide
  the leg that is failing. Screen capture uses a separate profile, and starting
  or stopping it renegotiates every pairing once so receivers decode the
  swapped track instead of holding the previous frame.
- Each leg attempts two ICE restarts after a connection failure. Call-page
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

### Email-capability guest calls

An authenticated, key-configured local host can email one no-account guest an
unguessable 256-bit capability. The database stores only its SHA-256 hash,
normalized invited email, two-hour expiry, lifecycle timestamps, and eventual
temporary display name/public key. The guest route generates an ephemeral
X25519 identity in that browser tab, checks devices, and enters a waiting room.
The host must explicitly admit the expected display name before a `guest_calls`
row and WebRTC session are created; the host may decline or revoke beforehand.

Guest SDP/ICE is sealed between the host's pinned identity and the guest's
temporary public key. Media, chat, and files use the same peer-to-peer call
channels and remain ephemeral. Ending the call clears the persisted guest
public key, while lifecycle metadata and invited email remain in the
guest-conference row. The capability grants only that conference and expires
after two hours. After an ended call, the guest may optionally exchange it for
a normal membership invitation when instance invitation policy allows; no
hidden user account is created automatically.

## YouTube watch parties

`Veejr.WatchParties` holds at most one party in process memory. It stores the
random party ID, initiating local user, YouTube video ID, playback direction,
and position. The host alone may control/end playback; all authenticated users
on the same instance receive a join hint. Control refreshes a 90-second timer,
so an abandoned host causes the party to expire. State is neither durable nor
federated and disappears on application restart.

Hosts may create up to 25 outsider invitations from normalized,
comma-separated email addresses. A distinct 256-bit capability is emailed to
each recipient; only its SHA-256 hash and email remain in the in-memory party
state. The public `/watch/guest/:token` LiveView is in the ordinary `:browser`
pipeline with no authentication mount because the unguessable token is its
sole authorization boundary. It exposes synchronized playback only. Ending
the party, host expiry, or process restart clears every invitation.

Optional voice uses a peer-to-peer WebRTC mesh. Every page joins receive-only;
a participant explicitly grants microphone access to start transmitting and
may stop their track independently. SDP/ICE signaling is sealed pairwise with
participant identity keys before LiveView relays it. The server observes
membership and encrypted signaling sizes/timing but not voice. Mesh upload
cost grows with participant count, so the feature targets small communities.

The YouTube iframe runs in each browser against `youtube-nocookie.com`.
Instances do not proxy video, but YouTube sees each viewer's request metadata.
Playback directions are not content-encrypted in a general watch party; the
video ID and state are server-readable. In a call, the same directions use the
authenticated WebRTC data channels instead, and only the participant whose
channel started the share may steer it.

Someone who is not steering the video watches through a click guard rather than
an inert frame, because YouTube can interrupt any viewer with a "confirm you're
not a bot" check that is painted inside that frame. The check wants a signed-in
YouTube session, and `youtube-nocookie.com` is a separate origin that never
carries one, so the player offers that viewer the same video from
`youtube.com`. Nothing about it is instance-wide: it is one browser's frame,
chosen by the person in front of it, and the privacy host remains what every
share loads.

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
| `envelopes` | Per-recipient ciphertext, nonce, sender-key snapshot, delivery/read/edit/expiry/display metadata, and a materialized per-viewer thread key so conversation lists and pages are index queries that load no ciphertext except the newest encrypted preview candidate. Also the scheduled-send fields (`deliver_at`, `released_at`, `release_error`, `recipient_public_key`) and one-shot reminder fields (`remind_at`, `reminded_at`). |
| `conversation_archives` | Archived/preserved conversation instances; archiving stamps member envelopes with the instance key. |
| `notifications` | Per-envelope consent state. |
| `conversation_windows` | Rolling user/peer auto-accept expiry. |
| `calls` | Call consent/lifecycle state (ringing/accepted/…) plus the host and first invitee; signaling itself is relayed, never stored. |
| `call_participants` | One membership row per person per call: role, own lifecycle state, and join/leave timestamps. The source of truth for who is in a call and who may open its page. |
| `scheduled_calls` | Persistent organizer/invitee plans, UTC time, device and two-minute email reminder checkpoints, shared notes, lifecycle state, cancellation actor, and optional cancellation reason. |
| `guest_conferences`, `guest_calls` | Expiring hashed email capabilities, invited email, temporary guest identity, host admission/lifecycle metadata, and one guest call; signaling and media are not stored. |
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

The sudo-protected account Settings LiveView accepts the same zip for an
additive restore into the signed-in account. It rejects oversized archives,
unexpected or duplicate paths, excessive expansion, malformed manifests,
cross-account public-ID collisions, and any username or wrapped-key identity
mismatch before writing. Existing envelopes and blobs are skipped, so retrying
the same restore is safe; credentials and key material are never overwritten.
The LiveView stays in the existing authenticated account `live_session`, while
the download remains in the authenticated `:browser` controller scope.

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
- guest-conference host, invited email, capability hash, expiry/lifecycle
  timestamps, temporary display name/public key while active, and call timing;
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

Browser responses carry a Content-Security-Policy
(`VeejrWeb.ContentSecurityPolicy`) that confines `script-src` and
`connect-src` to the instance's own origin, with the inline theme bootstrap
authorized by a per-response nonce rather than `'unsafe-inline'`. This does not
change the boundary above — an attacker who can rewrite `app.js` can rewrite
the header alongside it. What it constrains is the weaker case: an injection,
a compromised dependency, or a templating mistake cannot execute inline script
and has no off-origin destination to send a captured key to. Federated avatars
require `img-src` to allow arbitrary `https:` origins, and shared viewing
requires `frame-src` for both YouTube embed hosts; all are content sources
rather than script or exfiltration paths.

Request budgets (`Veejr.RateLimiter`) cover authentication, directory,
invitation, upload, and federation endpoints. Because every deployment sits
behind a TLS-terminating proxy, budgets key on the client address resolved from
`x-forwarded-for` via `Veejr.RemoteIp`, which believes the header only when the
immediate peer is a configured trusted proxy and reads the chain right to left
so a caller cannot spoof its address. Counters are per node and in memory.
