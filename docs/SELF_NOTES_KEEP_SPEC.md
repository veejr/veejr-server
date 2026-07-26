# Notes to yourself — Keep-style board specification

**Status:** implemented web baseline plus forward-looking requirements (v0.3.54)
**Audience:** Phoenix/LiveView, web client, Android, API, QA, and security reviewers  
**Primary surface:** the existing **Notes to yourself** self-conversation in `/messages`

## Current implementation status

Veejr currently implements encrypted payload-v2 `self_note` cards, creation
and edit, text/checklists, labels, colors, pin/archive/trash/restore/delete,
bulk actions, local text/label/date filtering, encrypted attachments, voice and
video capture, and incremental **Load more** plus **Load all notes**. Entering
a search automatically requests all remaining encrypted note envelopes before
client-side filtering. Successful edits refresh the visible card without
requiring a page reload.

Google Keep Takeout import is also implemented in the browser. It imports note
JSON plus available attachments, uses keyed opaque deduplication identifiers,
and updates an earlier imported card when Keep content changes instead of
creating a duplicate.

This document still records the intended complete behavior. Requirements not
yet matching the web implementation remain roadmap items, notably the richer
three-way conflict comparison, cursor/progress/cancellation UX for very large
searches, legacy self-message conversion, and native-client parity. Current
loading starts at 50 and can add 50 or remove the limit with **Load all
notes**. Search requests that load-all path automatically. Scheduled reminders
remain explicitly unimplemented.

## 1. Outcome

Turn **Notes to yourself** from a chronological message thread into a private, card-based workspace inspired by Google Keep. A person can quickly capture, organize, find, edit, archive, restore, and delete their own encrypted notes without changing Veejr's end-to-end encryption or making note content visible to the server.

This is a behavioral and interaction reference, not a visual copy of Google Keep. Veejr should retain its own typography, themes, icons, and privacy language.

## 2. Product principles

1. **Private by construction.** Title, body, checklist contents, labels, colors, pin/archive/trash state, and search terms are encrypted in the note payload. The server must not be able to read or filter on them.
2. **Capture first.** A new note must take one action from the board and save without a modal confirmation.
3. **Cards, not bubbles.** Self-notes are displayed as responsive masonry/grid cards; ordinary conversations retain the existing thread UI.
4. **No surprise loss.** Delete first moves a note to Trash. Permanent deletion is explicit and irreversible.
5. **One note is one encrypted item.** A note uses the existing self-only encrypted envelope model. There is never a notification, federation request, or second self-copy.
6. **Accessible and offline-tolerant.** All controls are keyboard reachable, labelled, and announce save/failure state. Do not persist decrypted note content in browser storage by default.

## 3. Scope

### 3.1 Version 1 (required)

- Create text notes and checklist notes.
- Edit title, body, checklist items, color, labels, pin state, and archive state.
- Convert between text and checklist while preserving text where possible.
- Pin/unpin; pinned notes appear before unpinned active notes.
- Archive/unarchive, trash/restore, and permanently delete from Trash.
- Client-side full-text search of title, body, labels, and checklist text.
- Client-side filters: Notes, Reminders (empty-state only in v1), Labels, Archive, and Trash.
- Multi-select: pin/unpin, archive, trash, change color, add/remove labels.
- Attach existing encrypted file uploads to a note using the existing encrypted blob flow.
- Responsive board and list views, including dark and Art Deco themes.
- Migration of existing self-message text items into read-only legacy cards with an in-product action to convert each item to a full note.

### 3.2 Explicitly deferred

- Scheduled notifications/reminders (the UI may reserve the location, but must not claim it works).
- Drawing/canvas notes, OCR, voice transcription, collaborators, shared notes, public links, and third-party sync.
- Server-side search, server-readable labels, server-side color/state filtering, or analytics containing note plaintext.
- Drag-and-drop reordering. Default order is deterministic and based on encrypted note timestamps.

## 4. Current-system constraints and decision

Veejr already stores messages as client-encrypted `envelopes`. A self-send creates one envelope for the sender, with the stable participant sentinel `"notes to yourself"`. The browser encrypts the JSON payload using the account key; the server stores ciphertext and nonce only.

**Decision:** add a `self_note` envelope kind and use one self-only envelope per card. Do not create a plaintext `notes` table and do not reuse the existing `note` kind, which means map note.

This keeps the note portable with encrypted history, compatible with key rotation, and accessible to future native clients through the same protocol. The server will continue to see only normal envelope metadata already exposed by messaging: owner/sender, recipient (the same user), kind, ciphertext size, timestamps, and expiry/deletion state.

## 5. Information architecture and navigation

### 5.1 Entry points

