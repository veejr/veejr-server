defmodule Veejr.Presence do
  @moduledoc """
  Who is currently using this instance.

  Every authenticated app page registers here through `VeejrWeb.LiveNotify`,
  so "has veejr open somewhere" falls out of the LiveView processes that
  already exist — no polling, no heartbeat from the browser.

  ## States

    * `:online` — at least one live socket right now.
    * `:recently` — no socket, but there was one within the recent window.
    * `:offline` — nothing for longer than that.
    * `:unknown` — no basis for an answer: the contact's instance has not
      told us, is unreachable, does not speak presence, or the person turned
      sharing off.

  `:unknown` is deliberately distinct from `:offline`. Reporting "offline"
  for someone we simply cannot see would be a lie, and a dot that lies is a
  dot people learn to ignore.

  ## Contacts on other instances

  Presence for remote contacts is pushed, not polled: their instance tells
  ours when they arrive or leave (`Veejr.Federation.deliver_presence/2`), one
  request per peer rather than per contact. Polling would scale with viewers
  × contacts and would leak *when you look at your contacts page* to every
  server your friends use.

  Every assertion carries a TTL and is re-asserted on a slower heartbeat, so
  a peer that crashes mid-session decays to `:unknown` instead of leaving a
  dot lit forever. Deliveries never go through `Veejr.Federation.Outbox`: a
  presence update retried six hours later is not late, it is false.

  ## Why the states are coarse

  Mobile browsers drop and reconnect LiveView sockets constantly. A socket
  loss is therefore not evidence of anything for the first `@grace_ms`, and
  the transition out of `:online` is only broadcast once that grace expires —
  the same reasoning as the call-page registry in `Veejr.Calls`, which must
  not read a reconnect as a hangup. Nothing finer than these buckets is
  stored, and no timestamps are exposed: a per-minute record of when someone
  is at their computer is a behavioural log, not a feature.

  ## Storage

  ETS, not the database. Presence is ephemeral and flappy; a write per
  transition per user would be real WAL traffic for state that is worthless
  after a restart. Losing the table on boot is correct — the instance really
  does not know who is around until sockets reconnect.

  Reads go straight to ETS from the calling process. Writes to the local
  table go through the GenServer, which owns it along with the process
  monitors; the remote table is public so an inbound federation request can
  record what a peer told us without queueing behind page mounts.
  """

  use GenServer

  alias Veejr.Accounts.User

  @table __MODULE__
  # What peers have told us about their users: {user_id, state, expires_at_ms}.
  @remote_table __MODULE__.Remote
  # Peers that answered 404, so we stop posting into the void until they
  # upgrade: {authority, retry_after_ms}.
  @peers_table __MODULE__.Peers

  # A dropped socket is not evidence of leaving until this expires.
  @default_grace_ms 20_000
  # How long after that a user still reads as "recently here".
  @default_recent_ms 5 * 60 * 1_000
  # Re-assert online users to peers this often, and sweep expired remotes.
  @default_heartbeat_ms 2 * 60 * 1_000
  # How long a peer's assertion stands without being refreshed. Two missed
  # heartbeats before a contact decays to `:unknown`.
  @default_ttl_s 300
  # A peer cannot make us hold its claims longer than this.
  @max_ttl_s 900
  # How long to leave a peer alone after it 404s the presence endpoint.
  @default_unsupported_backoff_ms 60 * 60 * 1_000

  @wire_states %{
    "online" => :online,
    "recently" => :recently,
    "offline" => :offline,
    "unknown" => :unknown
  }

  @type state :: :online | :recently | :offline | :unknown

  ## Client

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Registers the calling process as a live page for `user`.

  The process is monitored, so a crashed or navigated-away LiveView releases
  its slot without any explicit untrack. Users who are remote or who turned
  sharing off are never tracked at all — the opt-out is enforced here, at the
  source, rather than by asking anyone downstream to please not look.
  """
  def track(%User{host: nil, presence_sharing: true, id: id}) do
    GenServer.call(__MODULE__, {:track, id, self()})
  end

  def track(%User{}), do: :ok

  @doc """
  Forgets a user entirely and tells their friends they are gone.

  Used when sharing is switched off mid-session: the rows and monitors have
  to go immediately, not whenever the open tabs happen to close.
  """
  def untrack(%User{id: id}), do: GenServer.call(__MODULE__, {:untrack, id})

  @doc false
  # Test support. Presence is global state keyed by user id, and the test
  # database hands the same ids out again after each rollback, so a suite
  # needs a way to start from nothing.
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc """
  Runs one heartbeat pass: expire assertions peers stopped refreshing, then
  re-assert our online users to the peers hosting their friends.

  A plain function so tests can drive it synchronously, the way the
  federation outbox and the janitor are driven (`:presence_heartbeat_ms` is
  `:never` in the test environment).
  """
  def tick, do: GenServer.call(__MODULE__, :tick)

  @doc """
  The presence state of one user.

  A remote contact's own `presence_sharing` column is not consulted: it is
  their instance's setting to enforce, and it does so by not sending. All we
  can read here is what their instance last told us, and whether that has
  gone stale.
  """
  @spec state(User.t() | nil) :: state()
  def state(%User{host: host, id: id}) when is_binary(host), do: remote_lookup(id)
  def state(%User{presence_sharing: false}), do: :unknown
  def state(%User{id: id}), do: lookup(id)
  def state(_), do: :unknown

  @doc """
  Presence for a list of users as a `%{user_id => state}` map.

  One pass for a whole contact list, so rendering a page of friends costs no
  more than rendering one.
  """
  @spec states([User.t()]) :: %{optional(integer()) => state()}
  def states(users) do
    Map.new(users, fn user -> {user.id, state(user)} end)
  end

  @doc "True when the state should be drawn as a live indicator."
  def visible?(state), do: state in [:online, :recently]

  @doc "Human-readable label for a presence state."
  def label(:online), do: "Online"
  def label(:recently), do: "Recently online"
  def label(:offline), do: "Offline"
  def label(:unknown), do: "Not known"

  ## Contacts on other instances

  @doc """
  Records what a peer just told us about one of its users, and tells that
  user's local friends.

  Called from the inbound federation request process, not the presence
  server: it already did the database work to resolve the contact and their
  local friends, and presence writes must not queue behind page mounts.

  `:unknown` means the peer is withdrawing the claim — the person turned
  sharing off — so the row goes rather than lingering as a stale dot.
  """
  def put_remote(user_id, presence, ttl_seconds, friend_ids)
      when is_integer(user_id) and is_list(friend_ids) do
    if presence == :unknown do
      :ets.delete(@remote_table, user_id)
    else
      ttl = ttl_seconds |> min(@max_ttl_s) |> max(1)
      expires_at = System.monotonic_time(:millisecond) + ttl * 1_000
      :ets.insert(@remote_table, {user_id, presence, expires_at})
    end

    for friend_id <- friend_ids, do: publish(friend_id, user_id, presence)

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Translates a wire state into an atom, or `:error` for anything else."
  def cast_state(value) when is_binary(value) do
    case Map.fetch(@wire_states, value) do
      {:ok, presence} -> {:ok, presence}
      :error -> :error
    end
  end

  def cast_state(_), do: :error

  @doc "The TTL this instance asks peers to hold its assertions for."
  def ttl_seconds, do: Application.get_env(:veejr, :presence_ttl_s, @default_ttl_s)

  @doc """
  Whether it is worth posting presence to `authority` right now.

  A peer running a version without the endpoint answers 404. Retrying that on
  every transition would be pure noise for both instances, so it is parked
  for an hour — long enough to stay quiet, short enough that an upgraded peer
  starts working again on its own.
  """
  def peer_supported?(authority) do
    case :ets.lookup(@peers_table, authority) do
      [{^authority, retry_at}] -> System.monotonic_time(:millisecond) >= retry_at
      [] -> true
    end
  rescue
    ArgumentError -> true
  end

  @doc false
  def mark_peer_unsupported(authority) do
    backoff =
      Application.get_env(
        :veejr,
        :presence_unsupported_backoff_ms,
        @default_unsupported_backoff_ms
      )

    :ets.insert(@peers_table, {authority, System.monotonic_time(:millisecond) + backoff})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def mark_peer_supported(authority) do
    :ets.delete(@peers_table, authority)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp remote_lookup(user_id) do
    case :ets.lookup(@remote_table, user_id) do
      [{^user_id, presence, expires_at}] ->
        # Silence is not evidence of absence: an expired assertion means the
        # peer stopped talking to us, not that the person went away.
        if System.monotonic_time(:millisecond) < expires_at, do: presence, else: :unknown

      [] ->
        :unknown
    end
  rescue
    ArgumentError -> :unknown
  end

  defp lookup(user_id) do
    case :ets.lookup(@table, user_id) do
      [{^user_id, count, _since}] when count > 0 ->
        :online

      [{^user_id, 0, since}] ->
        elapsed = System.monotonic_time(:millisecond) - since

        cond do
          elapsed < grace_ms() -> :online
          elapsed < grace_ms() + recent_ms() -> :recently
          true -> :offline
        end

      [] ->
        :offline
    end
  rescue
    # Reads must never take a page down if the table is not up yet.
    ArgumentError -> :offline
  end

  defp grace_ms, do: Application.get_env(:veejr, :presence_grace_ms, @default_grace_ms)
  defp recent_ms, do: Application.get_env(:veejr, :presence_recent_ms, @default_recent_ms)

  ## Server

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    # Public: inbound federation requests write these from their own process
    # rather than queueing behind every page mount.
    :ets.new(@remote_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@peers_table, [:named_table, :set, :public, read_concurrency: true])

    schedule_heartbeat()
    {:ok, %{monitors: %{}, timers: %{}}}
  end

  @impl true
  def handle_call({:track, user_id, pid}, _from, state) do
    ref = Process.monitor(pid)
    state = put_in(state.monitors[ref], user_id)

    was = current(user_id)
    :ets.insert(@table, {user_id, count(user_id) + 1, nil})

    state =
      state
      |> cancel_timer(user_id)
      |> announce(user_id, was)

    {:reply, :ok, state}
  end

  def handle_call({:untrack, user_id}, _from, state) do
    tracked? = :ets.member(@table, user_id)

    refs = for {ref, id} <- state.monitors, id == user_id, do: ref
    Enum.each(refs, &Process.demonitor(&1, [:flush]))

    :ets.delete(@table, user_id)

    state =
      state
      |> Map.update!(:monitors, &Map.drop(&1, refs))
      |> cancel_timer(user_id)

    # Sharing just went off, so the honest report to friends is "no longer
    # visible", not "offline". Nothing to announce if they were never shown.
    if tracked?, do: broadcast(user_id, :unknown)

    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    Enum.each(state.monitors, fn {ref, _user_id} -> Process.demonitor(ref, [:flush]) end)
    Enum.each(state.timers, fn {_user_id, timer} -> Process.cancel_timer(timer) end)
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@remote_table)
    :ets.delete_all_objects(@peers_table)

    {:reply, :ok, %{state | monitors: %{}, timers: %{}}}
  end

  def handle_call(:tick, _from, state) do
    beat()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {user_id, monitors} ->
        state = %{state | monitors: monitors}
        remaining = max(count(user_id) - 1, 0)

        state =
          if remaining == 0 do
            # Still :online for now — the grace period decides.
            :ets.insert(@table, {user_id, 0, System.monotonic_time(:millisecond)})
            schedule(state, user_id, :grace_expired, grace_ms())
          else
            :ets.insert(@table, {user_id, remaining, nil})
            state
          end

        {:noreply, state}
    end
  end

  def handle_info({:grace_expired, user_id}, state) do
    state = Map.update!(state, :timers, &Map.delete(&1, user_id))

    if count(user_id) == 0 do
      broadcast(user_id, :recently)
      {:noreply, schedule(state, user_id, :recent_expired, recent_ms())}
    else
      {:noreply, state}
    end
  end

  def handle_info({:recent_expired, user_id}, state) do
    state = Map.update!(state, :timers, &Map.delete(&1, user_id))

    if count(user_id) == 0 do
      # No row means offline, so the table stays small on a busy instance.
      :ets.delete(@table, user_id)
      broadcast(user_id, :offline)
    end

    {:noreply, state}
  end

  # Two jobs on one timer: re-assert to peers so nobody's TTL lapses while
  # they are still here, and expire assertions peers stopped refreshing.
  def handle_info(:heartbeat, state) do
    beat()
    schedule_heartbeat()

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## Internals

  defp count(user_id) do
    case :ets.lookup(@table, user_id) do
      [{^user_id, count, _since}] -> count
      [] -> 0
    end
  end

  defp current(user_id) do
    case :ets.lookup(@table, user_id) do
      [] -> :offline
      _ -> lookup(user_id)
    end
  end

  # Only a real change is worth waking every friend's LiveView for.
  defp announce(state, user_id, was) do
    now = lookup(user_id)
    if now != was, do: broadcast(user_id, now)
    state
  end

  # Local friends learn synchronously — it is a cheap indexed query and page
  # tests depend on the dot being right by the time `track/1` returns. Peers
  # learn in a task, because a dead instance must never stall a page mount
  # behind an eight-second timeout.
  defp broadcast(user_id, presence) do
    for friend_id <- Veejr.Social.local_friend_ids(user_id) do
      publish(friend_id, user_id, presence)
    end

    deliver_to_peers([{user_id, presence}])

    :ok
  end

  # Presence rides the per-user topic every app page already joins through
  # `VeejrWeb.LiveNotify`, so a contact list updates without subscribing to a
  # topic per contact.
  defp publish(friend_id, user_id, presence) do
    Phoenix.PubSub.broadcast(
      Veejr.PubSub,
      "user:#{friend_id}",
      {:veejr_presence, user_id, presence}
    )
  end

  @doc """
  Groups presence changes into one payload per peer that needs telling.

  Pure apart from the friendship lookup, and separate from delivery so the
  addressing can be tested without standing up a peer.
  """
  @spec peer_deliveries([{integer(), state()}]) :: [{String.t(), [map()]}]
  def peer_deliveries([]), do: []

  def peer_deliveries(changes) do
    states = Map.new(changes)

    states
    |> Map.keys()
    |> Veejr.Social.remote_friend_authorities()
    |> Enum.group_by(
      fn {_id, _username, authority} -> authority end,
      fn {id, username, _authority} ->
        %{username: username, state: Atom.to_string(Map.fetch!(states, id))}
      end
    )
    |> Enum.to_list()
  end

  defp deliver_to_peers([]), do: :ok

  defp deliver_to_peers(changes) do
    if federate?() do
      for {authority, entries} <- peer_deliveries(changes) do
        # Only the HTTP call is detached. The database work stays here, where
        # it is a cheap indexed query on a path that runs once per genuine
        # transition; it is the peer that might be dead for eight seconds,
        # and no page mount should ever wait behind that.
        Task.Supervisor.start_child(Veejr.TaskSupervisor, fn ->
          Veejr.Federation.deliver_presence(authority, entries)
        end)
      end
    end

    :ok
  end

  defp federate?, do: Application.get_env(:veejr, :presence_federation, true)

  defp beat do
    expire_remotes()
    reassert_to_peers()
  end

  # Everyone this instance currently considers online, told to the peers that
  # host their friends. One request per peer, however many contacts it holds.
  defp reassert_to_peers do
    online =
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {user_id, _count, _since} -> {user_id, lookup(user_id)} end)
      |> Enum.filter(fn {_id, presence} -> presence == :online end)

    deliver_to_peers(online)
  end

  # An assertion nobody refreshed says nothing about the person, only about
  # the link to their instance, so it decays to `:unknown` rather than to
  # `:offline`.
  defp expire_remotes do
    now = System.monotonic_time(:millisecond)
    expired = :ets.select(@remote_table, [{{:"$1", :_, :"$2"}, [{:<, :"$2", now}], [:"$1"]}])

    Enum.each(expired, fn user_id ->
      :ets.delete(@remote_table, user_id)

      for friend_id <- Veejr.Social.local_friend_ids(user_id) do
        publish(friend_id, user_id, :unknown)
      end
    end)
  end

  defp schedule_heartbeat do
    case Application.get_env(:veejr, :presence_heartbeat_ms, @default_heartbeat_ms) do
      ms when is_integer(ms) and ms > 0 -> Process.send_after(self(), :heartbeat, ms)
      _ -> :ok
    end
  end

  defp schedule(state, user_id, message, after_ms) do
    state = cancel_timer(state, user_id)
    timer = Process.send_after(self(), {message, user_id}, after_ms)
    put_in(state.timers[user_id], timer)
  end

  defp cancel_timer(state, user_id) do
    case Map.pop(state.timers, user_id) do
      {nil, _} ->
        state

      {timer, timers} ->
        Process.cancel_timer(timer)
        %{state | timers: timers}
    end
  end
end
