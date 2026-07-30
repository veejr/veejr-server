defmodule Veejr.Messaging.Scheduler do
  @moduledoc """
  Polls for scheduled messages that have come due and note reminders that need
  to fire.

  The database timestamp is the source of truth, exactly as it is for
  `Veejr.Calls.Reminders`, so a restart delays work until the next tick rather
  than losing it. Nothing is held in this process's state.
  """

  use GenServer

  alias Veejr.Messaging

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs one sweep immediately, for tests and for the admin page."
  def sweep, do: GenServer.call(__MODULE__, :sweep)

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:sweep, _from, state), do: {:reply, run(), state}

  @impl true
  def handle_info(:tick, state) do
    run()
    schedule_tick()
    {:noreply, state}
  end

  defp run do
    sends = safely(&Messaging.dispatch_due_sends/0, %{released: 0, refused: 0, queued: 0})
    reminders = safely(&Messaging.dispatch_due_note_reminders/0, %{reminded: 0})
    Map.merge(sends, reminders)
  end

  # One bad row must not take the sweep down and leave every other due message
  # waiting for the next tick.
  defp safely(fun, fallback) do
    fun.()
  rescue
    error ->
      Logger.error("scheduler: sweep failed: #{Exception.message(error)}")
      fallback
  end

  defp schedule_tick do
    case Application.get_env(:veejr, :message_schedule_interval_ms, 30_000) do
      ms when is_integer(ms) and ms > 0 -> Process.send_after(self(), :tick, ms)
      _ -> :ok
    end
  end
end