- In the Messages conversation rail, the self thread remains titled **Notes to yourself** and gets a note/card icon instead of a message-count emphasis.
- Selecting that thread shows the notes board instead of the message-bubble thread.
- The existing empty self-recipient state opens the notes board and focuses the quick-create editor.
- No new route is required for v1. The implemented board uses
  `GET /messages?self_notes=true`, so browser back/forward and direct links work
  without exposing note content or search terms in the URL.

The existing `/messages` route is inside the authenticated `live_session :app`, whose mounts require authentication, current scope, unlocked keys, and live notifications. The board must stay there because it requires `@current_scope.user` and browser-held encryption keys. Do not place it in a public or merely `:current_user` session.

### 5.2 Board layout

Desktop layout:

```text
Notes to yourself                         Search notes       Grid/List
[ Take a note… ] [ New checklist ] [ Attach file ]

  Pinned
  [ card ] [ card ] [ card ]

  Others
  [ card ] [ card ] [ card ]
```

Mobile uses one column, sticky search/filter controls, and a bottom-aligned create button. Desktop uses 2–4 columns according to container width; cards must not be visually reordered across a keyboard tab sequence.

Each card contains a title (optional), body/checklist preview, attachment
count/preview, labels, `Edited <relative time>`, and actions for selection,
pin, archive, trash/restore, and permanent delete where applicable. Text bodies
are initially clamped to ten lines. Clicking a clamped body expands it;
clicking the expanded body opens a tall inline editor, while Control-click
collapses it again. Do not rely on hover alone.

## 6. User flows and acceptance criteria

### 6.1 Create

1. User selects **New note** or presses `c` while focus is not in a field.
2. An inline editor opens; title is optional and the body accepts long,
   resizable text.
3. **Save note** explicitly saves; **Cancel** or Escape closes without saving.
4. Before saving, the browser encrypts the complete document and sends exactly one `self_note` envelope addressed to the signed-in user.
5. A successfully saved note immediately renders in the appropriate pinned/unpinned section.

Acceptance: blank notes are never saved; a failed save keeps the editor open with plaintext only in its DOM memory and a retry action.

### 6.2 Edit

- Selecting a card opens the same inline editor after decryption. A clamped
  long body uses the expand-then-edit interaction described in §5.2.
- Save replaces the ciphertext for that envelope through the existing sender-side batch-edit mechanism; it must update `edited_at` in the encrypted document.
- Editing must preserve attachments and every non-edited note property.
- If another device changed the note after this device loaded it, the current
  web client asks whether to keep the local version or reload the latest
  version. A richer read-only three-way comparison remains roadmap work; stale
  content must never overwrite without an explicit choice.

Acceptance: repeated saves never create duplicate cards; reload shows the last confirmed encrypted version.

### 6.3 Checklists

- A checklist contains ordered items `{id, text, checked}`; item IDs are UUIDs generated in the browser.
- Enter adds an item; Backspace on an empty item merges/removes it; Space toggles only when focus is on the checkbox.
- Completed items move below incomplete ones only when the user enables **Move checked items to bottom** in the editor. Preserve stable order within each group.
- The card preview shows completed/total and does not expose item text before decryption.

### 6.4 Organize, search, and selection

- Pinning changes only encrypted `pinned`; board sort is pinned first, then `updated_at` descending, then `note_id` descending as a stable tie-breaker.
- Labels are normalized client-side: trim, collapse internal whitespace, Unicode case-fold for duplicate detection, retain original display casing, maximum 50 labels/account and 10/note.
- Search is case- and diacritic-insensitive Unicode substring matching after
  decryption. It indexes title, body, labels, checklist text/state, attachment
  metadata, color, pin/archive/trash state, created/updated timestamps, and
  opaque note/legacy IDs. Quoted terms are one required phrase; unquoted terms
  are separate required clauses, and a missing closing quote safely treats the
  remainder as a phrase. Search plaintext never appears in a LiveView event,
  logs, URL query string, telemetry, database column, or server-side index.
- Selecting two or more cards enters bulk mode and displays an accessible action toolbar. All selected-note mutations are independently encrypted and submitted; partial failure identifies the notes that failed and leaves their selection intact.

### 6.5 Archive, trash, and permanent deletion

- **Archive** sets encrypted `archived_at`; archived notes disappear from Notes and remain searchable only in Archive.
- **Move to Trash** sets encrypted `trashed_at`; Trash is excluded from Notes, Labels, and normal search.
- **Restore** clears `trashed_at` and returns the note to its prior archive state.
- **Delete forever** uses the existing sender-side envelope deletion. It also deletes all blob references for that self-note batch using the existing cleanup path.
- V1 does not auto-empty Trash. A future retention policy may add it only after a product/security decision.

Acceptance: permanent deletion requires a confirmation naming the number of selected notes; archive and trash remain undoable from their destination views.

