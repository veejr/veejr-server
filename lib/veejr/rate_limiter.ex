defmodule Veejr.RateLimiter do
  @moduledoc """
  In-memory fixed-window rate limiting.

  `docs/REIMPLEMENTATION_SPEC.md` requires login, magic-link, registration,
  directory, invitation, upload, and federation endpoints to be rate limited.
  This module is the shared counter behind that requirement.

  Counters live in a single ETS table owned by this process, keyed by
  `{bucket, key, window}`. A fixed window is coarser than a sliding window or a
  token bucket — a caller can spend one window's budget at its end and the next
  window's at its start — but it needs one `:ets.update_counter/4` per request,
  no timers per key, and no external service. That matches an instance that is
  one BEAM node with one SQLite file.

  State is deliberately per-node and non-durable: a restart clears counters.
  For abuse mitigation on a single-writer instance that is an acceptable
  trade, and it keeps the limiter off the database write path.

  Limits are configured as `{limit, window_ms}` pairs:

      config :veejr, :rate_limits,
        enabled: true,
        login: {10, 60_000}

  ## Usage

      case Veejr.RateLimiter.check(:login, client_ip) do
        :ok -> ...
        {:error, retry_after_seconds} -> ...
      end
  """

  use GenServer

  @table __MODULE__

  # Conservative defaults, chosen so a legitimate human never notices them.
  # Each is {max_requests, window_milliseconds}.
  @default_limits [
    login: {10, :timer.minutes(1)},
    magic_link: {5, :timer.minutes(5)},
    registration: {5, :timer.hours(1)},
    directory: {60, :timer.minutes(1)},
    invitation: {20, :timer.hours(1)},
    upload: {60, :timer.minutes(1)},
    federation: {120, :timer.minutes(1)}
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Records one request against `bucket`/`key`.

  Returns `:ok` when the request is within budget, or `{:error, retry_after}`
  with the whole seconds remaining in the current window.
  """
  def check(bucket, key) when is_atom(bucket) do
    case limit_for(bucket) do
      nil ->
        :ok

      {limit, window_ms} ->
        if enabled?(), do: count(bucket, key, limit, window_ms), else: :ok
    end
  end

  @doc """
  Same as `check/2` but with an explicit limit, for callers that need a
  narrower budget than the configured bucket default.
  """
  def check(bucket, key, limit, window_ms)
      when is_atom(bucket) and is_integer(limit) and is_integer(window_ms) do
    if enabled?(), do: count(bucket, key, limit, window_ms), else: :ok
  end

  @doc "Clears every counter. Intended for tests."
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  defp count(_bucket, key, _limit, _window_ms) when key in [nil, "", "unknown"] do
    # Without a usable client identity there is nothing to bucket on. Failing
    # open is deliberate: bucketing every unidentified caller together would
    # let one of them lock out the rest.
    :ok
  end

  defp count(bucket, key, limit, window_ms) do
    now = System.system_time(:millisecond)
    window = div(now, window_ms)
    ets_key = {bucket, key, window}

    count = :ets.update_counter(@table, ets_key, {2, 1}, {ets_key, 0})

    if count > limit do
      window_ends_at = (window + 1) * window_ms
      {:error, max(1, ceil((window_ends_at - now) / 1000))}
    else
      :ok
    end
  end

  defp enabled? do
    Application.get_env(:veejr, :rate_limits, [])
    |> Keyword.get(:enabled, true)
  end

  defp limit_for(bucket) do
    configured = Application.get_env(:veejr, :rate_limits, [])

    case Keyword.get(configured, bucket, Keyword.get(@default_limits, bucket)) do
      {limit, window_ms} when is_integer(limit) and is_integer(window_ms) -> {limit, window_ms}
      _ -> nil
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  # Windows are keyed by index, so an entry is dead once its window has
  # passed. Sweeping keeps the table proportional to active callers rather
  # than to every caller ever seen.
  defp sweep do
    now = System.system_time(:millisecond)

    cutoffs =
      for {bucket, {_limit, window_ms}} <- all_limits(),
          into: %{},
          do: {bucket, div(now, window_ms)}

    :ets.foldl(
      fn {{bucket, _key, window} = ets_key, _count}, acc ->
        case Map.get(cutoffs, bucket) do
          nil -> acc
          current when window < current -> [ets_key | acc]
          _ -> acc
        end
      end,
      [],
      @table
    )
    |> Enum.each(&:ets.delete(@table, &1))
  end

  defp all_limits do
    configured = Application.get_env(:veejr, :rate_limits, [])

    @default_limits
    |> Keyword.merge(Keyword.delete(configured, :enabled))
    |> Enum.filter(fn
      {_bucket, {limit, window}} when is_integer(limit) and is_integer(window) -> true
      _ -> false
    end)
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, :timer.minutes(5))
end
