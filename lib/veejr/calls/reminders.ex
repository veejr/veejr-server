defmodule Veejr.Calls.Reminders do
  @moduledoc """
  Polls persisted scheduled calls and dispatches each reminder once.

  The database timestamp is the source of truth, so a restart merely delays a
  reminder until the next tick instead of losing it.
  """

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    Veejr.Calls.dispatch_due_reminders()
    schedule_tick()
    {:noreply, state}
  end

  defp schedule_tick do
    case Application.get_env(:veejr, :call_reminder_interval_ms, 30_000) do
      ms when is_integer(ms) and ms > 0 -> Process.send_after(self(), :tick, ms)
      _ -> :ok
    end
  end
end
