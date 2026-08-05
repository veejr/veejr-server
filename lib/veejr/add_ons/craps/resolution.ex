defmodule Veejr.AddOns.Craps.Resolution do
  @moduledoc """
  Settles every bet on the table against one roll.

  Splits the board three ways: bets that resolved and owe a payout, bets that
  stay up for the next roll, and bets that stayed up but changed — a come bet
  that just travelled to a number.

  Pure: it reports what is owed and does not move any chips.
  """

  alias Veejr.AddOns.Craps.{Bet, Bets, State}

  @type settlement :: %{
          bet_id: term(),
          player_id: term(),
          result: :win | :lose | :push,
          payout: non_neg_integer()
        }

  @type t :: %{
          resolved: [settlement()],
          remaining: [Bet.t()],
          updates: [Bet.t()]
        }

  @doc """
  Resolves `bets` against a roll.

  Returns `:resolved` settlements in board order, the `:remaining` bets to
  carry into the next roll, and the subset of those whose target changed as
  `:updates`, so a caller can tell players which come bets moved.
  """
  @spec resolve_all([Bet.t()], 1..6, 1..6, State.t()) :: t()
  def resolve_all(bets, die1, die2, %State{} = state) do
    {resolved, remaining, updates} =
      Enum.reduce(bets, {[], [], []}, fn %Bet{} = bet, {resolved, remaining, updates} ->
        case Bets.payout(bet.type, bet.amount, bet.target, die1, die2, state) do
          {:come_point_set, nil} ->
            moved = %{bet | target: die1 + die2}
            {resolved, [moved | remaining], [moved | updates]}

          {:pending, nil} ->
            {resolved, [bet | remaining], updates}

          {result, payout} ->
            {[settlement(bet, result, payout) | resolved], remaining, updates}
        end
      end)

    %{
      resolved: Enum.reverse(resolved),
      remaining: Enum.reverse(remaining),
      updates: Enum.reverse(updates)
    }
  end

  defp settlement(%Bet{} = bet, result, payout) do
    %{bet_id: bet.id, player_id: bet.player_id, result: result, payout: payout}
  end
end
