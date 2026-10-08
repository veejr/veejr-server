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

  alias Veejr.{Presence, Social}
  alias Phoenix.LiveView.JS

  use Phoenix.VerifiedRoutes,
    endpoint: VeejrWeb.Endpoint,
    router: VeejrWeb.Router,
    statics: VeejrWeb.static_paths()

  @doc """
  The page bar: back, title, New conversation, and a settings gear.
  """
  attr :conversations, :list, required: true
  attr :friends, :list, required: true
  attr :groups, :list, required: true
  attr :self_notes, :boolean, required: true

  def page_header(assigns) do
    ~H"""
    <%!-- One bar that is always there: where you are, the one thing most people
          come here to do, and a gear for everything else. Settings used to sit
          behind two nested disclosures, so starting a conversation took four
          clicks and the page opened as a title and the word "Expand". --%>
    <div class="messages-page-header relative z-20 rounded-t-[31px] border-b border-base-300 bg-base-100">
      <div
        id="messages-page-header"
        aria-label="Messages header"
        class="flex items-center gap-2 px-3 py-2.5 sm:gap-3 sm:px-4"
      >
        <.link
          id="back-to-contacts"
          navigate={~p"/contacts"}
          title="Back to contacts"
          aria-label="Back to contacts"
          class="btn btn-ghost btn-sm btn-circle shrink-0 text-base-content/65 hover:text-primary"
        >
          <.icon name="hero-arrow-left" class="size-5" />
        </.link>

        <div id="messages-page-header-title" class="min-w-0 flex-1">
          <h1 class="truncate text-lg leading-tight font-semibold tracking-tight text-base-content">
            {if(@self_notes, do: "Notes to yourself", else: "Messages")}
          </h1>
          <p class="hidden truncate text-xs text-base-content/60 sm:block">
            {if(@self_notes,
              do: "Private, end-to-end encrypted notes",
              else: "End-to-end encrypted conversations"
            )}
          </p>
        </div>

        <.conversation_builder
          id="messages-conversation-builder"
          form_id="messages-conversation-builder-form"
          conversations={@conversations}
          friends={@friends}
          groups={@groups}
          phx-click-away={JS.remove_attribute("open")}
        />

        <%!-- Settings: the things you set once, not the things you do. Closes
              on a click elsewhere or Escape, like any menu. --%>
        <details
          id="messages-tools"
          class="group dropdown dropdown-end shrink-0"
          aria-label="Message settings"
          phx-click-away={JS.remove_attribute("open")}
          phx-window-keydown={JS.remove_attribute("open", to: "#messages-tools")}
          phx-key="Escape"
        >
          <summary
            id="messages-tools-toggle"
            aria-label="Settings"
            title="Settings"
            class="btn btn-ghost btn-sm btn-circle list-none text-base-content/65 transition hover:text-primary group-open:text-primary [&::-webkit-details-marker]:hidden"
          >
            <.icon name="hero-cog-6-tooth" class="size-5" />
          </summary>

          <div
            id="messages-tools-content"
            class="app-menu-surface dropdown-content z-40 mt-2 w-[min(21rem,calc(100vw-2rem))] space-y-4 rounded-2xl border p-4 shadow-lg"
          >
            <section id="messages-appearance-tool" aria-labelledby="messages-appearance-title">
              <h2
                id="messages-appearance-title"
                class="mb-2 flex items-center gap-2 text-xs font-semibold tracking-wide uppercase opacity-70"
              >
                <.icon name="hero-swatch" class="size-4" /> Appearance
              </h2>
              <div
                id="chat-theme-picker"
                class="chat-theme-picker grid grid-cols-2 gap-1 rounded-2xl border border-base-300 bg-base-200 p-1.5"
                role="group"
                aria-label="Chat appearance"
              >
                <button
                  :for={
                    {id, label} <- [
                      classic: "Classic",
                      salon: "Salon",
                      party: "Party",
                      comic: "Comic"
                    ]
                  }
                  id={"chat-theme-#{id}"}
                  type="button"
                  data-chat-theme-option={id}
                  aria-pressed={to_string(id == :classic)}
                  class="chat-theme-option justify-start"
                >
                  <span class="chat-theme-swatch" aria-hidden="true"></span>
                  <span>{label}</span>
                </button>
              </div>
            </section>

            <div
              :if={@self_notes}
              id="self-notes-settings-section"
              class="space-y-4 border-t border-base-300 pt-3"
            >
              <section id="self-notes-date-filters" aria-labelledby="self-notes-date-title">
                <h2
                  id="self-notes-date-title"
                  class="mb-2 flex items-center gap-2 text-xs font-semibold tracking-wide uppercase opacity-70"
                >
                  <.icon name="hero-calendar-days" class="size-4" /> Filter by updated date
                </h2>
                <div class="grid grid-cols-2 gap-2 text-xs">
                  <label class="flex items-center gap-2 rounded-lg border border-base-300 bg-base-100 px-2 py-1.5">
                    <span class="text-base-content/55">From</span>
                    <input
                      id="self-notes-date-from"
                      data-role="date-from"
                      type="date"
                      class="min-w-0 flex-1 bg-transparent text-base-content outline-none"
                    />
                  </label>
                  <label class="flex items-center gap-2 rounded-lg border border-base-300 bg-base-100 px-2 py-1.5">
                    <span class="text-base-content/55">To</span>
                    <input
                      id="self-notes-date-to"
                      data-role="date-to"
                      type="date"
                      class="min-w-0 flex-1 bg-transparent text-base-content outline-none"
                    />
                  </label>
                </div>
                <div class="mt-2 flex flex-wrap items-center gap-1 text-xs">
                  <button
                    :for={
                      {days, label} <- [
                        {"0", "Today"},
                        {"7", "Last 7 days"},
                        {"30", "Last 30 days"}
                      ]
                    }
                    data-role="date-preset"
                    data-days={days}
                    type="button"
                    class="rounded-lg px-2.5 py-1.5 font-medium text-base-content/60 transition hover:bg-base-200 hover:text-base-content aria-[pressed=true]:bg-primary/10 aria-[pressed=true]:text-primary"
                    aria-pressed="false"
                  >
                    {label}
                  </button>
                  <button
                    data-role="clear-dates"
                    type="button"
                    class="ml-auto rounded-lg px-2.5 py-1.5 font-medium text-base-content/50 transition hover:bg-base-200 hover:text-base-content"
                  >
                    Clear
                  </button>
                </div>
              </section>

              <div class="space-y-1 border-t border-base-300 pt-3">
                <button
                  id="self-notes-import"
                  type="button"
                  class="flex w-full items-center gap-3 rounded-xl px-2 py-2 text-left text-sm font-medium transition hover:bg-base-200"
                  phx-click={
                    JS.dispatch("self-notes:import", to: "#self-notes-board")
                    |> JS.remove_attribute("open", to: "#messages-tools")
                  }
                >
                  <span class="flex size-8 items-center justify-center rounded-lg bg-base-200 text-base-content/60">
                    <.icon name="hero-arrow-down-tray" class="size-4" />
                  </span>
                  <span>
                    <span class="block">Import notes</span>
                    <span class="block text-xs font-normal text-base-content/55">
                      From a Google Keep export (.zip)
                    </span>
                  </span>
                </button>
                <button
                  data-role="delete-trashed"
                  type="button"
                  disabled
                  class="w-full rounded-lg px-2 py-2 text-left text-xs font-semibold text-error transition hover:bg-error/10 disabled:hidden"
                >
                  Delete all trashed forever
                </button>
              </div>
            </div>

            <div class="border-t border-base-300 pt-3">
              <.link
                id="messages-invite-person"
                navigate={~p"/invites/new"}
                class="flex items-center gap-3 rounded-xl px-2 py-2 text-sm font-medium transition hover:bg-base-200"
              >
                <span class="flex size-8 items-center justify-center rounded-lg bg-base-200 text-base-content/60">
                  <.icon name="hero-qr-code" class="size-4" />
                </span>
                <span class="min-w-0">
                  <span class="block">Invite a person</span>
                  <span class="block text-xs font-normal text-base-content/55">
                    Share a link or QR code
                  </span>
                </span>
              </.link>
            </div>
          </div>
        </details>
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
  attr :presence, :map, default: %{}

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
          <span :if={conv.avatar_user} class="relative inline-flex shrink-0">
            <.user_avatar
              id={"rail-conversation-avatar-#{conv.key}"}
              user={conv.avatar_user}
              class="size-10 text-sm"
              on_click="open_profile"
            />
            <.presence_dot state={Map.get(@presence, conv.avatar_user.id, :unknown)} />
          </span>
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
            <span class="relative inline-flex shrink-0">
              <.user_avatar
                id={"message-friend-avatar-#{friend.id}"}
                user={friend}
                class="size-10 text-sm"
                on_click="open_profile"
              />
              <.presence_dot
                id={"start-friend-presence-#{friend.id}"}
                state={Map.get(@presence, friend.id, :unknown)}
              />
            </span>
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
  Who a note can be sent to as a message, as JSON for the notes board.

  Only what the server already knows — names and ids of the viewer's own
  friends and groups. The browser resolves and seals for them exactly as the
  composer does.
  """
  def send_targets(friends, groups) do
    people =
      Enum.map(friends, fn friend ->
        %{type: "friend", id: friend.id, label: friend.display_name || "@#{friend.username}"}
      end)

    circles = Enum.map(groups, fn group -> %{type: "group", id: group.id, label: group.name} end)

    Jason.encode!(people ++ circles)
  end

  @doc """
  Notes to yourself: encrypted cards the browser decrypts locally. Rendered instead of a conversation thread when @self_notes is set.
  """
  attr :self_notes, :boolean, required: true
  attr :self_note_envelopes, :list, required: true
  attr :has_more_self_notes, :boolean, required: true
  attr :current_scope, :map, required: true
  attr :friends, :list, default: []
  attr :groups, :list, default: []

  def self_notes_pane(assigns) do
    assigns = assign(assigns, :send_targets, send_targets(assigns.friends, assigns.groups))

    ~H"""
    <div :if={@self_notes} class="flex min-h-0 flex-1 flex-col">
      <div
        id="self-notes-pane-header"
        class="border-b border-base-300 bg-base-100 px-3 py-3 sm:px-5"
      >
        <%!-- Everything for finding, making and filtering notes, in one place
              and one glance. Search is the main way in, so it gets the room;
              what you set once (date range, import, clearing the trash) is
              behind the gear. The wrapper keeps its old id because the board
              looks its controls up under it. --%>
        <div
          id="self-notes-command-center"
          aria-label="Search, create and filter notes"
          class="space-y-3"
        >
          <div class="flex items-center gap-2 sm:gap-3">
            <div
              id="self-notes-search-bar"
              class="flex min-w-0 flex-1 items-center rounded-2xl border border-base-300 bg-base-100 shadow-sm transition focus-within:border-primary/50 focus-within:ring-2 focus-within:ring-primary/20"
            >
              <label class="group/search flex min-w-0 flex-1 items-center gap-3 px-4 py-3">
                <.icon
                  name="hero-magnifying-glass"
                  class="size-5 shrink-0 text-base-content/45 transition group-focus-within/search:text-primary"
                />
                <input
                  id="self-notes-search"
                  data-role="search"
                  type="search"
                  placeholder="Search notes"
                  aria-label="Search notes"
                  class="min-w-0 flex-1 bg-transparent text-base text-base-content outline-none placeholder:text-base-content/40"
                />
                <kbd class="hidden rounded-lg border border-base-300 bg-base-200 px-2 py-1 text-[0.65rem] font-semibold text-base-content/55 sm:block">
                  /
                </kbd>
              </label>
            </div>

            <%!-- A note is what most people make, so that is the button; the
                  other things you can make are one click further. --%>
            <div class="join shrink-0">
              <button
                id="self-notes-new"
                type="button"
                title="New note (C)"
                class="btn btn-primary join-item"
                phx-click={JS.dispatch("self-notes:new", to: "#self-notes-board")}
              >
                <.icon name="hero-plus" class="size-5" />
                <span class="max-sm:sr-only">New note</span>
              </button>
              <details
                id="self-notes-new-menu"
                class="dropdown dropdown-end join-item"
                phx-click-away={JS.remove_attribute("open")}
                phx-window-keydown={JS.remove_attribute("open", to: "#self-notes-new-menu")}
                phx-key="Escape"
              >
                <summary
                  aria-label="More things to create"
                  title="Spreadsheet or document"
                  class="btn btn-primary list-none px-2 [&::-webkit-details-marker]:hidden"
                >
                  <.icon name="hero-chevron-down" class="size-4" />
                </summary>
                <div class="app-menu-surface dropdown-content z-40 mt-2 w-60 rounded-2xl border p-2 shadow-lg">
                  <button
                    id="self-notes-new-sheet"
                    data-role="new-sheet"
                    type="button"
                    phx-click={JS.remove_attribute("open", to: "#self-notes-new-menu")}
                    class="flex w-full items-center gap-3 rounded-xl px-3 py-2 text-left text-sm transition hover:bg-base-200"
                  >
                    <.icon name="hero-table-cells" class="size-5 shrink-0 text-base-content/60" />
                    <span>
                      <span class="block font-semibold">Spreadsheet</span>
                      <span class="block text-xs text-base-content/55">Grid with formulas</span>
                    </span>
                  </button>
                  <button
                    id="self-notes-new-page"
                    data-role="new-page"
                    type="button"
                    phx-click={JS.remove_attribute("open", to: "#self-notes-new-menu")}
                    class="flex w-full items-center gap-3 rounded-xl px-3 py-2 text-left text-sm transition hover:bg-base-200"
                  >
                    <.icon name="hero-document-text" class="size-5 shrink-0 text-base-content/60" />
                    <span>
                      <span class="block font-semibold">Document</span>
                      <span class="block text-xs text-base-content/55">
                        Headings, lists, formatting
                      </span>
                    </span>
                  </button>
                </div>
              </details>
            </div>
          </div>

          <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
            <div
              class="flex flex-wrap items-center gap-1 rounded-xl bg-base-200/75 p-1"
              role="tablist"
              aria-label="Note filters"
            >
              <button
                :for={
                  {filter, label} <- [
                    {"active", "Notes"},
                    {"reminders", "Reminders"},
                    {"archived", "Archive"},
                    {"trashed", "Trash"}
                  ]
                }
                data-role="filter"
                id={"self-notes-filter-#{filter}"}
                data-filter={filter}
                type="button"
                class="rounded-lg px-3 py-1.5 text-xs font-semibold text-base-content/60 transition hover:text-base-content aria-[pressed=true]:bg-base-100 aria-[pressed=true]:text-base-content aria-[pressed=true]:shadow-sm"
                aria-pressed={to_string(filter == "active")}
              >
                {label}
              </button>
            </div>

            <div class="ml-auto flex items-center gap-2">
              <label
                for="self-notes-sort"
                class="flex shrink-0 items-center gap-1.5 rounded-xl border border-base-300 bg-base-100 px-2 text-base-content/60 transition focus-within:border-primary focus-within:text-primary"
              >
                <.icon name="hero-arrows-up-down" class="size-4" />
                <span class="sr-only">Sort notes by</span>
                <select
                  id="self-notes-sort"
                  data-role="sort"
                  aria-label="Sort notes by"
                  class="h-8 max-w-32 bg-transparent pr-1 text-xs font-semibold text-base-content outline-none sm:max-w-none"
                >
                  <option value="updated" selected>Last edited</option>
                  <option value="created">Creation date</option>
                  <option value="title">Title</option>
                </select>
              </label>

              <div
                class="flex items-center gap-1 rounded-xl bg-base-200/75 p-1"
                role="group"
                aria-label="Note layout"
              >
                <button
                  :for={
                    {view, label, icon} <- [
                      {"grid", "Grid view", "hero-squares-2x2"},
                      {"list", "List view", "hero-list-bullet"},
                      {"timeline", "Timeline view", "hero-clock"},
                      {"postit", "Sticky note view", "hero-rectangle-group"}
                    ]
                  }
                  id={"self-notes-view-#{view}"}
                  data-role="view"
                  data-view={view}
                  type="button"
                  title={label}
                  aria-label={label}
                  class="rounded-lg p-1.5 text-base-content/50 transition hover:text-base-content aria-[pressed=true]:bg-base-100 aria-[pressed=true]:text-base-content aria-[pressed=true]:shadow-sm"
                  aria-pressed={to_string(view == "grid")}
                >
                  <.icon name={icon} class="size-4" />
                </button>
              </div>
            </div>
          </div>

          <div
            id="self-notes-labels"
            data-role="labels"
            class="flex flex-wrap gap-1 [&:not(:has(*))]:hidden"
          >
          </div>
          <p
            id="self-notes-filter-status"
            data-role="filter-status"
            class="hidden text-xs text-base-content/55"
            aria-live="polite"
          >
          </p>
        </div>
      </div>
      <div
        id="self-notes-board"
        phx-hook="SelfNotesBoard"
        data-user-id={@current_scope.user.id}
        data-peer-key={@current_scope.user.public_key}
        data-send-targets={@send_targets}
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
          <span data-note-icon="reminder"><.icon name="hero-clock" class="size-4" /></span>
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
        <p
          id="self-notes-reminders-empty"
          data-role="reminders-empty"
          class="hidden mb-4 text-sm opacity-70"
        >
          No reminders match this view. Use “Remind me” on a note or document to set one.
        </p>
        <div
          id="self-notes-reminder-notice"
          data-role="reminder-notice"
          phx-update="ignore"
          role="status"
          class="hidden mb-4 rounded-xl border border-primary/30 bg-primary/10 p-3 text-sm"
        >
          A note reminder is due.
          <button
            id="self-notes-show-reminders"
            data-role="show-reminders"
            type="button"
            class="ml-2 rounded-lg px-2 py-1 font-semibold text-primary transition hover:bg-primary/10"
          >
            View reminders
          </button>
        </div>
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
  attr :presence, :map, default: %{}

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
          <span :if={@selected_conversation.avatar_user} class="relative inline-flex shrink-0">
            <.user_avatar
              user={@selected_conversation.avatar_user}
              class="size-11 text-sm"
              on_click="open_profile"
            />
            <.presence_dot
              id="thread-peer-presence"
              state={thread_presence(@presence, @selected_conversation)}
            />
          </span>
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
            <p class="flex items-center gap-1.5 text-xs opacity-70">
              <span>{@selected_conversation.message_count} messages</span>
              <%!-- The header has room for words, so say it rather than
                    making the dot carry the whole meaning. --%>
              <span :if={presence_visible?(@presence, @selected_conversation)}>
                · {Presence.label(thread_presence(@presence, @selected_conversation))}
              </span>
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
        class="messages-thread min-h-0 flex-1 space-y-3 overflow-y-auto px-4 py-4 sm:px-6"
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
      <section class="messages-composer-dock sticky bottom-0 z-20 border-t border-base-300 bg-base-100/90 p-3 shadow-[0_-8px_24px_rgba(0,0,0,0.06)] backdrop-blur">
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

  # Presence belongs to a person, so a group thread never has one.
  def thread_presence(presence, %{avatar_user: %{id: id}}), do: Map.get(presence, id, :unknown)
  def thread_presence(_presence, _conversation), do: :unknown

  # The dot still shows for offline; only a live state earns words in the
  # header, where "Offline" next to every quiet thread would just be nagging.
  def presence_visible?(presence, conversation) do
    presence |> thread_presence(conversation) |> Presence.visible?()
  end

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
