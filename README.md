# veejr

veejr is a self-hostable Phoenix application for sharing end-to-end encrypted
messages, attachments, locations, and map notes with selected friends and
groups. Encryption and decryption happen in the browser or native Android
client; the server stores and federates ciphertext while enforcing identity,
friendship, and consent rules.

> **Project status:** veejr is an early-stage application. Review the security
> model and deployment configuration before relying on it for sensitive data.

## Highlights

- Browser-generated X25519 identity keys, with the secret key wrapped by a
  passphrase-derived key before it is stored on the server.
- Pull-based delivery: a recipient normally accepts or declines a notification
  before the ciphertext is fetched. An accepted conversation opens a rolling
  five-minute auto-accept window for that peer.
- Local and federated friends addressed as `username@authority`.
- Encrypted attachments, expiring/view-limited messages, sender-side edits and
  deletion, recorded voice/video messages, conversations, location sharing,
  and geo-notes.
- An encrypted **Notes to yourself** board with text/checklist cards, labels,
  colors, pin/archive/trash flows, local search, attachments, and idempotent
  Google Keep Takeout import.
- Personal notes attached to contacts and groups. Unlike Notes to yourself,
  these convenience notes are server-side plaintext and are not part of the
  end-to-end encrypted message system.
- Public profile images with colorful initials placeholders and browser-side
  cropping for consistent contact and conversation avatars.
- Account export/import, administrator-controlled moves into newly provisioned
  instances, key rewrap/rotation/reset, installable PWA support, browser
  notifications, and encrypted Web Push.
- Pull-based self-upgrades: each instance checks the upstream releases on its
  administrator's request and can upgrade and restart itself, with an
  automatic database backup and build-failure rollback.
- 1:1 browser audio/video calls, including across federated instances, with
  device preview, adaptive video, screen sharing, full-screen/Picture-in-
  Picture/pop-out views, ephemeral direct chat and files, synchronized YouTube
  sharing, interruption recovery, caller re-invites, and persistent scheduled
  calls with reminders, shared notes, participant cancellation, and
  cancellation email. WebRTC media and data flow peer-to-peer; signaling is
  sealed between pinned participant keys.
- Email-capability guest calls let a member invite one person without a Veejr
  account into a host-admitted, encrypted 1:1 video call. The guest uses a
  temporary browser identity and can optionally join Veejr after the call.
- Instance-local, host-controlled YouTube watch parties. Signed-in users can
  join synchronized playback and independently enable or disable peer-to-peer
  voice; hosts can email ephemeral playback-only guest links to outsiders.