## 7. Encrypted payload contract

All fields below are JSON inside the existing NaCl box payload. The envelope kind is `"self_note"`; the payload's `kind` is also `"self_note"` to detect malformed/cross-kind payloads.

```json
{
  "v": 2,
  "kind": "self_note",
  "note_id": "a browser-generated UUID",
  "title": "Optional title",
  "body": "Plain-text body for text notes",
  "checklist": [
    {"id": "UUID", "text": "Book dentist", "checked": false}
  ],
  "labels": ["Home", "Errands"],
  "color": "default",
  "pinned": false,
  "archived_at": null,
  "trashed_at": null,
  "created_at": "2026-07-20T12:00:00Z",
  "updated_at": "2026-07-20T12:00:00Z",
  "attachments": ["existing encrypted attachment descriptors"],
  "settings": {"move_checked_to_bottom": false}
}
```

Validation after decryption:

- `v` must be `2`; unknown later versions render a safe unsupported-note card without editing.
- `note_id`, checklist IDs, and timestamps are required and UUID/ISO-8601 validated.
- Title: 500 Unicode scalar values; body: 100,000; checklist: 500 items; item text: 2,000; labels: 10 per note, 64 each.
- `color` is one of `default`, `sand`, `rose`, `violet`, `blue`, `mint`, or `slate`. Colors map to theme tokens, never hard-coded foreground text.
- Attachments use the existing descriptor validation; attachment keys and metadata remain encrypted in this payload.

## 8. Server, protocol, and client changes

### 8.1 Server

1. Add `"self_note"` to `Veejr.Messaging.Envelope.kinds/0`, the API's allowed-kind contract, notification labels, and fixtures.
2. Update `Messaging.send_batch/4` to enforce self-note invariants:
   - exactly one envelope;
   - its recipient is the sender;
   - no expiry or display limit;
   - no local/federated notification and no conversation-window update.
3. Add owner-scoped `Messaging.list_self_note_envelopes(user, opts)` ordered by `updated_at DESC, id DESC`; it must only return the caller's self-note envelopes and exclude permanently deleted records.
4. Reuse `editable_batch/2` and `edit_sent_batch/3`, but require self-only copies for self-note edits. The server validates envelope ownership and kind, not document contents.
5. Add a migration for the kind constraint only if the deployed database has an explicit kind check. Do not add columns for title, labels, card color, search text, or encrypted state.
6. Ensure export/import and key rotation include `self_note` exactly as other envelopes.

### 8.2 Web client

- Add a dedicated `SelfNotes` hook/module in `assets/js/veejr/`; it owns decrypting note cards, client-side filtering, the editor state, keyboard shortcuts, and re-encryption.
- The hook receives ciphertext/nonce/public ID/key metadata only. It must use the existing `openFrom`, `sealFor`, `encryptAndUpload`, and key-unlock flow.
- Render a server skeleton with stable card IDs; after decryption, populate card content through DOM APIs or a LiveView-compatible hook. The hook-owned card body must use `phx-update="ignore"`.
- Do not add raw inline scripts to HEEx. Register an external hook in `assets/js/veejr/hooks.js` and `app.js` as required by the current app convention.
- Debounced saves must be cancellable on navigation; never transmit a pending plaintext draft after the user leaves the page.
- When unlocked keys are unavailable, show the existing key-setup/unlock call-to-action, not blank cards or a content error.

### 8.3 LiveView

- In `MessagesLive`, branch only when the selected conversation is the stable self-thread and contains/self-selects notes. Ordinary message threads and composer behavior must remain unchanged.
- Use LiveView streams for the encrypted envelope-card collection. The view tracks separate assigns for pagination/loading state; it must not enumerate a stream to filter notes.
- Add events only for envelope retrieval, delete/restore navigation, and refresh signals. Plaintext search, labels, colors, checklist updates, and drafts remain browser-only until the encrypted save request.
- Add unique IDs for the board, quick capture, search, filters, card editor, selection toolbar, and destructive-confirmation dialog.

### 8.4 API and Android

- Version the API contract to allow `self_note` in `message_kinds` and batch/envelope endpoints. An older client must display an unsupported encrypted item rather than treat it as a normal message.
- Android must use the same payload contract, client-side search, and privacy rules before advertising self-note sync. Cross-device note edits use the conflict behavior in §6.2.
- Do not ship web-only payload fields that Android cannot safely preserve on edit.

## 9. Pagination, performance, and consistency

- The server orders encrypted self-note envelopes by edited/inserted time and
  ID. The board loads 50 initially, **Load more** adds 50, and **Load all
  notes** removes the query limit.
- The browser decrypts fetched cards and retains the searchable index in memory
  for the active tab only.
