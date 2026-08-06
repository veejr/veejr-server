# Host runbook: current Windows deployment

Everything needed to understand, recover, or replicate the veejr deployment
on the current Windows host at `192.168.0.251`. INSTALLATION.md and
OPERATIONS.md are the general guides; this file records what is actually
running here and why. No secret values appear in this file — only their
locations.

## Topology

| Component | Kind | Ports (host) | Restart policy | Role |
| --- | --- | --- | --- | --- |
| `veej_fable` | Swarm service (1 replica) | 4000/tcp (host mode) | condition `any` | Main community instance, `veejr.dyndns-server.com` |
| `veejr_veejr0_dyndns_server_com` | Swarm service (1 replica) | 4001/tcp (host mode) | condition `any` | Provisioned personal instance, `veejr0.dyndns-server.com` |
| `veej_caddy` | Container | 443 tcp+udp | `unless-stopped` | TLS termination and per-hostname reverse proxy to `host.docker.internal:4000/4001` |
| `veej_coturn` | Container | 3478 tcp+udp, 41000–41040/udp | `unless-stopped` | STUN/TURN relay for calls |
| `veej_postfix` | Container | 587/tcp (internal) | `unless-stopped` | Available SMTP relay; unused (Phoenix mails via external SMTP directly) |

All application containers run the stock `elixir:1.20-otp-28` image and
start their instance with `mix phx.server` (`MIX_ENV=prod`) — a
source-mounted deployment, not a release image.

- `veej_fable` bind-mounts the working repository
  `C:\Users\eded1\Documents\Codex\2026-07-07\i\work\veej_fable` at `/app`.
  **This directory is simultaneously the development workbench** — see
  Hazards below. Its state lives inside the repo mount:
  `DATABASE_PATH=/app/veejr_prod.db`,
  `VEEJR_BLOB_DIR=/app/priv/static/uploads` (both gitignored).
- The provisioned instance keeps a dedicated clone at
  `C:\ProgramData\Veejr\instances\veejr_veejr0_dyndns_server_com\repo`
  (mounted at `/app`) with state under `...\data` (mounted at
  `/var/lib/veejr`).

Boot-time migrations are enabled for prod (`:auto_migrate`), so starting a
newer checkout migrates its own database — there is no manual
`mix ecto.migrate` step in any current procedure.

## DNS and network

- Public hostnames `veejr.dyndns-server.com` and
  `veejr0.dyndns-server.com` resolve to the (dynamic) public IPv4 via
  dyndns.