- A native Jetpack Compose Android client with portable-key unlock, consent,
  conversation messaging, filtered history, contact/group policy controls, and
  private notes. See [veejr-android](https://github.com/veejr/veejr-android).
- Community and personal instance modes backed by SQLite.

For protocol details, trust boundaries, and data flows, see
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

For a map of all user, operator, compatibility, and planning documents, see
[docs/README.md](docs/README.md).

For a framework- and language-independent specification suitable for recreating
Veejr in another environment, see
[docs/REIMPLEMENTATION_SPEC.md](docs/REIMPLEMENTATION_SPEC.md).

For installation and server administration, see:

- [Installation and server setup](docs/INSTALLATION.md)
- [Production operations, upgrades, and recovery](docs/OPERATIONS.md)
- [Calls and YouTube watch parties](docs/CALLS_AND_WATCH_PARTIES.md)

## Technology

- Elixir 1.15+ and Phoenix 1.8 / LiveView 1.2
- SQLite through `ecto_sqlite3`
- TweetNaCl in the browser (`nacl.box` and `nacl.secretbox`)
- Kotlin, Jetpack Compose, and compatible NaCl primitives in the Android client
- Leaflet with OpenStreetMap tiles
- Phoenix PubSub, the Notifications API, and Web Push
- WebRTC for calls, ephemeral data channels, screen sharing, and watch-party voice
- YouTube's privacy-enhanced embed for synchronized shared viewing

## Local development

Prerequisites: Elixir 1.15+ with OTP 26+ and the build tools required by
`bcrypt_elixir`.

```sh
mix setup
mix phx.server
```

Open <http://localhost:4000>. Development email is available at
<http://localhost:4000/dev/mailbox>.

The development server listens on all IPv4 interfaces by default, so another
device on the same LAN can open `http://<computer-lan-ip>:4000`. Set
`BIND_ALL=false` to restrict it to this computer. Windows Firewall must also
allow inbound TCP port 4000 on private networks. Browser features that require
a secure context, including WebCrypto, service workers, and push, may not work
over a plain LAN-IP HTTP URL; use HTTPS (for example through a trusted local
certificate or tunnel) when testing those features.

### Android development

The native client is maintained in
[veejr-android](https://github.com/veejr/veejr-android) and consumes the
versioned contract in [docs/CLIENT_PROTOCOL_V1.md](docs/CLIENT_PROTOCOL_V1.md).
An Android emulator reaches this server at `http://10.0.2.2:4000`. For a
physical device connected through ADB, run:

```sh
adb reverse tcp:4000 tcp:4000
```

Then configure the debug app with `http://127.0.0.1:4000`. Production Android
builds require an HTTPS instance.

First-time flow:

1. Register with an email address and username.
2. Confirm or log in using the link in the development mailbox (a password can
   also be configured).
3. Visit `/keys`, create an encryption passphrase, and keep it safe. Losing it
   means received encrypted history cannot be recovered.
4. Add a friend on `/contacts`, then send from `/messages` or `/map`.

### Account and conversation controls

Click your username in the header to open the account page. From there you
can open Settings, manage encryption keys, or open Archived conversations.
Settings also lets you choose, replace, or remove your profile image. Images
are center-cropped and resized in the browser before upload, then shown on the
Contacts and Messages pages. Click a contact's image to open a larger profile
view and edit the private notes you keep about that person.

Contacts has persistent Classic, Quiet, six playful, and two experimental 3D
appearances. Orbit and Soiree render conversations in WebGL while preserving
the same profile-image and conversation actions; accepted federated avatars
are served through an authorization-scoped, same-origin texture proxy when
the remote instance cannot be used directly as a canvas texture.

To archive a conversation, open it in `/messages` and choose **Archive** in
the conversation header. Archiving hides the thread from Messages and
Contacts without deleting its messages. Restore it from Account → Archived
conversations by choosing **Unarchive**.

In Messages, the composer stays pinned to the bottom of the conversation.
Press **Enter** to send; press **Shift+Enter** to insert a newline.
The conversation rail shows client-decrypted previews and unread counts;
opening a thread marks its accepted incoming messages read. Choose Classic,
Salon, Party, or Comic for a browser-local Messages appearance. New-message
animation and control colors follow that choice, while every message retains
an explicit UTC date and time.

The Message options menu can set an availability time and a display count.
Those limits are applied to every encrypted copy, including the sender's
outgoing copy, so attached files disappear with the message in the app as
well. A file that has already been downloaded or captured by a recipient
cannot be recalled by the server.

### Calls and YouTube watch parties

Start a 1:1 call from an accepted contact or conversation. Both participants
can choose devices before joining, mute audio/video, share a screen, exchange
ephemeral direct chat/files, or share a synchronized YouTube video. If a brief
network or page interruption cannot recover automatically, the original
caller can send a fresh invitation. Veejr warns before in-app navigation that
would close an active call.

Use **Calls** to schedule a persistent one-to-one call. Calendar entries start
as compact person-and-time rows and expand to show reminders, shared notes,
start controls, and cancellation. Either participant can cancel with an
optional reason; the other participant receives an email, including across
federated instances through their own home server.

From **Invite someone**, choose **Guest call** to email a two-hour capability
link to a person without an account. The guest checks devices and supplies a
display name, then waits for the host to admit them. The host can cancel before
admission. Guest chat, files, and the temporary browser identity disappear
when the conference ends; joining Veejr afterward remains optional.

The global **Watch** page hosts one instance-local YouTube watch party at a
time. The initiator controls playback; every other signed-in user on that
instance may join and may independently turn their microphone on or off. The
host can also paste up to 25 comma-separated email addresses into **Invite
outsiders**. Each recipient receives a different private, no-account guest
link for synchronized playback; encrypted party voice remains member-only.

Call chat/files and watch-party state are deliberately ephemeral: they are not
message history, export data, or durable server records. Browser autoplay,
camera, microphone, pop-up, and screen-capture policies still apply. See
[Calls and YouTube watch parties](docs/CALLS_AND_WATCH_PARTIES.md) for the
complete behavior, privacy model, recovery flow, and troubleshooting.

Useful commands:

```sh
mix test
mix precommit
mix ecto.reset
```

### Test federation locally

Run two instances with separate SQLite databases:

```sh
# terminal 1
mix phx.server

# terminal 2 (first run)
PORT=4001 VEEJR_DB=veejr_dev2.db mix ecto.setup
PORT=4001 VEEJR_DB=veejr_dev2.db mix phx.server
```

Add `someone@localhost:4001` from the first instance. Set `BIND_ALL=false` when
a development server should listen only on loopback.

## Instance modes

| Mode | Registration behavior |
| --- | --- |
| `community` (default) | Registration is open. |
| `personal` | The first account can register; further users need a seven-day invite link generated by an existing user. |

Development mode is configured in `config/config.exs`. In production, set
`VEEJR_MODE=personal` for a private instance.

### Instance administration

The first local account is permanently assigned as the instance administrator.
That assignment cannot be changed or deleted. The administrator can open
`/admin` from the Account page to:

- Review service health, versions, registrations, attachment storage, email
  failures, federation retries, and pending remote key changes.
- Configure open, invitation-only, or closed registration; invitation lifetime;
  upload and total attachment-storage limits; default message retention; the
  public instance name and description; and mail sender identity.
- Inspect, revoke, or immediately expire tracked invitations and see who joined
  through them.
- Review local-account operational metadata, revoke web and Android sessions,
  and suspend or reactivate members without deleting their data.
- Test and provision a separate instance for a non-admin member, verify the
  encrypted export import, and explicitly finalize removal from the source.
- Inspect pinned federation peers, block or unblock their traffic, and retry
  queued federation deliveries.
- Review an append-only audit trail of administrator actions. Audit and
  operational-failure records contain no decrypted messages, attachments,
  notes, locations, passwords, secret keys, or recipient email addresses.

Admin sections are individually collapsible. **Overview** starts open; the
remaining operational sections start closed so sensitive and advanced
controls do not overwhelm the page.

`PHX_HOST`, TLS, DNS, SMTP credentials, and `VEEJR_MODE` remain deployment
settings. The Admin page displays the effective mode and public federation
authority but does not mutate them, because changing either without updating
the reverse proxy, certificates, DNS, and peer identity would break the
instance. The Admin registration policy can override the mode's default signup
behavior without changing its federation identity.

## Production configuration

Production builds run database migrations automatically at startup, including
the current source-mounted Docker service (`:auto_migrate` is enabled in
`config/prod.exs`). The manual rollout procedure also runs
`mix ecto.migrate` before restart so an incompatible migration fails while the
old task is still serving. See [docs/INSTALLATION.md](docs/INSTALLATION.md) for
the complete, tested setup.

Set `PHX_SERVER=true` when starting a release and provide these required
variables:

| Variable | Purpose |
| --- | --- |
| `DATABASE_PATH` | Absolute path to the SQLite database. |
| `SECRET_KEY_BASE` | Phoenix cookie/session secret; generate with `mix phx.gen.secret`. |
| `PHX_HOST` | Public host used in URLs and federated addresses. |
| `MAIL_FROM_ADDRESS` | Sender address for authentication email. |
| `SMTP_HOST` | SMTP relay hostname. |

Common optional variables are `PORT` (default `4000`), `POOL_SIZE` (default
`5`), `VEEJR_MODE`, `VEEJR_BLOB_DIR` (default `/var/lib/veejr/uploads`),
`MAIL_FROM_NAME`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_AUTH`,
`SMTP_TLS`, `SMTP_SSL`, and `DNS_CLUSTER_QUERY`.

To enable Android background push, provide a Firebase **service-account** JSON
to Docker as a Swarm secret and set `FCM_SERVICE_ACCOUNT_JSON_FILE` to its
mounted path, `/run/secrets/fcm_service_account_json`. The legacy
`FCM_SERVICE_ACCOUNT_JSON` environment variable remains supported for
non-Swarm deployments, but must not be used in production. The service account
is a production secret: never add it to this repository, an Android build, an
ordinary environment file, or a Docker image. This turns on `android_push` in
the capabilities API. Browser Web Push remains available without it.

### Browser push troubleshooting

Browser Web Push requires HTTPS (except on localhost), an allowed notification
permission, and a browser push service. In Brave, enable **Use Google services
for push messaging** under `brave://settings/privacy` if enabling push reports
`Registration failed - push service error`. Then refresh the Settings page and
select **Enable push on this device** again.

On a phone, if the app reports that notification permission was not granted,
open the browser's site settings for the veejr address, set **Notifications** to
**Allow**, and reload the page. A previous denial usually prevents the browser
from showing the permission prompt again until this setting is changed.

### FCM Docker Swarm setup (current Windows host)

This host runs Docker Desktop on Windows. Store the downloaded Firebase key
outside the repository at:

```text
C:\ProgramData\Veejr\secrets\fcm-service-account.json
```

Create the directory, restrict its ACL to the deployment operator,
Administrators, and SYSTEM, then download a *new* key from Firebase Console:
select the Veejr project, open **Project settings → Service accounts**, choose
**Generate new private key**, and save it at that path. `google-services.json`
is an Android client configuration file, not a server credential, and cannot
be used here.

Initialize this single-node host as a Swarm manager once, then create the
immutable Docker secret. Do not print the JSON or use `docker secret inspect`
to troubleshoot it.

```powershell
docker swarm init
Get-Content -Raw C:\ProgramData\Veejr\secrets\fcm-service-account.json |
  docker secret create fcm_service_account_json -
```

The current `veej_fable` Swarm service already mounts this secret and has the
following configuration. New installations should attach it while creating
the service as described in [docs/INSTALLATION.md](docs/INSTALLATION.md):

```text
secret: fcm_service_account_json → /run/secrets/fcm_service_account_json
environment: FCM_SERVICE_ACCOUNT_JSON_FILE=/run/secrets/fcm_service_account_json
restart policy: any, no maximum retry count
```

Do not print or inspect the secret contents. Verify the running service without
exposing secret material:

```powershell
docker service ls
docker service ps veej_fable
docker service logs --tail 100 veej_fable
curl.exe https://veejr.dyndns-server.com/api/v1/capabilities
```

The capabilities response should contain `"android_push": true`. If it is
false, first confirm that the secret is attached to the service and that
`FCM_SERVICE_ACCOUNT_JSON_FILE` has the mounted path. Do not fall back to an
environment variable containing the JSON.

To rotate the Firebase key, generate a replacement in Firebase, create a new
Docker secret with a versioned name, update the service to remove the old secret
and add the new one at the same target path, verify the capability, then revoke
the old Firebase key and remove the old Docker secret. Docker secrets are
immutable, so they cannot be overwritten in place. The full rotation and
recovery procedures are in [docs/OPERATIONS.md](docs/OPERATIONS.md).

Terminate TLS at a reverse proxy or configure HTTPS before exposing an
instance. Back up both `DATABASE_PATH` and `VEEJR_BLOB_DIR`; the database also
contains instance federation-signing and VAPID credentials.

### Current Docker deployment

The main currently operated instance uses one Docker Swarm service and three
standalone supporting containers on the Windows host at `192.168.0.251`:

| Service/container | Role | Published ports |
| --- | --- | --- |
| `veej_fable` | Single-replica Phoenix Swarm service (`MIX_ENV=prod`) | TCP 4000, host mode |
| `veej_caddy` | TLS termination and reverse proxy | TCP/UDP 443 |
| `veej_coturn` | STUN/TURN relay for restrictive call networks | TCP/UDP 3478 and UDP 41000–41040 |
| `veej_postfix` | Available local SMTP relay; not currently used by Phoenix | Internal TCP 587 |

Caddy serves `https://veejr.dyndns-server.com` and proxies requests to
`host.docker.internal:4000`. The router forwards public HTTPS to this host;
Windows Firewall allows Caddy on TCP/UDP 443 and the Phoenix listener on TCP
4000. Phoenix currently sends authentication email directly through an
external authenticated SMTP provider. Production forces HTTPS, so a request
to a raw HTTP address such as
`http://192.168.0.251:4000` redirects to the public hostname.

The router does not provide NAT loopback. For the production URL to work from
inside the LAN, configure split DNS (also called a local DNS override or host
record):

```text
veejr.dyndns-server.com -> 192.168.0.251
```

LAN and WAN clients should then use the same URL:
<https://veejr.dyndns-server.com>. A per-device hosts-file entry is a fallback
when the router cannot provide split DNS:

```text
192.168.0.251 veejr.dyndns-server.com
```

Useful operational commands:

```sh
docker service ls --filter name=veej_fable
docker service ps veej_fable --no-trunc
docker service logs --tail 100 veej_fable
docker service update --force veej_fable
docker ps --filter name=veej_caddy
docker logs --tail 100 veej_caddy
```

The Swarm service bind-mounts the project and starts the application with
`mix phx.server`; this is operationally convenient but is not an immutable
release deployment. Swarm restarts the Phoenix task on failure. The standalone
Caddy, coturn, and Postfix containers are configured with an `unless-stopped`
restart policy, so they return automatically after a Docker daemon or host
restart (provided Docker Desktop itself starts). A future deployment should use
a built release image and configure all supporting containers with persistent
volumes. The exact current host layout, secrets, and recovery steps are in
[docs/HOST_RUNBOOK.md](docs/HOST_RUNBOOK.md); installation, upgrade order,
backup procedure, and troubleshooting are in
[docs/INSTALLATION.md](docs/INSTALLATION.md) and
[docs/OPERATIONS.md](docs/OPERATIONS.md).

## Account portability

Settings can export a zip containing the profile image, profile, wrapped key
material, friends, groups, encrypted envelope history, and blobs uploaded by
the user.
The export remains encrypted at the content level but exposes social metadata,
so treat it as private.

The same **Backup and restore** panel accepts a previous export for the
currently signed-in account. Browser restore is additive and idempotent: it
restores missing encrypted history, contacts, profile image, and owned blobs
without replacing login credentials or encryption keys. The archive's
username and complete wrapped-key identity must match the current account.

Import it into a fresh instance with:

```sh
mix veejr.import path/to/veejr-export.zip
```

The import restores the account, profile image, history, sender key snapshots, owned blobs,
and accepted friendships as contacts at their recorded server addresses. A
managed account move also replaces the departing source contact with the new
address when the administrator finalizes it. Received attachments are not
included because their blob identifiers exist only inside encrypted payloads.

## Security summary

Messages, locations, geo-notes, and attachment descriptors are encrypted once
per recipient with NaCl `box`; the sender also creates a self-copy for history.
Attachments are encrypted once with a random `secretbox` key carried inside the
encrypted envelope. The server can observe metadata such as accounts,
friendships, sender/recipient pairs, item kinds, timestamps, and blob sizes, but
not encrypted content or coordinates.

The web delivery model still trusts the server to serve honest JavaScript. A
compromised server can replace the client code and capture plaintext or keys.
This is a fundamental limitation of browser-delivered end-to-end encryption,
not something veejr currently eliminates.
