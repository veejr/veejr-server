# Product assessment and roadmap

Status: assessment written against **v0.3.16 on 2026-07-22**. Current version
is **v0.3.58**. The judgments below have not been re-derived since; treat them
as a snapshot of thinking at that point rather than a description of today's
code. `docs/README.md` explains why this file is not a compatibility or
operational contract — a roadmap item is not implemented unless the current
behavior is also documented in the README, architecture, feature guide, or a
code-backed specification.

## Landed since this assessment

Items above that have since moved, so the roadmap is not read as still-open
work:

- **Server CI is established** (`.github/workflows/ci.yml`): compile with
  warnings as errors, formatting, unused-dependency, and protocol-fixture
  checks plus the full test suite on every pull request, and a separate
  production asset build. *Android CI remains outstanding.*
- **Cryptographic fixtures now verify the shipped browser module.**
  `mix protocol.verify` previously re-derived its values from tweetnacl and
  never executed `assets/js/veejr/crypto.js`; it now replays the fixture
  through the real module and runs in CI. *Automated Android-side
  interoperability still runs manually.*
- **A Content-Security-Policy is enforced** in production, pinning `script-src`
  and `connect-src` to the instance origin. This narrows, but does not remove,
  the browser trust problem described under Weak Points — a server that can
  rewrite the client can rewrite the header too.
- **Request budgets** now cover authentication, directory, invitation, upload,
  and federation endpoints, closing a requirement that
  `REIMPLEMENTATION_SPEC.md` §17 had specified but nothing implemented.
- **A disclosure policy exists** (`SECURITY.md`) with private reporting
  enabled, which is a precondition for the independent review listed below.

Still open from the list below: two-instance federation tests, an independent
protocol and security review, immutable release images, automated
backup/restore drills, and everything under product polish, federation
maturity, conversation evolution, operational portability, and conferencing
consolidation.

Veejr has become a genuinely interesting application. It is no longer just a messaging experiment; it has a recognizable philosophy: private communication, deliberate consent, self-hosting, federation, and user portability.

**Strong Points**
- **Clear identity.** Veejr is not trying to be another generic chat service. Consent-before-delivery, private contact notes, personal instances, and account moves give it a distinctive shape.
- **Meaningful end-to-end encryption.** Messages, locations, notes, and attachments are encrypted in the client. The server primarily stores opaque ciphertext.
- **Self-hosting remains realistic.** One application, one database, one encrypted-blob directory, and an HTTPS proxy is still understandable for a technically capable operator.
- **Federation and portability are unusually ambitious.** Friends can exist across instances, and a person can move while retaining identity, history, avatar, and friendships.
- **The administrative layer is becoming mature.** Permanent instance administrator, registration policies, invitations, suspension, quotas, audit history, peer controls, and account moves form a serious operational foundation.
- **Good media capabilities.** Images, PDFs, voice recordings, and video messages are encrypted and viewed inside the application.
- **Encrypted personal workspace.** Notes to yourself now provides encrypted cards, checklists, organization, local search, attachments, and idempotent Google Keep import without creating a plaintext notes index.
- **Substantial live communication.** Browser calls now include device setup, adaptive video, screen sharing, multiple viewing modes, ephemeral direct chat/files, synchronized YouTube, mobile lifecycle handling, and reconnect/re-invite. Instance-local watch parties add host-directed playback and opt-in peer voice.
- **Browser and Android interoperability.** Using a documented protocol and shared cryptographic format is much stronger than treating Android as an unrelated companion app.
- **Documentation is now a real asset.** The reimplementation specification makes the product understandable independently of Phoenix.

