defmodule Veejr.AddOns.Craps.TableTest do
  use Veejr.DataCase

  import Veejr.AccountsFixtures

  alias Veejr.AddOns.Craps
  alias Veejr.AddOns.Craps.Table

  setup do
    # The dice are injected so a test can force a seven-out rather than
    # rolling until one turns up.
    {:ok, dice} = Agent.start_link(fn -> [] end)

    roll_fn = fn _weights ->
      Agent.get_and_update(dice, fn
        [{die1, die2} | rest] -> {%{die1: die1, die2: die2, total: die1 + die2}, rest}
        [] -> {%{die1: 3, die2: 4, total: 7}, []}
      end)
    end

    {:ok, table} = Table.start_link(name: nil, roll_fn: roll_fn)

    %{
      table: table,
      roll_fn: roll_fn,
      queue: fn rolls -> Agent.update(dice, fn _ -> rolls end) end
    }
  end

  defp sit!(table, user) do
    {:ok, state} = Table.sit(user, table)
    state
  end

  describe "taking a seat" do
    test "draws a starting stack the first time", %{table: table} do
      user = user_fixture()

      assert %{seats: [seat]} = sit!(table, user)
      assert seat.chips == Craps.starting_stack()
      assert Craps.chip_balance(user) == Craps.starting_stack()
    end

    test "the first player to sit holds the dice", %{table: table} do
      alice = user_fixture()
      bob = user_fixture()

      sit!(table, alice)
      assert %{shooter_id: shooter} = sit!(table, bob)
      assert shooter == alice.id
    end

    test "sitting twice is not an error and does not double the seat", %{table: table} do
      user = user_fixture()
      sit!(table, user)

      assert %{seats: [_only_one]} = sit!(table, user)
    end

    test "a returning player keeps the stack they left with", %{table: table} do
      user = user_fixture()
      Craps.put_chip_balance(user.id, 250)

      assert %{seats: [seat]} = sit!(table, user)
      assert seat.chips == 250
    end

    test "a broke player is topped back up rather than stuck", %{table: table} do
      user = user_fixture()
      Craps.put_chip_balance(user.id, 0)

      assert %{seats: [seat]} = sit!(table, user)
      assert seat.chips == Craps.starting_stack()
    end

    test "the table fills up", %{table: table} do
      for _ <- 1..8, do: sit!(table, user_fixture())

      assert {:error, :table_full} = Table.sit(user_fixture(), table)
    end
  end

  describe "placing bets" do
    setup %{table: table} do
      user = user_fixture()
      sit!(table, user)
      %{user: user}
    end

    test "takes the stake out of the stack", %{table: table, user: user} do
      assert {:ok, _bet} = Table.place_bet(user.id, :pass_line, 25, nil, table)

      assert %{seats: [seat]} = Table.state(table)
      assert seat.chips == Craps.starting_stack() - 25
      assert Craps.chip_balance(user) == Craps.starting_stack() - 25
    end

    test "refuses a bet the phase does not allow", %{table: table, user: user} do
      assert {:error, :invalid_phase} = Table.place_bet(user.id, :place_6, 10, nil, table)
    end

    test "refuses a second line bet", %{table: table, user: user} do
      {:ok, _} = Table.place_bet(user.id, :pass_line, 10, nil, table)

      assert {:error, :duplicate_bet} = Table.place_bet(user.id, :pass_line, 10, nil, table)
    end

    test "refuses odds with nothing behind them", %{table: table, user: user, queue: queue} do
      queue.([{2, 2}])
      {:ok, _} = Table.place_bet(user.id, :pass_line, 10, nil, table)
      {:ok, _} = Table.roll(user.id, table)

      # The point is on and the player is on the pass side, so there is no
      # don't pass for these odds to sit behind.
      assert {:error, :no_base_bet} = Table.place_bet(user.id, :dont_pass_odds, 10, nil, table)
    end

    test "refuses more than the player has", %{table: table, user: user} do
      assert {:error, :insufficient_chips} =
               Table.place_bet(user.id, :pass_line, Craps.starting_stack() + 1, nil, table)
    end

    test "refuses a bet from somebody who is not seated", %{table: table} do
      assert {:error, :not_at_table} = Table.place_bet(-1, :pass_line, 10, nil, table)
    end

    test "come odds must name their number", %{table: table, user: user, queue: queue} do
      queue.([{2, 2}])
      {:ok, _} = Table.place_bet(user.id, :pass_line, 10, nil, table)
      {:ok, _} = Table.roll(user.id, table)

      assert {:error, :missing_target} = Table.place_bet(user.id, :come_odds, 10, nil, table)
    end

    test "re-betting the odds adjusts the wager instead of stacking one", %{
      table: table,
      user: user,
      queue: queue
    } do
      queue.([{2, 2}])
      {:ok, _} = Table.place_bet(user.id, :pass_line, 10, nil, table)
      {:ok, _} = Table.roll(user.id, table)

      {:ok, _} = Table.place_bet(user.id, :pass_odds, 10, nil, table)
      {:ok, _} = Table.place_bet(user.id, :pass_odds, 30, nil, table)

      state = Table.state(table)
      odds = Enum.filter(state.bets, &(&1.type == :pass_odds))

      assert [%{amount: 30}] = odds
      # 10 for the line, then 30 for the odds — the first 10 came back.
      assert hd(state.seats).chips == Craps.starting_stack() - 40
    end

    test "pass odds pick up the table point without being told", %{
      table: table,
      user: user,
      queue: queue
    } do
      queue.([{3, 3}])
      {:ok, _} = Table.place_bet(user.id, :pass_line, 10, nil, table)
      {:ok, _} = Table.roll(user.id, table)
      {:ok, bet} = Table.place_bet(user.id, :pass_odds, 10, nil, table)

      assert bet.target == 6
    end
  end

  describe "rolling" do
    setup %{table: table} do
      user = user_fixture()
      sit!(table, user)
      %{user: user}
    end

    test "only the shooter may throw", %{table: table} do
      other = user_fixture()
      sit!(table, other)

      assert {:error, :not_shooter} = Table.roll(other.id, table)
    end

    test "the shooter needs something on the line", %{table: table, user: user} do
      assert {:error, :shooter_needs_line_bet} = Table.roll(user.id, table)
    end

    test "a come-out natural pays the line", %{table: table, user: user, queue: queue} do
      queue.([{3, 4}])
      {:ok, _} = Table.place_bet(user.id, :pass_line, 10, nil, table)

      assert {:ok, %{total: 7, event: :natural}} = Table.roll(user.id, table)

      # Down 10 for the bet, back 20 for the win.
      assert hd(Table.state(table).seats).chips == Craps.starting_stack() + 10
    end

    test "a point is set and then made", %{table: table, user: user, queue: queue} do
      queue.([{2, 2}, {1, 3}])
      {:ok, _} = Table.place_bet(user.id, :pass_line, 10, nil, table)

      assert {:ok, %{event: :point_set}} = Table.roll(user.id, table)
      assert %{phase: :point, point: 4} = Table.state(table)

      assert {:ok, %{event: :point_made}} = Table.roll(user.id, table)
      assert %{phase: :come_out, point: nil} = Table.state(table)
      assert hd(Table.state(table).seats).chips == Craps.starting_stack() + 10
    end

    test "a seven-out clears the felt and passes the dice", %{
      table: table,
      user: alice,
      queue: queue
    } do
      bob = user_fixture()
      sit!(table, bob)

      queue.([{2, 2}, {3, 4}])
      {:ok, _} = Table.place_bet(alice.id, :pass_line, 10, nil, table)
      {:ok, _} = Table.roll(alice.id, table)
      {:ok, _} = Table.place_bet(alice.id, :place_6, 12, nil, table)

      assert {:ok, %{event: :seven_out}} = Table.roll(alice.id, table)

      state = Table.state(table)
      assert state.shooter_id == bob.id
      assert state.bets == []

      assert Enum.find(state.seats, &(&1.user_id == alice.id)).chips ==
               Craps.starting_stack() - 22
    end

    test "the roll is settled against the state it was thrown into", %{
      table: table,
      user: user,
      queue: queue
    } do
      # A come-out 7 pays the pass line even though the round restarts.
      queue.([{3, 4}])
      {:ok, _} = Table.place_bet(user.id, :pass_line, 10, nil, table)
      {:ok, roll} = Table.roll(user.id, table)

      assert [%{result: :win, payout: 20}] = roll.resolved
    end

    test "a travelling come bet is reported as an update", %{
      table: table,
      user: user,
      queue: queue
    } do
      queue.([{2, 2}, {2, 3}])
      {:ok, _} = Table.place_bet(user.id, :pass_line, 10, nil, table)
      {:ok, _} = Table.roll(user.id, table)
      {:ok, _} = Table.place_bet(user.id, :come, 10, nil, table)
      {:ok, roll} = Table.roll(user.id, table)

      assert [%{type: :come, target: 5}] = roll.updates
    end
  end

  describe "leaving" do
    test "refunds bets that never resolved", %{table: table} do
      user = user_fixture()
      sit!(table, user)
      {:ok, _} = Table.place_bet(user.id, :pass_line, 40, nil, table)

      {:ok, _} = Table.leave(user.id, table)

      assert Craps.chip_balance(user) == Craps.starting_stack()
      assert %{seats: [], bets: []} = Table.state(table)
    end

    test "passes the dice on when the shooter walks", %{table: table} do
      alice = user_fixture()
      bob = user_fixture()
      sit!(table, alice)
      sit!(table, bob)

      {:ok, state} = Table.leave(alice.id, table)

      assert state.shooter_id == bob.id
    end

    test "the last player out resets the round", %{table: table, queue: queue} do
      user = user_fixture()
      sit!(table, user)
      queue.([{2, 2}])
      {:ok, _} = Table.place_bet(user.id, :pass_line, 10, nil, table)
      {:ok, _} = Table.roll(user.id, table)
      assert %{phase: :point} = Table.state(table)

      {:ok, _} = Table.leave(user.id, table)

      assert %{phase: :come_out, point: nil, shooter_id: nil, last_roll: nil} = Table.state(table)
    end

    test "leaving a table you are not at changes nothing", %{table: table} do
      assert {:ok, %{seats: []}} = Table.leave(-1, table)
    end
  end

  describe "an absent shooter" do
    # The window has to sit comfortably between one timeout and the next:
    # once the dice pass to the next player their own clock starts, and a
    # sleep long enough to catch both would empty the table.
    @timeout_ms 200
    @past_one_timeout 320

    setup %{roll_fn: roll_fn} do
      {:ok, table} =
        Table.start_link(name: nil, roll_fn: roll_fn, idle_timeout_ms: @timeout_ms)

      %{table: table}
    end

    test "loses the dice so the table cannot stall", %{table: table} do
      alice = user_fixture()
      bob = user_fixture()
      sit!(table, alice)
      sit!(table, bob)
      assert Table.state(table).shooter_id == alice.id

      Process.sleep(@past_one_timeout)

      state = Table.state(table)
      assert state.shooter_id == bob.id
      assert [%{user_id: seated}] = state.seats
      assert seated == bob.id
    end

    test "gets their unresolved bets back", %{table: table} do
      alice = user_fixture()
      sit!(table, alice)
      {:ok, _} = Table.place_bet(alice.id, :pass_line, 40, nil, table)

      Process.sleep(@past_one_timeout)

      assert Table.state(table).seats == []
      assert Craps.chip_balance(alice) == Craps.starting_stack()
    end

    test "the clock restarts when the dice are actually thrown", %{table: table} do
      alice = user_fixture()
      sit!(table, alice)
      {:ok, _} = Table.place_bet(alice.id, :pass_line, 10, nil, table)

      for _ <- 1..4 do
        Process.sleep(div(@timeout_ms, 2))
        {:ok, _} = Table.roll(alice.id, table)
        {:ok, _} = Table.place_bet(alice.id, :pass_line, 10, nil, table)
      end

      assert [%{user_id: still_here}] = Table.state(table).seats
      assert still_here == alice.id
    end
  end

  test "each roll carries a new id so a browser can tell them apart", %{table: table} do
    user = user_fixture()
    sit!(table, user)
    {:ok, _} = Table.place_bet(user.id, :pass_line, 10, nil, table)
    {:ok, first} = Table.roll(user.id, table)
    {:ok, _} = Table.place_bet(user.id, :pass_line, 10, nil, table)
    {:ok, second} = Table.roll(user.id, table)

    assert second.id > first.id
  end

  test "changes are broadcast to everyone watching", %{table: table} do
    Table.subscribe()
    user = user_fixture()

    sit!(table, user)

    assert_receive {:craps_table, %{seats: [%{user_id: seated}]}}
    assert seated == user.id
  end
end
