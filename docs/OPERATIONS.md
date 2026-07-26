# Production operations

This guide applies to the source-mounted Docker Swarm deployment described in
[INSTALLATION.md](INSTALLATION.md). Commands use PowerShell and assume the
service is named `veej_fable`.

## Health checks

Check the Swarm replica, current task, logs, and public endpoint:

```powershell
docker service ls --filter name=veej_fable
docker service ps veej_fable --filter desired-state=running --no-trunc
docker service logs veej_fable --since 10m --tail 100
curl.exe -I https://veejr.example.com/
curl.exe https://veejr.example.com/api/v1/capabilities
```

Healthy output has one running replica (`1/1`), a recent task without an error,
Phoenix listening on port 4000, and HTTP status 200 from the public URL.

Guest-call invitations and scheduled-call invitation, cancellation, and
two-minute reminder emails use the configured `Veejr.Mailer`. Failed
deliveries are recorded under the `email` channel in **Recent delivery
failures**. Separate persisted organizer and invitee email checkpoints prevent
duplicate two-minute reminders while allowing one failed address to retry
independently; they are separate from the configurable device-notification
`reminded_at` checkpoint. Cancellation delivery is attempted when the state
changes and does not roll back a successful cancellation if SMTP fails.
Failed guest-invitation email revokes that newly created guest capability.

Check the supporting containers separately:

```powershell
docker ps --filter name=veej_caddy
docker logs --tail 100 veej_caddy
docker ps --filter name=veej_postfix
docker logs --tail 100 veej_postfix
```

Postfix checks are necessary only when `SMTP_HOST` points to that container or
relay. The current project host uses an external SMTP provider directly.

## In-app upgrades (pull-based)

Every instance can upgrade itself from `/admin` → **Software update**. The
check queries the configured upstream's GitHub releases (`:update_repo`,
overridable with `VEEJR_UPDATE_REPO`) and only when the administrator asks —
nothing phones home unattended. When a newer release exists, **Upgrade &
restart**:

1. records the current commit as last-known-good and takes an online SQLite
   backup next to the database (`<name>-preupgrade-<stamp>.db`),
2. checks out the release tag and builds it (deps, assets, compile) while
   the old version keeps serving,
3. stops the VM only after a successful build; the container restart policy
   boots the new version, which runs its own migrations at startup
   (`:auto_migrate` is enabled for prod).

The upgrader exits non-zero so `on-failure` restart policies also restart the
task, but services should use restart condition `any`. Installations created
before this default can switch with:

```powershell
docker service update --restart-condition any veej_fable
```

A failed build rolls the checkout back, recompiles the running version, and
records the error under **Recent delivery failures** — the running instance
is never replaced by an unproven build. In-place upgrade refuses to run on a
working tree with local modifications (a development checkout).

Recovery, if a new version fails **after** restart: stop the service, restore
the `-preupgrade-` database copy over `DATABASE_PATH`, `git checkout` the
previous commit in the instance repository, and start the service again.

### Release completion checklist (upstream maintainers)

A release is **not complete** after commit, push, or deployment alone.
Instances compare their compiled version with GitHub's newest published
release tag, so omitting the GitHub release makes an older instance
incorrectly report that it is up to date.

Complete these steps in order for every change that instances should receive:

1. Bump `version:` in `mix.exs` in the same change and confirm the intended
   version appears in the release commit.
2. Merge and push the release commit.
3. Create a non-draft, non-prerelease GitHub release named and tagged
   `v<version>`. Point the tag at the exact release commit, not merely at a
   branch name.
