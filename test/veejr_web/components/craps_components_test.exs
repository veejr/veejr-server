defmodule VeejrWeb.CrapsComponentsTest do
  use ExUnit.Case, async: true

  alias Veejr.AddOns.Craps.Bet
  alias VeejrWeb.CrapsComponents

  defp table(phase, bets) do
    %{
      phase: phase,
      point: if(phase == :point, do: 8),
      shooter_id: 1,
      seats: [%{user_id: 1, chips: 1000, display_name: "Ann", username: "ann"}],
      bets: bets,
      last_roll: nil,
      max_players: 8
    }
  end

  defp actions(shown), do: CrapsComponents.scene_state(shown, shown, 1).actions

  defp bet(id, type, target),
    do: %Bet{id: id, player_id: 1, type: type, amount: 10, target: target}

  describe "a number box where you hold a come bet" do
    test "lays come odds on that number" do
      action = actions(table(:point, [bet(1, :come, 6)]))["place_6"]

      assert action.enabled
      assert action.bet == "come_odds"
      assert action.target == 6
      assert action.label == "Come odds on 6"
    end

    test "lays don't come odds behind a don't come bet" do
      action = actions(table(:point, [bet(1, :dont_come, 9)]))["place_9"]

      assert action.bet == "dont_come_odds"
      assert action.target == 9
    end

    test "still takes odds on the come-out, when a place bet would be refused" do
      action = actions(table(:come_out, [bet(1, :come, 4)]))["place_4"]

      assert action.enabled
      assert action.bet == "come_odds"
    end

    test "leaves the other numbers as ordinary place bets" do
      actions = actions(table(:point, [bet(1, :come, 6)]))

      assert actions["place_5"].bet == "place_5"
      refute Map.has_key?(actions["place_5"], :target)
    end

    test "ignores a come bet that has not travelled to a number yet" do
      assert actions(table(:point, [bet(1, :come, nil)]))["place_6"].bet == "place_6"
    end

    test "ignores another player's come bet" do
      other = %Bet{id: 1, player_id: 2, type: :come, amount: 10, target: 6}

      assert actions(table(:point, [other]))["place_6"].bet == "place_6"
    end
  end

  describe "marker_odds_type/1" do
    test "follows the kind of come bet the marker sits on" do
      assert CrapsComponents.marker_odds_type("come") == "come_odds"
      assert CrapsComponents.marker_odds_type("dont_come") == "dont_come_odds"
      assert CrapsComponents.marker_odds_type(nil) == "come_odds"
    end
  end

  describe "parse_target/1" do
    test "accepts the number the felt sends as well as a form string" do
      assert CrapsComponents.parse_target(6) == 6
      assert CrapsComponents.parse_target("6") == 6
      assert CrapsComponents.parse_target(nil) == nil
    end
  end
end