- Entering any non-empty search automatically invokes the same load-all action
  once when more notes exist, then reapplies the local filter after LiveView
  updates. Future very-large-account work may replace this with cursor-backed
  progress and cancellation without exposing the query.
- Do not create a server-side full-text index, deterministic encrypted search index, or browser localStorage cache in v1.
- Every note edit carries its last decrypted `updated_at`. Before replacing ciphertext, the server atomically verifies that the envelope's stored `updated_at` matches; otherwise return `:stale_note` with fresh ciphertext metadata. This is the conflict trigger.

## 10. Security and privacy requirements

- Note plaintext, labels, search queries, titles, checklist items, attachment filenames, and state flags must never appear in LiveView assigns, URLs, Phoenix logs, browser analytics, flash text, notifications, or server-side error reports.
- The server must reject cross-user note list, edit, delete, and blob-reference operations, even with a guessed public ID.
- Only browser-generated UUIDs are accepted as note/item identifiers; never convert user input to atoms.
- Use text rendering only. Notes are plain text, not Markdown or HTML; never use `innerHTML` for decrypted fields.
- Sanitise/validate all decrypted payloads before rendering. Treat malformed ciphertext/payload as an unavailable card and allow permanent deletion; do not crash the board.
- Attachments retain existing encrypted-blob semantics. Deleting a note must not delete a blob still referenced by another valid envelope.
- Existing message retention, account export, key reset/rotation, and envelope deletion rules apply unless this spec states otherwise.

## 11. Accessibility and keyboard behavior

- Quick capture: `c`; search: `/`; Escape closes editor/search/selection in that order.
- Cards are semantic articles with an accessible title; opening a card uses a real button/link.
- Checklist inputs have visible labels and announce checked state.
- Action buttons have tooltip + `aria-label`; color choices expose selected state with `aria-pressed`/radio semantics, not color alone.
- Focus returns to the originating card after an editor or confirmation closes.
- Respect `prefers-reduced-motion`; no essential operation relies on animation or drag.

## 12. Test plan

### Context and data tests

- Only the owner can list, edit, or delete a self-note envelope.
- Self-note sends reject non-self, duplicate, expired, or display-limited envelopes.
- Self-note sends create one envelope, no notification, no federation outbox item, and the self-thread participant sentinel.
- Edited/inserted ordering is stable; the owner-scoped list never returns message, location, or map-note envelopes.
- Edit rejects stale `updated_at`; delete removes all note copies and releases blob references only when no other reference exists.

### LiveView tests

- Authenticated `/messages` inside `:app` renders the self-note board for the self thread and ordinary UI for any other thread.
- Assert key IDs such as `#self-notes-board`, `#self-notes-command-center`,
  `#self-notes-quick-create`, `#self-notes-search`,
  `#self-notes-load-all`, and `#self-notes-selection-toolbar`; do not assert
  raw HTML text.
- Pagination renders stream entries and the loading/empty/error states correctly.

### Browser-hook tests

- Encrypt/decrypt round-trip preserves every payload field and rejects malformed/unknown-version payloads.
- New note, title/body edit, checklist toggle, color/label/pin/archive/trash/restore, attachment preservation, and permanent delete.
- Search is local only; test that no `pushEvent` contains the query plaintext.
- Saving after a stale response opens conflict resolution; choosing each branch has deterministic results.
- Keyboard, focus-return, screen-reader labels, reduced-motion, narrow mobile layout, and all three installed themes.

### End-to-end smoke tests

1. Create a checklist and a file-backed note in browser A.
2. Open the same account in browser B, unlock keys, verify both cards decrypt.
3. Edit one card in A, then save a conflicting edit in B and resolve it.
4. Archive, restore, trash, restore, permanently delete; verify encrypted attachments remain or are released appropriately.
5. Export/import and rotate keys; verify remaining notes decrypt and remain editable.

## 13. Delivery status

1. **Foundation — shipped:** envelope kind/invariants, API contract,
   owner-scoped listing, migration, dedup metadata, and context tests.
2. **Board — shipped:** self-notes route state, encrypted cards, decrypt/render
   hooks, quick capture, edit, immediate refresh, and incremental loading.
3. **Organization — shipped:** checklists, labels, colors,
   pin/archive/trash/restore, filters, date search, and bulk actions.
4. **Hardening — in progress:** encrypted attachments and media capture,
   idempotent Google Keep import/update, stale-write detection, automatic
   load-all local search, phrase parsing, long-body expand/edit behavior, and
   regression coverage are present. Rich conflict comparison, cursor/progress
   search UX for very large accounts, legacy conversion, deeper accessibility
   validation, and Android parity remain.

The board is no longer feature-flagged. Existing self-message history must
remain visible; future changes must not silently reinterpret or discard it.