4. Verify the public latest-release response reports the new tag:

   ```powershell
   $ExpectedVersion = (
     Select-String -Path mix.exs -Pattern 'version:\s*"([^"]+)"'
   ).Matches[0].Groups[1].Value
   $LatestRelease = Invoke-RestMethod `
     https://api.github.com/repos/veejr/veejr-server/releases/latest

   if ($LatestRelease.tag_name -ne "v$ExpectedVersion") {
     throw "Latest GitHub release is $($LatestRelease.tag_name), expected v$ExpectedVersion"
   }
   ```

5. Deploy the main instance, then verify its public instance metadata reports
   the expected version:

   ```powershell
   $Instance = Invoke-RestMethod https://veejr.example.com/api/instance

   if ($Instance.version -ne $ExpectedVersion) {
     throw "Main instance is $($Instance.version), expected $ExpectedVersion"
   }
   ```

6. On at least one older federated instance, open `/admin` → **Software
   update**, select **Check for updates**, and confirm it offers the new
   version. This final check validates the same discovery path used by
   operators rather than only proving that the main instance was deployed.

Record the release URL and the verified release commit in the deployment
notes. If any step fails, the release remains incomplete even if the main
instance is already serving the new code.

## Deploy an update (manual)

Complete the release checklist above before treating a manual deployment as a
published update. Do not deploy with an uncommitted working tree. Review
upstream changes and take a backup before an update that includes migrations.

```powershell
Set-Location C:\Services\veejr-server
git status --short
git pull --ff-only
git log -1 --oneline
```

Find the running container, run migrations, build digested assets, and force a
compile after the digest so Phoenix references the new manifest:

```powershell
$AppContainer = docker ps `
  --filter label=com.docker.swarm.service.name=veej_fable `
  --format "{{.ID}}"

docker exec $AppContainer mix ecto.migrate
docker exec $AppContainer mix assets.deploy
docker exec $AppContainer mix compile --force
docker service update --force veej_fable
```

Production startup runs `Ecto.Migrator` before the endpoint, for both a built
release and this source-mounted `mix phx.server` service. Running
`mix ecto.migrate` explicitly above remains useful: migration failures surface
before the healthy old task is replaced.

With host-mode port publishing on a single node, Swarm may briefly report
`no suitable node (host-mode port already in use)` while replacing the old
task. It should then converge to `1/1`. Treat failure to converge as an error.

Run the health checks after every rollout and confirm the public HTML points to
new digested CSS/JavaScript files:

```powershell
$Response = Invoke-WebRequest https://veejr.example.com/ -UseBasicParsing
$Response.StatusCode
[regex]::Matches(
  $Response.Content,
  'assets/(?:js|css)/app-[a-f0-9]+\.(?:js|css)'
).Value | Sort-Object -Unique
```

## Calls: STUN and TURN

Calls default to a public STUN server, which suffices for most NAT
combinations. When both parties sit behind symmetric NAT the direct
connection fails (the call page reports it); a TURN relay fixes this. TURN
only relays already-encrypted SRTP — it never sees call content.

Production deployments should advertise TURN over UDP, TCP, and TLS so calls
can cross restrictive VPNs and firewalls. Run a coturn sidecar and point the
instance at it:

```powershell
docker run -d --name veej_coturn --restart unless-stopped `
  -p 3478:3478 -p 3478:3478/udp -p 41000-41040:41000-41040/udp `
  coturn/coturn -n --realm=veejr `
  --user=veejr:CHOOSE_A_LONG_SECRET `
  --external-ip=PUBLIC_IP/LAN_IP `
  --min-port=41000 --max-port=41040 --no-cli --no-tls
```

Keep the relay range below 49152 on Windows hosts — Windows reserves blocks
of the ephemeral range (49152+) and Docker cannot publish ports inside them.

