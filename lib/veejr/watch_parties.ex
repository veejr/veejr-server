defmodule Veejr.WatchParties do
  @moduledoc """
  Ephemeral, instance-local YouTube watch parties.

  The server retains only the YouTube video id and current playback direction.
  Browsers stream from YouTube directly. One party may be active at a time and
  every control command is authorized against its initiating user.
  """

  use GenServer

  alias Phoenix.PubSub
  alias Veejr.Social.Address

  @global_topic "watch_parties"
  @host_timeout_ms 90_000
  @video_id_re ~r/^[A-Za-z0-9_-]{11}$/
  @email_re ~r/^[^@\s,;]+@[^@\s,;]+$/
  @max_guest_invites 25

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  def subscribe do
    PubSub.subscribe(Veejr.PubSub, @global_topic)
  end

  def subscribe(public_id) do
    PubSub.subscribe(Veejr.PubSub, party_topic(public_id))
  end

  def active_party(server \\ __MODULE__), do: GenServer.call(server, :active_party)

  def start_party(user, input, server \\ __MODULE__) do
    with {:ok, video_id} <- extract_video_id(input) do
      GenServer.call(server, {:start_party, user, video_id})
    end
  end

  def end_party(public_id, user_id, server \\ __MODULE__) do
    GenServer.call(server, {:end_party, public_id, user_id})
  end

  def control(public_id, user_id, command, position, server \\ __MODULE__) do
    GenServer.call(server, {:control, public_id, user_id, command, position})
  end

  def join_voice(public_id, user, pid \\ self(), server \\ __MODULE__) do
    GenServer.call(server, {:join_voice, public_id, user, pid})
  end

  def signal_voice(
        public_id,
        participant_id,
        target_id,
        ciphertext,
        nonce,
        server \\ __MODULE__
      ) do
    GenServer.call(
      server,
      {:signal_voice, public_id, participant_id, target_id, ciphertext, nonce}
    )
  end

  @doc "Creates one private guest capability per comma-separated email."
  def create_guest_invites(public_id, host_id, input, server \\ __MODULE__) do
    with {:ok, emails} <- parse_guest_emails(input) do
      GenServer.call(server, {:create_guest_invites, public_id, host_id, emails})
    end
  end

  @doc "Returns the active party authorized by a guest capability."
  def guest_party(token, server \\ __MODULE__)

  def guest_party(token, server) when is_binary(token) and byte_size(token) > 0 do
    GenServer.call(server, {:guest_party, token_hash(token)})
  end

  def guest_party(_token, _server), do: nil

  @doc "Revokes one guest capability after an invitation email fails."
  def revoke_guest_invite(public_id, host_id, token, server \\ __MODULE__)
      when is_binary(token) do
    GenServer.call(server, {:revoke_guest_invite, public_id, host_id, token_hash(token)})
  end

  def parse_guest_emails(input) when is_binary(input) do
    emails =
      input
      |> String.split(~r/[,\r\n]+/, trim: true)
      |> Enum.map(&(String.trim(&1) |> String.downcase()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      emails == [] ->
        {:error, :no_guest_emails}

      length(emails) > @max_guest_invites ->
        {:error, :too_many_guest_emails}

      invalid = Enum.find(emails, &(byte_size(&1) > 160 or not Regex.match?(@email_re, &1))) ->
        {:error, {:invalid_guest_email, invalid}}

      true ->
        {:ok, emails}
    end
  end

  def parse_guest_emails(_input), do: {:error, :no_guest_emails}

  def extract_video_id(input) when is_binary(input) do
    input = String.trim(input)

    cond do
      Regex.match?(@video_id_re, input) -> {:ok, input}
      true -> extract_video_id_from_uri(URI.parse(input))
    end
  end

  def extract_video_id(_input), do: {:error, :invalid_youtube_url}

  @impl true
  def init(_state),
    do: {:ok, %{party: nil, expiry_ref: nil, participants: %{}, guest_invites: %{}}}

  @impl true
  def handle_call(:active_party, _from, state), do: {:reply, state.party, state}

  def handle_call({:start_party, _user, _video_id}, _from, %{party: party} = state)
      when not is_nil(party) do
    {:reply, {:error, :party_active}, state}
  end

  def handle_call({:start_party, user, video_id}, _from, state) do
    party = %{
      public_id: Ecto.UUID.generate(),
      host_id: user.id,
      host: user.display_name || Address.handle(user),
      video_id: video_id,
      playback: "paused",
      position: 0.0
    }

    state = schedule_expiry(%{state | party: party})
    PubSub.broadcast(Veejr.PubSub, @global_topic, {:watch_party_started, party})
    {:reply, {:ok, party}, state}
  end

  def handle_call({:end_party, public_id, user_id}, _from, state) do
    case state.party do
      %{public_id: ^public_id, host_id: ^user_id} = party ->
        broadcast_ended(party)
        {:reply, :ok, clear_party(state)}

      %{public_id: ^public_id} ->
        {:reply, {:error, :not_host}, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:control, public_id, user_id, command, position}, _from, state) do
    with %{public_id: ^public_id, host_id: ^user_id} = party <- state.party,
         true <- command in ["playing", "paused"],
         {:ok, position} <- valid_position(position) do
      party = %{party | playback: command, position: position}
      PubSub.broadcast(Veejr.PubSub, party_topic(public_id), {:watch_party_control, party})
      {:reply, :ok, schedule_expiry(%{state | party: party})}
    else
      %{public_id: ^public_id} -> {:reply, {:error, :not_host}, state}
      _ -> {:reply, {:error, :invalid_control}, state}
    end
  end

  def handle_call(
        {:create_guest_invites, public_id, host_id, emails},
        _from,
        %{party: %{public_id: public_id, host_id: host_id}} = state
      ) do
    existing =
      Map.reject(state.guest_invites, fn {_hash, invitation} ->
        invitation.email in emails
      end)

    {invitations, guest_invites} =
      Enum.map_reduce(emails, existing, fn email, invites ->
        token = random_token()
        hash = token_hash(token)
        invitation = %{email: email, token_hash: hash}
        {%{email: email, token: token}, Map.put(invites, hash, invitation)}
      end)

    {:reply, {:ok, invitations}, %{state | guest_invites: guest_invites}}
  end

  def handle_call({:create_guest_invites, _public_id, _host_id, _emails}, _from, state) do
    {:reply, {:error, :not_host}, state}
  end

  def handle_call({:guest_party, token_hash}, _from, state) do
    party = if state.party && Map.has_key?(state.guest_invites, token_hash), do: state.party
    {:reply, party, state}
  end

  def handle_call(
        {:revoke_guest_invite, public_id, host_id, token_hash},
        _from,
        %{party: %{public_id: public_id, host_id: host_id}} = state
      ) do
    {:reply, :ok, %{state | guest_invites: Map.delete(state.guest_invites, token_hash)}}
  end

  def handle_call({:revoke_guest_invite, _public_id, _host_id, _token_hash}, _from, state) do
    {:reply, {:error, :not_host}, state}
  end

  def handle_call(
        {:join_voice, public_id, user, pid},
        _from,
        %{party: %{public_id: public_id}} = state
      )
      when is_pid(pid) and is_binary(user.public_key) do
    participant = %{
      id: Ecto.UUID.generate(),
      user_id: user.id,
      name: user.display_name || Address.handle(user),
      public_key: user.public_key,
      pid: pid,
      monitor_ref: Process.monitor(pid)
    }

    peers = state.participants |> Map.values() |> Enum.map(&public_participant/1)
    participants = Map.put(state.participants, participant.id, participant)

    PubSub.broadcast(
      Veejr.PubSub,
      party_topic(public_id),
      {:watch_voice_joined, public_participant(participant)}
    )

    {:reply, {:ok, public_participant(participant), peers}, %{state | participants: participants}}
  end

  def handle_call({:join_voice, _public_id, _user, _pid}, _from, state) do
    {:reply, {:error, :not_found}, state}
  end

  def handle_call(
        {:signal_voice, public_id, participant_id, target_id, ciphertext, nonce},
        {caller_pid, _tag},
        state
      )
      when is_binary(ciphertext) and is_binary(nonce) and byte_size(ciphertext) <= 100_000 and
             byte_size(nonce) <= 200 do
    with %{public_id: ^public_id} <- state.party,
         %{pid: ^caller_pid} = sender <- Map.get(state.participants, participant_id),
         %{} <- Map.get(state.participants, target_id) do
      PubSub.broadcast(
        Veejr.PubSub,
        party_topic(public_id),
        {:watch_voice_signal, target_id, public_participant(sender), ciphertext, nonce}
      )

      {:reply, :ok, state}
    else
      _ -> {:reply, {:error, :invalid_signal}, state}
    end
  end

  def handle_call(
        {:signal_voice, _public_id, _participant_id, _target_id, _ciphertext, _nonce},
        _from,
        state
      ) do
    {:reply, {:error, :invalid_signal}, state}
  end

  @impl true
  def handle_info({:expire, public_id}, %{party: %{public_id: public_id} = party} = state) do
    broadcast_ended(party)
    {:noreply, clear_party(state)}
  end

  def handle_info({:expire, _public_id}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Enum.find(state.participants, fn {_id, participant} ->
           participant.monitor_ref == monitor_ref
         end) do
      {participant_id, _participant} ->
        participants = Map.delete(state.participants, participant_id)

        if state.party do
          PubSub.broadcast(
            Veejr.PubSub,
            party_topic(state.party.public_id),
            {:watch_voice_left, participant_id}
          )
        end

        {:noreply, %{state | participants: participants}}

      nil ->
        {:noreply, state}
    end
  end

  defp extract_video_id_from_uri(%URI{scheme: scheme, host: host} = uri)
       when scheme in ["http", "https"] do
    host = host && String.downcase(host)

    candidate =
      case host do
        host when host in ["youtu.be", "www.youtu.be"] ->
          first_path_segment(uri.path)

        host when host in ["youtube.com", "www.youtube.com", "m.youtube.com"] ->
          youtube_path_id(uri)

        host when host in ["youtube-nocookie.com", "www.youtube-nocookie.com"] ->
          embedded_id(uri.path)

        _ ->
          nil
      end

    if is_binary(candidate) and Regex.match?(@video_id_re, candidate) do
      {:ok, candidate}
    else
      {:error, :invalid_youtube_url}
    end
  end

  defp extract_video_id_from_uri(_uri), do: {:error, :invalid_youtube_url}

  defp youtube_path_id(%URI{path: "/watch", query: query}) do
    query
    |> then(&(&1 || ""))
    |> URI.decode_query()
    |> Map.get("v")
  end

  defp youtube_path_id(%URI{path: path}), do: embedded_id(path)

  defp embedded_id(path) do
    case String.split(path || "", "/", trim: true) do
      [kind, video_id | _] when kind in ["embed", "shorts", "live"] -> video_id
      _ -> nil
    end
  end

  defp first_path_segment(path), do: path |> String.split("/", trim: true) |> List.first()

  defp valid_position(position) when is_integer(position) and position >= 0 and position < 86_400,
    do: {:ok, position * 1.0}

  defp valid_position(position) when is_float(position) and position >= 0 and position < 86_400,
    do: {:ok, position}

  defp valid_position(_position), do: {:error, :invalid_position}

  defp schedule_expiry(state) do
    if state.expiry_ref, do: Process.cancel_timer(state.expiry_ref)
    ref = Process.send_after(self(), {:expire, state.party.public_id}, @host_timeout_ms)
    %{state | expiry_ref: ref}
  end

  defp clear_party(state) do
    if state.expiry_ref, do: Process.cancel_timer(state.expiry_ref)

    Enum.each(state.participants, fn {_id, participant} ->
      Process.demonitor(participant.monitor_ref, [:flush])
    end)

    %{state | party: nil, expiry_ref: nil, participants: %{}, guest_invites: %{}}
  end

  defp broadcast_ended(party) do
    event = {:watch_party_ended, party.public_id}
    PubSub.broadcast(Veejr.PubSub, @global_topic, event)
    PubSub.broadcast(Veejr.PubSub, party_topic(party.public_id), event)
  end

  defp party_topic(public_id), do: "watch_party:#{public_id}"

  defp public_participant(participant) do
    Map.take(participant, [:id, :user_id, :name, :public_key])
  end

  defp random_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp token_hash(token), do: :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)
end
