defmodule VeejrWeb.MessagesLive do
  use VeejrWeb, :live_view

  # Page layout plus the presentation helpers that moved with it; imported so
  # event handlers below can still call them unqualified. The shared
  # MessagingComponents are now used from that module rather than here.
  import VeejrWeb.MessagesLive.Components

  alias Veejr.{Messaging, Presence, Social}
  alias Veejr.Messaging.Envelope
  alias VeejrWeb.ConversationLauncher

  @message_page_size 50

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      pending_count={@pending_count}
      main_class="flex min-h-0 flex-1 flex-col"
      main_padding_class=""
      container_class="mx-auto h-full min-h-0 w-full max-w-7xl"
    >
      <div
        id="messages-workspace"
        phx-hook="ChatTheme"
        data-chat-theme="classic"
        class="messages-workspace flex h-full min-h-0 flex-col rounded-[32px] border border-base-300 bg-base-200 shadow-sm"
      >
        <.page_header
          conversations={@conversations}
          friends={@friends}
          groups={@groups}
          self_notes={@self_notes}
        />

        <.new_message_celebration />

        <.consent_dialog pending={@pending} current_scope={@current_scope} />

        <section class="messages-layout flex min-h-0 flex-1 overflow-hidden rounded-b-[31px]">
          <.conversation_rail
            conversations={@conversations}
            selected_conversation_key={@selected_conversation_key}
            selected_recipient={@selected_recipient}
            bulk_selected_conversations={@bulk_selected_conversations}
            available_friends={@available_friends}
            available_groups={@available_groups}
            presence={@presence}
          />

          <main class="messages-main flex h-full min-h-0 min-w-0 flex-1 flex-col bg-base-200/80">
            <.self_notes_pane
              self_notes={@self_notes}
              self_note_envelopes={@self_note_envelopes}
              has_more_self_notes={@has_more_self_notes}
              current_scope={@current_scope}
            />

            <.conversation_thread
              selected_conversation={@selected_conversation}
              self_notes={@self_notes}
              has_more_messages={@has_more_messages}
              friends={@friends}
              groups={@groups}
              current_scope={@current_scope}
              presence={@presence}
            />

            <.empty_state
              selected_conversation={@selected_conversation}
              selected_recipient={@selected_recipient}
              self_notes={@self_notes}
              friends={@friends}
              groups={@groups}
              current_scope={@current_scope}
            />
          </main>
        </section>
      </div>

      <.profile_dialog
        user={@selected_profile}
        note={profile_note(@contact_notes, @selected_profile)}
        editable={profile_editable?(@friends, @selected_profile)}
      />
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Messages",
       selected_conversation_key: nil,
       selected_recipient_type: nil,
       selected_recipient_id: nil,
       selected_profile: nil,
       message_limit: @message_page_size,
       self_note_limit: 50,
       self_notes: false,
       self_note_envelopes: [],
       bulk_selected_conversations: MapSet.new()
     )
     |> refresh()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply,
     params
     |> apply_message_params(socket)
     |> reset_message_limit()
     |> refresh()
     |> scroll_to_selected()}
  end

  @impl true
  def handle_event("request", %{"id" => id}, socket) do
    case Messaging.accept_notification(socket.assigns.current_scope.user, id) do
      {:ok, _} ->
        {:noreply, refresh(socket)}

      {:error, :origin_unreachable} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The sender's instance is unreachable right now — try again later."
         )}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Notification not found.") |> refresh()}
    end
  end

  def handle_event("decline", %{"id" => id}, socket) do
    Messaging.decline_notification(socket.assigns.current_scope.user, id)
    {:noreply, refresh(socket)}
  end

  def handle_event(
        "busy_later",
        %{"id" => id, "envelopes" => envelopes},
        socket
      )
      when is_list(envelopes) do
    user = socket.assigns.current_scope.user

    with notification when not is_nil(notification) <-
           Enum.find(socket.assigns.pending, &(to_string(&1.id) == to_string(id))),
         :ok <- validate_busy_later_envelopes(envelopes, user.id, notification.envelope.sender_id),
         {:ok, _batch_id, _queued} <- Messaging.send_batch(user, "message", envelopes),
         {:ok, _notification} <- Messaging.decline_notification(user, notification.id) do
      {:reply, %{ok: true},
       socket
       |> put_flash(:info, "Encrypted quick reply sent.")
       |> refresh()}
    else
      nil -> {:reply, %{error: "That request is no longer waiting."}, refresh(socket)}
      _ -> {:reply, %{error: "The quick reply could not be sent."}, refresh(socket)}
    end
  end

  def handle_event("start_conversation", params, socket) do
    case ConversationLauncher.destination(socket.assigns, params) do
      {:ok, destination} ->
        {:noreply, push_navigate(socket, to: destination)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("select_conversation", %{"key" => key}, socket) do
    destination =
      if Enum.any?(
           socket.assigns.conversations,
           &(&1.key == key and &1.participants == ["notes to yourself"])
         ) do
        ~p"/messages?self_notes=true"
      else
        ~p"/messages?conversation=#{key}"
      end

    {:noreply, push_patch(socket, to: destination)}
  end

  def handle_event("archive_conversation", %{"key" => key}, socket) do
    case Messaging.archive_conversation(socket.assigns.current_scope.user, key) do
      {:ok, _archive} ->
        {:noreply,
         socket
         |> put_flash(:info, "Conversation archived.")
         |> push_patch(to: ~p"/messages", replace: true)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not archive that conversation.")}
    end
  end

  def handle_event("toggle_conversation_selection", %{"key" => key}, socket) do
    visible? = Enum.any?(socket.assigns.conversations, &(&1.key == key))

    selected =
      cond do
        not visible? ->
          socket.assigns.bulk_selected_conversations

        MapSet.member?(socket.assigns.bulk_selected_conversations, key) ->
          MapSet.delete(socket.assigns.bulk_selected_conversations, key)

        true ->
          MapSet.put(socket.assigns.bulk_selected_conversations, key)
      end

    {:noreply, assign(socket, :bulk_selected_conversations, selected)}
  end

  def handle_event("bulk_mark_read", _params, socket) do
    keys = MapSet.to_list(socket.assigns.bulk_selected_conversations)

    case Messaging.mark_conversations_read(socket.assigns.current_scope.user, keys) do
      {:ok, count} ->
        {:noreply,
         socket
         |> assign(:bulk_selected_conversations, MapSet.new())
         |> put_flash(:info, "Marked #{count} encrypted item(s) read.")
         |> refresh()}
    end
  end

  def handle_event("bulk_archive_conversations", _params, socket) do
    keys = MapSet.to_list(socket.assigns.bulk_selected_conversations)

    case Messaging.archive_conversations(socket.assigns.current_scope.user, keys) do
      {:ok, archives} ->
        {:noreply,
         socket
         |> assign(:bulk_selected_conversations, MapSet.new())
         |> put_flash(:info, "Archived #{length(archives)} conversation(s).")
         |> push_patch(to: ~p"/messages", replace: true)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not archive those conversations.")}
    end
  end

  def handle_event("new_message", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/messages")}
  end

  def handle_event("select_friend", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/messages?friend_id=#{id}")}
  end

  def handle_event("select_group", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/messages?group_id=#{id}")}
  end

  def handle_event("start_call", %{"id" => id}, socket) do
    case Veejr.Calls.start_call(socket.assigns.current_scope.user, id) do
      {:ok, call} ->
        return_to = ~p"/messages?conversation=#{socket.assigns.selected_conversation_key}"
        call_path = ~p"/call/#{call.public_id}?#{[return_to: return_to]}"

        {:noreply, push_navigate(socket, to: call_path)}

      {:error, :callee_unreachable} ->
        {:noreply,
         put_flash(socket, :error, "Their instance is unreachable right now — try again later.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not start the call.")}
    end
  end

  def handle_event("open_profile", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    thread_senders =
      case socket.assigns.selected_conversation do
        %{envelopes: envelopes} -> Enum.map(envelopes, & &1.sender)
        _ -> []
      end

    profiles =
      [user | socket.assigns.friends] ++
        Enum.map(socket.assigns.pending, & &1.envelope.sender) ++
        thread_senders

    profile = Enum.find(profiles, &(to_string(&1.id) == id))

    {:noreply, assign(socket, :selected_profile, profile)}
  end

  def handle_event("close_profile", _params, socket) do
    {:noreply, assign(socket, :selected_profile, nil)}
  end

  def handle_event(
        "save_profile_note",
        %{"contact_id" => contact_id, "body" => body},
        socket
      ) do
    case Social.upsert_contact_note(socket.assigns.current_scope.user, contact_id, body) do
      {:ok, _note} ->
        {:noreply, socket |> put_flash(:info, "Contact note saved.") |> refresh()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, profile_note_error(changeset))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save that note.")}
    end
  end

  def handle_event("load_more_messages", _params, socket) do
    limit = socket.assigns.message_limit + @message_page_size
    {:noreply, socket |> assign(:message_limit, limit) |> refresh()}
  end

  def handle_event("load_more_notes", _params, socket) do
    limit =
      case socket.assigns.self_note_limit do
        :all -> :all
        current -> current + 50
      end

    {:noreply, socket |> assign(:self_note_limit, limit) |> refresh()}
  end

  def handle_event("load_all_notes", _params, socket) do
    {:noreply, socket |> assign(:self_note_limit, :all) |> refresh()}
  end

  # A newly created document has no card yet; the board asks for the list again
  # rather than reloading the page.
  def handle_event("refresh_self_notes", _params, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_event("delete_envelope", %{"id" => public_id}, socket) do
    case Messaging.delete_envelope(socket.assigns.current_scope.user, public_id) do
      {:ok, {:deleted, _count}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Deleted for every recipient.")
         |> refresh()}

      {:ok, :hidden} ->
        {:noreply,
         socket
         |> put_flash(:info, "Hidden from your history.")
         |> refresh()}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not delete that item.")
         |> refresh()}
    end
  end

  def handle_event("delete_self_note", %{"id" => public_id}, socket) do
    user = socket.assigns.current_scope.user

    case Messaging.delete_self_item(user, public_id) do
      {:ok, _} -> {:reply, %{ok: true}, refresh(socket)}
      {:error, _} -> {:reply, %{error: "Could not permanently delete that note."}, socket}
    end
  end

  def handle_event("message_displayed", %{"id" => public_id}, socket) do
    case Messaging.record_display(socket.assigns.current_scope.user, public_id) do
      {:ok, envelope}
      when is_integer(envelope.max_displays) and
             envelope.display_count >= envelope.max_displays ->
        {:reply, %{ok: true}, refresh(socket)}

      _ ->
        {:reply, %{ok: true}, socket}
    end
  end

  def handle_event("prepare_edit", %{"id" => public_id}, socket) do
    case Messaging.editable_batch(socket.assigns.current_scope.user, public_id) do
      {:ok, batch} -> {:reply, Map.put(batch, :ok, true), socket}
      {:error, _} -> {:reply, %{error: "That message can no longer be edited."}, socket}
    end
  end

  def handle_event("edit_batch", %{"id" => public_id, "envelopes" => envelopes} = params, socket) do
    case Messaging.edit_sent_batch(socket.assigns.current_scope.user, public_id, envelopes,
           attachment_ids: Map.get(params, "attachment_ids", []),
           expected_updated_at: Map.get(params, "expected_updated_at")
         ) do
      {:ok, _count} ->
        {:reply, %{ok: true}, socket |> put_flash(:info, "Message updated.") |> refresh()}

      {:error, :stale} ->
        {:reply, %{error: "This note changed on another device.", stale: true}, refresh(socket)}

      {:error, _} ->
        {:reply, %{error: "Could not update that message."}, socket}
    end
  end

  def handle_event("resolve_recipients", params, socket) do
    {:reply, VeejrWeb.RecipientResolver.resolve(socket.assigns.current_scope.user, params),
     socket}
  end

  def handle_event("send_batch", %{"kind" => kind, "envelopes" => envelopes} = params, socket) do
    opts = Map.take(params, ["expires_at", "max_displays", "attachment_ids", "deliver_at"])

    case Messaging.send_batch(socket.assigns.current_scope.user, kind, envelopes, opts) do
      {:ok, _batch_id, _queued} ->
        socket =
          socket
          |> put_flash(:info, send_batch_message(kind, params["deliver_at"]))
          |> refresh()

        socket =
          if Envelope.self_kind?(kind) and not socket.assigns.self_notes do
            push_patch(socket, to: ~p"/messages?self_notes=true")
          else
            socket
          end

        {:reply, %{ok: true}, socket}

      {:error, :invalid_deliver_at} ->
        {:reply, %{error: "That send time is not valid. Pick a time in the next year."}, socket}

      {:error, _} ->
        {:reply, %{error: "Sending failed — are all recipients still your friends?"}, socket}
    end
  end

  # Sets or clears a reminder on one of the caller's own board items. The time
  # has to be server-visible for anything to fire it; the note itself stays
  # encrypted and the reminder that fires names none of its content.
  def handle_event("set_reminder", %{"id" => public_id} = params, socket) do
    user = socket.assigns.current_scope.user

    case Messaging.set_reminder(user, public_id, params["remind_at"]) do
      {:ok, envelope} ->
        message = if envelope.remind_at, do: "Reminder set.", else: "Reminder cleared."
        {:reply, %{ok: true}, socket |> put_flash(:info, message) |> refresh()}

      {:error, :invalid_remind_at} ->
        {:reply, %{error: "Pick a reminder time in the next year."}, socket}

      {:error, _reason} ->
        {:reply, %{error: "That note could not be found."}, socket}
    end
  end

  # Cancels an unreleased scheduled message: deleting the batch as its sender
  # removes every copy, including ones no recipient has been told about.
  def handle_event("cancel_scheduled", %{"id" => public_id}, socket) do
    case Messaging.delete_envelope(socket.assigns.current_scope.user, public_id) do
      {:ok, {:deleted, _count}} ->
        {:reply, %{ok: true},
         socket |> put_flash(:info, "Scheduled message cancelled.") |> refresh()}

      _ ->
        {:reply, %{error: "That scheduled message could not be cancelled."}, socket}
    end
  end

  # Idempotency pre-check for a Keep import: given the opaque dedup keys the
  # client computed for its notes, reply with a {key => content-fingerprint} map
  # of the ones already imported. The client skips unchanged notes and re-sends
  # only new or changed ones (no wasted re-encrypt / re-upload).
  def handle_event("check_self_note_dedup", %{"keys" => keys}, socket) when is_list(keys) do
    versions = Messaging.self_note_dedup_versions(socket.assigns.current_scope.user, keys)
    {:reply, %{versions: versions}, socket}
  end

  # Bulk import of self-notes (e.g. a Google Keep Takeout). The browser has
  # already encrypted each note; here we persist a chunk idempotently — a note
  # is inserted if new or updated in place if its fingerprint changed — and
  # reply with the counts. No per-note flash/refresh — the client reloads the
  # board once the whole import finishes.
  def handle_event("import_self_notes", %{"notes" => notes}, socket) when is_list(notes) do
    user = socket.assigns.current_scope.user

    {imported, updated} =
      Enum.reduce(notes, {0, 0}, fn note, {imp, upd} ->
        case Messaging.import_self_note(user, note) do
          {:ok, :imported} -> {imp + 1, upd}
          {:ok, :updated} -> {imp, upd + 1}
          _ -> {imp, upd}
        end
      end)

    {:reply, %{ok: true, imported: imported, updated: updated}, socket}
  end

  @impl true
  def handle_info({:veejr_notification, _notification}, socket) do
    {:noreply, refresh(socket)}
  end

  # A scheduled message went out: the thread's "Scheduled" chip should become
  # an ordinary sent message.
  def handle_info({:veejr_schedule_released}, socket) do
    {:noreply, refresh(socket)}
  end

  # It could not go out. The reason is a code, never message content.
  def handle_info({:veejr_schedule_failed, _public_id, reason}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, schedule_failure_message(reason))
     |> refresh()}
  end

  # A note reminder fired. The board reloads and lets the browser decrypt the
  # card; the server names no note content here.
  def handle_info({:veejr_note_reminder, public_id}, socket) do
    {:noreply,
     socket
     |> push_event("veejr:note_reminder", %{id: public_id})
     |> refresh()}
  end

  # A correspondent came or went. Only the dots change — no reason to rebuild
  # threads or re-read envelopes.
  def handle_info({:veejr_presence, user_id, state}, socket) do
    {:noreply, assign(socket, :presence, Map.put(socket.assigns.presence, user_id, state))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp send_batch_message("self_note", _deliver_at), do: "Note saved."
  defp send_batch_message("self_doc", _deliver_at), do: "Document saved."

  defp send_batch_message(_kind, deliver_at) when is_binary(deliver_at) and deliver_at != "",
    do: "Encrypted and scheduled."

  defp send_batch_message(_kind, _deliver_at), do: "Encrypted and sent."

  defp schedule_failure_message("recipient_key_changed"),
    do:
      "A scheduled message was not sent: the recipient's encryption key changed " <>
        "after you scheduled it. Send it again to use their new key."

  defp schedule_failure_message(_reason),
    do: "A scheduled message could not be sent. Send it again."

  defp refresh(socket) do
    socket = mark_selected_conversation_read(socket)
    user = socket.assigns.current_scope.user
    pending = Messaging.list_pending_notifications(user)
    friends = Social.list_friends(user)
    groups = Social.list_groups(user)
    message_limit = socket.assigns[:message_limit] || @message_page_size
    selected_key = socket.assigns[:selected_conversation_key]

    conversations = build_conversations(user, friends)

    selected_conversation =
      case Enum.find(conversations, &(&1.key == selected_key)) do
        nil ->
          nil

        conversation ->
          %{
            conversation
            | envelopes:
                Messaging.list_thread_envelopes(user, conversation.key, limit: message_limit)
          }
      end

    has_more_messages =
      selected_conversation != nil and selected_conversation.message_count > message_limit

    selected_key = if selected_conversation, do: selected_key
    selected_recipient = selected_recipient(socket, friends, groups)

    socket =
      assign(socket,
        pending: pending,
        pending_count: length(pending),
        friends: friends,
        groups: groups,
        contact_notes: Social.list_contact_notes(user),
        available_friends: available_friends(friends, conversations),
        available_groups: available_groups(groups, conversations),
        conversations: conversations,
        has_more_messages: has_more_messages,
        selected_conversation: selected_conversation,
        selected_conversation_key: selected_key,
        selected_recipient: selected_recipient,
        presence: Presence.states(friends)
      )

    if socket.assigns.self_notes do
      limit = socket.assigns.self_note_limit || 50
      self_note_envelopes = Messaging.list_self_envelopes(user, limit: limit)
      self_note_count = Messaging.count_self_envelopes(user)

      assign(socket,
        self_note_envelopes: self_note_envelopes,
        has_more_self_notes: length(self_note_envelopes) < self_note_count
      )
    else
      assign(socket, self_note_envelopes: [], has_more_self_notes: false)
    end
  end

  defp clear_selected_recipient(socket) do
    assign(socket, selected_recipient_type: nil, selected_recipient_id: nil)
  end

  defp reset_message_limit(socket), do: assign(socket, :message_limit, @message_page_size)

  defp mark_selected_conversation_read(socket) do
    case socket.assigns[:selected_conversation_key] do
      key when is_binary(key) ->
        :ok = Messaging.mark_conversation_read(socket.assigns.current_scope.user, key)
        socket

      _ ->
        socket
    end
  end

  defp scroll_to_selected(socket) do
    case socket.assigns[:selected_conversation_key] do
      key when is_binary(key) ->
        push_event(socket, "scroll_to_bottom", %{thread_id: "thread-#{key}"})

      _ ->
        socket
    end
  end

  defp apply_message_params(%{"conversation" => key}, socket) when is_binary(key) do
    if key == Messaging.conversation_key(["notes to yourself"]) do
      socket
      |> assign(:self_notes, true)
      |> assign(:selected_conversation_key, nil)
      |> clear_selected_recipient()
    else
      socket
      |> assign(:self_notes, false)
      |> assign(:selected_conversation_key, key)
      |> clear_selected_recipient()
    end
  end

  defp apply_message_params(%{"self_notes" => value}, socket) when value in ["true", "1"] do
    socket
    |> assign(:self_notes, true)
    |> assign(:selected_conversation_key, nil)
    |> clear_selected_recipient()
  end

  defp apply_message_params(%{"friend_id" => id}, socket) do
    assign(socket,
      self_notes: false,
      selected_conversation_key: nil,
      selected_recipient_type: :friend,
      selected_recipient_id: id
    )
  end

  defp apply_message_params(%{"group_id" => id}, socket) do
    assign(socket,
      self_notes: false,
      selected_conversation_key: nil,
      selected_recipient_type: :group,
      selected_recipient_id: id
    )
  end

  defp apply_message_params(%{"friend_ids" => _ids} = params, socket) do
    assign_multi_recipient(socket, params)
  end

  defp apply_message_params(%{"group_ids" => _ids} = params, socket) do
    assign_multi_recipient(socket, params)
  end

  defp apply_message_params(_params, socket) do
    socket
    |> assign(:self_notes, false)
    |> assign(:selected_conversation_key, nil)
    |> clear_selected_recipient()
  end

  defp selected_recipient(socket, friends, groups) do
    id = socket.assigns[:selected_recipient_id]

    case socket.assigns[:selected_recipient_type] do
      :friend ->
        with {friend_id, ""} <- Integer.parse(to_string(id)),
             friend when not is_nil(friend) <- Enum.find(friends, &(&1.id == friend_id)) do
          %{
            type: :friend,
            id: friend.id,
            title: friend.display_name || friend.username,
            subtitle: Social.Address.handle(friend),
            friend_ids: [to_string(friend.id)],
            group_ids: [],
            initials: person_initials(friend),
            user: friend
          }
        else
          _ -> nil
        end

      :group ->
        with {group_id, ""} <- Integer.parse(to_string(id)),
             group when not is_nil(group) <- Enum.find(groups, &(&1.id == group_id)) do
          %{
            type: :group,
            id: group.id,
            title: group.name,
            subtitle: "#{length(group.members)} members",
            friend_ids: [],
            group_ids: [to_string(group.id)],
            initials: group_initials(group)
          }
        else
          _ -> nil
        end

      :multi ->
        selected = id || %{}
        friend_ids = Map.get(selected, :friend_ids, [])
        group_ids = Map.get(selected, :group_ids, [])
        include_self = Map.get(selected, :include_self, false)
        friend_id_set = MapSet.new(friend_ids)
        group_id_set = MapSet.new(group_ids)
        chosen_friends = Enum.filter(friends, &MapSet.member?(friend_id_set, to_string(&1.id)))
        chosen_groups = Enum.filter(groups, &MapSet.member?(group_id_set, to_string(&1.id)))

        recipient_ids =
          chosen_friends
          |> Enum.map(&to_string(&1.id))
          |> Kernel.++(
            chosen_groups
            |> Enum.flat_map(& &1.members)
            |> Enum.map(&to_string(&1.id))
          )
          |> Enum.uniq()

        count = length(recipient_ids) + if(include_self, do: 1, else: 0)

        if count > 0 do
          %{
            type: :multi,
            id: "multi",
            title: "New conversation",
            subtitle: "#{count} selected #{if(count == 1, do: "recipient", else: "recipients")}",
            friend_ids: Enum.map(chosen_friends, &to_string(&1.id)),
            group_ids: Enum.map(chosen_groups, &to_string(&1.id)),
            include_self: include_self,
            initials: "NEW"
          }
        end

      _ ->
        nil
    end
  end

  defp assign_multi_recipient(socket, params) do
    friend_ids = parse_id_list(Map.get(params, "friend_ids"))
    group_ids = parse_id_list(Map.get(params, "group_ids"))
    include_self = Map.get(params, "include_self") in [true, "true", "1", "on"]

    assign(socket,
      self_notes: false,
      selected_conversation_key: nil,
      selected_recipient_type: :multi,
      selected_recipient_id: %{
        friend_ids: friend_ids,
        group_ids: group_ids,
        include_self: include_self
      }
    )
  end

  defp validate_busy_later_envelopes(envelopes, user_id, sender_id) do
    recipient_ids =
      Enum.map(envelopes, fn
        attrs when is_map(attrs) ->
          attrs
          |> Map.get("recipient_id", Map.get(attrs, :recipient_id))
          |> to_string()

        _ ->
          ""
      end)

    expected = [to_string(user_id), to_string(sender_id)] |> Enum.sort()

    if length(recipient_ids) == 2 and Enum.sort(recipient_ids) == expected,
      do: :ok,
      else: {:error, :invalid_recipients}
  end

  defp parse_id_list(nil), do: []

  defp parse_id_list(value) do
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.uniq()
  end

  defp available_friends(friends, conversations) do
    used_ids =
      conversations
      |> Enum.flat_map(&selected_friend_ids/1)
      |> MapSet.new()

    Enum.reject(friends, &(to_string(&1.id) in used_ids))
  end

  defp available_groups(groups, conversations) do
    conversation_participants = MapSet.new(conversations, & &1.participants)

    Enum.reject(groups, fn group ->
      group
      |> group_participant_handles()
      |> then(&MapSet.member?(conversation_participants, &1))
    end)
  end

  defp person_initials(user) do
    user
    |> display_name()
    |> initials()
  end

  defp group_participant_handles(group) do
    group.members
    |> Enum.map(&Social.Address.handle/1)
    |> Enum.sort()
  end

  # One entry per thread, from the materialized thread keys: what you sent
  # to {@alice, @bob} and what @alice sent you form separate threads (a
  # received group message lands in the sender's thread — the server can't
  # see its other recipients; the decrypted payload shows them). Only the
  # selected conversation loads envelope ciphertext, in refresh/1.
  defp build_conversations(user, friends) do
    handle_to_friend = Map.new(friends, &{Veejr.Social.Address.handle(&1), &1})
    archives = Messaging.list_thread_archives(user)

    user
    |> Messaging.list_conversation_summaries()
    |> Enum.reject(fn summary ->
      case archives[summary.key] do
        %{archived: true} -> true
        _ -> false
      end
    end)
    |> Enum.reject(&(&1.participants == ["notes to yourself"]))
    |> Enum.map(fn summary ->
      archive = archives[summary.key]
      participants = summary.participants

      %{
        key: summary.key,
        participants: participants,
        message_count: summary.message_count,
        unread_count: summary.unread_count,
        envelopes: [],
        latest: summary.latest_envelope,
        started_at: (archive && archive.started_at) || summary.started_at,
        preserved: archive != nil,
        reply_ids:
          participants
          |> Enum.map(&handle_to_friend[&1])
          |> Enum.reject(&is_nil/1)
          |> Enum.map(& &1.id)
          |> Enum.join(","),
        avatar_user:
          case participants do
            ["notes to yourself"] -> user
            [handle] -> handle_to_friend[handle]
            _ -> nil
          end
      }
    end)
  end
end
