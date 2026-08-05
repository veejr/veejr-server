defmodule VeejrWeb.CrapsLiveTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Admin}
  alias Veejr.AddOns.Craps.Table

  # The page drives the instance's one real table, so each test clears its
  # seats rather than leaking a roster into the next one.
  setup do
    on_exit(fn ->
      Enum.each(Table.state().seats, &Table.leave(&1.user_id))
    end)
  end

  setup %{conn: conn} do
    admin = with_keys(user_fixture())

    %{conn: log_in_user(conn, admin), admin: admin}
  end

  # Every page in the :app live session is behind the key gate.
  defp with_keys(user) do
    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        "public_key" => Base.encode64(String.pad_trailing("public-key", 32, "x")),
        "enc_secret_key" => Base.encode64(String.pad_trailing("wrapped-key", 48, "x")),
        "key_salt" => Base.encode64(String.pad_trailing("salt", 16, "x")),
        "key_nonce" => Base.encode64(String.pad_trailing("nonce", 24, "x"))
      })

    user
  end

  defp offer_craps(admin, attrs \\ %{}) do
    {:ok, settings} =
      Admin.update_instance_settings(admin, Map.merge(%{"craps_enabled" => "true"}, attrs))

    settings
  end

  test "an instance that does not offer craps neither links nor serves it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/contacts")
    refute has_element?(view, "a[href='/craps']")

    assert {:error, {:live_redirect, %{to: "/contacts"}}} = live(conn, ~p"/craps")
  end

  test "turning craps on links it in the navigation menu", %{conn: conn, admin: admin} do
    offer_craps(admin)

    {:ok, view, _html} = live(conn, ~p"/contacts")
    assert has_element?(view, "a[href='/craps']", "Craps")
  end

  test "the table opens with fair dice and says the server referees it", %{
    conn: conn,
    admin: admin
  } do
    offer_craps(admin)

    {:ok, _view, html} = live(conn, ~p"/craps")

    assert html =~ "This table is refereed"
    assert html =~ "The server rolls the dice"
    assert html =~ "every combination is equally likely"
    refute html =~ "1.12 times likelier"
  end

  test "a disclosed house edge is shown at the table", %{conn: conn, admin: admin} do
    offer_craps(admin, %{"craps_dice_mode" => "house"})

    {:ok, _view, html} = live(conn, ~p"/craps")

    assert html =~ "House edge"
    assert html =~ "1.12 times likelier"
  end

  test "turning craps back off closes the page again", %{conn: conn, admin: admin} do
    offer_craps(admin)
    assert {:ok, _view, _html} = live(conn, ~p"/craps")

    {:ok, _settings} = Admin.update_instance_settings(admin, %{"craps_enabled" => "false"})

    assert {:error, {:live_redirect, %{to: "/contacts"}}} = live(conn, ~p"/craps")
  end

  test "the capabilities endpoint reports what the instance offers", %{conn: conn, admin: admin} do
    assert conn |> get(~p"/api/v1/capabilities") |> json_response(200) |> Map.get("add_ons") == []

    offer_craps(admin)

    assert conn |> get(~p"/api/v1/capabilities") |> json_response(200) |> Map.get("add_ons") == [
             "craps"
           ]
  end

  describe "playing" do
    setup %{conn: conn, admin: admin} do
      offer_craps(admin)
      {:ok, view, _html} = live(conn, ~p"/craps")
      %{view: view}
    end

    defp sit(view), do: view |> element("button[phx-click='sit']") |> render_click()

    defp chips(html), do: Regex.run(~r/Your chips.*?([\d,]+)/s, html) |> List.last()

    # Bets are placed by dropping a chip on the felt, which reaches the server
    # as a hook event rather than a click on any element in the markup.
    defp drop_chip(view, bet), do: render_hook(view, "felt_bet", %{"bet" => bet})

    # What the WebGL felt is told about the table.
    defp scene(view) do
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query_by_id("craps-felt")
      |> LazyHTML.attribute("data-table")
      |> hd()
      |> Jason.decode!()
    end

    # Tells the page the dice have stopped, which is what releases the outcome.
    defp settle(view) do
      case scene(view)["last_roll"] do
        nil -> render(view)
        %{"id" => id} -> render_hook(view, "dice_settled", %{"id" => id})
      end
    end

    defp set_point(view) do
      {:ok, _} = Veejr.AddOns.Craps.Table.roll(Veejr.AddOns.Craps.Table.state().shooter_id)
      settle(view)

      # Roll on until a point is actually established rather than resolving.
      if Veejr.AddOns.Craps.Table.state().phase == :come_out do
        drop_chip(view, "pass_line")
        set_point(view)
      else
        render(view)
      end
    end

    test "sitting down draws a stack and the dice", %{view: view, admin: admin} do
      refute has_element?(view, "#craps-roll")

      view |> element("button[phx-click='sit']") |> render_click()

      assert has_element?(view, "#craps-seats", "@#{admin.username}")
      assert has_element?(view, "#craps-seats", "Shooter")
      assert render(view) =~ "1000"
    end

    test "the shooter cannot roll until there is a line bet", %{view: view} do
      sit(view)

      assert has_element?(view, "#craps-roll[disabled]")
      assert render(view) =~ "before you roll"

      drop_chip(view, "pass_line")

      refute has_element?(view, "#craps-roll[disabled]")
    end

    test "a chip dropped on the felt comes out of the stack", %{view: view} do
      sit(view)
      view |> element("button[phx-value-amount='25']") |> render_click()
      drop_chip(view, "pass_line")

      assert has_element?(view, "#craps-my-bets", "Pass line")
      assert render(view) =~ "975"
    end

    test "the felt greys out what the come-out does not allow", %{view: view} do
      sit(view)
      actions = scene(view)["actions"]

      assert actions["field"]["enabled"]
      assert actions["field"]["bet"] == "field"
      refute actions["place_6"]["enabled"]
      assert actions["place_6"]["label"] =~ "not this roll"
      refute actions["hard_8"]["enabled"]
    end

    test "a chip on your own line bet lays odds behind it", %{view: view} do
      sit(view)
      drop_chip(view, "pass_line")

      # Nothing to lay odds behind until a point is on.
      assert scene(view)["actions"]["pass_line"]["label"] =~ "already down"

      set_point(view)

      action = scene(view)["actions"]["pass_line"]
      assert action["enabled"]
      assert action["bet"] == "pass_odds"
      assert action["label"] =~ "behind your Pass line"

      drop_chip(view, action["bet"])
      assert has_element?(view, "#craps-my-bets", "Pass odds")
    end

    test "a rejected bet says why", %{view: view} do
      sit(view)

      assert render_hook(view, "felt_bet", %{"bet" => "place_6"}) =~ "cannot be placed right now"
    end

    test "the felt only offers bets to somebody who is seated", %{view: view} do
      refute scene(view)["seated"]

      sit(view)

      assert scene(view)["seated"]
    end

    test "no outcome is shown until the dice have stopped", %{view: view} do
      sit(view)
      drop_chip(view, "pass_line")
      before = render(view)

      view |> element("#craps-roll") |> render_click()
      mid_air = render(view)

      # The server has already resolved. None of it may be on screen yet.
      assert mid_air =~ "Dice in the air"
      refute mid_air =~ ~r/\d \+ \d = \d+/
      refute mid_air =~ "Point established"
      refute mid_air =~ "pass line wins"
      refute mid_air =~ "Seven out"
      assert chips(mid_air) == chips(before)

      # The felt is told the faces so it can throw them, and nothing else.
      scene = scene(view)
      assert scene["last_roll"]["die1"] in 1..6
      assert scene["phase"] == "come_out"
      assert scene["point"] == nil

      settled = render_hook(view, "dice_settled", %{"id" => scene["last_roll"]["id"]})

      refute settled =~ "Dice in the air"
      assert settled =~ ~r/\d \+ \d = \d+/
    end

    test "a roll cannot be thrown again while the dice are still going", %{view: view} do
      sit(view)
      drop_chip(view, "pass_line")

      view |> element("#craps-roll") |> render_click()

      assert has_element?(view, "#craps-roll[disabled]")
    end

    test "a bet landing mid-throw does not leak the outcome", %{view: view, conn: conn} do
      sit(view)
      other = with_keys(user_fixture())
      {:ok, watcher, _html} = conn |> log_in_user(other) |> live(~p"/craps")
      watcher |> element("button[phx-click='sit']") |> render_click()

      drop_chip(view, "pass_line")
      view |> element("#craps-roll") |> render_click()

      # Another player betting broadcasts state that already carries the
      # resolved roll; the watcher must still see nothing.
      drop_chip(watcher, "field")

      assert render(view) =~ "Dice in the air"
      refute render(view) =~ "Point established"
    end

    test "a browser that never reports still gets its outcome", %{view: view} do
      sit(view)
      drop_chip(view, "pass_line")
      view |> element("#craps-roll") |> render_click()

      assert render(view) =~ "Dice in the air"

      # The grace timer is the backstop for a tab that never answers.
      send(view.pid, {:reveal, scene(view)["last_roll"]["id"]})

      refute render(view) =~ "Dice in the air"
    end

    test "the felt shows every player's action, tagged so yours stands out", %{
      view: view,
      conn: conn
    } do
      sit(view)
      drop_chip(view, "pass_line")

      other = with_keys(user_fixture())
      {:ok, watcher, _html} = conn |> log_in_user(other) |> live(~p"/craps")
      watcher |> element("button[phx-click='sit']") |> render_click()
      render_hook(watcher, "felt_bet", %{"bet" => "field"})

      # Each player sees both bets, and only their own is theirs.
      assert [%{"type" => "pass_line", "mine" => true}, %{"type" => "field", "mine" => false}] =
               scene(view)["bets"]

      assert [%{"type" => "pass_line", "mine" => false}, %{"type" => "field", "mine" => true}] =
               scene(watcher)["bets"]

      # The written list underneath stays personal.
      assert has_element?(view, "#craps-my-bets", "Pass line")
      refute has_element?(view, "#craps-my-bets", "Field")
    end

    test "seats alternate between the two ends so a full table stays balanced", %{
      view: view,
      conn: conn
    } do
      sit(view)
      drop_chip(view, "pass_line")

      second = with_keys(user_fixture())
      {:ok, other, _html} = conn |> log_in_user(second) |> live(~p"/craps")
      other |> element("button[phx-click='sit']") |> render_click()
      render_hook(other, "felt_bet", %{"bet" => "field"})

      third = with_keys(user_fixture())
      {:ok, another, _html} = conn |> log_in_user(third) |> live(~p"/craps")
      another |> element("button[phx-click='sit']") |> render_click()
      render_hook(another, "felt_bet", %{"bet" => "any_craps"})

      bets = Map.new(scene(view)["bets"], &{&1["type"], &1})

      # First left, second right, third back to the left in a fresh lane.
      assert %{"side" => "left", "slot" => 0} = bets["pass_line"]
      assert %{"side" => "right", "slot" => 0} = bets["field"]
      assert %{"side" => "left", "slot" => 1} = bets["any_craps"]
    end

    test "a full table splits evenly across the two ends", %{view: view} do
      sit(view)

      for _ <- 1..7 do
        {:ok, _} = Veejr.AddOns.Craps.Table.sit(with_keys(user_fixture()))
      end

      # Every seat bets the field, which both ends carry.
      for seat <- Veejr.AddOns.Craps.Table.state().seats do
        {:ok, _} = Veejr.AddOns.Craps.Table.place_bet(seat.user_id, :field, 10)
      end

      sides = scene(view)["bets"] |> Enum.map(& &1["side"]) |> Enum.frequencies()
      assert sides == %{"left" => 4, "right" => 4}

      # And nobody shares a lane with the player beside them.
      stations = Enum.map(scene(view)["bets"], &{&1["side"], &1["slot"]})
      assert length(Enum.uniq(stations)) == 8
    end

    test "everyone sees the same stations, whichever seat they are in", %{
      view: view,
      conn: conn
    } do
      sit(view)
      drop_chip(view, "pass_line")

      second = with_keys(user_fixture())
      {:ok, other, _html} = conn |> log_in_user(second) |> live(~p"/craps")
      other |> element("button[phx-click='sit']") |> render_click()

      # Where a chip sits is a fact about the table, not about who is looking.
      assert Enum.map(scene(view)["bets"], &{&1["type"], &1["side"], &1["slot"]}) ==
               Enum.map(scene(other)["bets"], &{&1["type"], &1["side"], &1["slot"]})
    end

    test "another player's bet is held back while the dice are in the air", %{
      view: view,
      conn: conn
    } do
      sit(view)
      drop_chip(view, "pass_line")

      other = with_keys(user_fixture())
      {:ok, watcher, _html} = conn |> log_in_user(other) |> live(~p"/craps")
      watcher |> element("button[phx-click='sit']") |> render_click()

      view |> element("#craps-roll") |> render_click()
      render_hook(watcher, "felt_bet", %{"bet" => "field"})

      # The felt must not gain a chip mid-throw either: bets ride on `shown`.
      refute Enum.any?(scene(view)["bets"], &(&1["type"] == "field"))

      render_hook(view, "dice_settled", %{"id" => scene(view)["last_roll"]["id"]})

      assert Enum.any?(scene(view)["bets"], &(&1["type"] == "field"))
    end

    test "the full-screen overlay carries the chips, the stake and the bets", %{view: view} do
      sit(view)
      view |> element("button[phx-value-amount='25']") |> render_click()
      drop_chip(view, "pass_line")

      hud = view |> element("#craps-hud") |> render()

      assert hud =~ "Chips"
      assert hud =~ "975"
      assert hud =~ "Your bets"
      assert hud =~ "Pass line"
      # The stake is a dropdown here rather than the row of buttons that fits
      # under the felt in the page.
      assert has_element?(view, "#craps-hud-stake option[value='25'][selected]")
    end

    test "the overlay's stake dropdown changes what a chip is worth", %{view: view} do
      sit(view)

      view
      |> element("#craps-hud form[phx-change='stake']")
      |> render_change(%{"amount" => "100"})

      drop_chip(view, "pass_line")

      assert render(view) =~ "900"
      assert has_element?(view, "#craps-my-bets", "100")
    end

    test "the overlay is a sibling of the felt, not inside the ignored subtree", %{view: view} do
      # The scene owns the felt's DOM, so an overlay placed inside it would
      # never be patched again.
      assert has_element?(view, "#craps-stage > #craps-felt[phx-update='ignore']")
      assert has_element?(view, "#craps-stage > #craps-hud")
      refute has_element?(view, "#craps-felt #craps-hud")
    end

    test "the overlay offers the shooter a way to roll without leaving", %{view: view} do
      sit(view)

      assert has_element?(view, "#craps-hud-roll[disabled]")

      drop_chip(view, "pass_line")

      assert has_element?(view, "#craps-hud-roll")
      refute has_element?(view, "#craps-hud-roll[disabled]")
    end

    test "a friend can be asked to come and play", %{conn: conn, admin: admin} do
      friend = with_keys(user_fixture())
      {:ok, request} = Veejr.Social.send_friend_request(admin, friend.username)
      {:ok, _} = Veejr.Social.accept_friend_request(friend, request.id)

      # Stand in for the friend's own open page.
      Phoenix.PubSub.subscribe(Veejr.PubSub, "user:#{friend.id}")

      # The roster of friends is read at mount, so this needs a fresh page.
      {:ok, page, _html} = live(conn, ~p"/craps")

      assert has_element?(page, "#craps-invite-friends", friend.username)
      page |> element("button[phx-value-id='#{friend.id}']") |> render_click()

      assert_receive {:craps_invite, host}
      assert host =~ admin.username
    end

    test "somebody who is not a friend cannot be invited", %{view: view, admin: admin} do
      stranger = user_fixture()
      refute render(view) =~ stranger.username

      assert Veejr.AddOns.Craps.invite(admin, stranger) == {:error, :not_friends}
    end

    test "leaving refunds what never resolved", %{view: view, admin: admin} do
      sit(view)
      drop_chip(view, "pass_line")

      view |> element("button[phx-click='leave']") |> render_click()

      assert Veejr.AddOns.Craps.chip_balance(admin) == 1000
      assert has_element?(view, "button[phx-click='sit']")
    end

    test "one player's move reaches everyone else's table", %{view: view, conn: conn} do
      other = with_keys(user_fixture())
      {:ok, watcher, _html} = conn |> log_in_user(other) |> live(~p"/craps")

      refute render(watcher) =~ "Shooter"

      view |> element("button[phx-click='sit']") |> render_click()

      assert render(watcher) =~ "Shooter"
      assert has_element?(watcher, "#craps-seats", "At the table")
    end
  end
end
