defmodule VeejrWeb.CrapsGuestLiveTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Admin}
  alias Veejr.AddOns.Craps
  alias Veejr.AddOns.Craps.Table

  setup do
    on_exit(fn -> Enum.each(Table.state().seats, &Table.leave(&1.user_id)) end)
  end

  setup %{conn: conn} do
    host = user_fixture()
    {:ok, _} = Admin.update_instance_settings(host, %{"craps_enabled" => "true"})
    assert_email_sent()

    {:ok, guest, token} = Craps.invite_guest(host, %{"invited_email" => "pat@example.test"})

    %{conn: conn, host: host, guest: guest, token: token}
  end

  test "an unknown token is turned away", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/craps/guest/not-a-real-token")

    assert html =~ "That invitation has expired"
  end

  test "an expired capability stops working", %{conn: conn, guest: guest, token: token} do
    guest
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -60))
    |> Veejr.Repo.update!()

    {:ok, _view, html} = live(conn, ~p"/craps/guest/#{token}")

    assert html =~ "That invitation has expired"
  end

  test "the capability opens the table without an account", %{conn: conn, token: token} do
    {:ok, view, html} = live(conn, ~p"/craps/guest/#{token}")

    assert html =~ "This table is refereed"
    assert has_element?(view, "#craps-felt")
    assert has_element?(view, "#craps-guest-sit")
    assert Accounts.get_user_by_email("pat@example.test") == nil
  end

  test "a guest names themselves, sits, and plays", %{conn: conn, token: token} do
    {:ok, view, _html} = live(conn, ~p"/craps/guest/#{token}")

    view |> form("#craps-guest-sit", %{"guest" => %{"display_name" => "Pat"}}) |> render_submit()

    assert has_element?(view, "#craps-seats", "Pat")
    assert render(view) =~ "1000"

    render_hook(view, "felt_bet", %{"bet" => "pass_line"})

    assert has_element?(view, "#craps-my-bets", "Pass line")
    assert render(view) =~ "990"
  end

  test "a guest's chips are never written to the database", %{
    conn: conn,
    token: token,
    guest: guest
  } do
    {:ok, view, _html} = live(conn, ~p"/craps/guest/#{token}")
    view |> form("#craps-guest-sit", %{"guest" => %{"display_name" => "Pat"}}) |> render_submit()
    render_hook(view, "felt_bet", %{"bet" => "pass_line"})

    # No user row, so no stack row either — the seat key is not an id.
    assert Veejr.Repo.aggregate(Craps.Player, :count) == 0
    refute Craps.member?(Craps.guest_player_id(guest))
  end

  test "a guest sits alongside members and can hold the dice", %{conn: conn, token: token} do
    member = user_fixture()
    {:ok, _} = Table.sit(member)

    {:ok, view, _html} = live(conn, ~p"/craps/guest/#{token}")
    view |> form("#craps-guest-sit", %{"guest" => %{"display_name" => "Pat"}}) |> render_submit()

    state = Table.state()
    assert length(state.seats) == 2
    # The member sat first, so the guest is not the shooter yet.
    assert state.shooter_id == member.id
  end

  describe "the offer to stay" do
    setup %{conn: conn, token: token} do
      {:ok, view, _html} = live(conn, ~p"/craps/guest/#{token}")
      %{view: view}
    end

    test "is there while the guest has not taken it", %{view: view} do
      assert has_element?(view, "#craps-join-veejr")
    end

    test "mints one membership invitation and sends them to register", %{
      view: view,
      guest: guest
    } do
      assert {:error, {:live_redirect, %{to: path}}} =
               view |> element("#craps-join-veejr") |> render_click()

      assert path =~ "/users/register"
      assert path =~ "invite="
      assert path =~ URI.encode_www_form(guest.invited_email)

      assert Veejr.Repo.reload!(guest).joined_at
    end

    test "cannot be taken twice", %{guest: guest} do
      {:ok, joined} = Craps.mark_guest_joined(guest)

      assert {:error, {:already_joined, _}} = Craps.mark_guest_joined(joined)
    end
  end

  test "the host sees who they invited", %{conn: conn, host: host} do
    {:ok, host} = Accounts.setup_user_keys(host, valid_key_attrs())

    {:ok, view, _html} = conn |> log_in_user(host) |> live(~p"/craps")

    assert has_element?(view, "#craps-invite-friends", "pat@example.test")
  end

  test "inviting a guest emails them a link", %{conn: conn, host: host} do
    {:ok, host} = Accounts.setup_user_keys(host, valid_key_attrs())
    {:ok, view, _html} = conn |> log_in_user(host) |> live(~p"/craps")

    view
    |> form("#craps-guest-invite", %{"guest" => %{"invited_email" => "sam@example.test"}})
    |> render_submit()

    assert_email_sent(fn email ->
      assert email.to == [{"", "sam@example.test"}]
      assert email.subject =~ "invited you to a game of craps"
      assert email.text_body =~ "/craps/guest/"
      assert email.text_body =~ "play money"
    end)
  end

  defp valid_key_attrs do
    %{
      "public_key" => Base.encode64(String.pad_trailing("public-key", 32, "x")),
      "enc_secret_key" => Base.encode64(String.pad_trailing("wrapped-key", 48, "x")),
      "key_salt" => Base.encode64(String.pad_trailing("salt", 16, "x")),
      "key_nonce" => Base.encode64(String.pad_trailing("nonce", 24, "x"))
    }
  end
end
