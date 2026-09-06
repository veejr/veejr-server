defmodule Veejr.AddOns.Craps.BetsTest do
  use ExUnit.Case, async: true

  alias Veejr.AddOns.Craps.{Bets, State}

  @come_out %State{phase: :come_out, point: nil}
  @point_4 %State{phase: :point, point: 4}
  @point_6 %State{phase: :point, point: 6}
  @point_8 %State{phase: :point, point: 8}

  defp payout(type, amount, target, die1, die2, state),
    do: Bets.payout(type, amount, target, die1, die2, state)

  describe "the board" do
    test "carries all 28 standard bets" do
      assert length(Bets.types()) == 28
      assert Enum.all?(Bets.types(), &Bets.type?/1)
      refute Bets.type?(:roulette)
    end

    test "an unknown bet is refused rather than silently losing" do
      assert_raise ArgumentError, ~r/unknown craps bet type/, fn ->
        payout(:insurance, 10, nil, 3, 4, @come_out)
      end
    end
  end

  describe "pass line" do
    test "wins on a come-out natural" do
      assert {:win, 20} = payout(:pass_line, 10, nil, 3, 4, @come_out)
      assert {:win, 20} = payout(:pass_line, 10, nil, 5, 6, @come_out)
    end

    test "loses on come-out craps, including 12" do
      for {die1, die2} <- [{1, 1}, {1, 2}, {6, 6}] do
        assert {:lose, 0} = payout(:pass_line, 10, nil, die1, die2, @come_out)
      end
    end

    test "waits once a point is set" do
      assert {:pending, nil} = payout(:pass_line, 10, nil, 2, 2, @come_out)
    end

    test "wins on the point and loses on a seven-out" do
      assert {:win, 20} = payout(:pass_line, 10, nil, 4, 4, @point_8)
      assert {:lose, 0} = payout(:pass_line, 10, nil, 3, 4, @point_8)
      assert {:pending, nil} = payout(:pass_line, 10, nil, 2, 2, @point_8)
    end
  end

  describe "don't pass" do
    test "wins on 2 and 3 but the 12 is barred" do
      assert {:win, 20} = payout(:dont_pass, 10, nil, 1, 1, @come_out)
      assert {:win, 20} = payout(:dont_pass, 10, nil, 1, 2, @come_out)
      assert {:push, 10} = payout(:dont_pass, 10, nil, 6, 6, @come_out)
    end

    test "loses to a come-out natural" do
      assert {:lose, 0} = payout(:dont_pass, 10, nil, 3, 4, @come_out)
      assert {:lose, 0} = payout(:dont_pass, 10, nil, 5, 6, @come_out)
    end

    test "wins on the seven-out and loses to the point" do
      assert {:win, 20} = payout(:dont_pass, 10, nil, 3, 4, @point_8)
      assert {:lose, 0} = payout(:dont_pass, 10, nil, 4, 4, @point_8)
      assert {:pending, nil} = payout(:dont_pass, 10, nil, 2, 2, @point_8)
    end
  end

  describe "odds behind the line" do
    test "pass odds pay true odds for each point" do
      # 2:1 on the 4, 6:5 on the 6, 3:2 on the 5.
      assert {:win, 30} = payout(:pass_odds, 10, nil, 2, 2, @point_4)
      assert {:win, 22} = payout(:pass_odds, 10, nil, 3, 3, @point_6)
      assert {:win, 25} = payout(:pass_odds, 10, nil, 1, 4, %State{phase: :point, point: 5})
    end

    test "don't pass odds pay the inverse" do
      # Laying the odds: 1:2 against the 4, 5:6 against the 6.
      assert {:win, 15} = payout(:dont_pass_odds, 10, nil, 3, 4, @point_4)
      assert {:win, 22} = payout(:dont_pass_odds, 12, nil, 3, 4, @point_6)
    end

    test "an explicit target overrides the table point" do
      assert {:win, 30} = payout(:pass_odds, 10, 4, 2, 2, @point_8)
    end

    test "odds with nothing to ride on simply wait" do
      assert {:pending, nil} = payout(:pass_odds, 10, nil, 3, 4, @come_out)
      assert {:pending, nil} = payout(:dont_pass_odds, 10, nil, 3, 4, @come_out)
    end
  end

  describe "come and don't come" do
    test "a come bet that has not travelled behaves like a fresh pass line" do
      assert {:win, 20} = payout(:come, 10, nil, 3, 4, @point_8)
      assert {:lose, 0} = payout(:come, 10, nil, 1, 1, @point_8)
      assert {:come_point_set, nil} = payout(:come, 10, nil, 2, 4, @point_8)
    end

    test "a travelled come bet rides its own number, not the table's" do
      assert {:win, 20} = payout(:come, 10, 6, 3, 3, @point_8)
      assert {:lose, 0} = payout(:come, 10, 6, 3, 4, @point_8)
      assert {:pending, nil} = payout(:come, 10, 6, 4, 4, @point_8)
    end

    test "don't come bars the 12 the same way don't pass does" do
      assert {:push, 10} = payout(:dont_come, 10, nil, 6, 6, @point_8)
      assert {:win, 20} = payout(:dont_come, 10, nil, 1, 1, @point_8)
      assert {:lose, 0} = payout(:dont_come, 10, nil, 5, 6, @point_8)
    end

    test "come odds ride the come point" do
      assert {:win, 30} = payout(:come_odds, 10, 4, 2, 2, @point_8)
      assert {:lose, 0} = payout(:come_odds, 10, 4, 3, 4, @point_8)
      assert {:pending, nil} = payout(:come_odds, 10, nil, 2, 2, @point_8)
    end
  end

  describe "place bets" do
    test "all numbers are off for every come-out roll" do
      for type <- [:place_4, :place_5, :place_6, :place_8, :place_9, :place_10],
          die1 <- 1..6,
          die2 <- 1..6 do
        assert {:pending, nil} = payout(type, 12, nil, die1, die2, @come_out)
      end
    end

    test "pay their standard odds" do
      assert {:win, 28} = payout(:place_4, 10, nil, 2, 2, @point_8)
      assert {:win, 24} = payout(:place_5, 10, nil, 2, 3, @point_8)
      assert {:win, 26} = payout(:place_6, 12, nil, 3, 3, @point_4)
    end

    test "truncate rather than pay a fraction of a chip" do
      # 7:6 on a $10 place 6 is $11.66; the player is paid $11.
      assert {:win, 21} = payout(:place_6, 10, nil, 3, 3, @point_4)
    end

    test "lose on the seven and otherwise wait" do
      assert {:lose, 0} = payout(:place_6, 12, nil, 3, 4, @point_4)
      assert {:pending, nil} = payout(:place_6, 12, nil, 2, 2, @point_4)
    end
  end

  describe "hard ways" do
    test "need the pair" do
      # 7:1 on the hard 4 and 10, 9:1 on the hard 6 and 8.
      assert {:win, 80} = payout(:hard_4, 10, nil, 2, 2, @point_8)
      assert {:win, 100} = payout(:hard_6, 10, nil, 3, 3, @point_8)
    end

    test "die on the easy version of their own number" do
      assert {:lose, 0} = payout(:hard_6, 10, nil, 2, 4, @point_8)
      assert {:lose, 0} = payout(:hard_4, 10, nil, 1, 3, @point_8)
    end

    test "die on the seven and otherwise wait" do
      assert {:lose, 0} = payout(:hard_8, 10, nil, 3, 4, @point_8)
      assert {:pending, nil} = payout(:hard_8, 10, nil, 2, 3, @point_8)
    end
  end

  describe "single-roll bets" do
    test "the field pays double on the extremes" do
      assert {:win, 30} = payout(:field, 10, nil, 1, 1, @come_out)
      assert {:win, 30} = payout(:field, 10, nil, 6, 6, @come_out)
      assert {:win, 20} = payout(:field, 10, nil, 1, 2, @come_out)
      assert {:win, 20} = payout(:field, 10, nil, 5, 6, @come_out)
    end

    test "the field loses the box numbers" do
      for {die1, die2} <- [{1, 4}, {1, 5}, {3, 4}, {2, 6}] do
        assert {:lose, 0} = payout(:field, 10, nil, die1, die2, @come_out)
      end
    end

    test "the props pay their posted odds" do
      assert {:win, 50} = payout(:any_seven, 10, nil, 3, 4, @come_out)
      assert {:win, 80} = payout(:any_craps, 10, nil, 1, 1, @come_out)
      assert {:win, 160} = payout(:yo, 10, nil, 5, 6, @come_out)
      assert {:win, 310} = payout(:aces, 10, nil, 1, 1, @come_out)
      assert {:win, 160} = payout(:ace_deuce, 10, nil, 1, 2, @come_out)
      assert {:win, 310} = payout(:boxcars, 10, nil, 6, 6, @come_out)
    end

    test "a prop that misses is settled immediately, not left up" do
      assert {:lose, 0} = payout(:any_seven, 10, nil, 2, 2, @come_out)
      assert {:lose, 0} = payout(:yo, 10, nil, 3, 4, @come_out)
    end
  end

  describe "horn" do
    # A horn is four quarter-bets. One leg wins, three lose, so a $4 horn on
    # 12 returns the 30:1 leg's $31 and nothing else.
    test "returns the winning leg less the three lost quarters" do
      assert {:win, 31} = payout(:horn, 4, nil, 6, 6, @come_out)
      assert {:win, 31} = payout(:horn, 4, nil, 1, 1, @come_out)
      assert {:win, 16} = payout(:horn, 4, nil, 5, 6, @come_out)
      assert {:win, 16} = payout(:horn, 4, nil, 1, 2, @come_out)
    end

    test "scales with the stake" do
      assert {:win, 62} = payout(:horn, 8, nil, 6, 6, @come_out)
      assert {:win, 32} = payout(:horn, 8, nil, 5, 6, @come_out)
    end

    test "loses on anything outside 2, 3, 11, and 12" do
      assert {:lose, 0} = payout(:horn, 4, nil, 3, 4, @come_out)
    end

    # The reference implementation this was ported from paid 7.75 chips here,
    # because it divided the stake by four in floating point. Chips are whole,
    # so a stake that does not split four ways is truncated instead.
    test "truncates a stake that does not divide into four quarters" do
      assert {:win, 7} = payout(:horn, 1, nil, 6, 6, @come_out)
      assert {:win, 77} = payout(:horn, 10, nil, 1, 1, @come_out)
    end
  end

  describe "big 6 and big 8" do
    test "pay even money and die on the seven" do
      assert {:win, 20} = payout(:big_6, 10, nil, 3, 3, @point_8)
      assert {:win, 20} = payout(:big_8, 10, nil, 4, 4, @point_8)
      assert {:lose, 0} = payout(:big_6, 10, nil, 3, 4, @point_8)
      assert {:pending, nil} = payout(:big_6, 10, nil, 4, 4, @point_8)
    end
  end

  test "every bet type resolves every roll without raising" do
    for type <- Bets.types(),
        die1 <- 1..6,
        die2 <- 1..6,
        state <- [@come_out, @point_4, @point_6, @point_8],
        target <- [nil, 4, 6, 10] do
      assert {result, payout} = payout(type, 12, target, die1, die2, state)
      assert result in [:win, :lose, :push, :pending, :come_point_set]
      assert is_nil(payout) or (is_integer(payout) and payout >= 0)
    end
  end
end
