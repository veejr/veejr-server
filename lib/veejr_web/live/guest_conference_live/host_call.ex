defmodule VeejrWeb.GuestConferenceLive.HostCall do
  use VeejrWeb, :live_view

  alias Veejr.{Calls, GuestConferences}

  @impl true
  def render(assigns), do: VeejrWeb.CallLive.render(assigns)

  @impl true
  def mount(%{"public_id" => public_id}, _session, socket) do
    host = socket.assigns.current_scope.user

    with {:ok, conference} <- GuestConferences.get_for_host(host, public_id),
         call when not is_nil(call) <- conference.call,
         true <- call.state in ["ringing", "accepted"] do
      if connected?(socket) do
        Calls.subscribe(call)
        Calls.register_presence(call.public_id, host.id)

        if call.state == "accepted" do
          send(self(), {:call_peer_joined, call.public_id, :guest})
        end
      end

      {:ok,
       assign(socket,
         page_title: "Guest call",
         call: call,
         role: "caller",
         peer: guest_peer(conference),
         actor: host,
         # The mesh id the guest's side uses for this participant, which is
         # not the host's user id.
         local_id: "host",
         layout_scope: socket.assigns.current_scope,
         is_guest: false,
         allow_reinvite: false,
         # A guest conference is host plus one temporary guest, and the guest
         # has no account to add anyone with. Fixed single peer, no invites.
         peers: [guest_peer_entry(conference)],
         can_add_participant: false,
         addable_friends: [],
         show_add_participant: false,
         conference: conference,
         return_to: ~p"/guest-conferences/#{public_id}",
         ice_servers: Jason.encode!(Veejr.Calls.IceConfig.servers())
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That guest call is no longer available.")
         |> push_navigate(to: ~p"/guest-conferences/#{public_id}", replace: true)}
    end
  end

  @impl true
  def handle_event("signal", %{"ciphertext" => ciphertext, "nonce" => nonce}, socket) do
    Calls.signal_guest_host(
      socket.assigns.current_scope.user,
      socket.assigns.call,
      ciphertext,
      nonce
    )

    {:noreply, socket}
  end

  def handle_event("hangup", _params, socket) do
    Calls.end_guest_host_call(socket.assigns.current_scope.user, socket.assigns.call)
    {:noreply, push_navigate(socket, to: socket.assigns.return_to, replace: true)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:call_peer_joined, _id, _participant}, socket) do
    {:noreply, push_event(socket, "call:peer_joined", %{peer: "guest"})}
  end

  def handle_info({:call_signal, _id, from_id, _target, ciphertext, nonce}, socket) do
    if from_id == socket.assigns.current_scope.user.id do
      {:noreply, socket}
    else
      # The host's only peer is the temporary guest.
      {:noreply,
       push_event(socket, "call:signal", %{ciphertext: ciphertext, nonce: nonce, from: "guest"})}
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
    if call = socket.assigns[:call] do
      Calls.end_guest_host_call_after_grace(
        socket.assigns.current_scope.user,
        call
      )
    end

    :ok
  end

  defp guest_peer(conference) do
    %{
      id: "guest-#{conference.id}",
      username: conference.display_name,
      display_name: conference.display_name,
      public_key: conference.public_key
    }
  end

  # The mesh entry for the host's single peer. "guest" is the stable id both
  # sides use, matching the `from: "guest"` on relayed signals.
  defp guest_peer_entry(conference) do
    %{
      id: "guest",
      name: conference.display_name,
      public_key: conference.public_key,
      state: "joined"
    }
  end
end
