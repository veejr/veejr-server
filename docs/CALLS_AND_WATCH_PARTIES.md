# Calls and YouTube watch parties

This guide describes the current browser conferencing features in Veejr. It
covers member, scheduled, and no-account guest calls; recovery and privacy
boundaries; watch parties; and the operator settings that affect connectivity.
For the lower-level trust model, see
[ARCHITECTURE.md](ARCHITECTURE.md); for TURN deployment, see
[OPERATIONS.md](OPERATIONS.md#calls-stun-and-turn).

## Requirements and scope

- Use the public HTTPS instance URL. Camera, microphone, screen capture,
  Picture-in-Picture, pop-ups, and autoplay are controlled by the browser and
  may require site permission or a user gesture.
- Both participants need configured identity keys. A call page can unlock the
  wrapped key locally with the encryption passphrase; the passphrase never
  becomes a LiveView event or server request.
- 1:1 calls work between accepted friends on the same instance or federated
  Veejr instances. General watch parties are instance-local.
- Media compatibility, screen sharing, speaker selection, Picture-in-Picture,
  and full-screen support vary by browser and operating system. Unsupported
  controls are hidden where the browser exposes no matching API.

## 1:1 calls

### Start and answer

Start a call from an accepted contact or conversation. The callee sees a
centered incoming-call consent dialog with **Accept**, **Busy now, laters**,
and **Reject** actions. The busy action declines the ring while relaying that
distinct outcome to the caller; it does not expose call media or message
content. Unanswered rings have a 60-second stale threshold; the periodic
janitor marks them missed, so the row may remain visibly ringing until its
next sweep. If the callee was temporarily offline, the newest invitation still
marked ringing is replayed when an authenticated Veejr page reconnects.
The pending dialog is not replayed over its own call page. Repeated start
events reuse the active call instead of creating another invitation.

Opening the call page first presents a private device check. Choose the
microphone, camera, and (where supported) speaker, review the local preview,
then join. A missing camera does not prevent an audio-only call. Both caller
and callee may enter their encryption passphrase on this page if the tab has
not already unlocked the identity key.

While an outgoing invitation is still ringing, the caller sees **Cancel
invitation**. Cancelling records a distinct cancelled state, dismisses the
callee's in-app ring banner, and mirrors the cancellation to a federated
callee. After the callee accepts, the same control becomes **End call**.

### Schedule a call and reminders

Open **Calls** from the global navigation, or choose **Schedule** beside the
Call button in a one-to-one conversation. Select an accepted friend, local date
and time, reminder lead time, and optional shared call notes. Every scheduled
call card keeps a call-notes field visible; the organizer can update it and the
invitee sees the synchronized value. The Calls page lists upcoming plans for
both participants. Each entry is initially a compact one-line person-and-time
row; open it to see status, reminders, notes, start, and cancellation controls.
The organizer can start early, and either participant can cancel with an
optional reason. Cancellation records who canceled, mirrors the state and
reason to the other home instance when federated, and emails the other
participant from their own home instance. Starting creates a normal realtime
call invitation, so the callee still explicitly accepts before media connects.

Schedules are persistent. A reminder worker checks them every 30 seconds and
dispatches each reminder once. Connected tabs show an in-app banner and browser
notification; registered browser and Android devices also receive a
content-free push. If the instance was down at the reminder instant, a
schedule up to one hour overdue is delivered on the next sweep. Notification
permission and operating-system background restrictions still apply.

The invitee also receives an email when the schedule is first created. A
cancellation email goes to the other participant and includes the optional
reason. Two minutes before the scheduled start, both organizer and invitee
receive an email from their respective home instances. Email timestamps are
explicitly UTC because Veejr does not persist a named browser time zone; the
linked Calls page renders the same instant in the device's current local time.
Email delivery failures appear in the operations failure log and do not undo
the cancellation or cancel an active schedule.

Federated schedules are mirrored through the durable federation outbox, unlike
realtime rings and signaling. Each participant's home instance reminds its own
local user. The scheduled time, reminder lead time, participants, lifecycle
state, shared call notes, cancellation actor and reason, and reminder
checkpoints are server-readable metadata on both home instances;
call media and signaling retain the privacy boundaries described below.

### Invite a person without a Veejr account

Open **Invite someone** and choose **Guest call**. Enter one email address;
Veejr sends a distinct private link that expires after two hours. The guest
does not receive an account and cannot see contacts, messages, history, or any
other authenticated page.

The guest opens the link, enters a display name, checks camera/microphone
devices, and enters a waiting room. The host sees that name and must choose
**Admit** before the call starts. Before admission, the host can **Decline** a
waiting guest or **Cancel invitation** while the invitation is merely sent or
waiting. A cancelled, declined, or expired capability cannot open the lobby.

The guest's browser creates a temporary X25519 identity for sealed signaling.
It stays in that tab and is discarded after the conference; the server stores
the temporary public key only while the conference is active and clears it
when the call ends. Media, direct chat, and files use WebRTC and remain
ephemeral as in a member call. Re-invite is not available for a guest call.
After an ended call, the guest may optionally choose **Join Veejr**; normal
instance invitation policy still applies and no account is created silently.

### In-call controls

- Mute/unmute the microphone (`M`) and turn the camera on/off (`V`).
- Switch cameras or reopen device selection without leaving the call.
- Share a screen, application window, or browser tab. Screen sharing and
  YouTube sharing are mutually exclusive.
- Fit or fill the remote video; use full screen (`F` or double-click),
  Picture-in-Picture, or pop the shared screen into a separate window.
- Open call chat (`C`) to send text, paste/drop files, or select multiple
  files. HTTP/HTTPS links are rendered as clickable links. Each file is
  limited to 25 MB.
- Share a YouTube link or 11-character video ID. The person who starts that
  share controls play, pause, seeking, and ending the shared video. The other
  participant may need to tap once before audio can autoplay.

The call shows duration, connection quality, relay use, peer mute/camera
state, and recovery status. Video starts at up to 720p/30fps and can move
between HD, Balanced, and Data saver profiles while preserving audio priority.
Screen sharing uses a separate screen-oriented profile.

### Interruption, reconnect, and re-invite

Veejr attempts up to two WebRTC ICE restarts after an interrupted peer
connection. A participant's LiveView disappearance also has a 25-second grace
period, so a short mobile backgrounding, network switch, or socket reconnect
does not immediately end the call. When an accepted callee reloads their call
page, their instance re-announces the join so the original caller restarts
negotiation rather than leaving the reloaded callee waiting on a lost offer.

If the callee remains disconnected after recovery:

1. The accepted call is ended.
2. The original caller remains on a **Connection lost** screen.
3. **Re-invite** creates a new call ID and a fresh ring; it does not reuse the
   failed WebRTC session.
4. If the callee reconnects to any authenticated Veejr page while that new
   ring is active, the pending invitation is shown.

An explicit hangup or decline is final and does not offer automatic re-invite.
The callee does not silently resurrect an ended call; they reconnect by
accepting the caller's fresh invitation. This keeps consent explicit and
avoids two sides independently creating competing calls.

In-app navigation, form actions, and call hangup actions ask for confirmation
when they would close an active call. Refreshing, closing the tab/window, or
leaving the site uses the browser's native before-unload warning; browsers do
not allow Veejr to customize that text. Once a connection is definitively
lost, returning to Messages no longer produces the active-call warning.

### What is and is not stored

- Audio, video, shared-screen tracks, call chat, and call files use the WebRTC
  peer connection and are not persisted by either Veejr instance.
- SDP offers, answers, and ICE candidates are sealed in the browser with
  `nacl.box` using the participants' pinned identity keys. Instances relay
  only ciphertext and do not store signaling history.
- Call rows store participant IDs, a random public ID, lifecycle state, and
  timestamps. Instances can observe who called whom and when.
- Scheduled-call rows additionally store the organizer, invitee, UTC time,
  reminder lead time, lifecycle state, device and per-participant email
  reminder checkpoints, shared call notes, cancellation actor, and optional
  cancellation reason. These are metadata, not encrypted message content.
- Guest-conference rows store the host, normalized invited email, SHA-256 hash
  of the capability, expiry and lifecycle times, guest display name, and the
  temporary public key while active. Guest-call rows store host/conference
  linkage and lifecycle state. The raw email capability, signaling plaintext,
  media, chat, and files are not stored.
- Call chat and file transfer use the authenticated WebRTC data channel. They
  disappear when the call ends and are not included in History or account
  exports. A recipient can still save a transferred file, copy text, record
  media, or capture the screen.
- Direct WebRTC normally reveals each peer's network address to the other.
  TURN can relay traffic and reduce direct address exposure, but the TURN
  operator observes connection metadata and bandwidth. TURN cannot decrypt
  DTLS-SRTP media or the data channel.
- YouTube is a third-party service. Each browser connects to YouTube directly,
  so YouTube receives the viewer's network and browser request metadata under
  its own terms. Veejr exchanges only the video ID and playback directions.

## Instance-wide YouTube watch parties

Open **Watch**, paste a supported YouTube, `youtu.be`, Shorts, Live, or embed
URL (or a video ID), and start the party. Only one party may be active per
instance. Every signed-in user receives a join banner and can also open the
active party from the Watch page.

The host may use **Invite outsiders** to send up to 25 comma-separated email
addresses private guest links. Every recipient gets a distinct random
capability and can open synchronized playback without creating an account.
Only a hash of each capability is retained. Guest links stop working when the
party ends or the application restarts, expose no account data, and do not
include encrypted party voice because outsiders have no pinned Veejr identity
key.

The initiator is the host and is the only participant allowed to control or
end playback. Host play/pause/position updates synchronize viewers, with a
10-second heartbeat to correct drift. Browser autoplay rules may require a
viewer to tap **Tap to watch together**. If the host stops sending controls,
the in-memory party expires after 90 seconds.

Voice is optional for every participant. Joining the page allows listening;
selecting **Turn microphone on** requests microphone permission and sends
audio to the other current participants. Turning it off stops the local audio
track. Voice uses a small peer-to-peer mesh: signaling is sealed between each
pair's identity keys and media uses WebRTC DTLS-SRTP. This design is intended
for small instance communities, not large broadcasts; each speaking browser
uploads one audio stream per connected peer.

Watch-party state exists only in the running application process. It is not
federated, persisted, added to history, or restored after an application
restart. Ephemeral outsider email addresses and capability hashes live in that
same process only. The server can observe participant identity, invited email
addresses, the YouTube video ID, playback state, and timing, but not voice
content.

## Troubleshooting

### No camera or microphone

1. Confirm the page uses HTTPS and the browser supports WebRTC.
2. Open browser site settings and allow the requested device.
3. Check operating-system privacy settings and close another application that
   may hold exclusive access to the device.
4. Reopen **Devices** or reload before the call is accepted. If the call must
   be left, use Re-invite afterward.

### Ring never appears

- Confirm the users are still accepted friends.
- Treat a ring as stale after 60 seconds and start a new call; periodic cleanup
  may take longer to mark the old row missed.
- Keep an authenticated Veejr page connected; an offline callee receives only
  the newest still-pending ring after reconnecting.
- For federated calls, inspect both instances' logs and peer block/key state.
  Call invites are synchronous and are not queued in the durable federation
  outbox.

### Scheduled call or reminder does not appear

- Confirm both people are still accepted friends and the scheduled time is in
  the future.
- For federated schedules, inspect the durable federation outbox and peer
  block/key state. Scheduling is retried; the eventual realtime ring is not.
- Confirm browser notification permission and a registered push subscription
  under Account settings. The Calls page remains the authoritative list even
  when an operating system suppresses a notification.
- Check that `Veejr.Calls.Reminders` is running and the database is writable.
  A reminder already stamped `reminded_at` is not dispatched twice.
- For a missing cancellation email, confirm the other participant is local to
  the instance attempting delivery and inspect the `email` operational failure
  for `scheduled_call_cancellation`. Federated peers email only their own
  local participant.

### Guest invitation or waiting room fails

- Confirm SMTP delivery succeeded for operation
  `guest_conference_invitation`; if email fails, Veejr revokes the newly
  created invitation instead of leaving an unreachable live capability.
- Guest links expire after two hours and become unavailable immediately after
  host cancellation or decline.
- The guest must provide a display name and allow a temporary browser identity
  to be generated before the host sees **Admit**.
- Only the member who created the invitation can view its host waiting room,
  admit, decline, cancel, signal, or end that guest call.
- Guest pages still require HTTPS for camera/microphone and can be affected by
  the same browser autoplay, device, STUN, and TURN restrictions as member
  calls.

### Call connects on some networks but not others

- Confirm both browsers can reach every advertised STUN/TURN URL.
- Provide TURN over UDP and TCP; add trusted `turns:` on TCP 5349 for highly
  restrictive networks.
- Check coturn credentials, certificate hostname, public port forwarding, UDP
  relay range, and firewall rules.
- A **Relayed** quality label confirms TURN is carrying media. See
  [OPERATIONS.md](OPERATIONS.md#calls-stun-and-turn).

### YouTube does not start or has no sound

- Allow the YouTube embed and disable content blocking for the instance if it
  blocks `youtube-nocookie.com`.
- Tap the viewer overlay once; browsers commonly block audible autoplay.
- Verify the video allows embedding and is available in the viewer's region.
- Screen sharing must stop before YouTube sharing begins, and vice versa.

### Shared-screen pop-out does not open

Allow pop-ups for the Veejr instance. The pop-out contains the current remote
screen stream only; closing it does not end screen sharing or the call.

## Operator checklist

- Serve Veejr over its canonical HTTPS hostname with websocket support.
- Configure at least STUN; configure TURN/turns for reliable production calls.
- Preserve one application replica when using SQLite.
- Verify SMTP for schedule invitations/reminders/cancellations and immediate
  guest-call invitations; review sanitized `email` operational failures.
- Test calls between different networks, including a cellular connection and
  a restrictive VPN, after changing proxy, firewall, DNS, or TURN settings.
- Treat call metadata, watch participation, TURN logs, and YouTube access as
  privacy-sensitive operational data even though media content is encrypted.
- Monitor application and coturn errors without enabling SDP, ICE candidate,
  passphrase, ciphertext, or token logging.
