defmodule Veejr.AddOns.Craps.Bets do
  @moduledoc """
  The bet board and its payout table.

  `payout/6` answers one question: given this bet and this roll, what happens?
  It never mutates anything and never decides what the dice did — the caller
  has already rolled and advanced `Veejr.AddOns.Craps.State`.

  ## Payouts are stake-inclusive

  A winning payout is the stake plus the winnings, because that is the whole
  amount returned to the player: a winning $10 pass line pays 20, not 10. A
  loss pays 0 (the stake was collected when the bet was placed) and a push
  returns the stake untouched.

  Winnings are computed with integer arithmetic and truncated toward zero, so
  a $12 place 6 at 7:6 returns 12 + 14 = 26 and never a fraction of a chip.
  """

  alias Veejr.AddOns.Craps.State

  @bet_types [
    :pass_line,
    :dont_pass,
    :pass_odds,
    :dont_pass_odds,
    :come,
    :dont_come,
    :come_odds,
    :dont_come_odds,
    :place_4,
    :place_5,
    :place_6,
    :place_8,
    :place_9,
    :place_10,
    :hard_4,
    :hard_6,
    :hard_8,
    :hard_10,
    :field,
    :any_seven,
    :any_craps,
    :yo,
    :aces,
    :ace_deuce,
    :boxcars,
    :horn,
    :big_6,
    :big_8
  ]

  @place_numbers %{place_4: 4, place_5: 5, place_6: 6, place_8: 8, place_9: 9, place_10: 10}
  @hard_numbers %{hard_4: 4, hard_6: 6, hard_8: 8, hard_10: 10}

  # What may be put down on the come-out. Come and don't come are absent
  # because a come bet on the come-out is just a pass line with extra steps,
  # and the place and hard-way numbers have no point to run against yet.
  #
  # Come odds are here on purpose: a come bet that already has its number
  # survives `point_made` into the next come-out, so its odds must be
  # placeable then too.
  @placeable_come_out [
    :pass_line,
    :dont_pass,
    :field,
    :any_seven,
    :any_craps,
    :yo,
    :aces,
    :ace_deuce,
    :boxcars,
    :horn,
    :come_odds,
    :dont_come_odds
  ]

  # Once a point is on, the whole board is open.
  @placeable_point @bet_types

  # One to a customer: a second pass line on the same round is not a thing.
  @single_bet_types [:pass_line, :dont_pass]

  @type bet_type :: atom()
  @type target :: 4 | 5 | 6 | 8 | 9 | 10 | nil

  @typedoc """
  What a roll did to one bet.

  `:come_point_set` means the come (or don't come) bet just moved to a number;
  the caller sets its target to the total rolled and keeps it on the table.
  """
  @type outcome ::
          {:win, non_neg_integer()}
          | {:lose, 0}
          | {:push, non_neg_integer()}
          | {:pending, nil}
          | {:come_point_set, nil}

  @doc "Every bet type the board accepts."
  @spec types() :: [bet_type()]
  def types, do: @bet_types

  @doc "Whether the board accepts this bet type."
  @spec type?(any()) :: boolean()
  def type?(bet_type), do: bet_type in @bet_types

  @doc "Whether this bet may be put down in this phase."
  @spec placeable?(bet_type(), State.phase()) :: boolean()
  def placeable?(bet_type, :come_out), do: bet_type in @placeable_come_out
  def placeable?(bet_type, :point), do: bet_type in @placeable_point

  @doc "Bets a player may hold only one of at a time."
  @spec single?(bet_type()) :: boolean()
  def single?(bet_type), do: bet_type in @single_bet_types

  @doc "The base bet an odds bet must sit behind, or `nil` if it is not an odds bet."
  @spec odds_base(bet_type()) :: bet_type() | nil
  def odds_base(:pass_odds), do: :pass_line
  def odds_base(:dont_pass_odds), do: :dont_pass
  def odds_base(:come_odds), do: :come
  def odds_base(:dont_come_odds), do: :dont_come
  def odds_base(_bet_type), do: nil

  @doc "Whether an odds bet has to name the number it rides on."
  @spec odds_needs_target?(bet_type()) :: boolean()
  def odds_needs_target?(bet_type), do: bet_type in [:come_odds, :dont_come_odds]

  @doc """
  Resolves one bet against one roll.

  `target` carries the number a bet is riding on: the come point for come and
  don't-come bets, and the point behind an odds bet. It is `nil` for a come
  bet that has not travelled yet, and for every bet that rides on nothing.
  """
  @spec payout(bet_type(), pos_integer(), target(), 1..6, 1..6, State.t()) :: outcome()
  def payout(bet_type, amount, target, die1, die2, %State{} = state)
      when die1 in 1..6 and die2 in 1..6 do
    resolve(bet_type, amount, target, die1, die2, die1 + die2, state)
  end

  # ── Line bets ──

  defp resolve(:pass_line, amount, _target, _d1, _d2, total, %State{phase: :come_out}) do
    cond do
      total in [7, 11] -> win(amount, {1, 1})
      total in [2, 3, 12] -> lose()
      true -> pending()
    end
  end

  defp resolve(:pass_line, amount, _target, _d1, _d2, total, %State{point: point}) do
    cond do
      total == point -> win(amount, {1, 1})
      total == 7 -> lose()
      true -> pending()
    end
  end

  # Don't pass bars the 12: on the come-out it pushes rather than winning, which
  # is the whole of the house's edge on the don't side.
  defp resolve(:dont_pass, amount, _target, _d1, _d2, total, %State{phase: :come_out}) do
    cond do
      total in [2, 3] -> win(amount, {1, 1})
      total == 12 -> push(amount)
      total in [7, 11] -> lose()
      true -> pending()
    end
  end

  defp resolve(:dont_pass, amount, _target, _d1, _d2, total, %State{point: point}) do
    cond do
      total == 7 -> win(amount, {1, 1})
      total == point -> lose()
      true -> pending()
    end
  end

  # ── Odds behind the line ──

  defp resolve(:pass_odds, amount, target, _d1, _d2, total, %State{point: point}) do
    case target || point do
      nil ->
        pending()

      on ->
        cond do
          total == on -> win(amount, pass_odds_multiplier(on))
          total == 7 -> lose()
          true -> pending()
        end
    end
  end

  defp resolve(:dont_pass_odds, amount, target, _d1, _d2, total, %State{point: point}) do
    case target || point do
      nil ->
        pending()

      on ->
        cond do
          total == 7 -> win(amount, dont_odds_multiplier(on))
          total == on -> lose()
          true -> pending()
        end
    end
  end

  # ── Come and don't come ──

  defp resolve(:come, amount, nil, _d1, _d2, total, _state) do
    cond do
      total in [7, 11] -> win(amount, {1, 1})
      total in [2, 3, 12] -> lose()
      true -> {:come_point_set, nil}
    end
  end

  defp resolve(:come, amount, target, _d1, _d2, total, _state) do
    cond do
      total == target -> win(amount, {1, 1})
      total == 7 -> lose()
      true -> pending()
    end
  end

  defp resolve(:dont_come, amount, nil, _d1, _d2, total, _state) do
    cond do
      total in [2, 3] -> win(amount, {1, 1})
      total == 12 -> push(amount)
      total in [7, 11] -> lose()
      true -> {:come_point_set, nil}
    end
  end

  defp resolve(:dont_come, amount, target, _d1, _d2, total, _state) do
    cond do
      total == 7 -> win(amount, {1, 1})
      total == target -> lose()
      true -> pending()
    end
  end

  defp resolve(:come_odds, _amount, nil, _d1, _d2, _total, _state), do: pending()

  defp resolve(:come_odds, amount, target, _d1, _d2, total, _state) do
    cond do
      total == target -> win(amount, pass_odds_multiplier(target))
      total == 7 -> lose()
      true -> pending()
    end
  end

  defp resolve(:dont_come_odds, _amount, nil, _d1, _d2, _total, _state), do: pending()

  defp resolve(:dont_come_odds, amount, target, _d1, _d2, total, _state) do
    cond do
      total == 7 -> win(amount, dont_odds_multiplier(target))
      total == target -> lose()
      true -> pending()
    end
  end

  # ── Place bets ──

  defp resolve(bet_type, amount, _target, _d1, _d2, total, _state)
       when is_map_key(@place_numbers, bet_type) do
    number = Map.fetch!(@place_numbers, bet_type)

    cond do
      total == number -> win(amount, place_multiplier(number))
      total == 7 -> lose()
      true -> pending()
    end
  end

  # ── Hard ways ──
  #
  # A hard way needs the pair. The same total rolled any other way ("easy")
  # kills it just as a 7 does.
  defp resolve(bet_type, amount, _target, die1, die2, total, _state)
       when is_map_key(@hard_numbers, bet_type) do
    number = Map.fetch!(@hard_numbers, bet_type)
    multiplier = if number in [4, 10], do: {7, 1}, else: {9, 1}

    cond do
      die1 == die2 and total == number -> win(amount, multiplier)
      total == number or total == 7 -> lose()
      true -> pending()
    end
  end

  # ── Single-roll bets ──

  defp resolve(:field, amount, _target, _d1, _d2, total, _state) do
    cond do
      total in [5, 6, 7, 8] -> lose()
      total in [2, 12] -> win(amount, {2, 1})
      true -> win(amount, {1, 1})
    end
  end

  defp resolve(:any_seven, amount, _t, _d1, _d2, total, _s),
    do: if(total == 7, do: win(amount, {4, 1}), else: lose())

  defp resolve(:any_craps, amount, _t, _d1, _d2, total, _s),
    do: if(total in [2, 3, 12], do: win(amount, {7, 1}), else: lose())

  defp resolve(:yo, amount, _t, _d1, _d2, total, _s),
    do: if(total == 11, do: win(amount, {15, 1}), else: lose())

  defp resolve(:aces, amount, _t, _d1, _d2, total, _s),
    do: if(total == 2, do: win(amount, {30, 1}), else: lose())

  defp resolve(:ace_deuce, amount, _t, _d1, _d2, total, _s),
    do: if(total == 3, do: win(amount, {15, 1}), else: lose())

  defp resolve(:boxcars, amount, _t, _d1, _d2, total, _s),
    do: if(total == 12, do: win(amount, {30, 1}), else: lose())

  # A horn is four bets in one: aces, ace-deuce, yo, boxcars, a quarter each.
  # One quarter can win while the other three lose, so the return is the
  # winning component's payout less the three lost quarters.
  defp resolve(:horn, amount, _target, _d1, _d2, total, _state) do
    case total do
      t when t in [2, 12] -> {:win, amount + div(amount * (30 - 3), 4)}
      t when t in [3, 11] -> {:win, amount + div(amount * (15 - 3), 4)}
      _other -> lose()
    end
  end

  # ── Big 6 / Big 8 ──

  defp resolve(:big_6, amount, _target, _d1, _d2, total, _state), do: big(amount, total, 6)
  defp resolve(:big_8, amount, _target, _d1, _d2, total, _state), do: big(amount, total, 8)

  defp resolve(bet_type, _amount, _target, _d1, _d2, _total, _state) do
    raise ArgumentError, "unknown craps bet type: #{inspect(bet_type)}"
  end

  defp big(amount, total, number) do
    cond do
      total == number -> win(amount, {1, 1})
      total == 7 -> lose()
      true -> pending()
    end
  end

  defp win(amount, {numerator, denominator}),
    do: {:win, amount + div(amount * numerator, denominator)}

  defp lose, do: {:lose, 0}
  defp push(amount), do: {:push, amount}
  defp pending, do: {:pending, nil}

  defp pass_odds_multiplier(4), do: {2, 1}
  defp pass_odds_multiplier(10), do: {2, 1}
  defp pass_odds_multiplier(5), do: {3, 2}
  defp pass_odds_multiplier(9), do: {3, 2}
  defp pass_odds_multiplier(6), do: {6, 5}
  defp pass_odds_multiplier(8), do: {6, 5}

  defp dont_odds_multiplier(4), do: {1, 2}
  defp dont_odds_multiplier(10), do: {1, 2}
  defp dont_odds_multiplier(5), do: {2, 3}
  defp dont_odds_multiplier(9), do: {2, 3}
  defp dont_odds_multiplier(6), do: {5, 6}
  defp dont_odds_multiplier(8), do: {5, 6}

  defp place_multiplier(4), do: {9, 5}
  defp place_multiplier(10), do: {9, 5}
  defp place_multiplier(5), do: {7, 5}
  defp place_multiplier(9), do: {7, 5}
  defp place_multiplier(6), do: {7, 6}
  defp place_multiplier(8), do: {7, 6}
end
