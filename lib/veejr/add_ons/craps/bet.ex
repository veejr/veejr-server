defmodule Veejr.AddOns.Craps.Bet do
  @moduledoc """
  One wager sitting on the table.

  `target` is the number the bet rides on — the come point for a come bet, the
  point behind an odds bet — and stays `nil` for a come bet that has not
  travelled yet and for every bet that rides on nothing in particular.

  An `off` bet stays on the table but does not play: no roll wins it or loses
  it until its owner turns it back on.
  """

  alias Veejr.AddOns.Craps.Bets

  @enforce_keys [:id, :player_id, :type, :amount]
  defstruct [:id, :player_id, :type, :amount, target: nil, off: false]

  @type t :: %__MODULE__{
          id: term(),
          player_id: term(),
          type: Bets.bet_type(),
          amount: pos_integer(),
          target: Bets.target(),
          off: boolean()
        }
end
