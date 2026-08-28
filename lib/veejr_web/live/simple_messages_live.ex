defmodule VeejrWeb.SimpleMessagesLive do
  @moduledoc """
  Messages reduced to what a message is: a face, a name, and the words.

  Two screens, never both: the list of conversations, and one open thread.
  There are no bubbles, no rail, no bulk actions, and no tools — the full page
  at `/messages` keeps all of that, along with notes to yourself, archiving,
  attachments, scheduling, and editing.

  What it does keep is the consent step, because a message nobody accepted is
  never delivered, and a simple page that silently dropped mail would be a
  broken one. Text is still decrypted in the browser by the `Decrypt` hook and
  still encrypted there by the `Composer` hook; the server sees ciphertext on
  this page exactly as it does on the other.
  """
  use VeejrWeb, :live_view

  import VeejrWeb.MessagingComponents, only: [composer: 1]

  alias Veejr.Accounts.User
  alias Veejr.Messaging.Envelope
  alias Veejr.{Messaging, Presence, Social}

  @message_limit 100

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      pending_count={@pending_count}
      main_class="flex min-h-0 flex-1 flex-col"
      main_padding_class=""
      container_class="mx-auto flex h-full min-h-0 w-full max-w-2xl flex-col"
    >
      <section
        :if={@pending != []}
        id="simple-pending"
        class="mt-4 space-y-2 rounded-2xl border border-primary/30 bg-primary/5 p-3"
      >
        <p
          :for={notification <- @pending}
          id={"simple-pending-#{notification.id}"}
          class="flex flex-wrap items-center gap-2 text-sm"
        >
          <span class="min-w-0 flex-1">
            <span class="font-medium">
              {Social.Address.handle(notification.envelope.sender)}
            </span>
            sent you an encrypted message.
          </span>
          <button
            id={"simple-accept-#{notification.id}"}
            phx-click="request_notification"
            phx-value-id={notification.id}
            class="btn btn-primary btn-xs"
          >
            Accept
          </button>
          <button
            id={"simple-decline-#{notification.id}"}
            phx-click="decline_notification"
            phx-value-id={notification.id}
            class="btn btn-ghost btn-xs"
          >
            Decline
          </button>
        </p>
      </section>

      <div :if={@thread} class="flex min-h-0 flex-1 flex-col">
        <header class="flex items-center gap-3 border-b border-base-300 py-3">
          <.link
            id="simple-back"
            navigate={~p"/messages/simple"}
            title="All conversations"
            aria-label="All conversations"
            class="flex size-9 shrink-0 items-center justify-center rounded-full transition hover:bg-base-200"
          >
            <.icon name="hero-arrow-left" class="size-5" />
          </.link>
          <span :if={@thread.avatar_user} class="relative inline-flex shrink-0">
            <.user_avatar user={@thread.avatar_user} class="size-10 text-sm" ring={false} />
            <.presence_dot
              id="simple-thread-presence"
              state={Map.get(@presence, @thread.avatar_user.id, :unknown)}
            />
          </span>
          <span
            :if={!@thread.avatar_user}
            class="flex size-10 shrink-0 items-center justify-center rounded-full bg-primary/15 text-primary"
          >
            <.icon name="hero-user-group" class="size-5" />
          </span>
          <h1 class="min-w-0 flex-1 truncate text-base font-semibold">{@thread.title}</h1>
        </header>

        <div
          id={"simple-thread-#{@thread.key}"}
          phx-hook="ScrollBottom"
          data-has-more={@thread.has_more}
          class="min-h-0 flex-1 space-y-5 overflow-y-auto py-5"
        >
          <div :if={@thread.has_more} class="text-center">
            <button
              id="simple-load-more"
              type="button"
              data-role="load-more-messages"
              phx-click="load_more_messages"
              class="rounded-full px-3 py-1.5 text-xs font-medium opacity-70 ring-1 ring-base-300 transition hover:bg-base-200 hover:opacity-100"
            >
              Load earlier messages
            </button>
          </div>
          <p
            :if={@thread.envelopes == []}
            id="simple-thread-empty"
            class="py-10 text-center text-sm opacity-60"
          >
            No messages yet.
          </p>
          <.message
            :for={envelope <- @thread.envelopes}
            envelope={envelope}
            user={@current_scope.user}
          />
          <div data-role="thread-end" aria-hidden="true" class="h-px shrink-0" />
        </div>

        <div class="border-t border-base-300 py-3">
          <%!-- A line to type in and a paper clip that opens the rest:
                files, voice, video. Expiry, display limits and send-later
                stay on the full page. --%>
          <.composer
            id="simple-message-composer"
            user={@current_scope.user}
            friends={@friends}
            groups={[]}
            kind="message"
            surface="messages"
            show_recipients={false}
            files_layout="menu"
            show_options={false}
            selected_friend_ids={@thread.friend_ids}
            draft_key={"simple-#{@thread.key}"}
            text_placeholder="Write a message…"
          />
        </div>
      </div>

      <div :if={!@thread} class="flex min-h-0 flex-1 flex-col py-6">
        <header class="flex flex-wrap items-center justify-between gap-4">
          <h1 class="text-lg font-semibold leading-8">Messages</h1>
        </header>

        <p
          :if={@conversations == []}
          id="simple-conversations-empty"
          class="mt-8 rounded-2xl border border-dashed border-base-300 p-12 text-center text-sm opacity-70"
        >
          No conversations yet.
          <.link navigate={~p"/contacts/simple"} class="link link-primary">Pick a contact</.link>
          to write to.
        </p>

        <ul
          :if={@conversations != []}
          id="simple-conversations"
          class="mt-4 min-h-0 flex-1 divide-y divide-base-300 overflow-y-auto"
        >
          <li :for={conversation <- @conversations}>
            <.link
              id={"simple-conversation-#{conversation.key}"}
              navigate={~p"/messages/simple?conversation=#{conversation.key}"}
              class="flex items-center gap-3 rounded-2xl px-2 py-3 transition hover:bg-base-200 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
            >
              <.user_avatar
                :if={conversation.avatar_user}
                user={conversation.avatar_user}
                class="size-11 text-sm"
                ring={false}
              />
              <span
                :if={!conversation.avatar_user}
                class="flex size-11 shrink-0 items-center justify-center rounded-full bg-primary/15 text-primary"
              >
                <.icon name="hero-user-group" class="size-5" />
              </span>
              <span class="min-w-0 flex-1">
                <span class="flex items-baseline gap-2">
                  <span class="min-w-0 flex-1 truncate font-medium">{conversation.title}</span>
                  <span class="shrink-0 text-xs opacity-50">
                    {Calendar.strftime(conversation.latest_at, "%b %d")}
                  </span>
                </span>
                <span
                  id={"simple-preview-#{conversation.key}"}
                  phx-hook="ConversationPreview"
                  phx-update="ignore"
                  data-user-id={@current_scope.user.id}
                  data-peer-key={Messaging.peer_key(conversation.latest, @current_scope.user)}
                  data-ciphertext={conversation.latest.ciphertext}
                  data-nonce={conversation.latest.nonce}
                  data-kind={conversation.latest.kind}
                  class="mt-0.5 block truncate text-sm opacity-70"
                >
                  <span class="loading loading-dots loading-xs"></span>
                </span>
              </span>
              <span
                :if={conversation.unread_count > 0}
                class="badge badge-primary badge-sm shrink-0"
              >
                {conversation.unread_count}
              </span>
            </.link>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end

  attr :envelope, Envelope, required: true, doc: "sender preloaded"
  attr :user, User, required: true

  defp message(assigns) do
    assigns = assign(assigns, :mine, assigns.envelope.sender_id == assigns.user.id)

    ~H"""
    <div
      id={"message-shell-#{@envelope.public_id}"}
      data-message-mine={to_string(@mine)}
      class="flex gap-3"
    >
      <.user_avatar user={@envelope.sender} class="mt-0.5 size-9 text-xs" ring={false} />
      <div class="min-w-0 flex-1">
        <p class="flex items-baseline gap-2">
          <span class="min-w-0 truncate text-sm font-semibold">
            {if(@mine, do: "You", else: sender_name(@envelope.sender))}
          </span>
          <time
            datetime={DateTime.to_iso8601(@envelope.inserted_at)}
            class="shrink-0 text-xs opacity-50"
          >
            {Calendar.strftime(@envelope.inserted_at, "%b %d, %H:%M")} UTC
          </time>
        </p>
        <%!-- Filled in by the browser; the server never holds the plaintext. --%>
        <div
          id={"env-#{@envelope.public_id}"}
          phx-hook="Decrypt"
          phx-update="ignore"
          data-user-id={@user.id}
          data-peer-key={Messaging.peer_key(@envelope, @user)}
          data-ciphertext={@envelope.ciphertext}
          data-nonce={@envelope.nonce}
          data-kind={@envelope.kind}
          data-public-id={@envelope.public_id}
          data-expires-at={@envelope.expires_at && DateTime.to_iso8601(@envelope.expires_at)}
          class="mt-0.5 text-[0.95rem] leading-relaxed"
        >
          <span class="loading loading-dots loading-xs"></span>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Messages",
       selection: nil,
       message_limit: @message_limit
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply,
     socket
     |> assign(:selection, selection(params))
     |> assign(:message_limit, @message_limit)
     |> refresh()
     |> scroll_to_bottom()}
  end

  @impl true
  def handle_event("request_notification", %{"id" => id}, socket) do
    case Messaging.accept_notification(socket.assigns.current_scope.user, id) do
      {:ok, _notification} ->
        {:noreply, refresh(socket)}

      {:error, :origin_unreachable} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The sender's instance is unreachable right now — try again later."
         )}

      {:error, _reason} ->
        {:noreply, socket |> put_flash(:error, "Notification not found.") |> refresh()}
    end
  end

  def handle_event("decline_notification", %{"id" => id}, socket) do
    Messaging.decline_notification(socket.assigns.current_scope.user, id)
    {:noreply, refresh(socket)}
  end

  def handle_event("load_more_messages", _params, socket) do
    limit = socket.assigns.message_limit + @message_limit
    {:noreply, socket |> assign(:message_limit, limit) |> refresh()}
  end

  def handle_event("resolve_recipients", params, socket) do
    {:reply, VeejrWeb.RecipientResolver.resolve(socket.assigns.current_scope.user, params),
     socket}
  end

  def handle_event("send_batch", %{"kind" => kind, "envelopes" => envelopes} = params, socket) do
    opts = Map.take(params, ["attachment_ids", "client_batch_id"])

    case Messaging.send_batch(socket.assigns.current_scope.user, kind, envelopes, opts) do
      {:ok, _batch_id, _queued} ->
        {:reply, %{ok: true}, refresh(socket)}

      {:error, _reason} ->
        {:reply, %{error: "Sending failed — are all recipients still your friends?"}, socket}
    end
  end

  # The `Decrypt` hook reports a read so display limits can be counted; a
  # message that has just spent its last display leaves the thread.
  def handle_event("message_displayed", %{"id" => public_id}, socket) do
    case Messaging.record_display(socket.assigns.current_scope.user, public_id) do
      {:ok, envelope}
      when is_integer(envelope.max_displays) and envelope.display_count >= envelope.max_displays ->
        {:reply, %{ok: true}, refresh(socket)}

      _ ->
        {:reply, %{ok: true}, socket}
    end
  end

  @impl true
  def handle_info({:veejr_notification, _notification}, socket), do: {:noreply, refresh(socket)}

  def handle_info({:veejr_schedule_released}, socket), do: {:noreply, refresh(socket)}

  def handle_info({:veejr_presence, user_id, state}, socket) do
    {:noreply, assign(socket, :presence, Map.put(socket.assigns.presence, user_id, state))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp selection(%{"friend" => id}), do: {:friend, id}
  # The full page's own links say friend_id, and the layout preference sends
  # them here unchanged rather than rewriting every caller.
  defp selection(%{"friend_id" => id}), do: {:friend, id}
  defp selection(%{"conversation" => key}), do: {:conversation, key}
  defp selection(_params), do: nil

  defp refresh(socket) do
    user = socket.assigns.current_scope.user
    friends = Social.list_friends(user)
    conversations = list_conversations(user, friends)
    thread = build_thread(user, friends, conversations, socket.assigns)

    # After reading, not before: the list is never on screen beside an open
    # thread, so its unread counts cannot go stale in view.
    if thread, do: :ok = Messaging.mark_conversation_read(user, thread.key)

    pending = Messaging.list_pending_notifications(user)

    assign(socket,
      friends: friends,
      conversations: conversations,
      thread: thread,
      pending: pending,
      pending_count: length(pending),
      presence: Presence.states(friends)
    )
  end

  # One row per thread this page can open: notes to yourself belong to the
  # board on the full page, and an archived conversation was already put away.
  defp list_conversations(user, friends) do
    by_handle = Map.new(friends, &{Social.Address.handle(&1), &1})
    archives = Messaging.list_thread_archives(user)

    user
    |> Messaging.list_conversation_summaries()
    |> Enum.reject(&(&1.participants == ["notes to yourself"]))
    |> Enum.reject(&match?(%{archived: true}, archives[&1.key]))
    |> Enum.map(fn summary ->
      people = Enum.map(summary.participants, &by_handle[&1])

      %{
        key: summary.key,
        title: Enum.map_join(summary.participants, ", ", &participant_name(by_handle, &1)),
        avatar_user: single_person(people),
        friend_ids: people |> Enum.reject(&is_nil/1) |> Enum.map(&to_string(&1.id)),
        unread_count: summary.unread_count,
        latest: summary.latest_envelope,
        latest_at: summary.latest_at
      }
    end)
  end

  # Both entry points end at a thread key. A contact tile carries a friend id
  # rather than a key because that friend may have no thread yet, and a
  # one-to-one key is derived from their handle — so the first message and a
  # years-old exchange open the same conversation.
  defp build_thread(user, friends, conversations, %{selection: {:friend, id}} = assigns) do
    case Enum.find(friends, &(to_string(&1.id) == to_string(id))) do
      nil ->
        nil

      friend ->
        key = Messaging.conversation_key([Social.Address.handle(friend)])

        conversations
        |> Enum.find(&(&1.key == key))
        |> case do
          nil ->
            %{
              key: key,
              title: sender_name(friend),
              avatar_user: friend,
              friend_ids: [to_string(friend.id)]
            }

          conversation ->
            conversation
        end
        |> load_envelopes(user, assigns.message_limit)
    end
  end

  defp build_thread(user, _friends, conversations, %{selection: {:conversation, key}} = assigns) do
    case Enum.find(conversations, &(&1.key == key)) do
      nil -> nil
      conversation -> load_envelopes(conversation, user, assigns.message_limit)
    end
  end

  defp build_thread(_user, _friends, _conversations, _assigns), do: nil

  defp load_envelopes(conversation, user, limit) do
    envelopes = Messaging.list_thread_envelopes(user, conversation.key, limit: limit)

    conversation
    |> Map.put(:envelopes, envelopes)
    |> Map.put(:has_more, length(envelopes) == limit)
  end

  defp scroll_to_bottom(socket) do
    case socket.assigns.thread do
      %{key: key} -> push_event(socket, "scroll_to_bottom", %{thread_id: "simple-thread-#{key}"})
      _ -> socket
    end
  end

  # A face only stands for a conversation when there is one other person in it.
  defp single_person([person]), do: person
  defp single_person(_people), do: nil

  defp participant_name(by_handle, handle) do
    case by_handle[handle] do
      nil -> handle
      friend -> sender_name(friend)
    end
  end

  defp sender_name(user), do: user.display_name || Social.Address.handle(user)
end
