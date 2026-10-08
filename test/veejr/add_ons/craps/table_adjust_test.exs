defmodule Veejr.AddOns.Craps.TableAdjustTest do
  use Veejr.DataCase

  import Veejr.AccountsFixtures

  alias Veejr.AddOns.Craps.Table

  setup do
    {:ok, dice} = Agent.start_link(fn -> [] end)

    roll_fn = fn _weights ->
      Agent.get_and_update(dice, fn
        [{die1, die2} | rest] -> {%{die1: die1, die2: die2, total: die1 + die2}, rest}
        [] -> {%{die1: 3, die2: 4, total: 7}, []}
      end)
    end

    {:ok, table} = Table.start_link(name: nil, roll_fn: roll_fn)
    user = user_fixture()
    {:ok, _} = Table.sit(user, table)

    %{
      table: table,
      user: user,
      queue: fn rolls -> Agent.update(dice, fn _ -> rolls end) end
    }
  end

  defp chips(table, user),
    do: Table.state(table).seats |> Enum.find(&(&1.user_id == user.id)) |> Map.fetch!(:chips)

  defp bet!(table, user, type, amount, target \\ nil) do
    {:ok, bet} = Table.place_bet(user.id, type, amount, target, table)
    bet
  end

  # Gets the table to a point of 8 with a pass line bet riding.
  defp point_on(table, user, queue) do
    pass = bet!(table, user, :pass_line, 10)
    queue.([{4, 4}])
    {:ok, _} = Table.roll(user.id, table)
    pass
  end

  describe "before a point" do
    test "the pass line can be raised, lowered and pulled", %{table: table, user: user} do
      pass = bet!(table, user, :pass_line, 10)
      start = chips(table, user)

      assert {:ok, %{amount: 25}} = Table.raise_bet(user.id, pass.id, 15, table)
      assert chips(table, user) == start - 15

      assert {:ok, %{amount: 20}} = Table.lower_bet(user.id, pass.id, 5, table)
      assert chips(table, user) == start - 10

      assert {:ok, :pulled} = Table.pull_bet(user.id, pass.id, table)
      # Back to the full stack: the original 10 and the 10 net that was added.
      assert chips(table, user) == start + 10
      assert Table.state(table).bets == []
    end

    test "lowering by the whole bet pulls it", %{table: table, user: user} do
      pass = bet!(table, user, :pass_line, 10)

      assert {:ok, :pulled} = Table.lower_bet(user.id, pass.id, 50, table)
      assert Table.state(table).bets == []
    end
  end

  describe "contract bets" do
    test "the pass line is stuck once a point is on", %{table: table, user: user, queue: queue} do
      pass = point_on(table, user, queue)

      assert {:error, :not_allowed} = Table.raise_bet(user.id, pass.id, 5, table)
      assert {:error, :not_allowed} = Table.lower_bet(user.id, pass.id, 5, table)
      assert {:error, :not_allowed} = Table.pull_bet(user.id, pass.id, table)
    end

    test "a come bet is stuck once it has travelled", %{table: table, user: user, queue: queue} do
      point_on(table, user, queue)
      come = bet!(table, user, :come, 10)
      queue.([{3, 3}])
      {:ok, _} = Table.roll(user.id, table)

      assert [%{target: 6}] = Enum.filter(Table.state(table).bets, &(&1.type == :come))
      assert {:error, :not_allowed} = Table.pull_bet(user.id, come.id, table)
    end

    test "don't pass can be pulled with a point on but not added to", %{
      table: table,
      user: user,
      queue: queue
    } do
      dont = bet!(table, user, :dont_pass, 10)
      queue.([{4, 4}])
      {:ok, _} = Table.roll(user.id, table)
      # the shooter needs a line bet, which the don't pass is
      assert {:error, :not_allowed} = Table.raise_bet(user.id, dont.id, 5, table)

      start = chips(table, user)
      assert {:ok, :pulled} = Table.pull_bet(user.id, dont.id, table)
      assert chips(table, user) == start + 10
    end
  end

  describe "free bets" do
    test "odds can be raised and lowered any time", %{table: table, user: user, queue: queue} do
      point_on(table, user, queue)
      odds = bet!(table, user, :pass_odds, 20)

      assert {:ok, %{amount: 30}} = Table.raise_bet(user.id, odds.id, 10, table)
      assert {:ok, %{amount: 5}} = Table.lower_bet(user.id, odds.id, 25, table)
    end

    test "pulling a don't come bet takes its odds down with it", %{
      table: table,
      user: user,
      queue: queue
    } do
      point_on(table, user, queue)
      dont_come = bet!(table, user, :dont_come, 10)
      queue.([{3, 3}])
      {:ok, _} = Table.roll(user.id, table)
      bet!(table, user, :dont_come_odds, 20, 6)
      start = chips(table, user)

      assert {:ok, :pulled} = Table.pull_bet(user.id, dont_come.id, table)

      assert chips(table, user) == start + 30
      refute Enum.any?(Table.state(table).bets, &(&1.type in [:dont_come, :dont_come_odds]))
    end

    test "a raise needs the chips", %{table: table, user: user} do
      field = bet!(table, user, :field, 10)

      assert {:error, :insufficient_chips} = Table.raise_bet(user.id, field.id, 1_000_000, table)
      assert {:error, :invalid_amount} = Table.raise_bet(user.id, field.id, 0, table)
    end

    test "nobody can touch somebody else's bet", %{table: table, user: user} do
      other = user_fixture()
      {:ok, _} = Table.sit(other, table)
      field = bet!(table, user, :field, 10)

      assert {:error, :no_such_bet} = Table.pull_bet(other.id, field.id, table)
      assert {:error, :no_such_bet} = Table.pull_bet(user.id, 99_999, table)
    end
  end

  describe "turning a bet off" do
    test "an off place bet survives a seven, and comes back on", %{
      table: table,
      user: user,
      queue: queue
    } do
      point_on(table, user, queue)
      place = bet!(table, user, :place_6, 12)

      assert {:ok, %{off: true}} = Table.set_bet_off(user.id, place.id, true, table)

      # A seven would kill an on place bet and pays the pass line... which is
      # a seven-out here, so the place bet is the only thing left standing.
      queue.([{3, 4}])
      start = chips(table, user)
      {:ok, _} = Table.roll(user.id, table)

      assert Enum.any?(Table.state(table).bets, &(&1.id == place.id and &1.off))
      assert chips(table, user) == start

      assert {:ok, %{off: false}} = Table.set_bet_off(user.id, place.id, false, table)
    end

    test "an off place bet does not win its number", %{table: table, user: user, queue: queue} do
      point_on(table, user, queue)
      place = bet!(table, user, :place_6, 12)
      {:ok, _} = Table.set_bet_off(user.id, place.id, true, table)

      queue.([{3, 3}])
      start = chips(table, user)
      {:ok, _} = Table.roll(user.id, table)

      assert chips(table, user) == start
    end

    test "only bets that can be off may be", %{table: table, user: user} do
      field = bet!(table, user, :field, 10)
      pass = bet!(table, user, :pass_line, 10)

      assert {:error, :not_allowed} = Table.set_bet_off(user.id, field.id, true, table)
      assert {:error, :not_allowed} = Table.set_bet_off(user.id, pass.id, true, table)
    end
  end
end