Omit `--external-ip` on routers without NAT loopback (hairpin): with it, LAN
devices are handed relay addresses at the public IP they cannot reach. Left
out, the relay advertises its LAN address; external parties (including
VPN'd devices, whose traffic arrives from the internet) still relay fine
through their own allocation, provided the router forwards 3478 (TCP and
UDP) and the relay UDP range to the host. The instance automatically
advertises a `?transport=tcp` TURN variant for clients whose VPN or
firewall drops UDP. Each `turn:` URL without an explicit transport gets that
TCP variant automatically.

Then set on the application service (and open the UDP ports on the
firewall/router):

```text
VEEJR_TURN_URLS=turn:your-host:3478,turns:your-host:5349
VEEJR_TURN_USERNAME=veejr
VEEJR_TURN_PASSWORD=CHOOSE_A_LONG_SECRET
VEEJR_STUN_URLS=stun:stun.l.google.com:19302   # optional override
```

The command above is a UDP/TCP baseline. To serve `turns:` as well, expose
TCP 5349 and configure coturn with a publicly trusted certificate and key,
for example `--tls-listening-port=5349 --cert=/certs/fullchain.pem
--pkey=/certs/privkey.pem`. Mount those files read-only into the coturn
container and remove `--no-tls`. Browsers reject a `turns:` endpoint whose
certificate does not match `your-host`. Keep UDP 3478 available because it
normally gives the best media performance; TLS is the restrictive-network
fallback.

For parties outside the LAN the router must forward 3478 (TCP+UDP) and the
relay UDP range to the host.

Static credentials are the simple v1; time-limited HMAC credentials are a
future hardening step.

## Restart services

Restart Phoenix through Swarm rather than `docker restart`:

```powershell
docker service update --force veej_fable
```

Restart standalone supporting containers with:

```powershell
docker restart veej_caddy
docker restart veej_postfix
```

Only restart Postfix when it is actually part of the configured mail path.

## Operate account moves

Account moves are intentionally resumable and are visible on `/admin`:

1. **Awaiting test / Testing**: the source account remains active while the
   provisioner imports into a disposable database.
2. **Test verified**: review the target hostname and counts, then approve
   cutover. This suspends the member, revokes web and Android sessions, and
   creates a fresh final export.
3. **Provisioning / Target verified**: confirm the new HTTPS site works and the
   moved user can request a login link before selecting **Finalize**.
4. **Finalized**: the target directory has been verified against the moved
   user's pinned public key, source-side friendships and address-book references
   point to the new server, and the source account and private package have
   been removed. Signed move notices update established friends on other
   federated servers.

Test or provision failures preserve the source account and package. Use
**Retry** after correcting DNS, Docker, storage, SMTP-template, or Caddy errors.
If a job remains in Testing or Provisioning because the host process stopped,
first confirm no provisioner is still processing it, then use **Retry**. Cancel
reactivates a member suspended by cutover. Never finalize solely because a
Docker service exists; verify its public HTTPS endpoint and imported owner.

If final import and service creation succeeded but Caddy or certificate
readiness failed, Retry resumes from the saved import receipt. Earlier partial
failures deliberately keep their instance directory for diagnosis. After
confirming no useful target service exists, rename that directory as a backup
before retrying; do not recursively delete it as a first response.

The import currently includes the user's profile image, encrypted envelope
history, and blobs they own. Received attachment blobs cannot be discovered from server-side
ciphertext and therefore cannot be copied automatically. This limitation is
shown in the export documentation and should be explained before cutover.

Attachment reference tracking applies to uploads created after its migration.
Sender batch deletion frees tracked blobs after their final reference; hidden
recipient copies do not. Unattached tracked uploads older than 24 hours are
reclaimed opportunistically on the next upload. Legacy blobs are deliberately
excluded because their message references are inside unreadable ciphertext.

## Backups

A complete backup contains:

- The SQLite database at `DATABASE_PATH`.
- The encrypted blob directory at `VEEJR_BLOB_DIR`.
- The protected production environment file.
- The original Firebase service-account JSON, when enabled.
- Caddy's `/data` volume, which contains certificates and account state.

The database also contains federation signing material and browser-push VAPID
credentials. Losing it changes the instance identity and can break established
federation relationships.

For a simple consistent backup, briefly stop the one application replica,
copy the state directory, and start it again:

```powershell
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$Backup = "D:\Backups\Veejr\$Stamp"

docker service scale veej_fable=0
New-Item -ItemType Directory -Force $Backup
Copy-Item -Recurse -Force C:\ProgramData\Veejr\data "$Backup\data"
Copy-Item -Force C:\ProgramData\Veejr\secrets\veejr.env "$Backup\veejr.env"
docker service scale veej_fable=1
```

Confirm the service returns to `1/1`, then encrypt the backup and copy it off
the host. Keep multiple generations and test restoration periodically. Do not
commit backups, databases, environment files, service-account files, or
attachment directories to Git.

## Restore

1. Stop the application replica with `docker service scale veej_fable=0`.
2. Preserve the current state directory separately; do not overwrite the only
   copy.
3. Restore the database and uploads to the exact paths configured in the
   environment file.
4. Restore the same `SECRET_KEY_BASE` and public hostname.
5. Ensure host/container permissions allow SQLite and uploads to be written.
6. Run `mix ecto.migrate` with the checked-out application version.
7. Scale the service back to one replica and run all health checks.

Restoring only SQLite or only the blob directory produces incomplete
attachments. Restoring under a different public hostname changes federated
addresses and requires a deliberate migration plan.

## Roll back application code

Database migrations are not automatically reversible. Before rolling back,
read the migrations introduced by the failed release and restore a compatible
backup when necessary.

For a code-only rollback:

```powershell
git log --oneline -10
git switch --detach <known-good-commit>

$AppContainer = docker ps `
  --filter label=com.docker.swarm.service.name=veej_fable `
  --format "{{.ID}}"

docker exec $AppContainer mix assets.deploy
docker exec $AppContainer mix compile --force
docker service update --force veej_fable
```

After recovery, return the checkout to the managed branch deliberately. Never
use `git reset --hard` on a host with unreviewed local work.

## Rotate secrets

### Session secret

Changing `SECRET_KEY_BASE` signs users out and invalidates existing browser
session cookies. Update the protected environment file, recreate/update the
service environment, and roll the service during a maintenance window.

### SMTP credential

Replace the provider credential, update `SMTP_PASSWORD`, roll Phoenix, and
perform a real login-email test. Revoke the old credential only after delivery
is confirmed.

### Firebase key

Docker secrets are immutable. Create a versioned replacement, update the
service to mount it at `/run/secrets/fcm_service_account_json`, verify
`"android_push": true` in the capabilities response, then revoke the old key
in Firebase and remove the old Docker secret.

## Common failures

### Public 403 response

- Confirm `PHX_HOST` exactly matches the public hostname, without a scheme or
  path.
- Confirm Caddy preserves the incoming `Host` header.
- Check that DNS is not still forwarding to an old tunnel or endpoint.
- Rebuild assets and force compile before restarting after a hostname/config
  change.

### TLS certificate is missing

- Confirm public DNS resolves to this host.
- Forward TCP 80 and 443 to Caddy and allow them through the host firewall.
- Check `docker logs veej_caddy` for ACME errors.
- Preserve the Caddy data volume between container replacements.

### Caddy returns 502

- Confirm the Swarm service is `1/1`.
- Request `http://localhost:4000` from the host.
- On Linux, ensure the Caddy container can resolve/reach
  `host.docker.internal`, or configure the host-gateway mapping.

### Email is not delivered

- Verify `SMTP_HOST`, port, TLS mode, username, and allowed sender address.
- For Gmail, use an App Password and two-step verification.
- Review `/admin` operational failures and Phoenix logs without printing the
  SMTP password.
- Check spam handling and the sender domain's SPF, DKIM, and DMARC records.
- If Postfix is used, inspect its queue/logs and verify it is not an open relay.

### Live call or watch-party voice fails

- Use the public HTTPS hostname; camera, microphone, screen capture, and
  WebRTC require a secure browser context.
- Recheck browser and operating-system permissions for the selected camera and
  microphone. Reopen the call's **Devices** panel after changing them.
- Confirm both clients can reach the advertised STUN/TURN URLs. If a call works
  on one network but not another, verify coturn credentials, TCP/UDP 3478,
  trusted TLS on 5349 when configured, and the UDP relay range.
- Inspect both home instances for a federated call. Invites, lifecycle updates,
  and signaling are synchronous and do not wait in the federation outbox.
- A brief disconnect gets two ICE restart attempts and a 25-second page-
  presence grace. After that, the original caller must use **Re-invite**.
- Watch-party voice uses one peer connection per other participant and is
  intended for small groups. Check CPU/uplink pressure as participant count
  grows.
- See [CALLS_AND_WATCH_PARTIES.md](CALLS_AND_WATCH_PARTIES.md) for the complete
  recovery and browser-permission checklist.

### Scheduled call reminders do not arrive

- Confirm the schedule remains `scheduled`, its `scheduled_for` time is
  correct in UTC, and `reminded_at` is still empty before the lead-time
  threshold.
- Confirm the `Veejr.Calls.Reminders` process is running. It checks every 30
  seconds and catches reminders up to one hour after their scheduled time.
- A connected tab receives the user-scoped reminder even without push. For
  background delivery, confirm browser notification permission or an Android
  push token and review push-service failures.
- Federated schedule changes use the durable federation outbox. Check peer
  block/key state and retry the outbox if the other participant does not see
  the plan. The later realtime ring remains synchronous.
- Cancellation email operation is `scheduled_call_cancellation`. Each home
  instance emails only its own local recipient after the signed cancellation
  is applied; it never sends to a federated placeholder email address.

### Guest-call invitation does not arrive

- Review `email` failures for operation `guest_conference_invitation` and test
  the configured SMTP transport/sender.
- A failed send revokes the generated capability. Send a new guest invitation
  after fixing SMTP rather than trying to recover the old link.
- A delivered link expires after two hours and becomes unavailable when the
  host cancels or declines it.

### Recorded voice or video message fails

- Recheck browser site permissions for camera and microphone.
- Confirm the instance upload limit and total storage quota have room.
- Test a browser-supported MP4 or WebM format.

### YouTube sharing fails

- Confirm `youtube-nocookie.com` is not blocked by browser content controls.
- Some viewers must tap once before audible autoplay is permitted.
- Verify that the video permits embedding and is available in the viewer's
  region. Stop screen sharing before starting a 1:1 YouTube share.

### Federated profile pictures are missing in Orbit or Soiree

- First switch to a standard Contacts theme. If the image is also missing
  there, verify the remote directory record reports `has_avatar: true` and a
  positive `avatar_version`, and confirm the remote public
  `/avatars/<username>?v=<version>` URL returns a JPEG.
- While signed in, inspect the failed request to
  `/avatar-textures/<remote-user-id>?v=<version>`. A `404` means the user is not
  currently an accepted federated friend, its avatar metadata is absent, the
  recorded home authority is unreachable, or the response failed the JPEG size
  and format checks.
- An upstream `406` in local logs indicates that a texture fetch used an
  image-only `Accept` header against a peer whose public avatar route still
  passes through Phoenix's HTML browser pipeline. Current clients send a
  browser-compatible header for older-peer interoperability.
- Check the local Phoenix logs and test server-to-server HTTPS connectivity to
  the remote user's recorded authority. The browser does not fetch the remote
  texture directly, so changing browser CORS settings is not a fix.
- Confirm both instances advertise the expected authority and that DNS and TLS
  for the remote authority are valid. The texture fetch does not follow
  redirects.
- After an avatar replacement, confirm federation directory data carries the
  new version. The texture URL is intentionally cached immutably by version;
  do not purge it when the version changed correctly.

### SQLite is locked or read-only

- Keep exactly one application replica.
- Confirm the host directory is writable by the container.
- Do not place the live database on a network filesystem with unreliable file
  locking.
- Stop the application before filesystem-level backup or restore.

### Service does not return after host restart

- Confirm Docker Desktop/Engine starts automatically.
- Check that the node is still an active Swarm manager.
- Use `docker service ps veej_fable --no-trunc` to inspect scheduling errors.
- Configure standalone Caddy/Postfix containers with `--restart unless-stopped`.

## Security checklist

- Expose only Caddy's public HTTP/HTTPS ports.
- Keep the manager node, environment file, SMTP credential, and Firebase key
  restricted to administrators.
- Apply OS, Docker, Elixir-image, and Caddy updates on a tested schedule.
- Pin container versions or digests instead of relying on `latest`.
- Maintain encrypted off-host backups and perform restoration drills.
- Review administrator audit events and operational failures.
- Remember that encrypted content does not hide account, friendship,
  sender/recipient, timestamp, item-kind, or blob-size metadata from the server.
