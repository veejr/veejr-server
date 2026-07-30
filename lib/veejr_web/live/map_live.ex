defmodule VeejrWeb.MapLive do
  use VeejrWeb, :live_view

  import VeejrWeb.MessagingComponents

  alias Veejr.{Messaging, Social}
  alias Veejr.Messaging.Envelope
  alias Veejr.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} pending_count={@pending_count}>
      <.header>
        Map
        <:subtitle>
          Locations and notes shared with you — decrypted only in your browser.
          Click the map to pin a spot for a note.
        </:subtitle>
      </.header>

      <div
        id="veejr-map"
        phx-hook="VeejrMap"
        phx-update="ignore"
        data-user-id={@current_scope.user.id}
        class="mt-4"
      >
        <p data-role="map-status" class="text-sm opacity-70 mb-2">Loading map…</p>
        <div data-role="map-canvas" class="h-96 w-full rounded-lg border border-base-300 z-0"></div>

        <ul class="hidden">
          <li
            :for={envelope <- @geo_envelopes}
            data-role="map-envelope"
            data-peer-key={Veejr.Messaging.peer_key(envelope, @current_scope.user)}
            data-ciphertext={envelope.ciphertext}
            data-nonce={envelope.nonce}
            data-kind={envelope.kind}
            data-label={map_label(envelope, @current_scope.user)}
            data-time={Calendar.strftime(envelope.inserted_at, "%b %d, %H:%M UTC")}
            data-public-id={envelope.public_id}
            data-delete-label={delete_label(envelope, @current_scope.user)}
            data-delete-confirm={delete_confirm(envelope, @current_scope.user)}
          >
          </li>
        </ul>

        <div class="mt-6 grid gap-6 lg:grid-cols-2">
          <section>
            <h2 class="text-lg font-semibold">Share my location</h2>
            <button type="button" data-role="locate" class="btn btn-sm btn-outline my-2">
              Use my current location
            </button>
            <.composer
              id="location-composer"
              user={@current_scope.user}
              friends={@friends}
              groups={@groups}
              kind="location"
              recipient_layout="dropdown"
              show_files={false}
              text_placeholder="Optional label, e.g. “at the cabin until Sunday”"
              submit_label="Share location"
            />
          </section>

          <section>
            <h2 class="text-lg font-semibold">Drop a note on the map</h2>
            <p data-role="picked-readout" class="text-sm opacity-70 my-2">
              Click the map to pin where the note goes.
            </p>
            <.composer
              id="note-composer"
              user={@current_scope.user}
              friends={@friends}
              groups={@groups}
              kind="note"
              recipient_layout="dropdown"
              show_files={false}
              text_placeholder="What's here? The note is encrypted end-to-end."
              submit_label="Pin note"
            />
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Map") |> refresh()}
  end

  @impl true
  def handle_event("resolve_recipients", params, socket) do
    {:reply, VeejrWeb.RecipientResolver.resolve(socket.assigns.current_scope.user, params),
     socket}
  end

  def handle_event(
        "send_batch",
        %{"kind" => kind, "envelopes" => envelopes} = params,
        socket
      )
      when kind in ["location", "note"] do
    opts = Map.take(params, ["attachment_ids"])

    case Messaging.send_batch(socket.assigns.current_scope.user, kind, envelopes, opts) do
      {:ok, batch_id, _queued} ->
        user = socket.assigns.current_scope.user

        socket =
          case Messaging.get_sent_self_copy(user, batch_id) do
            %Envelope{} = envelope ->
              push_event(socket, "map:item_added", map_entry(envelope, user))

            nil ->
              socket
          end

        {:reply, %{ok: true}, put_flash(socket, :info, "Shared on the map.")}

      {:error, _} ->
        {:reply, %{error: "Sharing failed — are all recipients still your friends?"}, socket}
    end
  end

  def handle_event("delete_envelope", %{"id" => public_id}, socket) do
    case Messaging.delete_envelope(socket.assigns.current_scope.user, public_id) do
      {:ok, {:deleted, _count}} ->
        {:reply, %{ok: true, message: "Deleted for every recipient."},
         socket
         |> put_flash(:info, "Deleted for every recipient.")
         |> refresh()}

      {:ok, :hidden} ->
        {:reply, %{ok: true, message: "Hidden from your map."},
         socket
         |> put_flash(:info, "Hidden from your map.")
         |> refresh()}

      {:error, _} ->
        {:reply, %{error: "Could not delete that map item."},
         socket
         |> put_flash(:error, "Could not delete that map item.")
         |> refresh()}
    end
  end

  @impl true
  def handle_info({:veejr_notification, _}, socket), do: {:noreply, socket}

  # Other broadcasts on the user's topic belong to other views; ignoring them
  # here keeps a new message type from crashing this one.
  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh(socket) do
    user = socket.assigns.current_scope.user

    geo =
      Messaging.list_history(user, kind: "location", limit: 200) ++
        Messaging.list_history(user, kind: "note", limit: 200)

    assign(socket,
      geo_envelopes: geo,
      friends: Social.list_friends(user),
      groups: Social.list_groups(user)
    )
  end

  defp map_label(%Envelope{sender_id: uid}, %User{id: uid}), do: "You"
  defp map_label(%Envelope{sender: sender}, _user), do: Veejr.Social.Address.handle(sender)

  defp map_entry(envelope, user) do
    %{
      ciphertext: envelope.ciphertext,
      nonce: envelope.nonce,
      kind: envelope.kind,
      label: map_label(envelope, user),
      time: Calendar.strftime(envelope.inserted_at, "%b %d, %H:%M UTC"),
      public_id: envelope.public_id,
      peer_key: Messaging.peer_key(envelope, user),
      delete_label: delete_label(envelope, user),
      delete_confirm: delete_confirm(envelope, user)
    }
  end

  defp delete_label(%Envelope{sender_id: uid}, %User{id: uid}), do: "Delete everywhere"
  defp delete_label(_envelope, _user), do: "Hide from my map"

  defp delete_confirm(%Envelope{sender_id: uid}, %User{id: uid}),
    do: "Delete this map item for every recipient? This cannot be undone."

  defp delete_confirm(_envelope, _user),
    do: "Hide this map item from your history?"
end
