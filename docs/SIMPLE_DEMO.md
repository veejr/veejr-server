# Simple view demo

The simple view demo is a public, interactive preview of Veejr's reduced
contacts-and-messages experience. It lets someone understand the interaction
model without registering, creating encryption keys, adding friends, or
touching account data.

Open `/demo/simple` on a running Veejr instance. In local development, the
default URL is <http://localhost:4000/demo/simple>.

## What the demo includes

The demo deliberately follows the simple view's two-screen model:

1. **Contacts** — search a small sample directory and choose one person.
2. **Conversation** — read a sample thread, add session-only replies, return to
   contacts, or open the call-choice dialog.

The **Start over** action restores the original contacts, messages, search
field, and selected screen. Contact presence states, message times, and call
feedback are illustrative rather than live.

The interface is responsive. At narrow widths, the call choice is presented as
a bottom sheet; wider layouts use a centered dialog. Keyboard focus moves into
the dialog when it opens, Escape closes it, and the composer retains focus
after a message is added.

## Privacy and data boundary

The demo is a simulation, not a second messaging client.

- All contacts and initial messages are constants in
  `VeejrWeb.SimpleDemoLive`.
- Replies exist only in the visitor's LiveView process. They disappear when
  that session ends or **Start over** is selected.
- The view performs no account, social, messaging, call, federation, upload,
  or notification context calls.
- It does not read a signed-in user's contacts, messages, encryption keys, or
  preferences.
- **Start demo call** only shows explanatory feedback; it never requests media
  permissions and never rings another user.
- Sample text is rendered as ordinary server-side demo content. It does not
  claim to demonstrate end-to-end encryption or browser-side decryption.

Keep this boundary explicit when extending the demo. A feature that reads or
writes real user data belongs in the authenticated product views, not here.

## Route and authentication placement

The route is declared as:

```elixir
live "/demo/simple", SimpleDemoLive
```

It lives in the router's existing `live_session :current_user` block, which is
inside the normal `:browser` pipeline. That placement is intentional:

- signed-out and signed-in visitors can both open the demo;
- `mount_current_scope` supplies `@current_scope` when a session exists and
  leaves it `nil` otherwise;
- the normal layout can therefore show the appropriate account or
  registration navigation;
- the route does not pass through `:require_authenticated_user`, `KeyGate`, or
  the authenticated `live_session :app`, because the demo needs neither an
  account nor encryption keys.

Do not create another `:current_user` live session for the demo. Live session
names must be unique, and routes that work with or without authentication
belong in the existing block.

## Implementation map

| Concern | Location |
| --- | --- |
| LiveView, sample data, state transitions, and UI | `lib/veejr_web/live/simple_demo_live.ex` |
| Public route | `lib/veejr_web/router.ex` |
| LiveView behavior tests | `test/veejr_web/live/simple_demo_live_test.exs` |

The contact and message collections use LiveView streams. Filtering resets the
contact stream; opening a conversation resets the active message stream; a new
reply is inserted into that stream and mirrored into the small in-memory sample
map so it remains visible when the conversation is reopened during the same
session.

The `.DemoMessageInput` colocated hook clears and refocuses the browser input
after the server accepts a sample reply. The input uses `phx-update="ignore"`
because the hook owns that element's transient value; the LiveView still owns
the surrounding form and every submitted message.

## Testing

The focused suite covers the durable interaction contract:

- the route mounts without authentication and exposes sample contacts;
- search filters by handle or name;
- a contact opens a conversation and a reply appears as the visitor's message;
- call options open as an accessible dialog and can be dismissed.

Run it with:

```sh
mix test test/veejr_web/live/simple_demo_live_test.exs
```

Before committing changes, run the project-wide check:

```sh
mix precommit
```

For visual changes, also inspect `/demo/simple` at a narrow mobile width and a
desktop width. Check the contact grid, an empty thread such as Nora's, message
sending and input clearing, the call dialog, Escape dismissal, and horizontal
overflow.

## Extension checklist

When the production simple contacts or messages experience changes, decide
whether the demo should teach the same concept. If it should:

1. keep sample content clearly labeled and non-sensitive;
2. preserve the no-real-data and no-network-side-effect boundary;
3. use existing core components, icons, layout tokens, and LiveView streams;
4. give every new key element a stable DOM ID and cover the user outcome in
   `simple_demo_live_test.exs`;
5. maintain keyboard focus, dialog semantics, reduced-motion behavior, and
   responsive layouts;
6. update this guide when the route, boundary, state model, or supported demo
   interactions change.

The authenticated simple views remain the source of truth for real behavior:
`SimpleContactsLive` owns actual contacts and call initiation, while
`SimpleMessagesLive` owns consent, browser encryption/decryption, delivery,
read tracking, presence, and real message history.
