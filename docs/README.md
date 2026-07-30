# Documentation map

Use this page to choose the right Veejr document. Product behavior and
operations evolve faster than protocol compatibility documents, so each file
has a distinct purpose.

## Start here

| Document | Audience | Purpose |
| --- | --- | --- |
| [Project README](../README.md) | Everyone | Product overview, local development, common configuration, and links. |
| [Installation](INSTALLATION.md) | Operators | New development and source-mounted Docker Swarm installation. |
| [Operations](OPERATIONS.md) | Operators | Health checks, release/update flow, backup, restore, rollback, TURN, and troubleshooting. |
| [Calls and watch parties](CALLS_AND_WATCH_PARTIES.md) | Users, operators, developers | Conferencing controls, privacy, recovery/re-invite, YouTube sharing, voice, and diagnostics. |
| [Architecture](ARCHITECTURE.md) | Developers and security reviewers | Runtime components, cryptography, federation, calls, storage, and trust boundaries. |

## Compatibility and implementation references

| Document | Status | Purpose |
| --- | --- | --- |
| [Client protocol v1](CLIENT_PROTOCOL_V1.md) | Draft versioned contract | Native HTTP API, payload formats, cryptographic wire format, and Android interoperability. Browser call/watch signaling is explicitly outside v1. |
| [Reimplementation specification](REIMPLEMENTATION_SPEC.md) | Normative baseline for v0.3.55 | Framework-independent product, data, security, federation, UI, operation, call, and acceptance requirements. |
| [Notes to yourself specification](SELF_NOTES_KEEP_SPEC.md) | Implemented baseline plus roadmap | Encrypted card payload v2, reminders, privacy rules, current web behavior, and remaining parity/hardening work. |
| [Documents specification](DOCUMENTS.md) | Implemented web baseline | The `self_doc` payload for spreadsheets and pages, the formula engine, the block/mark model, and the on-demand editor chunk. |
| [`protocol-fixtures/v1.json`](../protocol-fixtures/v1.json) | Machine-verified fixture | Cross-client cryptographic interoperability values. |

## Deployment-specific reference

| Document | Scope | Purpose |
| --- | --- | --- |
| [Current Windows host runbook](HOST_RUNBOOK.md) | Project-operated host only | Exact services, paths, network constraints, boot behavior, and host-specific hazards. Do not copy secret locations or host assumptions blindly into another deployment. |

## Reporting problems

| Document | Audience | Purpose |
| --- | --- | --- |
| [Security policy](../SECURITY.md) | Security researchers, operators | How to report a vulnerability privately, what is in scope, and which architectural limits are documented rather than defects. |

## Planning

[`next_sol.md`](../next_sol.md) is a product assessment and roadmap, not a
compatibility or operational contract. A roadmap item is not implemented
unless the current behavior is also documented in the README, architecture,
feature guide, or code-backed specification.

## Documentation maintenance

When a behavior changes:

1. Update the user/operator guide that describes the visible behavior.
2. Update [ARCHITECTURE.md](ARCHITECTURE.md) for trust or data-flow changes.
3. Update [REIMPLEMENTATION_SPEC.md](REIMPLEMENTATION_SPEC.md) when a compatible
   implementation must reproduce it.
4. Change [CLIENT_PROTOCOL_V1.md](CLIENT_PROTOCOL_V1.md) only for the versioned
   native contract; do not document internal LiveView events as public API.
5. Update installation/operations when configuration, migration, backup,
   health, or recovery steps change.
6. Verify relative Markdown links and run `mix precommit` before release.
