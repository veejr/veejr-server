defmodule VeejrWeb.NativeCallChannel do
  @moduledoc """
  Native-client calls: the `calls:v1` extension of client protocol v1.

  This is the native counterpart of `VeejrWeb.CallLive`. It drives the same
  `Veejr.Calls` lifecycle and listens on the same PubSub topics, so a native
  app and a browser are interchangeable ends of one call. The server's role
  is unchanged: it relays `nacl.box` ciphertext it cannot read and never sees
  media.

  A channel holds at most one active call — the one this device started or
  answered. Rings for other calls are only announced; the client answers one
  with `accept`. See `docs/CLIENT_PROTOCOL_V1.md` ("Calls extension") for the
  wire contract.
  """

  use Phoenix.Channel

  alias Veejr.Accounts.User
  alias Veejr.Calls
  alias Veejr.Calls.Call
  alias Veejr.Social.Address

  @impl true
  def join("calls:v1", _params, socket) do
    user = socket.assigns.user
    Phoenix.PubSub.subscribe(Veejr.PubSub, "user:#{user.id}")

    # A ring that arrived while the app was disconnected (it woke from a
    # push) is replayed once the channel is up.
    send(self(), :replay_pending_ring)

    {:ok, %{user_id: to_string(user.id), ice_servers: Calls.IceConfig.servers()},
     assign(socket, active_call: nil, watched: MapSet.new())}
  end

  ## Client → server

  @impl true
  def handle_in("start", %{"callee_id" => callee_id}, socket) do
    user = socket.assigns.user

    with {:ok, callee_id} <- parse_id(callee_id),
         {:ok, %Call{} = call} <- Calls.start_call(user, callee_id) do
      socket = activate(socket, call)

      # Starting again reuses an active call; if its callee already answered,
      # replay the join so this device begins negotiating.
      if call.state == "accepted" and call.caller_id == user.id do
        send(self(), {:call_peer_joined, call.public_id, call.callee_id})
      end

      {:reply, {:ok, call_json(call, user)}, socket}
    else
      {:error, reason} -> {:reply, error(reason), socket}
    end
  end

  def handle_in("accept", %{"call_id" => call_id}, socket) when is_binary(call_id) do
    user = socket.assigns.user

    with {:ok, %Call{} = call} <- Calls.get_call(user, call_id),
         {:ok, call} <- answer(user, call) do
      {:reply, {:ok, call_json(call, user)}, activate(socket, call)}
    else
      {:error, reason} -> {:reply, error(reason), socket}
    end
  end

  def handle_in("decline", %{"call_id" => call_id} = params, socket) when is_binary(call_id) do
    reason = if params["reason"] == "busy", do: "busy", else: "declined"

    case Calls.decline_call(socket.assigns.user, call_id, reason) do
      {:ok, _call} -> {:reply, :ok, unwatch(socket, call_id)}
      {:error, reason} -> {:reply, error(reason), socket}
    end
  end

  def handle_in("hangup", %{"call_id" => call_id}, socket) when is_binary(call_id) do
    user = socket.assigns.user

    # Hanging up an outgoing ring cancels the invitation; otherwise it leaves.
    case Calls.cancel_call(user, call_id) do
      {:ok, _call} -> :ok
      {:error, _} -> Calls.end_call(user, call_id)
    end

    {:reply, :ok, deactivate(socket, call_id)}
  end

  def handle_in(
        "signal",
        %{"call_id" => call_id, "ciphertext" => ct, "nonce" => nonce} = params,
        socket
      )
      when is_binary(call_id) and is_binary(ct) and is_binary(nonce) do
    with ^call_id <- socket.assigns.active_call,
         {:ok, target} <- parse_optional_id(params["target"]),
         :ok <- Calls.signal(socket.assigns.user, call_id, ct, nonce, target) do
      {:reply, :ok, socket}
    else
      {:error, reason} -> {:reply, error(reason), socket}
      _other -> {:reply, error(:not_active), socket}
    end
  end

  def handle_in(_event, _params, socket), do: {:reply, error(:bad_request), socket}

  ## Server → client

  @impl true
  def handle_info(:replay_pending_ring, socket) do
    case Calls.pending_ring(socket.assigns.user) do
      nil -> {:noreply, socket}
      call -> {:noreply, announce_ring(socket, call)}
    end
  end

  def handle_info({:veejr_call_ring, %Call{} = call}, socket) do
    {:noreply, announce_ring(socket, call)}
  end

  def handle_info({:veejr_call_cancelled, call_id}, socket) do
    {:noreply, ring_over(socket, call_id, "cancelled")}
  end

  def handle_info({:call_peer_joined, call_id, participant_id}, socket) do
    me = socket.assigns.user.id

    cond do
      call_id == socket.assigns.active_call and participant_id != me ->
        push_peer_joined(socket, call_id, participant_id)

      # This user answered on another device: stop ringing here.
      participant_id == me and MapSet.member?(socket.assigns.watched, call_id) ->
        {:noreply, ring_over(socket, call_id, "answered_elsewhere")}

      true ->
        {:noreply, socket}
    end
  end

  # Federated updates announce a join without saying who; in a 1:1 it is
  # always the other side.
  def handle_info({:call_peer_joined, call_id}, socket) do
    if call_id == socket.assigns.active_call,
      do: push_peer_joined(socket, call_id, nil),
      else: {:noreply, socket}
  end

  def handle_info({:call_signal, call_id, from_id, target_id, ciphertext, nonce}, socket) do
    me = socket.assigns.user.id

    if call_id == socket.assigns.active_call and is_integer(from_id) and from_id != me and
         target_id in [:any, me] do
      push(socket, "signal", %{
        call_id: call_id,
        from: to_string(from_id),
        ciphertext: ciphertext,
        nonce: nonce
      })
    end

    {:noreply, socket}
  end

  def handle_info({:call_participant_left, call_id, departed_id}, socket) do
    if call_id == socket.assigns.active_call and departed_id != socket.assigns.user.id do
      push(socket, "peer_left", %{call_id: call_id, peer_id: to_string(departed_id)})
    end

    {:noreply, socket}
  end

  def handle_info({:call_ended, call_id, reason}, socket) do
    {:noreply, finish(socket, call_id, reason)}
  end

  def handle_info({:call_disconnected, call_id, _departed_id}, socket) do
    {:noreply, finish(socket, call_id, "connection_lost")}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    # Same grace as a closed call page: a socket blip while the phone
    # switches networks must not read as a hang-up.
    if call_id = socket.assigns[:active_call] do
      Calls.end_call_after_grace(socket.assigns.user, call_id)
    end

    :ok
  end

  ## Helpers

  defp answer(%User{id: user_id} = user, %Call{} = call) do
    participant = Calls.participant(call, user_id)

    cond do
      call.state not in ["ringing", "accepted"] ->
        {:error, :ended}

      participant && participant.state == "ringing" ->
        Calls.join_call(user, call.public_id)

      # The caller's socket reconnected while its own call still rings:
      # reattach so presence and signaling follow this channel again.
      (participant && participant.state == "joined") and call.state == "ringing" and
          call.caller_id == user_id ->
        {:ok, call}

      # Reconnecting to a call this user is already in (the socket dropped,
      # or the app restarted mid-call). Re-announce so negotiation restarts.
      (participant && participant.state == "joined") and call.state == "accepted" ->
        if call.caller_id == user_id do
          send(self(), {:call_peer_joined, call.public_id, call.callee_id})
          {:ok, call}
        else
          Calls.rejoin_call(user, call.public_id)
        end

      true ->
        {:error, :not_ringing}
    end
  end

  defp activate(socket, %Call{public_id: call_id}) do
    # A ring being answered is already subscribed; subscribing twice would
    # deliver every signal twice.
    unless MapSet.member?(socket.assigns.watched, call_id) or
             socket.assigns.active_call == call_id do
      Calls.subscribe(call_id)
    end

    Calls.register_presence(call_id, socket.assigns.user.id)

    socket
    |> assign(:active_call, call_id)
    |> update_watched(&MapSet.delete(&1, call_id))
  end

  defp deactivate(socket, call_id) do
    if socket.assigns.active_call == call_id do
      Phoenix.PubSub.unsubscribe(Veejr.PubSub, "call:#{call_id}")
      Registry.unregister(Veejr.CallRegistry, {call_id, socket.assigns.user.id})
      assign(socket, :active_call, nil)
    else
      socket
    end
  end

  defp announce_ring(socket, %Call{public_id: call_id} = call) do
    if call_id == socket.assigns.active_call or MapSet.member?(socket.assigns.watched, call_id) do
      socket
    else
      # Watch the call topic so an answer elsewhere or a cancellation stops
      # this device ringing even if the per-user cancel is missed.
      Calls.subscribe(call_id)
      call = Veejr.Repo.preload(call, [:caller, :callee])

      push(socket, "ring", %{
        call_id: call_id,
        caller: peer_json(call.caller),
        expires_at: DateTime.to_unix(ring_expiry(call))
      })

      update_watched(socket, &MapSet.put(&1, call_id))
    end
  end

  defp update_watched(socket, fun), do: assign(socket, :watched, fun.(socket.assigns.watched))

  defp ring_over(socket, call_id, reason) do
    if MapSet.member?(socket.assigns.watched, call_id) do
      push(socket, "ring_cancelled", %{call_id: call_id, reason: reason})
      unwatch(socket, call_id)
    else
      socket
    end
  end

  defp unwatch(socket, call_id) do
    if MapSet.member?(socket.assigns.watched, call_id) and
         call_id != socket.assigns.active_call do
      Phoenix.PubSub.unsubscribe(Veejr.PubSub, "call:#{call_id}")
    end

    update_watched(socket, &MapSet.delete(&1, call_id))
  end

  defp finish(socket, call_id, reason) do
    cond do
      call_id == socket.assigns.active_call ->
        push(socket, "ended", %{call_id: call_id, reason: reason})
        deactivate(socket, call_id)

      MapSet.member?(socket.assigns.watched, call_id) ->
        ring_over(socket, call_id, reason)

      true ->
        socket
    end
  end

  defp push_peer_joined(socket, call_id, participant_id) do
    user = socket.assigns.user

    with {:ok, call} <- Calls.get_call(user, call_id),
         %{user: peer} <- joined_peer(call, user.id, participant_id) do
      push(socket, "peer_joined", %{call_id: call_id, peer: peer_json(peer)})
    end

    {:noreply, socket}
  end

  defp joined_peer(call, my_id, nil), do: call |> Calls.peer_participants(my_id) |> List.first()

  defp joined_peer(call, _my_id, participant_id) do
    call
    |> Calls.participants()
    |> Enum.find(&(&1.user_id == participant_id))
  end

  defp call_json(%Call{} = call, %User{id: my_id}) do
    %{
      call_id: call.public_id,
      state: call.state,
      role: if(call.caller_id == my_id, do: "caller", else: "callee"),
      peers:
        call
        |> Calls.peer_participants(my_id)
        |> Enum.map(&Map.put(peer_json(&1.user), :state, &1.state))
    }
  end

  defp peer_json(%User{} = user) do
    %{
      id: to_string(user.id),
      handle: Address.handle(user),
      display_name: user.display_name,
      public_key: user.public_key
    }
  end

  defp ring_expiry(%Call{inserted_at: inserted_at}),
    do: DateTime.add(inserted_at, Calls.ring_timeout_seconds())

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :bad_request}
    end
  end

  defp parse_id(_id), do: {:error, :bad_request}

  defp parse_optional_id(nil), do: {:ok, nil}
  defp parse_optional_id(id), do: parse_id(id)

  defp error({:bad_state, state}), do: {:error, %{reason: "bad_state", state: state}}
  defp error(reason) when is_atom(reason), do: {:error, %{reason: Atom.to_string(reason)}}
  defp error(_reason), do: {:error, %{reason: "failed"}}
end
