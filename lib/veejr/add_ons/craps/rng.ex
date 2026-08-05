defmodule Veejr.AddOns.Craps.Rng do
  @moduledoc """
  The dice.

  The server draws the faces before the animation starts and the browser only
  stages a throw that lands on them, so nothing a client does can change a
  roll. That makes this the single place where the table's fairness lives.

  Draws come from `:crypto.strong_rand_bytes/1` with rejection sampling rather
  than `:rand`, so the sequence cannot be predicted from earlier rolls and the
  modulo is unbiased. At one roll every few seconds the cost is irrelevant and
  the property is worth having outright.

  ## Weights

  A weight table maps each `{die1, die2}` face pair to a non-negative integer
  drawn in proportion — they are relative, not probabilities, so `%{...}` with
  every entry `1` and every entry `100` behave identically. `fair_weights/0`
  is the honest table: 1 per combination, 1 in 36 each.

  A weighted table is how a house edge would be introduced. Veejr defaults to
  fair and shows the table's choice to its players; see `Veejr.AddOns`.
  """

  import Bitwise

  @combinations for die1 <- 1..6, die2 <- 1..6, do: {die1, die2}
  @fair_weights Map.new(@combinations, fn combination -> {combination, 1} end)

  # 1.12 sevens against 1.00 everything else, expressed as whole numbers so the
  # draw stays integer arithmetic. Ported from the reference implementation,
  # where this table was a server-side secret; here it is published.
  @seven_bias 112
  @house_weights Map.new(@combinations, fn {die1, die2} = combination ->
                   {combination, if(die1 + die2 == 7, do: @seven_bias, else: 100)}
                 end)

  @type combination :: {1..6, 1..6}
  @type weights :: %{optional(combination()) => non_neg_integer()}
  @type roll :: %{die1: 1..6, die2: 1..6, total: 2..12}

  @doc "All 36 ordered face pairs."
  @spec combinations() :: [combination()]
  def combinations, do: @combinations

  @doc "Equal weight on all 36 combinations."
  @spec fair_weights() :: weights()
  def fair_weights, do: @fair_weights

  @doc """
  The weighted table: sevens 1.12 times likelier than they should be.

  Every craps bet already carries its own edge, so this is a second one
  stacked on top. It exists because the reference implementation had it, and
  it is disclosed at the table rather than hidden.
  """
  @spec house_weights() :: weights()
  def house_weights, do: @house_weights

  @doc "How much likelier a seven is under `house_weights/0`, as a float."
  @spec seven_bias() :: float()
  def seven_bias, do: @seven_bias / 100

  @doc """
  The weight table for a dice mode, as stored in instance settings.

  See `Veejr.AddOns.craps_dice_mode/0`.
  """
  @spec weights_for(String.t()) :: weights()
  def weights_for("fair"), do: @fair_weights
  def weights_for("house"), do: @house_weights

  @doc """
  Draws one roll.

  A combination missing from `weights` is treated as weight 1, matching
  `fair_weights/0` for anything the caller did not bother to name.
  """
  @spec roll(weights()) :: roll()
  def roll(weights \\ @fair_weights) do
    total_weight = Enum.reduce(@combinations, 0, &(weight(weights, &1) + &2))

    if total_weight <= 0 do
      raise ArgumentError, "craps dice weights must leave at least one combination drawable"
    end

    {die1, die2} = pick(@combinations, weights, uniform_below(total_weight))
    %{die1: die1, die2: die2, total: die1 + die2}
  end

  # Walks the combinations subtracting weights until the draw is used up. A
  # zero-weight combination can never be selected because it never advances
  # past a draw that has already reached it.
  defp pick([combination | rest], weights, draw) do
    weight = weight(weights, combination)

    if draw < weight do
      combination
    else
      pick(rest, weights, draw - weight)
    end
  end

  defp weight(weights, combination) do
    case Map.get(weights, combination, 1) do
      value when is_integer(value) and value >= 0 ->
        value

      other ->
        raise ArgumentError,
              "craps dice weight for #{inspect(combination)} must be a non-negative " <>
                "integer, got #{inspect(other)}"
    end
  end

  # Uniform in 0..bound-1. Rejection sampling discards the tail of the byte
  # range that would otherwise make low values very slightly likelier.
  defp uniform_below(1), do: 0

  defp uniform_below(bound) do
    bytes = bound |> bit_length() |> Kernel.+(7) |> div(8)
    ceiling = 1 <<< (bytes * 8)
    cutoff = ceiling - rem(ceiling, bound)
    draw_below(bound, bytes, cutoff)
  end

  defp draw_below(bound, bytes, cutoff) do
    value = bytes |> :crypto.strong_rand_bytes() |> :binary.decode_unsigned()

    if value < cutoff, do: rem(value, bound), else: draw_below(bound, bytes, cutoff)
  end

  defp bit_length(value), do: bit_length(value, 0)
  defp bit_length(0, bits), do: bits
  defp bit_length(value, bits), do: bit_length(value >>> 1, bits + 1)
end
