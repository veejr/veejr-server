defmodule Veejr.AddOns.Craps.ResolutionTest do
  use ExUnit.Case, async: true

  alias Veejr.AddOns.Craps.{Bet, Resolution, State}

  @come_out %State{phase: :come_out, point: nil}
  @point_8 %State{phase: :point, point: 8}

  defp bet(overrides \\ []) do
    defaults = [id: "b1", player_id: "p1", type: :pass_line, amount: 10, target: nil]
    struct!(Bet, Keyword.merge(defaults, overrides))
  end

  test "an empty board resolves to nothing" do
    assert %{resolved: [], remaining: [], updates: []} =
             Resolution.resolve_all([], 3, 4, @come_out)
  end

  test "a winning bet is settled and comes off the table" do
    assert %{resolved: [settlement], remaining: []} =
             Resolution.resolve_all([bet()], 3, 4, @come_out)

    assert %{bet_id: "b1", player_id: "p1", result: :win, payout: 20} = settlement
  end

  test "a losing bet is settled at zero" do
    assert %{resolved: [%{result: :lose, payout: 0}]} =
             Resolution.resolve_all([bet()], 1, 1, @come_out)
  end

  test "an unresolved bet stays up untouched" do
    original = bet(id: "b1", player_id: "alice", amount: 25)

    assert %{resolved: [], remaining: [^original], updates: []} =
             Resolution.resolve_all([original], 2, 2, @come_out)
  end

  test "several bets on one roll are each settled on their own terms" do
    bets = [
      bet(id: "pass", type: :pass_line),
      bet(id: "dont", type: :dont_pass),
      bet(id: "place6", type: :place_6, amount: 12),
      bet(id: "hard8", type: :hard_8, amount: 5)
    ]

    # A seven-out: the line loses, the don't wins, the place and hard way die.
    assert %{resolved: resolved, remaining: []} =
             Resolution.resolve_all(bets, 3, 4, @point_8)

    assert [
             %{bet_id: "pass", result: :lose},
             %{bet_id: "dont", result: :win},
             %{bet_id: "place6", result: :lose},
             %{bet_id: "hard8", result: :lose}
           ] = resolved
  end

  test "settlements come back in board order" do
    bets = [bet(id: "a", type: :yo, amount: 5), bet(id: "b", type: :any_seven, amount: 5)]

    assert %{resolved: [%{bet_id: "a"}, %{bet_id: "b"}]} =
             Resolution.resolve_all(bets, 5, 6, @come_out)
  end

  test "number bets survive come-out rolls and resume after the point is established" do
    original = bet(type: :place_6, amount: 12)

    # Make the old point, then come out with a seven, craps, and a new point.
    {:point_made, come_out} = State.apply_roll(@point_8, 4, 4)

    assert %{resolved: [], remaining: [^original]} =
             Resolution.resolve_all([original], 4, 4, @point_8)

    for {die1, die2} <- [{3, 4}, {1, 1}, {3, 3}] do
      assert %{resolved: [], remaining: [^original], updates: []} =
               Resolution.resolve_all([original], die1, die2, come_out)
    end

    {:point_set, point_6} = State.apply_roll(come_out, 3, 3)

    assert %{resolved: [%{result: :win, payout: 26}], remaining: []} =
             Resolution.resolve_all([original], 3, 3, point_6)

    assert %{resolved: [%{result: :lose, payout: 0}], remaining: []} =
             Resolution.resolve_all([original], 3, 4, point_6)
  end

  describe "a travelling come bet" do
    test "moves to the number rolled and is reported as an update" do
      bets = [bet(id: "come1", type: :come, target: nil)]

      assert %{resolved: [], remaining: [moved], updates: [updated]} =
               Resolution.resolve_all(bets, 2, 4, @point_8)

      assert %Bet{id: "come1", target: 6} = moved
      assert updated == moved
    end

    test "wins once it reaches its own number" do
      bets = [bet(id: "come1", type: :come, target: 6)]

      assert %{resolved: [%{result: :win, payout: 20}], remaining: []} =
               Resolution.resolve_all(bets, 3, 3, @point_8)
    end

    test "dies on a seven like everything else" do
      bets = [bet(id: "come1", type: :come, target: 6)]

      assert %{resolved: [%{result: :lose}]} = Resolution.resolve_all(bets, 3, 4, @point_8)
    end

    test "a don't come pushes on the barred 12 rather than travelling" do
      bets = [bet(id: "dc", type: :dont_come, target: nil)]

      assert %{resolved: [%{result: :push, payout: 10}], updates: []} =
               Resolution.resolve_all(bets, 6, 6, @point_8)
    end
  end

  test "bets that stay up are not reported as updates" do
    bets = [bet(id: "pending", type: :place_6, amount: 12)]

    assert %{remaining: [_], updates: []} = Resolution.resolve_all(bets, 2, 2, @point_8)
  end
end
