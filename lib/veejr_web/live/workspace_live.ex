defmodule VeejrWeb.WorkspaceLive do
  use VeejrWeb, :live_view

  alias Veejr.{Messaging, Social}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section
        id="private-workspace"
        phx-hook="PrivateWorkspace"
        phx-update="ignore"
        data-user-id={@current_scope.user.id}
        data-public-key={@current_scope.user.public_key}
        data-handle={Veejr.Social.Address.handle(@current_scope.user)}
        class="space-y-6"
      >
        <h1 class="text-2xl font-semibold tracking-tight">Your private workspace</h1>
        <nav class="flex flex-wrap gap-2" aria-label="Workspace">
          <button
            id="workspace-search-tab"
            data-tab="search"
            class="rounded-xl border border-base-300 px-4 py-2 transition hover:bg-base-200"
          >Search</button>
          <button
            id="workspace-lists-tab"
            data-tab="list"
            class="rounded-xl border border-base-300 px-4 py-2 transition hover:bg-base-200"
          >Shared lists</button>
          <button
            id="workspace-polls-tab"
            data-tab="poll"
            class="rounded-xl border border-base-300 px-4 py-2 transition hover:bg-base-200"
          >Polls</button>
          <button
            id="workspace-refresh"
            data-action="refresh"
            class="ml-auto rounded-xl px-4 py-2 transition hover:bg-base-200"
          >Refresh</button>
        </nav>
        <p data-status role="status" class="text-sm text-base-content/70"></p>
        <div data-content class="space-y-4"></div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Messaging.subscribe(socket.assigns.current_scope.user)
    {:ok, assign(socket, page_title: "Private workspace")}
  end

  @impl true
  def handle_event("workspace_page", params, socket) do
    scope = socket.assigns.current_scope
    cursor = params["cursor"]
    before_id = cursor && Messaging.history_cursor_id(scope.user, cursor)

    if cursor && is_nil(before_id) do
      {:reply, %{error: "Invalid history cursor."}, socket}
    else
      items = Messaging.list_history(scope.user, limit: 100, before_id: before_id)

      page =
        Enum.map(items, fn e ->
          %{
            id: e.public_id,
            kind: e.kind,
            ciphertext: e.ciphertext,
            nonce: e.nonce,
            peer_key: Messaging.peer_key(e, scope.user),
            sender: Social.Address.handle(e.sender),
            created_at: e.inserted_at,
            expires_at: e.expires_at,
            max_displays: e.max_displays,
            thread: e.thread_key
          }
        end)

      next = if length(items) == 100, do: List.last(items).public_id
      {:reply, %{items: page, cursor: next}, socket}
    end
  end

  def handle_event("workspace_recipients", _params, socket) do
    user = socket.assigns.current_scope.user

    result =
      VeejrWeb.RecipientResolver.resolve(user, %{
        "friend_ids" => Enum.map(Social.list_friends(user), &to_string(&1.id)),
        "include_self" => true
      })

    {:reply, result, socket}
  end

  def handle_event("workspace_send", %{"envelopes" => envelopes, "client_batch_id" => id}, socket) do
    case Messaging.send_batch(socket.assigns.current_scope.user, "message", envelopes, %{
           "client_batch_id" => id
         }) do
      {:ok, _, _} ->
        {:reply, %{ok: true}, socket}

      {:error, _} ->
        {:reply, %{error: "Could not share. Every participant must still be your friend."},
         socket}
    end
  end

  @impl true
  def handle_info({:veejr_notification, _}, socket),
    do: {:noreply, push_event(socket, "workspace:refresh", %{})}

  def handle_info(_message, socket), do: {:noreply, socket}
end
