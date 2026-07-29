# Security policy

veejr is end-to-end encrypted messaging and calling that people self-host. A
vulnerability here can expose private correspondence, so reports are welcome
and taken seriously.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.** A public report
tells every operator's attacker before it tells the operators.

Report privately through GitHub:

1. Go to the [Security advisories page](https://github.com/veejr/veejr-server/security/advisories/new).
2. Describe the issue and how to reproduce it.

This creates a private advisory visible only to the maintainers. You do not
need a special invitation and nothing is disclosed until a fix is published.

If GitHub is not usable for you, open a public issue containing only a request
for a private contact channel — no technical detail — and a maintainer will
follow up.

### What helps

- Which version (`GET /api/instance` reports it) and how the instance is
  deployed.
- What an attacker gains: reading content, impersonating a user or instance,
  bypassing consent, escalating to administrator, denying service.
- A concrete reproduction. A proof of concept against your own test instance
  is far more useful than a description.
- Whether it needs an authenticated account, a federated peer, or nothing.

### What to expect

This is a small project, not a company with a response team. You should get an
acknowledgement within about a week. If a report is valid you will be credited
in the advisory and the release notes unless you would rather not be.

Please give a reasonable window to ship a fix before publishing. Instances
upgrade themselves on their administrator's initiative, so operators need time
to act after a release exists.

## Supported versions

Only the most recent release receives security fixes. veejr is pre-1.0 and
every instance can upgrade itself from `/admin` → **Software update**, so the
expectation is that operators stay current rather than that old versions get
backports.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Anything older | No — upgrade |

## Scope

In scope, roughly in order of severity:

- Anything that exposes message plaintext, decrypted attachments, location
  coordinates, or private keys to the server or to a third party.
- Breaking the consent model: retrieving ciphertext without acceptance,
  or messaging someone who has not accepted a friendship.
- Impersonating a user or an instance, including forging federation
  signatures or defeating key pinning after first contact.
- Authentication, session, invitation-capability, or guest-capability bypass.
- Privilege escalation to instance administrator.
- Cross-site scripting, or any injection that executes script in a page —
  particularly relevant because the browser holds the decryption keys.
- Server-side request forgery, path traversal, or archive-expansion attacks
  in export/import and avatar proxying.

### Known and documented, not vulnerabilities

These are consequences of the architecture and are described in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#security-boundaries). Reports that
restate them without a new attack will be closed as intended behaviour:

- **A compromised server can serve malicious JavaScript** and capture
  passphrases, keys, or plaintext. The browser client is delivered by the
  server it is meant to distrust for content. A Content-Security-Policy limits
  what a *partial* compromise can do, but it cannot fix this.
- **The server sees metadata**: accounts, the friend graph, groups,
  sender/recipient pairs, timestamps, item kinds, attachment sizes, contact
  and group notes, and delivery decisions.
- **Recipients keep what they decrypt.** Expiry and display limits remove
  normal application access; they are not revocation, and "no download" is a
  UI policy rather than a control.
- **Federation trusts the first contact.** Peer signing keys and remote user
  keys are pinned on first use, which protects continuity afterwards but does
  not authenticate that first key against an external source.
- **Capability URLs are credentials.** Envelope and blob identifiers are
  unguessable and authorize access; leaking one through a log or referrer
  exposes that item. Demonstrating that a leaked capability works is not a
  finding.
- **Calls reveal IP addresses to the peer** unless a TURN relay is configured,
  as in any peer-to-peer call.
- **Watch parties tell YouTube who is watching**, and general watch-party
  playback state is server-readable by design.

If you can turn one of these into something sharper — a way to *cause* a
capability to leak, or to make key pinning accept a substitution — that is very
much in scope.

### Out of scope

- Findings against instances you do not run and do not have permission to
  test. Please stand up your own instance; see
  [docs/INSTALLATION.md](docs/INSTALLATION.md).
- Missing hardening with no demonstrated impact, scanner output without
  analysis, and best-practice advice unattached to an attack.
- Denial of service by brute traffic volume.
- Social engineering, physical attacks, or anything targeting the maintainers.
- Vulnerabilities in an operator's own deployment choices — TLS
  configuration, exposed ports, unprotected backups — rather than in veejr.
  [docs/OPERATIONS.md](docs/OPERATIONS.md) covers those.

## For operators

If you run an instance, the security-relevant operational duties are in
[docs/OPERATIONS.md](docs/OPERATIONS.md): keep TLS current, restrict access to
the database and blob directory, protect backups, apply updates promptly, and
review administrator audit events.
