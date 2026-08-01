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
    * `:unknown` — no basis for an answer: the user is on another instance
      (presence is not federated yet), or they turned sharing off.

  `:unknown` is deliberately distinct from `:offline`. Reporting "offline"
  for someone we simply cannot see would be a lie, and a dot that lies is a
  dot people learn to ignore.

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

  Reads go straight to ETS from the calling process. Only writes go through
  the GenServer, which owns the table and the process monitors.
  """

  use GenServer

  alias Veejr.Accounts.User

  @table __MODULE__

  # A dropped socket is not evidence of leaving until this expires.
  @default_grace_ms 20_000
  # How long after that a user still reads as "recently here".
  @default_recent_ms 5 * 60 * 1_000

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

  @doc "The presence state of one user."
  @spec state(User.t() | nil) :: state()
  def state(%User{host: host}) when is_binary(host), do: :unknown
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
  def label(:unknown), do: "Not shared"

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

    {:reply, :ok, %{state | monitors: %{}, timers: %{}}}
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

  # Presence rides the per-user topic every app page already joins through
  # `VeejrWeb.LiveNotify`, so a contact list updates without subscribing to a
  # topic per contact.
  defp broadcast(user_id, presence) do
    for friend_id <- Veejr.Social.local_friend_ids(user_id) do
      Phoenix.PubSub.broadcast(
        Veejr.PubSub,
        "user:#{friend_id}",
        {:veejr_presence, user_id, presence}
      )
    end

    :ok
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