- **The router has no NAT loopback**, which shapes two decisions:
  - Split DNS on the router maps both hostnames to `192.168.0.251` for LAN
    clients — same URLs work inside and outside.
  - coturn runs **without `--external-ip`**: relayed addresses advertise
    `192.168.0.251`, reachable by LAN peers; internet parties (including
    VPN'd devices on the LAN Wi-Fi, whose traffic arrives from outside)
    relay through their own allocation via the public 3478 forwards.
- Router port forwards, all to `192.168.0.251`:
  - 443 tcp+udp (Caddy)
  - 3478 tcp+udp (TURN control; TCP variant serves VPN/firewalled clients)
  - 41000–41040 udp (TURN relay range)
- Windows Firewall: explicit allowances for Caddy (443) and Phoenix
  (4000); Docker Desktop's program-scoped backend rules have covered other
  published ports (TURN worked without dedicated rules). The relay range
  sits **below 49152** because Windows reserves blocks of the ephemeral
  range that Docker cannot publish.

## Secrets and credentials (locations only)

| Item | Location |
| --- | --- |
| Firebase service-account JSON | `C:\ProgramData\Veejr\secrets\fcm-service-account.json`, mounted into `veej_fable` as Swarm secret `fcm_service_account_json` |
| TURN static credential | `C:\ProgramData\Veejr\secrets\turn-credential.txt` (username `veejr`); also present in both app services' env (`VEEJR_TURN_PASSWORD`) and coturn's args |
| App env (SECRET_KEY_BASE, SMTP credentials, provisioner token, …) | Swarm service specs (`docker service inspect`); provisioned instances additionally keep an env file under their instance directory |
| GitHub access for tooling | Git pushes use Git Credential Manager (`git credential fill`). `gh` is installed but requires its own valid authenticated session for release/PR API operations. |

## Recreating the pieces

The app services and Caddy are documented in INSTALLATION.md; the
provisioner (`scripts/veejr_provisioner.ps1`) creates member instances.
The host-specific extras:

```powershell
# TURN relay (no --external-ip: router lacks NAT loopback; range < 49152)
$secret = (Get-Content C:\ProgramData\Veejr\secrets\turn-credential.txt -Raw).Trim()
docker run -d --name veej_coturn --restart unless-stopped `
  -p 3478:3478 -p 3478:3478/udp -p 41000-41040:41000-41040/udp `
  coturn/coturn -n --realm=veejr --user="veejr:$secret" `
  --min-port=41000 --max-port=41040 --no-cli --no-tls

# Point both app services at it (TCP fallback is derived automatically)
docker service update `
  --env-add "VEEJR_TURN_URL=turn:veejr.dyndns-server.com:3478" `
  --env-add "VEEJR_TURN_USERNAME=veejr" `
  --env-add "VEEJR_TURN_PASSWORD=$secret" veej_fable
```

## Boot and recovery

Recovery is self-healing **once the Docker engine is running**:

1. Host boots → operator signs in → Docker Desktop auto-starts (Settings →
   General → "Start Docker Desktop when you sign in" must stay enabled;
   an unattended reboot leaves everything down until someone signs in).
2. Swarm services restart themselves (condition `any`); coturn, Caddy, and
   Postfix restart via `unless-stopped`.
3. Nothing needs manual migration: app boots migrate their own databases.

Health check: `docker service ls`, then
`https://<host>/api/instance` on both hostnames should report the expected
`version`.

## Deploys and upgrades

- **A release is not complete when the code is merely committed, pushed, or
  deployed.** For any code change that instances should receive, follow the
  executable **Release completion checklist** in `docs/OPERATIONS.md` — the
  authoritative sequence, with its verification commands.
- **All instances** self-upgrade from `/admin` → Software update
  (pull-based; backup, build-while-serving, restart, boot migration).
- **The main instance** shares its checkout with the development
  workbench, so it is usually deployed manually right after a merge:
  `git checkout main && git pull`, then in its container
  `mix assets.deploy`, `mix compile --force`, then
  `docker service update --force veej_fable`.

## Development on this host

- **No native Elixir/Erlang.** All mix commands run in throwaway
  containers:
  `docker run --rm -v <repo>:/app -w /app elixir:1.20-otp-28 sh -c "mix local.hex --force >/dev/null 2>&1 && <command>"`
  (tests with `MIX_ENV=test mix test`).
- A dockerised dev server is defined in `.claude/launch.json`
  (`veejr-docker`: port 4010, throwaway `VEEJR_DB=veejr_preview.db`).
- Node.js lives at `~\.nvm\versions\node\v22.13.1\` (used by
  `mix precommit`'s protocol-fixture check and GitHub API scripting).

## Hazards learned the hard way

- **Never run host (Windows) git inside an instance's repo clone.** Host
  git writes CRLF line endings; the container's git then sees every file
  as modified and the self-upgrade dirty-tree guard refuses to run.
  Recovery: `docker exec <container> git checkout -- .` from inside the
  container. The main workbench repo is exempt only because the same
  host git manages its index.
- **The main instance runs whatever this working directory has checked
  out.** In-flight development means a restart boots unmerged code, and
  the self-upgrade button reports "modified checkout" while uncommitted
  work exists. Return to a clean `main` when stepping away.
- **Windows reserved ports**: publishing UDP ranges at 49152+ fails with
  "access permissions" errors; keep ranges below 49152.
- The router's missing NAT loopback silently breaks anything that
  advertises the public IP to LAN peers (TURN `--external-ip`, srflx
  candidates). Prefer LAN-valid addresses plus split DNS.
