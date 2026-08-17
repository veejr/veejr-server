defmodule VeejrWeb.ContactsLive do
  use VeejrWeb, :live_view

  import VeejrWeb.MessagingComponents, only: [conversation_builder: 1]

  alias Veejr.{Accounts, Messaging, Presence, Social}
  alias VeejrWeb.{ConversationLauncher, PageLayout}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      pending_count={@pending_count}
      container_class="mx-auto max-w-7xl"
    >
      <div
        id="contacts-workspace"
        phx-hook="ContactsTheme"
        data-contacts-theme="classic"
        class="contacts-workspace space-y-6"
      >
        <header class="relative pb-4">
          <div class="flex items-center gap-3 pr-14">
            <h1 class="text-lg font-semibold leading-8">Contacts</h1>
          </div>

          <details
            id="contacts-tools"
            open
            class="group"
            aria-label="Contact tools"
          >
            <summary
              id="contacts-tools-toggle"
              aria-label="Contact tools"
              title="Contact tools"
              class="absolute top-0 right-0 flex size-10 cursor-pointer list-none items-center justify-center rounded-xl border border-base-300 bg-base-100 text-base-content/65 shadow-sm transition hover:-translate-y-0.5 hover:border-primary/40 hover:bg-primary/10 hover:text-primary hover:shadow-md focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary group-open:border-primary/40 group-open:bg-primary/10 group-open:text-primary"
            >
              <.icon
                name="hero-cog-6-tooth"
                class="size-5 transition duration-300 group-open:rotate-90"
              />
            </summary>

            <div
              id="contacts-tools-content"
              class="mt-4 grid gap-3 rounded-2xl border border-base-300 bg-base-100 p-3 shadow-sm sm:p-4 lg:grid-cols-[minmax(0,1fr)_auto]"
            >
              <section class="rounded-2xl border border-base-300 bg-base-200/45 p-3">
                <p class="text-sm text-base-content/70">
                  Conversations, friends, and groups in one place. Your address:
                  <code class="break-all">{Social.Address.full(@current_scope.user)}</code>
                </p>
                <label class="contacts-theme-control mt-3">
                  <span class="contacts-theme-control-label">
                    <.icon name="hero-swatch" class="size-4" /> Appearance
                  </span>
                  <select
                    id="contacts-theme-select"
                    data-contacts-theme-select
                    aria-label="Contacts appearance"
                    class="contacts-theme-select select select-sm"
                  >
                    <optgroup :for={{group, options} <- theme_options()} label={group}>
                      <option :for={{value, label} <- options} value={value}>{label}</option>
                    </optgroup>
                  </select>
                </label>
              </section>

              <div class="grid content-center gap-2 sm:grid-cols-2 lg:grid-cols-1">
                <.link
                  id="contacts-invite-person"
                  navigate={~p"/invites/new"}
                  class="btn btn-outline btn-sm justify-start"
                >
                  <.icon name="hero-qr-code" class="size-4" /> Invite person
                </.link>
                <.conversation_builder
                  id="conversation-builder"
                  form_id="conversation-builder-form"
                  conversations={@conversations}
                  friends={@friends}
                  groups={@groups}
                />
              </div>
            </div>
          </details>
        </header>

        <section
          :if={@invitation_acceptances != []}
          id="invitation-acceptances"
          class="rounded-lg border border-success/30 bg-success/10 p-4"
        >
          <h2 class="text-sm font-semibold">Someone you invited has joined</h2>
          <ul class="mt-2 space-y-2">
            <li
              :for={invitation <- @invitation_acceptances}
              class="flex items-center justify-between gap-3 rounded-lg bg-base-100 px-3 py-2"
            >
              <span class="text-sm">
                <strong>
                  {invitation.accepted_by.display_name || "@#{invitation.accepted_by.username}"}
                </strong>
                joined this instance and is now your friend.
              </span>
              <button
                phx-click="dismiss_invitation_acceptance"
                phx-value-id={invitation.id}
                class="btn btn-ghost btn-xs"
                aria-label="Dismiss joined notification"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </li>
          </ul>
        </section>

        <section :if={@pending != []} class="rounded-lg border border-primary/20 bg-primary/10 p-4">
          <div class="flex items-center justify-between gap-3">
            <div>
              <h2 class="text-sm font-semibold text-base-content">
                Waiting for you
                <span class="ml-1 rounded-full bg-primary px-2 py-0.5 text-xs text-primary-content">
                  {length(@pending)}
                </span>
              </h2>
              <p class="text-xs opacity-70">Encrypted items need your approval.</p>
            </div>
            <.link navigate={~p"/messages"} class="btn btn-outline btn-sm">Messages</.link>
          </div>
          <ul class="mt-3 grid gap-2 lg:grid-cols-2">
            <li
              :for={notif <- @pending}
              class="flex items-center justify-between gap-3 rounded-lg border border-primary/20 bg-base-100 px-3 py-2"
            >
              <span class="min-w-0 text-sm text-base-content">
                <span class="font-medium">
                  {Veejr.Social.Address.handle(notif.envelope.sender)}
                </span>
                sent an encrypted {notif.envelope.kind}
                <span class="text-xs opacity-70">
                  - {Calendar.strftime(notif.inserted_at, "%b %d, %H:%M")} UTC
                </span>
              </span>
              <span class="flex shrink-0 gap-2">
                <button
                  phx-click="request_notification"
                  phx-value-id={notif.id}
                  class="btn btn-primary btn-xs"
                >
                  Request
                </button>
                <button
                  phx-click="decline_notification"
                  phx-value-id={notif.id}
                  class="btn btn-ghost btn-xs"
                >
                  Decline
                </button>
              </span>
            </li>
          </ul>
        </section>

        <div class="space-y-4">
          <%!-- data-default-open marks the one section Classic starts open.
                The appearance hook reads it when returning from a flat theme,
                so the two cannot drift apart. --%>
          <details
            open
            data-default-open
            class="contacts-section collapse collapse-arrow rounded-lg border border-base-300 bg-base-100"
          >
            <summary class="collapse-title">
              <div class="flex items-center justify-between gap-3 pr-6">
                <div>
                  <h2 class="text-lg font-semibold">Conversations</h2>
                  <p class="text-sm opacity-70">Pick a thread to continue it in Messages.</p>
                </div>
                <span class="badge badge-outline">{length(@conversations)}</span>
              </div>
            </summary>
            <div class="collapse-content">
              <p :if={@conversations == []} class="mt-4 text-sm opacity-60">
                No conversations yet.
              </p>

              <%!-- Mount point for the Orbit appearance. The hook reads the list
                  below rather than taking its own copy of the data, so it keeps
                  working with client-side decrypted previews. Empty and ignored
                  server-side; the hook owns everything inside it. --%>
              <div
                :if={@conversations != []}
                id="contacts-orbit"
                phx-hook="ContactsOrbit"
                phx-update="ignore"
                data-three-src={~p"/vendor/three.min.js"}
                class="contacts-orbit"
              >
              </div>

              <ul class="contacts-conversation-list mt-4 divide-y divide-base-300">
                <li
                  :for={conversation <- @conversations}
                  data-unread={conversation.unread_count > 0}
                  class={[
                    "flex items-center gap-2 rounded-lg px-2 py-2 transition hover:bg-base-200",
                    conversation.unread_count > 0 && "conversation-unread"
                  ]}
                >
                  <span :if={conversation.avatar_user} class="relative inline-flex shrink-0">
                    <.user_avatar
                      id={"conversation-avatar-#{conversation.key}"}
                      user={conversation.avatar_user}
                      class="size-10 text-sm"
                      on_click="open_profile"
                      data-avatar-texture-url={avatar_texture_url(conversation.avatar_user)}
                    />
                    <.presence_dot state={Map.get(@presence, conversation.avatar_user.id, :unknown)} />
                  </span>
                  <span
                    :if={!conversation.avatar_user}
                    class="flex size-10 shrink-0 items-center justify-center rounded-full bg-primary/15 text-primary"
                  >
                    <.icon name="hero-user-group" class="size-5" />
                  </span>
                  <.link
                    id={"open-conversation-#{conversation.key}"}
                    navigate={~p"/messages?conversation=#{conversation.key}"}
                    class="flex min-w-0 flex-1 items-center justify-between gap-3 py-1"
                  >
                    <div class="min-w-0">
                      <p class="truncate font-medium">
                        {conversation_title(conversation)}
                      </p>
                      <p
                        id={"conversation-preview-#{conversation.key}"}
                        phx-hook="ConversationPreview"
                        phx-update="ignore"
                        data-user-id={@current_scope.user.id}
                        data-peer-key={
                          Veejr.Messaging.peer_key(
                            conversation.latest,
                            @current_scope.user
                          )
                        }
                        data-ciphertext={conversation.latest.ciphertext}
                        data-nonce={conversation.latest.nonce}
                        data-kind={conversation.latest.kind}
                        class="mt-0.5 truncate text-sm opacity-80"
                      >
                        <span class="loading loading-dots loading-xs"></span>
                      </p>
                      <p class="text-xs opacity-70">
                        {conversation.message_count} messages · latest {Calendar.strftime(
                          conversation.latest.inserted_at,
                          "%b %d, %H:%M"
                        )} UTC
                      </p>
                    </div>
                    <span class="ml-auto shrink-0 text-sm font-medium text-primary">Open</span>
                  </.link>
                  <.auto_open_control
                    :if={conversation.policy_id}
                    subject_type="conversation"
                    subject_id={conversation.policy_id}
                    policies={@delivery_policies}
                    compact
                  />
                </li>
              </ul>
            </div>
          </details>

          <details class="contacts-section collapse collapse-arrow rounded-lg border border-base-300 bg-base-100">
            <summary class="collapse-title">
              <div class="flex items-center justify-between gap-3 pr-6">
                <h2 class="text-lg font-semibold">Friends</h2>
                <span class="badge badge-outline">{length(@friends)}</span>
              </div>
            </summary>
            <div class="collapse-content">
              <section :if={@key_changes != []} class="rounded-lg border border-warning/50 p-3">
                <h3 class="font-semibold text-warning">Key changes need confirmation</h3>
                <ul class="mt-2 space-y-2">
                  <li
                    :for={friend <- @key_changes}
                    class="flex items-center justify-between gap-3 text-sm"
                  >
                    <span class="min-w-0">
                      <span class="font-medium">{friend.display_name || friend.username}</span>
                      <span class="opacity-60">{Social.Address.handle(friend)}</span>
                    </span>
                    <button
                      phx-click="confirm_key"
                      phx-value-id={friend.id}
                      data-confirm="Accept this friend's new encryption key? Messages you send will be encrypted to it."
                      class="btn btn-warning btn-xs"
                    >
                      Accept key
                    </button>
                  </li>
                </ul>
              </section>

              <section :if={@incoming != []} class="mt-4">
                <h3 class="text-sm font-semibold uppercase tracking-wide opacity-70">
                  Incoming requests
                </h3>
                <ul class="mt-2 space-y-2">
                  <li
                    :for={req <- @incoming}
                    class="flex items-center justify-between gap-3 rounded-lg border border-base-300 p-3"
                  >
                    <span class="flex min-w-0 items-center gap-3">
                      <.user_avatar
                        id={"request-avatar-#{req.requester.id}"}
                        user={req.requester}
                        class="size-9 text-xs"
                        on_click="open_profile"
                      />
                      <span>
                        <span class="block font-medium">{req.requester.display_name ||
                          req.requester.username}</span>
                        <span class="block opacity-60">{Social.Address.handle(req.requester)}</span>
                      </span>
                    </span>
                    <span class="flex gap-2">
                      <button phx-click="accept" phx-value-id={req.id} class="btn btn-primary btn-xs">
                        Accept
                      </button>
                      <button phx-click="decline" phx-value-id={req.id} class="btn btn-ghost btn-xs">
                        Decline
                      </button>
                    </span>
                  </li>
                </ul>
              </section>

              <section :if={@outgoing != []} class="mt-4">
                <h3 class="text-sm font-semibold uppercase tracking-wide opacity-70">Waiting on</h3>
                <ul class="mt-2 space-y-1">
                  <li :for={req <- @outgoing} class="text-sm opacity-70">
                    {Social.Address.handle(req.addressee)} - request sent
                  </li>
                </ul>
              </section>

              <p :if={@friends == []} class="mt-4 text-sm opacity-60">
                No friends yet. Add someone below to start sharing.
              </p>

              <ul class="mt-4 space-y-2">
                <li
                  :for={friend <- @friends}
                  class="rounded-lg border border-base-300 p-3"
                >
                  <div class="flex items-start justify-between gap-3">
                    <span class="flex min-w-0 items-center gap-3">
                      <span class="relative inline-flex shrink-0">
                        <.user_avatar
                          id={"friend-avatar-#{friend.id}"}
                          user={friend}
                          class="size-12 text-sm"
                          on_click="open_profile"
                        />
                        <.presence_dot
                          id={"friend-presence-#{friend.id}"}
                          state={Map.get(@presence, friend.id, :unknown)}
                        />
                      </span>
                      <span class="min-w-0">
                        <span class="block truncate font-medium">{friend.display_name ||
                          friend.username}</span>
                        <span class="text-sm opacity-60">{Social.Address.handle(friend)}</span>
                        <span :if={friend.host} class="badge badge-info badge-sm ml-2">remote</span>
                        <span :if={!friend.public_key} class="badge badge-warning badge-sm ml-2">
                          no keys yet
                        </span>
                      </span>
                    </span>
                    <span class="flex shrink-0 gap-2">
                      <.link
                        navigate={~p"/messages?friend_id=#{friend.id}"}
                        class="btn btn-primary btn-sm"
                      >
                        Message
                      </.link>
                      <button
                        phx-click="remove"
                        phx-value-id={friend.id}
                        data-confirm="Remove this friend? They will also be removed from your groups."
                        class="btn btn-ghost btn-sm"
                      >
                        Remove
                      </button>
                    </span>
                  </div>

                  <details class="collapse collapse-arrow mt-3 rounded-lg border border-base-300 bg-base-200">
                    <summary class="collapse-title min-h-0 px-3 py-2 text-sm font-medium">
                      Personal info & notes
                    </summary>
                    <div class="collapse-content px-3 pb-3">
                      <div class="mb-4 flex items-center justify-between gap-3 rounded-lg border border-base-300 bg-base-100 p-3">
                        <div>
                          <p class="text-sm font-medium">Automatically open messages</p>
                          <p class="text-xs opacity-60">
                            Default to skipping the approval step for this contact.
                          </p>
                        </div>
                        <.auto_open_control
                          subject_type="contact"
                          subject_id={friend.id}
                          policies={@delivery_policies}
                        />
                      </div>
                      <form phx-submit="save_note">
                        <input type="hidden" name="contact_id" value={friend.id} />
                        <label class="text-xs font-semibold uppercase tracking-wide opacity-60">
                          Personal notes
                        </label>
                        <textarea
                          name="body"
                          rows="3"
                          maxlength="4000"
                          class="textarea textarea-bordered mt-1 w-full resize-y text-sm"
                          placeholder="Private notes about this contact"
                        >{Map.get(@contact_notes, friend.id, "")}</textarea>
                        <div class="mt-2 flex justify-end">
                          <button type="submit" class="btn btn-sm">Save note</button>
                        </div>
                      </form>
                    </div>
                  </details>
                </li>
              </ul>
            </div>
          </details>

          <details class="contacts-section collapse collapse-arrow rounded-lg border border-base-300 bg-base-100">
            <summary class="collapse-title">
              <div class="flex items-center justify-between gap-3 pr-6">
                <h2 class="text-lg font-semibold">Groups</h2>
                <span class="badge badge-outline">{length(@groups)}</span>
              </div>
            </summary>
            <div class="collapse-content">
              <form phx-submit="create_group" class="flex flex-col gap-2 sm:flex-row">
                <input
                  type="text"
                  name="name"
                  placeholder="new group name"
                  class="input flex-1"
                  autocomplete="off"
                  required
                />
                <button type="submit" class="btn btn-primary">Create</button>
              </form>

              <p :if={@groups == []} class="mt-4 text-sm opacity-60">
                No groups yet.
              </p>

              <div class="mt-4 space-y-4">
                <section :for={group <- @groups} class="rounded-lg border border-base-300 p-3">
                  <div class="flex items-center justify-between gap-3">
                    <div class="min-w-0">
                      <h3 class="truncate font-semibold">{group.name}</h3>
                      <p class="text-sm opacity-60">{length(group.members)} members</p>
                    </div>
                    <span class="flex shrink-0 gap-2">
                      <.link
                        navigate={~p"/messages?group_id=#{group.id}"}
                        class="btn btn-primary btn-sm"
                      >
                        Message
                      </.link>
                      <button
                        phx-click="delete_group"
                        phx-value-id={group.id}
                        data-confirm={"Delete group \"#{group.name}\"? Friends stay friends."}
                        class="btn btn-ghost btn-sm"
                      >
                        Delete
                      </button>
                    </span>
                  </div>

                  <div class="mt-3 flex flex-wrap gap-2">
                    <span :for={member <- group.members} class="badge badge-outline h-8 gap-1 pl-1">
                      <.user_avatar
                        user={member}
                        class="size-6 text-[0.6rem]"
                        ring={false}
                        on_click="open_profile"
                      />
                      {member.display_name || member.username}
                      <button
                        phx-click="remove_member"
                        phx-value-group={group.id}
                        phx-value-user={member.id}
                        class="ml-1 opacity-60 hover:opacity-100"
                        aria-label="remove from group"
                      >
                        x
                      </button>
                    </span>
                    <span :if={group.members == []} class="text-sm opacity-60">No members yet.</span>
                  </div>

                  <details class="collapse collapse-arrow mt-3 rounded-lg border border-base-300 bg-base-200">
                    <summary class="collapse-title min-h-0 px-3 py-2 text-sm font-medium">
                      Personal info & notes
                    </summary>
                    <div class="collapse-content px-3 pb-3">
                      <div class="mb-4 flex items-center justify-between gap-3 rounded-lg border border-base-300 bg-base-100 p-3">
                        <div>
                          <p class="text-sm font-medium">Automatically open messages</p>
                          <p class="text-xs opacity-60">
                            Let members skip approval unless a stricter setting overrides it.
                          </p>
                        </div>
                        <.auto_open_control
                          subject_type="group"
                          subject_id={group.id}
                          policies={@delivery_policies}
                        />
                      </div>
                      <form phx-submit="save_group_note">
                        <input type="hidden" name="group_id" value={group.id} />
                        <label class="text-xs font-semibold uppercase tracking-wide opacity-60">
                          Personal notes
                        </label>
                        <textarea
                          name="body"
                          rows="3"
                          maxlength="4000"
                          class="textarea textarea-bordered mt-1 w-full resize-y text-sm"
                          placeholder="Private notes about this group"
                        >{Map.get(@group_notes, group.id, "")}</textarea>
                        <div class="mt-2 flex justify-end">
                          <button type="submit" class="btn btn-sm">Save note</button>
                        </div>
                      </form>
                    </div>
                  </details>

                  <form
                    :if={addable_friends(@friends, group) != []}
                    phx-submit="add_member"
                    class="mt-3 flex gap-2"
                  >
                    <input type="hidden" name="group" value={group.id} />
                    <select name="user" class="select select-sm flex-1">
                      <option :for={friend <- addable_friends(@friends, group)} value={friend.id}>
                        {friend.display_name || friend.username} (@{friend.username})
                      </option>
                    </select>
                    <button type="submit" class="btn btn-sm">Add</button>
                  </form>
                </section>
              </div>
            </div>
          </details>

          <section class="rounded-lg border border-base-300 bg-base-100 p-4">
            <h2 class="text-lg font-semibold">Add Friend</h2>
            <p class="text-sm opacity-70">Use a local username or user@host from another instance.</p>
            <form phx-submit="add_friend" class="mt-4 flex flex-col gap-2 sm:flex-row">
              <input
                type="text"
                name="username"
                value={@add_username}
                placeholder="username or user@host"
                class="input flex-1"
                autocomplete="off"
              />
              <button type="submit" class="btn btn-primary">Send request</button>
            </form>
          </section>
        </div>

        <.profile_dialog
          user={@selected_profile}
          note={profile_note(@contact_notes, @selected_profile)}
          editable={profile_editable?(@friends, @selected_profile)}
        />
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    # The account asked for the plain pages, so leave before loading a page
    # it does not want: no first paint of this one, nothing fetched for it.
    if PageLayout.simple?(socket) and params["manage"] != "true" do
      {:ok, push_navigate(socket, to: PageLayout.route(:contacts, "simple"))}
    else
      {:ok,
       socket
       |> assign(add_username: "", page_title: "Contacts", selected_profile: nil)
       |> refresh()}
    end
  end

  @impl true
  def handle_info({:veejr_notification, _notification}, socket) do
    {:noreply, refresh(socket)}
  end

  # A friend came or went. Only the dot changes, so patch the map rather than
  # reloading every list on the page.
  def handle_info({:veejr_presence, user_id, state}, socket) do
    {:noreply, assign(socket, :presence, Map.put(socket.assigns.presence, user_id, state))}
  end

  # Everything else on the user's topic (schedule releases, note reminders,
  # anything added later) is for other views. Without this clause a new
  # broadcast would take the page down.
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("start_conversation", params, socket) do
    case ConversationLauncher.destination(socket.assigns, params) do
      {:ok, destination} ->
        {:noreply, push_navigate(socket, to: destination)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("add_friend", %{"username" => input}, socket) do
    case Social.Address.parse(input) do
      {:local, username} ->
        {:noreply, socket |> add_local_friend(username) |> assign(add_username: "") |> refresh()}

      {:remote, username, authority} ->
        socket =
          case Social.send_remote_friend_request(
                 socket.assigns.current_scope.user,
                 username,
                 authority
               ) do
            {:ok, _} ->
              put_flash(socket, :info, "Request sent to @#{username}@#{authority}.")

            {:error, :already_friends} ->
              put_flash(socket, :error, "You are already friends with @#{username}@#{authority}.")

            {:error, :already_requested} ->
              put_flash(
                socket,
                :error,
                "A request with @#{username}@#{authority} is already pending."
              )

            {:error, {:http, 404}} ->
              put_flash(socket, :error, "#{authority} doesn't know any @#{username}.")

            {:error, _} ->
              put_flash(
                socket,
                :error,
                "Could not reach #{authority} - check the address, or try again later."
              )
          end

        {:noreply, socket |> assign(add_username: "") |> refresh()}

      {:error, :invalid} ->
        {:noreply,
         put_flash(socket, :error, "That doesn't look like a username or user@host address.")}
    end
  end

  def handle_event("accept", %{"id" => id}, socket) do
    case Social.accept_friend_request(socket.assigns.current_scope.user, id) do
      {:ok, fr} ->
        {:noreply,
         socket
         |> put_flash(:info, "You and @#{fr.requester.username} are now friends!")
         |> refresh()}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Request no longer exists.") |> refresh()}
    end
  end

  def handle_event("decline", %{"id" => id}, socket) do
    Social.decline_friend_request(socket.assigns.current_scope.user, id)
    {:noreply, refresh(socket)}
  end

  def handle_event("request_notification", %{"id" => id}, socket) do
    case Messaging.accept_notification(socket.assigns.current_scope.user, id) do
      {:ok, _} ->
        {:noreply, refresh(socket)}

      {:error, :origin_unreachable} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The sender's instance is unreachable right now - try again later."
         )}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Notification not found.") |> refresh()}
    end
  end

  def handle_event("decline_notification", %{"id" => id}, socket) do
    Messaging.decline_notification(socket.assigns.current_scope.user, id)
    {:noreply, refresh(socket)}
  end

  def handle_event("dismiss_invitation_acceptance", %{"id" => id}, socket) do
    Accounts.dismiss_invitation_acceptance(socket.assigns.current_scope.user, id)
    {:noreply, refresh(socket)}
  end

  def handle_event(
        "toggle_auto_open",
        %{"subject_type" => subject_type, "subject_id" => subject_id},
        socket
      ) do
    user = socket.assigns.current_scope.user
    policy = Map.get(socket.assigns.delivery_policies, {subject_type, subject_id})
    acceptance = if policy && policy.acceptance == "automatic", do: "ask", else: "automatic"
    notification = if policy, do: policy.notification, else: "normal"

    case Messaging.put_delivery_policy(user, subject_type, subject_id, %{
           "acceptance" => acceptance,
           "notification" => notification
         }) do
      {:ok, _policy} ->
        message =
          if acceptance == "automatic",
            do: "Automatic message opening enabled.",
            else: "Automatic message opening disabled."

        {:noreply, socket |> put_flash(:info, message) |> refresh()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not update that message setting.")}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    Social.remove_friend(socket.assigns.current_scope.user, String.to_integer(id))
    {:noreply, socket |> put_flash(:info, "Friend removed.") |> refresh()}
  end

  def handle_event("confirm_key", %{"id" => id}, socket) do
    case Social.confirm_new_key(socket.assigns.current_scope.user, String.to_integer(id)) do
      {:ok, friend} ->
        {:noreply,
         socket |> put_flash(:info, "New key accepted for @#{friend.username}.") |> refresh()}

      {:error, _} ->
        {:noreply,
         socket |> put_flash(:error, "Nothing to confirm for that friend.") |> refresh()}
    end
  end

  def handle_event("save_note", %{"contact_id" => contact_id, "body" => body}, socket) do
    case Social.upsert_contact_note(socket.assigns.current_scope.user, contact_id, body) do
      {:ok, _note} ->
        {:noreply, socket |> put_flash(:info, "Contact note saved.") |> refresh()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, error_from(changeset))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save that note.")}
    end
  end

  def handle_event("open_profile", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    profiles =
      [user | socket.assigns.friends] ++
        Enum.map(socket.assigns.incoming, & &1.requester) ++
        Enum.map(socket.assigns.outgoing, & &1.addressee)

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
        {:noreply, put_flash(socket, :error, error_from(changeset))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save that note.")}
    end
  end

  def handle_event("save_group_note", %{"group_id" => group_id, "body" => body}, socket) do
    case Social.upsert_group_note(socket.assigns.current_scope.user, group_id, body) do
      {:ok, _note} ->
        {:noreply, socket |> put_flash(:info, "Group note saved.") |> refresh()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, error_from(changeset))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save that group note.")}
    end
  end

  def handle_event("create_group", %{"name" => name}, socket) do
    socket =
      case Social.create_group(socket.assigns.current_scope.user, %{name: String.trim(name)}) do
        {:ok, group} -> put_flash(socket, :info, "Group \"#{group.name}\" created.")
        {:error, changeset} -> put_flash(socket, :error, error_from(changeset))
      end

    {:noreply, refresh(socket)}
  end

  def handle_event("delete_group", %{"id" => id}, socket) do
    Social.delete_group(socket.assigns.current_scope.user, id)
    {:noreply, refresh(socket)}
  end

  def handle_event("add_member", %{"group" => group_id, "user" => user_id}, socket) do
    case Social.add_group_member(
           socket.assigns.current_scope.user,
           group_id,
           String.to_integer(user_id)
         ) do
      {:ok, _} ->
        {:noreply, refresh(socket)}

      {:error, :not_a_friend} ->
        {:noreply, put_flash(socket, :error, "Only friends can join your groups.")}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Could not add member.") |> refresh()}
    end
  end

  def handle_event("remove_member", %{"group" => group_id, "user" => user_id}, socket) do
    Social.remove_group_member(
      socket.assigns.current_scope.user,
      group_id,
      String.to_integer(user_id)
    )

    {:noreply, refresh(socket)}
  end

  defp add_local_friend(socket, username) do
    case Social.send_friend_request(socket.assigns.current_scope.user, username) do
      {:ok, %Veejr.Social.Friendship{status: "accepted"}} ->
        put_flash(socket, :info, "You and @#{username} are now friends!")

      {:ok, _} ->
        put_flash(socket, :info, "Request sent to @#{username}.")

      {:error, :not_found} ->
        put_flash(socket, :error, "No user named @#{username} here.")

      {:error, :self} ->
        put_flash(socket, :error, "That's you.")

      {:error, :already_friends} ->
        put_flash(socket, :error, "You are already friends with @#{username}.")

      {:error, :already_requested} ->
        put_flash(socket, :error, "Request to @#{username} is already pending.")

      {:error, _} ->
        put_flash(socket, :error, "Could not send request.")
    end
  end

  defp refresh(socket) do
    user = socket.assigns.current_scope.user
    pending = Messaging.list_pending_notifications(user)
    friends = Social.list_friends(user)
    groups = Social.list_groups(user)

    delivery_policies =
      user
      |> Messaging.list_delivery_policies()
      |> Map.new(&{{&1.subject_type, to_string(&1.subject_id)}, &1})

    assign(socket,
      pending: pending,
      pending_count: length(pending),
      invitation_acceptances: Accounts.list_unseen_invitation_acceptances(user),
      friends: friends,
      groups: groups,
      contact_notes: Social.list_contact_notes(user),
      group_notes: Social.list_group_notes(user),
      delivery_policies: delivery_policies,
      key_changes:
        Enum.filter(friends, &(&1.pending_public_key && &1.pending_public_key != &1.public_key)),
      incoming: Social.list_incoming_requests(user),
      outgoing: Social.list_outgoing_requests(user),
      presence: Presence.states(friends),
      conversations: build_conversations(user, friends)
    )
  end

  # Appearance choices for the header dropdown. "Simple" themes follow the
  # active site theme; the playful ones commit to their own palette. The
  # values must stay in sync with ContactsTheme's allowed set in hooks.js and
  # the [data-contacts-theme="..."] rules in app.css.
  defp theme_options do
    [
      {"Simple", [{"classic", "Classic"}, {"quiet", "Quiet"}]},
      {"Playful",
       [
         {"bubblegum", "Bubblegum"},
         {"aurora", "Aurora Glass"},
         {"arcade", "Arcade Neon"},
         {"blueprint", "Blueprint"},
         {"comic", "Comic Pop"},
         {"vapor", "Vaporwave"}
       ]},
      {"Experimental", [{"orbit", "Orbit (3D)"}, {"soiree", "Soiree (3D party)"}]}
    ]
  end

  defp addable_friends(friends, group) do
    member_ids = MapSet.new(group.members, & &1.id)
    Enum.reject(friends, &MapSet.member?(member_ids, &1.id))
  end

  defp build_conversations(user, friends) do
    handle_to_friend = Map.new(friends, &{Social.Address.handle(&1), &1})
    archives = Messaging.list_thread_archives(user)

    user
    |> Messaging.list_conversation_summaries()
    |> Enum.reject(fn summary ->
      case archives[summary.key] do
        %{archived: true} -> true
        _ -> false
      end
    end)
    |> Enum.map(fn summary ->
      archive = archives[summary.key]
      participants = summary.participants

      reply_ids =
        participants
        |> Enum.map(&handle_to_friend[&1])
        |> Enum.reject(&is_nil/1)
        |> Enum.map(& &1.id)

      avatar_user =
        case participants do
          ["notes to yourself"] -> user
          [handle] -> handle_to_friend[handle]
          _ -> nil
        end

      %{
        key: summary.key,
        participants: participants,
        message_count: summary.message_count,
        unread_count: summary.unread_count,
        latest: summary.latest_envelope,
        started_at: (archive && archive.started_at) || summary.started_at,
        preserved: archive != nil,
        reply_ids: Enum.join(reply_ids, ","),
        policy_id: if(length(reply_ids) == 1, do: List.first(reply_ids)),
        avatar_user: avatar_user
      }
    end)
  end

  defp conversation_title(conversation) do
    title = Enum.join(conversation.participants, ", ")

    if conversation.preserved do
      "#{title} · #{Calendar.strftime(conversation.started_at, "%b %d, %Y")}"
    else
      title
    end
  end

  defp profile_note(_notes, nil), do: ""
  defp profile_note(notes, profile), do: Map.get(notes, profile.id, "")

  defp profile_editable?(_friends, nil), do: false
  defp profile_editable?(friends, profile), do: Enum.any?(friends, &(&1.id == profile.id))

  defp avatar_texture_url(%{host: nil} = user), do: Accounts.avatar_url(user)

  defp avatar_texture_url(%{
         id: id,
         host: host,
         has_avatar: true,
         avatar_version: version
       })
       when is_binary(host) and is_integer(version) and version > 0 do
    ~p"/avatar-textures/#{id}?v=#{version}"
  end

  defp avatar_texture_url(_user), do: nil

  defp error_from(%Ecto.Changeset{errors: [{_field, {msg, _}} | _]}), do: msg
  defp error_from(_), do: "Something went wrong."

  attr :subject_type, :string, required: true
  attr :subject_id, :any, required: true
  attr :policies, :map, required: true
  attr :compact, :boolean, default: false

  defp auto_open_control(assigns) do
    subject_id = to_string(assigns.subject_id)
    policy = Map.get(assigns.policies, {assigns.subject_type, subject_id})

    assigns =
      assigns
      |> assign(:subject_id_string, subject_id)
      |> assign(:enabled, not is_nil(policy) and policy.acceptance == "automatic")

    ~H"""
    <button
      id={"auto-open-#{@subject_type}-#{@subject_id_string}"}
      type="button"
      role="switch"
      aria-checked={to_string(@enabled)}
      aria-label={
        if(@enabled,
          do: "Disable automatic message opening",
          else: "Enable automatic message opening"
        )
      }
      title={if(@enabled, do: "Automatic opening is on", else: "Automatic opening is off")}
      phx-click="toggle_auto_open"
      phx-value-subject_type={@subject_type}
      phx-value-subject_id={@subject_id_string}
      class={[
        "group inline-flex h-6 w-11 shrink-0 items-center rounded-full border p-0.5 transition duration-200 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
        @enabled && "border-primary bg-primary",
        !@enabled && "border-base-300 bg-base-300",
        @compact && "ml-1"
      ]}
    >
      <span class={[
        "flex size-5 items-center justify-center rounded-full bg-white text-[10px] shadow-sm transition duration-200",
        @enabled && "translate-x-5 text-primary",
        !@enabled && "translate-x-0 text-base-content/50"
      ]}>
        <.icon name={if(@enabled, do: "hero-lock-open", else: "hero-lock-closed")} class="size-3" />
      </span>
      <span class="sr-only">Automatic message opening</span>
    </button>
    """
  end
end
