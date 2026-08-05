defmodule Veejr.AddOns.Craps.State do
  @moduledoc """
  The come-out ↔ point phase machine.

  A round opens on the come-out. A 7 or 11 is a natural and a 2, 3, or 12 is
  craps; either way the shooter comes out again. Any other total establishes
  the point and moves to the point phase, where only rolling the point again
  or sevening out ends it.

  Pure: no process, no storage, no transport. Every function takes a state and
  returns a new one.
  """

  defstruct phase: :come_out, point: nil

  @type phase :: :come_out | :point
  @type point :: 4 | 5 | 6 | 8 | 9 | 10 | nil
  @type t :: %__MODULE__{phase: phase(), point: point()}

  @typedoc """
  What the roll did to the round.

  `:roll` is a point-phase roll that changed nothing — the round continues.
  """
  @type event :: :natural | :craps | :point_set | :point_made | :seven_out | :roll

  @doc "A fresh round, on the come-out with no point."
  @spec new() :: t()
  def new, do: %__MODULE__{phase: :come_out, point: nil}

  @doc """
  Applies a roll, returning what happened and the state that follows.

  Dispatches on the phase, so a come-out roll can never be mistakenly resolved
  against point-phase rules.
  """
  @spec apply_roll(t(), 1..6, 1..6) :: {event(), t()}
  def apply_roll(%__MODULE__{phase: :come_out} = state, die1, die2)
      when die1 in 1..6 and die2 in 1..6 do
    case die1 + die2 do
      total when total in [7, 11] -> {:natural, state}
      total when total in [2, 3, 12] -> {:craps, state}
      total -> {:point_set, %{state | phase: :point, point: total}}
    end
  end

  def apply_roll(%__MODULE__{phase: :point, point: point} = state, die1, die2)
      when die1 in 1..6 and die2 in 1..6 do
    case die1 + die2 do
      ^point -> {:point_made, new()}
      7 -> {:seven_out, new()}
      _other -> {:roll, state}
    end
  end
end
