defmodule Veejr.AddOns.Craps.StateTest do
  use ExUnit.Case, async: true

  alias Veejr.AddOns.Craps.State

  describe "new/0" do
    test "opens on the come-out with no point" do
      assert %State{phase: :come_out, point: nil} = State.new()
    end
  end

  describe "come-out rolls" do
    test "7 and 11 are naturals that come out again" do
      for {die1, die2} <- [{3, 4}, {5, 6}] do
        assert {:natural, %State{phase: :come_out, point: nil}} =
                 State.apply_roll(State.new(), die1, die2)
      end
    end

    test "2, 3, and 12 are craps and also come out again" do
      for {die1, die2} <- [{1, 1}, {1, 2}, {6, 6}] do
        assert {:craps, %State{phase: :come_out, point: nil}} =
                 State.apply_roll(State.new(), die1, die2)
      end
    end

    test "every other total sets the point" do
      for {die1, die2, total} <- [
            {2, 2, 4},
            {2, 3, 5},
            {3, 3, 6},
            {2, 6, 8},
            {4, 5, 9},
            {4, 6, 10}
          ] do
        assert {:point_set, %State{phase: :point, point: ^total}} =
                 State.apply_roll(State.new(), die1, die2)
      end
    end
  end

  describe "point-phase rolls" do
    test "rolling the point makes it and returns to the come-out" do
      for point <- [4, 5, 6, 8, 9, 10] do
        {die1, die2} = if point <= 6, do: {1, point - 1}, else: {point - 6, 6}

        assert {:point_made, %State{phase: :come_out, point: nil}} =
                 State.apply_roll(%State{phase: :point, point: point}, die1, die2)
      end
    end

    test "a 7 sevens out and returns to the come-out" do
      assert {:seven_out, %State{phase: :come_out, point: nil}} =
               State.apply_roll(%State{phase: :point, point: 8}, 3, 4)
    end

    test "anything else leaves the round exactly where it was" do
      state = %State{phase: :point, point: 8}

      assert {:roll, ^state} = State.apply_roll(state, 2, 2)
    end

    # A 12 is craps on the come-out but nothing at all once a point is on.
    test "12 is an ordinary roll once the point is established" do
      state = %State{phase: :point, point: 8}

      assert {:roll, ^state} = State.apply_roll(state, 6, 6)
    end
  end

  test "rejects faces that are not on a die" do
    assert_raise FunctionClauseError, fn -> State.apply_roll(State.new(), 0, 4) end
    assert_raise FunctionClauseError, fn -> State.apply_roll(State.new(), 3, 7) end
  end
end