**Weak Points**
- **The browser trust problem remains fundamental.** A compromised server can serve altered JavaScript that captures plaintext or keys. The Android app has a stronger independent-client trust boundary.
- **Cryptography creates a large correctness burden.** Key rotation, sender-key snapshots, attachment references, expiry, federation, and account movement interact in subtle ways. This needs an external security review eventually.
- **The system exposes considerable metadata.** The server sees friendships, participants, timestamps, content kinds, file sizes, notes, login activity, and delivery decisions.
- **Federation uses trust on first use.** This protects continuity after the first connection but cannot independently prove that the first key was authentic.
- **SQLite limits deployment scale.** It is an excellent choice now, but the current architecture expects one application writer and one replica.
- **Account movement is operationally complex.** It works, which is impressive, but DNS, TLS, provisioning, import verification, friendship repair, and deletion create many possible partial-failure states.
- **The product surface has grown quickly.** Messaging, maps, groups, media, administration, federation, native clients, and provisioning all compete for testing and polish.
- **Realtime features add a second reliability model.** Calls and watch-party voice depend on browser permissions, WebRTC, STUN/TURN, autoplay policy, and short-lived signaling rather than the durable message/outbox path. Cross-browser and adverse-network testing must remain a release discipline.
- **Third-party shared viewing has its own privacy boundary.** YouTube receives a request from every viewer and may apply regional, account, age, embedding, or content-blocking policy independently of Veejr.
- **Android verification needs strengthening.** The recent Android changes could not be built on this machine because JDK 17 and the Android SDK are missing. Continuous Android builds and cross-client integration tests should become mandatory.
- **“No download” media controls are only a UI policy.** A determined recipient can still retain network bytes or record the screen.
- **Conversation concepts remain somewhat implicit.** Conversations are largely derived from envelope participants and archive boundaries rather than represented as durable shared objects. That may become limiting for richer group-chat behavior.

**What I Think Comes Next**
The wisest next phase is consolidation rather than adding many headline features.

1. **Reliability and security**
   - Establish CI for server and Android.
   - Run browser/Android cryptographic interoperability tests automatically.
   - Add full two-instance federation tests.
   - Commission an independent protocol and security review.
   - Produce immutable release images and automated backup/restore drills.

2. **Product polish**
   - Make notification, unread, synchronization, and offline states exceptionally clear.
   - Improve accessibility and mobile layout consistency.
   - Refine the difference between contacts, conversations, groups, and delivery policies.
   - Add simple user-facing explanations for expiry, consent, and encryption without overwhelming people.

3. **Federation maturity**
   - Add safer first-contact verification, perhaps QR fingerprints or independently confirmed safety numbers.
   - Improve peer diagnostics and move recovery.
   - Version federation explicitly before outside implementations appear.

4. **Conversation evolution**
   - Introduce a durable conversation identity if Veejr needs shared group conversations, membership history, replies, reactions, read state, or multi-device synchronization.
   - Keep ordinary private messaging simple even if advanced conversation features are added.

5. **Operational portability**
   - Turn instance creation into a tested, repeatable package rather than a host-specific script.
   - Support Linux cleanly and eventually PostgreSQL or another multi-writer database where larger deployments need it.
   - Make spawning a personal instance feel like an intentional product feature, not an administrative stunt.

6. **Conferencing consolidation**
   - Exercise 1:1 calls across Chrome, Firefox, Safari, Android, iOS, VPN, cellular, direct, and TURN-relayed paths; automate what can be made deterministic.
   - Add operator-visible, privacy-safe call diagnostics without persisting SDP, ICE candidates, chat, files, or media.
   - Replace static TURN credentials with time-limited credentials before operating a broadly public instance.
   - Keep general watch-party voice intentionally small or introduce an SFU only after a separate scaling and trust-boundary design. The current peer mesh grows upload work per participant.
   - Specify a versioned native-client call lifecycle before adding Android call parity; current LiveView and federation event names are internal.

My overall judgment: **Veejr has a strong idea and more substance than its age suggests.** Its greatest opportunity is not becoming the largest messenger. It is becoming a humane, understandable way for small communities and individuals to own their communication and move without losing their relationships. The next leap will come from making what already exists exceptionally trustworthy and calm to use.
