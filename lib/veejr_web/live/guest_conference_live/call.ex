defmodule VeejrWeb.GuestConferenceLive.Call do
  use VeejrWeb, :live_view

  alias Veejr.{Calls, GuestConferences}

  @impl true
  def render(assigns), do: VeejrWeb.CallLive.render(assigns)

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    with conference when not is_nil(conference) <- GuestConferences.get_by_token(token),
         "admitted" <- conference.state,
         {:ok, call} <- Calls.get_guest_call(conference) do
      actor = guest_actor(conference)

      if connected?(socket) do
        Calls.subscribe(call)
        Calls.register_presence(call.public_id, Calls.guest_presence_id(conference))

        case call.state do
          "ringing" -> Calls.join_guest_call(conference)
          _ -> :ok
        end
      end

      {:ok,
       assign(socket,
         page_title: "Guest call",
         call: call,
         role: "callee",
         peer: call.host,
         actor: actor,
         # The mesh id, not the identity-key handle in `actor.id`: "guest" is
         # what the host's side calls this participant.
         local_id: "guest",
         layout_scope: nil,
         pending_count: nil,
         is_guest: true,
         allow_reinvite: false,
         # The guest's only peer is the host. "host" is the stable id both
         # sides use, matching the `from: "host"` on relayed signals.
         peers: [
           %{
             id: "host",
             name: call.host.display_name || call.host.username,
             public_key: call.host.public_key,
             state: "joined"
           }
         ],
         can_add_participant: false,
         addable_friends: [],
         show_add_participant: false,
         conference: conference,
         token: token,
         return_to: ~p"/guest/#{token}",
         ice_servers: Jason.encode!(Veejr.Calls.IceConfig.servers())
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That guest call is no longer available.")
         |> push_navigate(to: ~p"/guest/#{token}", replace: true)}
    end
  end

  @impl true
  def handle_event("signal", %{"ciphertext" => ciphertext, "nonce" => nonce}, socket) do
    Calls.signal_guest(socket.assigns.conference, ciphertext, nonce)
    {:noreply, socket}
  end

  def handle_event("hangup", _params, socket) do
    Calls.end_guest_call(socket.assigns.conference)
    {:noreply, push_navigate(socket, to: socket.assigns.return_to, replace: true)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:call_peer_joined, _id, _participant}, socket) do
    {:noreply, push_event(socket, "call:peer_joined", %{peer: "host"})}
  end

  def handle_info({:call_signal, _id, from_id, _target, ciphertext, nonce}, socket) do
    if from_id == Calls.guest_presence_id(socket.assigns.conference) do
      {:noreply, socket}
    else
      # A guest call has exactly one other side, so it is always the host.
      {:noreply,
       push_event(socket, "call:signal", %{ciphertext: ciphertext, nonce: nonce, from: "host"})}
    end
  end

  def handle_info({:call_ended, _id, _reason}, socket) do
    {:noreply, push_navigate(socket, to: socket.assigns.return_to, replace: true)}
  end

  def handle_info({:call_disconnected, _id, _departed}, socket) do
    {:noreply, push_navigate(socket, to: socket.assigns.return_to, replace: true)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if conference = socket.assigns[:conference] do
      Calls.end_guest_call_after_grace(conference)
    end

    :ok
  end

  defp guest_actor(conference) do
    %{
      id: "guest-#{conference.id}",
      username: conference.display_name,
      display_name: conference.display_name,
      public_key: conference.public_key,
      enc_secret_key: nil,
      key_salt: nil,
      key_nonce: nil
    }
  end
end
