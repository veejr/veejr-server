defmodule VeejrWeb.MessagesLive.Components do
  @moduledoc """
  Presentation for the Messages page.

  These are page-scoped, unlike `VeejrWeb.MessagingComponents`, which holds the
  encrypted-content UI shared with the map, contacts, and history pages. The
  split exists so the shared module stays about ciphertext handling rather than
  accumulating one page's layout.

  `VeejrWeb.MessagesLive` imports this module, so the presentation helpers at
  the bottom remain reachable from its event handlers as well as from the
  components here.
  """
  use Phoenix.Component
  use Gettext, backend: VeejrWeb.Gettext

  import VeejrWeb.CoreComponents
  import VeejrWeb.MessagingComponents

  alias Veejr.Social
  alias Phoenix.LiveView.JS

  use Phoenix.VerifiedRoutes,
    endpoint: VeejrWeb.Endpoint,
    router: VeejrWeb.Router,
    statics: VeejrWeb.static_paths()

  @doc """
  Title, back link, chat appearance picker, and the new-conversation launcher.
  """
  attr :conversations, :list, required: true
  attr :friends, :list, required: true
  attr :groups, :list, required: true

  def page_header(assigns) do
    ~H"""
    <div class="messages-page-header relative z-20 rounded-t-[31px] border-b border-base-300 bg-base-100 px-4 py-4">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div>
          <.link
            id="back-to-contacts"
            navigate={~p"/contacts"}
            class="group mb-2 inline-flex items-center gap-1 text-sm font-medium text-base-content/65 transition hover:text-primary"
          >
            <.icon
              name="hero-arrow-left"
              class="size-4 transition-transform group-hover:-translate-x-0.5"
            /> Back to contacts
          </.link>
          <h1 class="text-2xl font-semibold tracking-tight text-base-content">Messages</h1>
          <p class="text-sm opacity-70">End-to-end encrypted conversations</p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <div
            id="chat-theme-picker"
            class="chat-theme-picker flex flex-wrap items-center gap-1 rounded-2xl border border-base-300 bg-base-200 p-1.5"
            role="group"
            aria-label="Chat appearance"
          >
            <span class="chat-theme-picker-label">
              <.icon name="hero-swatch" class="size-4" /> Appearance
            </span>
            <button
              id="chat-theme-classic"
              type="button"
              data-chat-theme-option="classic"
              aria-pressed="true"
              class="chat-theme-option"
            >
              <span class="chat-theme-swatch" aria-hidden="true"></span>
              <span>Classic</span>
            </button>
            <button
              id="chat-theme-salon"
              type="button"
              data-chat-theme-option="salon"
              aria-pressed="false"
              class="chat-theme-option"
            >
              <span class="chat-theme-swatch" aria-hidden="true"></span>
              <span>Salon</span>
            </button>
            <button
              id="chat-theme-party"
              type="button"
              data-chat-theme-option="party"
              aria-pressed="false"
              class="chat-theme-option"
            >
              <span class="chat-theme-swatch" aria-hidden="true"></span>
              <span>Party</span>
            </button>
            <button
              id="chat-theme-comic"
              type="button"
              data-chat-theme-option="comic"
              aria-pressed="false"
              class="chat-theme-option"
            >
              <span class="chat-theme-swatch" aria-hidden="true"></span>
              <span>Comic</span>
            </button>
          </div>
          <.link
            id="messages-invite-person"
            navigate={~p"/invites/new"}
            class="btn btn-outline btn-sm"
          >
            <.icon name="hero-qr-code" class="size-4" /> Invite person
          </.link>
          <.conversation_builder
            id="messages-conversation-builder"
            form_id="messages-conversation-builder-form"
            conversations={@conversations}
            friends={@friends}
            groups={@groups}
          />
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Arrival announcement. Purely presentational: the ChatTheme hook drives it, and the sr-only span is the accessible half of the same event.
  """
  def new_message_celebration(assigns) do
    ~H"""
    <div
      id="new-message-celebration"
      data-role="new-message-celebration"
      role="status"
      aria-live="polite"
      aria-atomic="true"
      class="message-celebration pointer-events-none fixed top-20 left-1/2 z-[1050] -translate-x-1/2"
    >
      <span data-role="celebration-label" aria-hidden="true">New message!</span>
      <span data-role="arrival-announcement" class="sr-only"></span>
    </div>
    """
  end

  @doc """
  Pending-delivery consent prompts. Nothing is decrypted until the recipient accepts here, so this is the UI half of the consent model.
  """
  attr :pending, :list, required: true
  attr :current_scope, :map, required: true

  def consent_dialog(assigns) do
    ~H"""
    <section
      :if={@pending != []}
      id="message-consent-dialog"
      phx-hook="MessageConsent"
      data-user-id={@current_scope.user.id}
      data-my-key={@current_scope.user.public_key}
      role="dialog"
      aria-modal="true"
      aria-labelledby="message-consent-title"
      class="fixed inset-0 z-[1100] flex items-center justify-center bg-base-content/45 p-4 backdrop-blur-sm"
    >
      <div class="w-full max-w-2xl overflow-hidden rounded-[32px] border border-primary/25 bg-base-100 text-base-content shadow-2xl">
        <div class="border-b border-base-300 bg-primary/10 px-6 py-5 text-center">
          <div class="mx-auto flex size-12 items-center justify-center rounded-2xl bg-primary text-primary-content shadow-lg shadow-primary/20">
            <.icon name="hero-envelope" class="size-6" />
          </div>
          <h2 id="message-consent-title" class="mt-3 text-2xl font-semibold tracking-tight">
            A message is waiting
          </h2>
          <p class="mt-1 text-sm opacity-70">
            Choose what happens before any encrypted content is downloaded.
          </p>
        </div>
        <ul class="max-h-[60vh] space-y-3 overflow-y-auto p-4 sm:p-6">
          <li
            :for={notif <- @pending}
            id={"message-consent-#{notif.id}"}
            class="rounded-3xl border border-base-300 bg-base-200/70 p-4"
          >
            <div class="flex items-center gap-3">
              <.user_avatar
                user={notif.envelope.sender}
                class="size-11 text-sm"
                ring={false}
              />
              <span class="min-w-0">
                <span class="block truncate font-semibold">
                  {Veejr.Social.Address.handle(notif.envelope.sender)}
                </span>
                <span class="text-sm opacity-65">
                  Encrypted {notif.envelope.kind} · {Calendar.strftime(
                    notif.inserted_at,
                    "%b %d, %H:%M"
                  )} UTC
                </span>
              </span>
            </div>
            <div class="mt-4 grid gap-2 sm:grid-cols-3">
              <button
                id={"accept-message-#{notif.id}"}
                phx-click="request"
                phx-value-id={notif.id}
                class="btn btn-primary"
              >
                <.icon name="hero-check" class="size-4" /> Accept
              </button>
              <button
                id={"busy-later-message-#{notif.id}"}
                type="button"
                data-role="busy-later"
                data-notification-id={notif.id}
                data-sender-id={notif.envelope.sender.id}
                data-sender-key={notif.envelope.sender.public_key}
                data-sender-handle={Veejr.Social.Address.handle(notif.envelope.sender)}
                disabled={is_nil(notif.envelope.sender.public_key)}
                class="btn btn-outline"
                title={
                  if(is_nil(notif.envelope.sender.public_key),
                    do: "This sender has no encryption key yet",
                    else: "Reject and send an encrypted quick reply"
                  )
                }
              >
                Busy now, laters
              </button>
              <button
                id={"reject-message-#{notif.id}"}
                phx-click="decline"
                phx-value-id={notif.id}
                class="btn btn-ghost"
              >
                <.icon name="hero-x-mark" class="size-4" /> Reject
              </button>
            </div>
            <p data-role="busy-error" class="mt-2 hidden text-sm text-error"></p>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  @doc """
  Conversation list, bulk selection, and the recipient picker.
  """
  attr :conversations, :list, required: true
  attr :selected_conversation_key, :string, default: nil
  attr :selected_recipient, :any, default: nil
  attr :bulk_selected_conversations, :any, required: true
  attr :available_friends, :list, required: true
  attr :available_groups, :list, required: true

  def conversation_rail(assigns) do
    ~H"""
    <aside class="messages-rail hidden border-b border-base-300 bg-base-100 p-3 lg:overflow-y-auto lg:border-b-0 lg:border-r">
      <div class="mb-3 flex items-center justify-between px-2">
        <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">
          Conversations
        </h2>
        <button
          id="compose-new-rail"
          phx-click="new_message"
          class="rounded-full px-3 py-1.5 text-xs font-medium text-primary hover:bg-primary/10"
        >
          New
        </button>
      </div>
      <div
        id="conversation-bulk-actions"
        class="mb-3 flex items-center gap-1 rounded-xl bg-base-200 px-2 py-1.5"
      >
        <span class="mr-auto text-xs opacity-70">
          {MapSet.size(@bulk_selected_conversations)} selected
        </span>
        <button
          id="bulk-mark-conversations-read"
          type="button"
          phx-click="bulk_mark_read"
          disabled={MapSet.size(@bulk_selected_conversations) == 0}
          class="btn btn-ghost btn-xs"
        >
          <.icon name="hero-check" class="size-3.5" /> Read
        </button>
        <button
          id="bulk-archive-conversations"
          type="button"
          phx-click="bulk_archive_conversations"
          disabled={MapSet.size(@bulk_selected_conversations) == 0}
          data-confirm="Archive the selected conversations?"
          class="btn btn-ghost btn-xs"
        >
          <.icon name="hero-archive-box" class="size-3.5" /> Archive
        </button>
      </div>
      <p :if={@conversations == []} class="px-2 py-6 text-sm opacity-70">
        No conversations yet.
      </p>
      <div class="space-y-1">
        <div
          :for={conv <- @conversations}
          class={[
            "flex w-full items-center gap-3 rounded-[22px] px-3 py-3 text-left transition",
            @selected_conversation_key == conv.key &&
              "bg-primary/10 text-base-content",
            @selected_conversation_key != conv.key &&
              "text-base-content hover:bg-base-200"
          ]}
        >
          <input
            id={"select-conversation-#{conv.key}"}
            type="checkbox"
            aria-label={"Select #{conversation_title(conv)}"}
            checked={MapSet.member?(@bulk_selected_conversations, conv.key)}
            phx-click="toggle_conversation_selection"
            phx-value-key={conv.key}
            class="checkbox checkbox-xs shrink-0"
          />
          <.user_avatar
            :if={conv.avatar_user}
            id={"rail-conversation-avatar-#{conv.key}"}
            user={conv.avatar_user}
            class="size-10 text-sm"
            on_click="open_profile"
          />
          <span
            :if={!conv.avatar_user}
            class="flex size-10 shrink-0 items-center justify-center rounded-full bg-primary/15 text-sm font-semibold text-primary"
          >
            {conversation_initials(conv)}
          </span>
          <button
            id={"conversation-#{conv.key}"}
            type="button"
            phx-click="select_conversation"
            phx-value-key={conv.key}
            class="min-w-0 flex-1 text-left"
          >
            <span class="block truncate text-sm font-medium">
              {conversation_title(conv)}
            </span>
            <span class="mt-0.5 flex items-center justify-between gap-2 text-xs opacity-70">
              <span>{conv.message_count} messages</span>
              <span>{Calendar.strftime(conv.latest.inserted_at, "%b %d")}</span>
            </span>
          </button>
        </div>
      </div>

      <div
        :if={@available_friends != [] or @available_groups != []}
        class="mt-5 border-t border-base-300 pt-4"
      >
        <h2 class="mb-2 px-2 text-sm font-semibold uppercase tracking-wide opacity-70">
          Start new
        </h2>
        <div :if={@available_friends != []} class="space-y-1">
          <div
            :for={friend <- @available_friends}
            class={[
              "flex w-full items-center gap-3 rounded-[22px] px-3 py-3 text-left transition",
              @selected_recipient && @selected_recipient.type == :friend &&
                @selected_recipient.id == friend.id && "bg-primary/10 text-base-content",
              (!@selected_recipient || @selected_recipient.id != friend.id ||
                 @selected_recipient.type != :friend) &&
                "text-base-content hover:bg-base-200"
            ]}
          >
            <.user_avatar
              id={"message-friend-avatar-#{friend.id}"}
              user={friend}
              class="size-10 text-sm"
              on_click="open_profile"
            />
            <button
              id={"start-friend-#{friend.id}"}
              type="button"
              phx-click="select_friend"
              phx-value-id={friend.id}
              class="min-w-0 flex-1 text-left"
            >
              <span class="block truncate text-sm font-medium">
                {friend.display_name || friend.username}
              </span>
              <span class="block truncate text-xs opacity-70">
                {Social.Address.handle(friend)}
              </span>
            </button>
          </div>
        </div>

        <div :if={@available_groups != []} class="mt-3 space-y-1">
          <button
            :for={group <- @available_groups}
            id={"start-group-#{group.id}"}
            type="button"
            phx-click="select_group"
            phx-value-id={group.id}
            class={[
              "flex w-full items-center gap-3 rounded-[22px] px-3 py-3 text-left transition",
              @selected_recipient && @selected_recipient.type == :group &&
                @selected_recipient.id == group.id && "bg-primary/10 text-base-content",
              (!@selected_recipient || @selected_recipient.id != group.id ||
                 @selected_recipient.type != :group) &&
                "text-base-content hover:bg-base-200"
            ]}
          >
            <span class="flex size-10 shrink-0 items-center justify-center rounded-full bg-base-200 text-sm font-semibold opacity-80">
              {group_initials(group)}
            </span>
            <span class="min-w-0 flex-1">
              <span class="block truncate text-sm font-medium">{group.name}</span>
              <span class="block truncate text-xs opacity-70">
                {length(group.members)} members
              </span>
            </span>
          </button>
        </div>
      </div>
    </aside>
    """
  end

  @doc """
  Notes to yourself: encrypted cards the browser decrypts locally. Rendered instead of a conversation thread when @self_notes is set.
  """
  attr :self_notes, :boolean, required: true
  attr :self_note_envelopes, :list, required: true
  attr :has_more_self_notes, :boolean, required: true
  attr :current_scope, :map, required: true

  def self_notes_pane(assigns) do
    ~H"""
    <div :if={@self_notes} class="flex min-h-0 flex-1 flex-col">
      <div class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 bg-base-100 px-5 py-4">
        <div>
          <h2 class="text-lg font-semibold text-base-content">Notes to yourself</h2>
          <p class="text-xs opacity-70">Private, end-to-end encrypted notes</p>
        </div>
        <div class="flex items-center gap-2">
          <button
            id="self-notes-import"
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click={JS.dispatch("self-notes:import", to: "#self-notes-board")}
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Import
          </button>
          <button
            id="self-notes-new"
            type="button"
            class="btn btn-primary btn-sm"
            phx-click={JS.dispatch("self-notes:new", to: "#self-notes-board")}
          >
            <.icon name="hero-plus" class="size-4" /> New note
          </button>
        </div>
      </div>
      <div
        id="self-notes-board"
        phx-hook="SelfNotesBoard"
        data-user-id={@current_scope.user.id}
        data-peer-key={@current_scope.user.public_key}
        class="min-h-[26rem] flex-1 overflow-y-auto p-4 sm:p-6"
      >
        <input
          type="file"
          data-role="import-file"
          accept=".zip,application/zip"
          class="hidden"
          aria-hidden="true"
        />
        <div id="self-notes-icon-kit" class="hidden" aria-hidden="true">
          <span data-note-icon="attachment"><.icon name="hero-paper-clip" class="size-4" /></span>
          <span data-note-icon="audio"><.icon name="hero-microphone" class="size-4" /></span>
          <span data-note-icon="video"><.icon name="hero-video-camera" class="size-4" /></span>
          <span data-note-icon="camera"><.icon
            name="hero-arrow-path-rounded-square"
            class="size-4"
          /></span>
        </div>
        <div
          id="self-notes-selection-toolbar"
          data-role="selection-toolbar"
          class="mb-3 hidden items-center gap-2 rounded-xl border border-primary/30 bg-primary/10 px-3 py-2 text-sm"
        >
          <span data-role="selection-count">0 selected</span>
          <span class="flex-1"></span>
          <button data-role="bulk-pin" type="button" class="btn btn-ghost btn-xs">Pin</button>
          <button data-role="bulk-archive" type="button" class="btn btn-ghost btn-xs">Archive</button>
          <button data-role="bulk-trash" type="button" class="btn btn-ghost btn-xs">Trash</button>
          <button data-role="bulk-color" type="button" class="btn btn-ghost btn-xs">Color</button>
          <button data-role="bulk-label" type="button" class="btn btn-ghost btn-xs">Labels</button>
          <button data-role="bulk-clear" type="button" class="btn btn-ghost btn-xs">Clear</button>
        </div>
        <div
          id="self-notes-search-bar"
          class="sticky top-0 z-20 mb-3 rounded-2xl border border-base-300 bg-base-100/95 p-2 shadow-sm backdrop-blur"
        >
          <label class="group flex items-center gap-3 rounded-xl px-3 py-2 transition focus-within:bg-base-200/60">
            <.icon
              name="hero-magnifying-glass"
              class="size-5 shrink-0 text-base-content/45 transition group-focus-within:text-primary"
            />
            <input
              id="self-notes-search"
              data-role="search"
              type="search"
              placeholder="Search notes"
              aria-label="Search notes"
              class="min-w-0 flex-1 bg-transparent text-sm text-base-content outline-none placeholder:text-base-content/40"
            />
            <kbd class="hidden rounded-lg border border-base-300 bg-base-200 px-2 py-1 text-[0.65rem] font-semibold text-base-content/55 sm:block">
              /
            </kbd>
          </label>
        </div>
        <details
          id="self-notes-command-center"
          class="group mb-5 overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-[0_18px_55px_-36px_color-mix(in_oklab,var(--color-base-content)_48%,transparent)]"
          aria-label="Create and filter notes"
        >
          <summary
            id="self-notes-command-center-toggle"
            class="flex cursor-pointer list-none items-center gap-3 px-4 py-3 text-sm font-semibold text-base-content/70 transition hover:bg-base-200/60 hover:text-base-content focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-primary"
          >
            <span class="flex size-8 items-center justify-center rounded-lg bg-primary/10 text-primary">
              <.icon name="hero-plus" class="size-4" />
            </span>
            <span>Create and filter</span>
            <span class="hidden text-xs font-normal text-base-content/45 sm:inline">
              Notes, spreadsheets, documents, and views
            </span>
            <.icon
              name="hero-chevron-down"
              class="ml-auto size-4 transition duration-200 group-open:rotate-180"
            />
          </summary>
          <div class="border-t border-base-300">
            <div class="grid gap-px bg-base-300/70 lg:grid-cols-2">
              <button
                id="self-notes-quick-create"
                data-role="new-note"
                type="button"
                class="group flex min-h-24 items-center gap-4 bg-base-100 px-5 py-4 text-left transition hover:bg-primary/5 focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-primary"
              >
                <span class="flex size-12 shrink-0 items-center justify-center rounded-2xl bg-primary text-primary-content shadow-lg shadow-primary/20 transition duration-200 group-hover:-translate-y-0.5 group-hover:rotate-2">
                  <.icon name="hero-plus" class="size-6" />
                </span>
                <span class="min-w-0 flex-1">
                  <span class="block text-base font-semibold text-base-content">
                    Capture a new note
                  </span>
                  <span class="mt-0.5 block text-xs text-base-content/60">
                    Write, make a checklist, or add private media
                  </span>
                </span>
                <kbd class="hidden rounded-lg border border-base-300 bg-base-200 px-2 py-1 text-[0.65rem] font-semibold text-base-content/55 sm:block">
                  C
                </kbd>
              </button>

              <div class="flex min-h-24 items-stretch gap-px bg-base-300/70">
                <button
                  id="self-notes-new-sheet"
                  data-role="new-sheet"
                  type="button"
                  class="group flex flex-1 items-center gap-3 bg-base-100 px-4 py-4 text-left transition hover:bg-primary/5 focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-primary"
                >
                  <span class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-base-200 text-base-content/60 transition group-hover:bg-primary/10 group-hover:text-primary">
                    <.icon name="hero-table-cells" class="size-5" />
                  </span>
                  <span class="min-w-0 flex-1">
                    <span class="block text-sm font-semibold text-base-content">Spreadsheet</span>
                    <span class="mt-0.5 block text-xs text-base-content/60">
                      Grid with formulas
                    </span>
                  </span>
                </button>

                <button
                  id="self-notes-new-page"
                  data-role="new-page"
                  type="button"
                  class="group flex flex-1 items-center gap-3 bg-base-100 px-4 py-4 text-left transition hover:bg-primary/5 focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-primary"
                >
                  <span class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-base-200 text-base-content/60 transition group-hover:bg-primary/10 group-hover:text-primary">
                    <.icon name="hero-document-text" class="size-5" />
                  </span>
                  <span class="min-w-0 flex-1">
                    <span class="block text-sm font-semibold text-base-content">Document</span>
                    <span class="mt-0.5 block text-xs text-base-content/60">
                      Headings, lists, formatting
                    </span>
                  </span>
                </button>
              </div>
            </div>
            <div class="border-t border-base-300 bg-base-100 px-4 py-3">
              <details
                id="self-notes-date-filters"
                class="group rounded-xl border border-transparent open:border-base-300 open:bg-base-200/40"
              >
                <summary class="flex cursor-pointer list-none items-center gap-2 rounded-xl px-2 py-2 text-xs font-semibold text-base-content/60 transition hover:bg-base-200/70 hover:text-base-content">
                  <.icon name="hero-calendar-days" class="size-4" /> Filter by updated date
                  <.icon
                    name="hero-chevron-down"
                    class="ml-auto size-4 transition group-open:rotate-180"
                  />
                </summary>
                <div class="flex flex-wrap items-center gap-2 border-t border-base-300 px-3 py-3 text-xs">
                  <label class="flex items-center gap-2 rounded-lg border border-base-300 bg-base-100 px-2 py-1.5">
                    <span class="text-base-content/55">From</span>
                    <input
                      id="self-notes-date-from"
                      data-role="date-from"
                      type="date"
                      class="bg-transparent text-base-content outline-none"
                    />
                  </label>
                  <label class="flex items-center gap-2 rounded-lg border border-base-300 bg-base-100 px-2 py-1.5">
                    <span class="text-base-content/55">To</span>
                    <input
                      id="self-notes-date-to"
                      data-role="date-to"
                      type="date"
                      class="bg-transparent text-base-content outline-none"
                    />
                  </label>
                  <button
                    data-role="date-preset"
                    data-days="0"
                    type="button"
                    class="rounded-lg px-2.5 py-1.5 font-medium text-base-content/60 transition hover:bg-base-200 hover:text-base-content aria-[pressed=true]:bg-primary/10 aria-[pressed=true]:text-primary"
                    aria-pressed="false"
                  >Today</button>
                  <button
                    data-role="date-preset"
                    data-days="7"
                    type="button"
                    class="rounded-lg px-2.5 py-1.5 font-medium text-base-content/60 transition hover:bg-base-200 hover:text-base-content aria-[pressed=true]:bg-primary/10 aria-[pressed=true]:text-primary"
                    aria-pressed="false"
                  >Last 7 days</button>
                  <button
                    data-role="date-preset"
                    data-days="30"
                    type="button"
                    class="rounded-lg px-2.5 py-1.5 font-medium text-base-content/60 transition hover:bg-base-200 hover:text-base-content aria-[pressed=true]:bg-primary/10 aria-[pressed=true]:text-primary"
                    aria-pressed="false"
                  >Last 30 days</button>
                  <button
                    data-role="clear-dates"
                    type="button"
                    class="rounded-lg px-2.5 py-1.5 font-medium text-base-content/50 transition hover:bg-base-200 hover:text-base-content"
                  >Clear</button>
                </div>
              </details>
              <div
                class="mt-3 flex flex-wrap items-center gap-1 rounded-xl bg-base-200/75 p-1"
                role="tablist"
                aria-label="Note filters"
              >
                <button
                  data-role="filter"
                  data-filter="active"
                  type="button"
                  class="rounded-lg px-3 py-1.5 text-xs font-semibold text-base-content/60 transition hover:text-base-content aria-[pressed=true]:bg-base-100 aria-[pressed=true]:text-base-content aria-[pressed=true]:shadow-sm"
                  aria-pressed="true"
                >Notes</button>
                <button
                  data-role="filter"
                  data-filter="reminders"
                  type="button"
                  class="rounded-lg px-3 py-1.5 text-xs font-semibold text-base-content/60 transition hover:text-base-content aria-[pressed=true]:bg-base-100 aria-[pressed=true]:text-base-content aria-[pressed=true]:shadow-sm"
                  aria-pressed="false"
                >Reminders</button>
                <button
                  data-role="filter"
                  data-filter="archived"
                  type="button"
                  class="rounded-lg px-3 py-1.5 text-xs font-semibold text-base-content/60 transition hover:text-base-content aria-[pressed=true]:bg-base-100 aria-[pressed=true]:text-base-content aria-[pressed=true]:shadow-sm"
                  aria-pressed="false"
                >Archive</button>
                <button
                  data-role="filter"
                  data-filter="trashed"
                  type="button"
                  class="rounded-lg px-3 py-1.5 text-xs font-semibold text-base-content/60 transition hover:text-base-content aria-[pressed=true]:bg-base-100 aria-[pressed=true]:text-base-content aria-[pressed=true]:shadow-sm"
                  aria-pressed="false"
                >Trash</button>
                <button
                  data-role="view"
                  data-view="grid"
                  type="button"
                  title="Grid view"
                  aria-label="Grid view"
                  class="ml-auto rounded-lg p-1.5 text-base-content/50 transition hover:text-base-content aria-[pressed=true]:bg-base-100 aria-[pressed=true]:text-base-content aria-[pressed=true]:shadow-sm"
                  aria-pressed="true"
                ><.icon name="hero-squares-2x2" class="size-4" /></button>
                <button
                  data-role="view"
                  data-view="list"
                  type="button"
                  title="List view"
                  aria-label="List view"
                  class="rounded-lg p-1.5 text-base-content/50 transition hover:text-base-content aria-[pressed=true]:bg-base-100 aria-[pressed=true]:text-base-content aria-[pressed=true]:shadow-sm"
                  aria-pressed="false"
                ><.icon name="hero-list-bullet" class="size-4" /></button>
              </div>
              <div id="self-notes-labels" data-role="labels" class="mt-3 flex flex-wrap gap-1"></div>
              <p
                id="self-notes-filter-status"
                data-role="filter-status"
                class="mt-3 border-t border-base-300 pt-3 text-xs text-base-content/55"
                aria-live="polite"
              >
              </p>
              <button
                data-role="delete-trashed"
                type="button"
                disabled
                class="mt-2 rounded-lg px-2.5 py-1.5 text-xs font-semibold text-error transition hover:bg-error/10 disabled:hidden"
              >Delete all trashed forever</button>
            </div>
          </div>
        </details>
        <p
          id="self-notes-reminders-empty"
          data-role="reminders-empty"
          class="hidden mb-4 text-sm opacity-70"
        >
          Reminders are coming soon. Your notes remain private and are not scheduled yet.
        </p>
        <div id="self-notes-grid" class="columns-1 gap-4 sm:columns-2 xl:columns-3">
          <p
            :if={@self_note_envelopes == []}
            id="self-notes-empty"
            class="rounded-2xl border border-dashed border-base-300 p-8 text-center text-sm opacity-70"
          >
            Capture a thought, a checklist, or a private reminder.
          </p>
          <.self_note_card
            :for={envelope <- @self_note_envelopes}
            envelope={envelope}
            user={@current_scope.user}
          />
        </div>
        <div :if={@has_more_self_notes} class="mt-5 grid grid-cols-2 gap-2">
          <button
            id="self-notes-load-more"
            type="button"
            phx-click="load_more_notes"
            phx-disable-with="Loading…"
            class="btn btn-outline btn-sm"
          >
            <.icon name="hero-chevron-down" class="size-4" /> Load more
          </button>
          <button
            id="self-notes-load-all"
            type="button"
            data-role="load-all-notes"
            phx-click="load_all_notes"
            phx-disable-with="Loading all…"
            class="btn btn-ghost btn-sm border border-base-300"
          >
            <.icon name="hero-queue-list" class="size-4" /> Load all notes
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The open conversation: header, message list, and composer.
  """
  attr :selected_conversation, :any, default: nil
  attr :self_notes, :boolean, required: true
  attr :has_more_messages, :boolean, required: true
  attr :friends, :list, required: true
  attr :groups, :list, required: true
  attr :current_scope, :map, required: true

  def conversation_thread(assigns) do
    ~H"""
    <%!--
    The whole thread is the drop target, not just the composer row: dragging a
    file at a 3rem-tall strip is a poor aim. The composer hook finds this by
    walking up from itself.
    --%>
    <div
      :if={@selected_conversation && !@self_notes}
      data-composer-dropzone
      data-drop-label="Drop to attach"
      class="messages-chat relative flex min-h-0 flex-1 flex-col"
    >
      <div class="messages-chat-header flex items-center justify-between gap-3 border-b border-base-300 bg-base-100 px-5 py-4">
        <div class="flex min-w-0 items-center gap-3">
          <.user_avatar
            :if={@selected_conversation.avatar_user}
            user={@selected_conversation.avatar_user}
            class="size-11 text-sm"
            on_click="open_profile"
          />
          <span
            :if={!@selected_conversation.avatar_user}
            class="flex size-11 shrink-0 items-center justify-center rounded-full bg-primary/15 text-primary"
          >
            <.icon name="hero-user-group" class="size-5" />
          </span>
          <div class="min-w-0">
            <h2 class="truncate text-lg font-semibold text-base-content">
              {conversation_title(@selected_conversation)}
            </h2>
            <p class="text-xs opacity-70">
              {@selected_conversation.message_count} messages
            </p>
          </div>
        </div>
        <div class="flex shrink-0 items-center gap-1">
          <button
            :if={call_peer_id(@selected_conversation)}
            id="start-call"
            phx-click="start_call"
            phx-value-id={call_peer_id(@selected_conversation)}
            phx-disable-with="Calling…"
            title="Start an encrypted audio/video call"
            class="rounded-full px-3 py-1.5 text-sm font-medium text-primary hover:bg-primary/10"
          >
            <.icon name="hero-phone" class="mr-1 inline size-4" /> Call
          </button>
          <.link
            :if={call_peer_id(@selected_conversation)}
            id="schedule-call"
            navigate={~p"/calls?friend_id=#{call_peer_id(@selected_conversation)}"}
            title="Schedule a call and reminder"
            class="rounded-full px-3 py-1.5 text-sm font-medium opacity-80 hover:bg-base-200 hover:opacity-100"
          >
            <.icon name="hero-calendar-days" class="mr-1 inline size-4" /> Schedule
          </.link>
          <button
            id="archive-conversation"
            phx-click="archive_conversation"
            phx-value-key={@selected_conversation.key}
            class="rounded-full px-3 py-1.5 text-sm font-medium opacity-80 hover:bg-base-200 hover:opacity-100"
          >
            <.icon name="hero-archive-box" class="mr-1 inline size-4" /> Archive
          </button>
        </div>
      </div>

      <div
        id={"thread-#{@selected_conversation.key}"}
        phx-hook="ScrollBottom"
        data-has-more={@has_more_messages}
        class="messages-thread min-h-[26rem] flex-1 space-y-3 overflow-y-auto px-4 py-4 sm:px-6 lg:min-h-0"
      >
        <div class="py-2 text-center">
          <button
            :if={@has_more_messages}
            id="load-more-messages"
            type="button"
            phx-click="load_more_messages"
            data-role="load-more-messages"
            class="rounded-full bg-base-100 px-3 py-1.5 text-xs font-medium opacity-70 shadow-sm ring-1 ring-base-300 hover:bg-base-200 hover:opacity-100"
          >
            Load earlier messages
          </button>
          <span :if={!@has_more_messages} class="text-xs opacity-50">
            Beginning of loaded history
          </span>
        </div>
        <.message_bubble
          :for={envelope <- @selected_conversation.envelopes}
          envelope={envelope}
          user={@current_scope.user}
          mine={envelope.sender_id == @current_scope.user.id}
          profile_click="open_profile"
        />
        <div data-role="thread-end" aria-hidden="true" class="h-px shrink-0" />
      </div>

      <section class="messages-composer-dock sticky bottom-0 z-20 border-t border-base-300 bg-base-100/90 p-3 shadow-[0_-8px_24px_rgba(0,0,0,0.06)] backdrop-blur">
        <.composer
          id="message-composer"
          user={@current_scope.user}
          friends={@friends}
          groups={@groups}
          kind="message"
          surface="messages"
          show_recipients={false}
          selected_friend_ids={selected_friend_ids(@selected_conversation)}
          selected_self={selected_self?(@selected_conversation)}
          draft_key={@selected_conversation.key}
          submit_label={composer_submit_label(@selected_conversation)}
        />
      </section>
    </div>
    """
  end

  @doc """
  Shown when no conversation is selected: composer plus a prompt.
  """
  attr :selected_conversation, :any, default: nil
  attr :selected_recipient, :any, default: nil
  attr :self_notes, :boolean, required: true
  attr :friends, :list, required: true
  attr :groups, :list, required: true
  attr :current_scope, :map, required: true

  def empty_state(assigns) do
    ~H"""
    <div
      :if={!@selected_conversation && !@self_notes}
      data-composer-dropzone
      data-drop-label="Drop to attach"
      class="relative flex flex-1 flex-col justify-end"
    >
      <div class="messages-empty-state mx-auto max-w-xl px-6 py-12 text-center">
        <.user_avatar
          :if={selected_recipient_user(@selected_recipient)}
          id="selected-recipient-avatar"
          user={selected_recipient_user(@selected_recipient)}
          class="mx-auto mb-4 size-16 text-lg"
          on_click="open_profile"
        />
        <div
          :if={!selected_recipient_user(@selected_recipient)}
          class="mx-auto mb-4 flex size-14 items-center justify-center rounded-full bg-primary/15 text-xl font-semibold text-primary"
        >
          {selected_recipient_initials(@selected_recipient)}
        </div>
        <h2 class="text-xl font-semibold text-base-content">
          {selected_recipient_title(@selected_recipient)}
        </h2>
        <p class="mt-2 text-sm opacity-70">
          {selected_recipient_subtitle(@selected_recipient)}
        </p>
      </div>
      <section class="border-t border-base-300 bg-base-100/90 p-3 backdrop-blur">
        <.composer
          id="message-composer"
          user={@current_scope.user}
          friends={@friends}
          groups={@groups}
          kind={if(is_nil(@selected_recipient), do: "self_note", else: "message")}
          surface="messages"
          show_recipients={false}
          selected_self={selected_recipient_self?(@selected_recipient)}
          selected_friend_ids={selected_recipient_friend_ids(@selected_recipient)}
          selected_group_ids={selected_recipient_group_ids(@selected_recipient)}
          draft_key={
            if(is_nil(@selected_recipient),
              do: "self-notes-new",
              else: "new-#{selected_recipient_title(@selected_recipient)}"
            )
          }
          text_placeholder={
            if(is_nil(@selected_recipient), do: "Take a note…", else: "Write a message…")
          }
          submit_label={if(is_nil(@selected_recipient), do: "Save note", else: "Send")}
        />
      </section>
    </div>
    """
  end

  ## Presentation helpers
  def selected_friend_ids(%{reply_ids: reply_ids}) do
    reply_ids
    |> String.split(",", trim: true)
  end

  def selected_self?(%{participants: ["notes to yourself"]}), do: true
  def selected_self?(_), do: false

  def selected_recipient_self?(nil), do: true
  def selected_recipient_self?(%{include_self: include_self}), do: include_self
  def selected_recipient_self?(_), do: false

  def selected_recipient_friend_ids(%{friend_ids: friend_ids}), do: friend_ids
  def selected_recipient_friend_ids(_), do: []

  def selected_recipient_group_ids(%{group_ids: group_ids}), do: group_ids
  def selected_recipient_group_ids(_), do: []

  def selected_recipient_title(%{title: title}), do: title
  def selected_recipient_title(_), do: "Notes to yourself"

  def selected_recipient_subtitle(%{subtitle: subtitle}), do: subtitle
  def selected_recipient_subtitle(_), do: "Send an encrypted message to this account."

  def selected_recipient_initials(%{initials: initials}), do: initials
  def selected_recipient_initials(_), do: "ME"

  def selected_recipient_user(%{user: user}), do: user
  def selected_recipient_user(_), do: nil

  def profile_note(_notes, nil), do: ""
  def profile_note(notes, profile), do: Map.get(notes, profile.id, "")

  def profile_editable?(_friends, nil), do: false
  def profile_editable?(friends, profile), do: Enum.any?(friends, &(&1.id == profile.id))

  def profile_note_error(%Ecto.Changeset{errors: [{_field, {message, _}} | _]}), do: message
  def profile_note_error(_changeset), do: "Could not save that note."

  def composer_submit_label(_conversation), do: "Send"

  # A call button appears only on 1:1 conversations with a single friend.
  def call_peer_id(%{reply_ids: reply_ids, participants: participants}) do
    case {String.split(reply_ids, ",", trim: true), participants} do
      {[single_friend_id], [_single_participant]} -> single_friend_id
      _ -> nil
    end
  end

  def call_peer_id(_conversation), do: nil

  def group_initials(group) do
    group.name
    |> initials()
  end

  def display_name(user), do: user.display_name || user.username || Social.Address.handle(user)

  def conversation_initials(%{participants: participants}) do
    participants
    |> Enum.take(2)
    |> Enum.map_join("", fn participant ->
      participant
      |> String.trim_leading("@")
      |> String.first()
      |> case do
        nil -> "?"
        initial -> String.upcase(initial)
      end
    end)
  end

  def initials(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", fn word ->
      word
      |> String.trim_leading("@")
      |> String.first()
      |> case do
        nil -> "?"
        initial -> String.upcase(initial)
      end
    end)
    |> case do
      "" -> "?"
      result -> result
    end
  end

  def conversation_title(conversation) do
    title = Enum.join(conversation.participants, ", ")

    if conversation.preserved do
      "#{title} · #{Calendar.strftime(conversation.started_at, "%b %d, %Y")}"
    else
      title
    end
  end
end
