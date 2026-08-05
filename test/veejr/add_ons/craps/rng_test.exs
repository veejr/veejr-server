defmodule Veejr.AddOns.Craps.RngTest do
  use ExUnit.Case, async: true

  alias Veejr.AddOns.Craps.Rng

  test "fair weights cover all 36 combinations equally" do
    weights = Rng.fair_weights()

    assert map_size(weights) == 36
    assert weights |> Map.values() |> Enum.uniq() == [1]
    assert length(Rng.combinations()) == 36
  end

  test "a roll always lands on two real faces and reports their total" do
    for _ <- 1..500 do
      assert %{die1: die1, die2: die2, total: total} = Rng.roll()
      assert die1 in 1..6
      assert die2 in 1..6
      assert total == die1 + die2
    end
  end

  test "every combination is reachable" do
    seen =
      Stream.repeatedly(fn -> Rng.roll() end)
      |> Enum.take(10_000)
      |> MapSet.new(fn roll -> {roll.die1, roll.die2} end)

    assert MapSet.size(seen) == 36
  end

  @tag :slow
  test "fair weights produce the real distribution of totals" do
    samples = 120_000

    ways = %{
      2 => 1,
      3 => 2,
      4 => 3,
      5 => 4,
      6 => 5,
      7 => 6,
      8 => 5,
      9 => 4,
      10 => 3,
      11 => 2,
      12 => 1
    }

    counts =
      Stream.repeatedly(fn -> Rng.roll().total end)
      |> Enum.take(samples)
      |> Enum.frequencies()

    for {total, ways} <- ways do
      actual = Map.get(counts, total, 0) / samples
      expected = ways / 36

      assert_in_delta actual, expected, 0.005, "total #{total} was off"
    end
  end

  describe "the published house table" do
    test "favours the seven and leaves everything else alone" do
      weights = Rng.house_weights()

      for {die1, die2} = combination <- Rng.combinations() do
        expected = if die1 + die2 == 7, do: 112, else: 100
        assert Map.fetch!(weights, combination) == expected
      end

      assert Rng.seven_bias() == 1.12
    end

    test "the dice mode selects the table" do
      assert Rng.weights_for("fair") == Rng.fair_weights()
      assert Rng.weights_for("house") == Rng.house_weights()
    end

    @tag :slow
    test "sevens actually come up more often than fair" do
      samples = 120_000

      sevens =
        Stream.repeatedly(fn -> Rng.roll(Rng.house_weights()) end)
        |> Enum.take(samples)
        |> Enum.count(&(&1.total == 7))

      # 6 * 112 out of (30 * 100 + 6 * 112) = 672/3672 ≈ 0.1830, against a
      # fair 1/6 ≈ 0.1667.
      assert_in_delta sevens / samples, 672 / 3672, 0.005
    end
  end

  describe "weighting" do
    test "a weighted table biases the draw" do
      weights =
        Map.new(Rng.combinations(), fn {die1, die2} = combination ->
          {combination, if(die1 + die2 == 7, do: 10, else: 1)}
        end)

      sevens =
        Stream.repeatedly(fn -> Rng.roll(weights) end)
        |> Enum.take(2_000)
        |> Enum.count(&(&1.total == 7))

      # Fair is 1 in 6; ten-to-one on the sevens should clear 40%.
      assert sevens / 2_000 > 0.4
    end

    test "a combination weighted to zero never comes up" do
      weights = Map.put(Rng.fair_weights(), {6, 6}, 0)

      refute Stream.repeatedly(fn -> Rng.roll(weights) end)
             |> Enum.take(5_000)
             |> Enum.any?(&(&1.die1 == 6 and &1.die2 == 6))
    end

    test "a combination the caller did not name is treated as fair" do
      seen =
        Stream.repeatedly(fn -> Rng.roll(%{{1, 1} => 1}) end)
        |> Enum.take(5_000)
        |> MapSet.new(fn roll -> {roll.die1, roll.die2} end)

      assert MapSet.size(seen) == 36
    end

    test "refuses a table that cannot be drawn from" do
      weights = Map.new(Rng.combinations(), &{&1, 0})

      assert_raise ArgumentError, ~r/at least one combination/, fn -> Rng.roll(weights) end
    end

    test "refuses a weight that is not a non-negative integer" do
      for bad <- [-1, 1.12, "heavy"] do
        weights = Map.put(Rng.fair_weights(), {3, 4}, bad)

        assert_raise ArgumentError, fn -> Rng.roll(weights) end
      end
    end
  end
end
