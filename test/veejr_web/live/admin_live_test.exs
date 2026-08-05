defmodule VeejrWeb.AdminLiveTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Operations, Repo}
  alias Veejr.Federation.Peers.Peer

  test "renders the administrator dashboard", %{conn: conn} do
    admin = user_fixture()
    {:ok, invitation, _token} = Accounts.create_invitation(admin)

    {:ok, view, html} =
      conn
      |> log_in_user(admin)
      |> live(~p"/admin")

    assert html =~ "Instance administration"
    assert has_element?(view, "details#admin-overview[open]")
    refute has_element?(view, "details#admin-settings[open]")
    refute has_element?(view, "details#admin-accounts[open]")
    refute has_element?(view, "details#admin-account-moves[open]")
    refute has_element?(view, "details#admin-invitations[open]")
    refute has_element?(view, "details#admin-audit[open]")
    refute has_element?(view, "details#admin-peers[open]")
    refute has_element?(view, "details#admin-operations[open]")
    refute has_element?(view, "details#admin-system[open]")
    refute has_element?(view, "details#admin-software-update[open]")
    assert has_element?(view, "#admin-health", "All monitored services operational")
    assert has_element?(view, "#metric-local-users", "1")
    assert has_element?(view, "#metric-storage")
    assert has_element?(view, "#admin-settings")
    assert has_element?(view, "#instance-settings-form")
    assert has_element?(view, "button[phx-click='refresh']")
    assert has_element?(view, "#admin-invitations a[href='/invites/new']")
    assert has_element?(view, "#invitation-#{invitation.id}", "Active")
    assert has_element?(view, "#invitation-#{invitation.id} button", "Revoke")

    view |> element("button[phx-click='refresh']") |> render_click()
    assert has_element?(view, "#admin-health")
  end

  test "checks for software updates on demand", %{conn: conn} do
    admin = user_fixture()

    Req.Test.stub(Veejr.UpdatesStub, fn conn ->
      Req.Test.json(conn, %{
        "tag_name" => "v9.9.9",
        "name" => "Release v9.9.9",
        "body" => "big improvements",
        "html_url" => "https://example.com/release"
      })
    end)

    {:ok, view, html} = conn |> log_in_user(admin) |> live(~p"/admin")

    # nothing phones home until the admin asks
    assert html =~ "Updates are checked only when you ask"
    assert html =~ "v#{Veejr.Updates.current_version()}"

    view |> element("#check-updates") |> render_click()

    assert has_element?(view, "#admin-software-update", "v9.9.9")
    assert has_element?(view, "#admin-software-update", "big improvements")
  end

  test "reports an up-to-date instance", %{conn: conn} do
    admin = user_fixture()

    Req.Test.stub(Veejr.UpdatesStub, fn conn ->
      Req.Test.json(conn, %{"tag_name" => "v" <> Veejr.Updates.current_version()})
    end)

    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/admin")

    view |> element("#check-updates") |> render_click()

    assert has_element?(view, "#admin-software-update", "Up to date")
    refute has_element?(view, "#start-upgrade")
  end

  test "offers craps from the add-ons panel, defaulting to fair dice", %{conn: conn} do
    admin = user_fixture()

    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/admin")

    assert has_element?(view, "#admin-add-ons")
    assert has_element?(view, "#add-on-craps", "Server-refereed")
    refute has_element?(view, "#add-ons-form input[name='add_ons[craps_enabled]'][checked]")
    assert has_element?(view, "#add-ons-form option[value='fair'][selected]")
    refute Veejr.AddOns.enabled?(:craps)

    view
    |> form("#add-ons-form", %{"add_ons" => %{"craps_enabled" => "true"}})
    |> render_submit()

    assert has_element?(view, "#add-ons-form input[name='add_ons[craps_enabled]'][checked]")
    assert has_element?(view, "#admin-audit", "Settings updated")
    assert Veejr.AddOns.enabled?(:craps)
    assert Veejr.AddOns.craps_dice_mode() == "fair"

    view
    |> form("#add-ons-form", %{
      "add_ons" => %{"craps_enabled" => "true", "craps_dice_mode" => "house"}
    })
    |> render_submit()

    assert Veejr.AddOns.craps_dice_mode() == "house"
  end

  test "clearing the add-on checkbox turns it back off", %{conn: conn} do
    admin = user_fixture()
    {:ok, _settings} = Veejr.Admin.update_instance_settings(admin, %{"craps_enabled" => "true"})

    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/admin")
    assert has_element?(view, "#add-ons-form input[name='add_ons[craps_enabled]'][checked]")

    # An unchecked box submits nothing of its own. What actually turns the
    # add-on off is the hidden "false" companion input the checkbox component
    # renders alongside it.
    view
    |> form("#add-ons-form", %{"add_ons" => %{"craps_enabled" => "false"}})
    |> render_submit()

    refute has_element?(view, "#add-ons-form input[name='add_ons[craps_enabled]'][checked]")
    refute Veejr.AddOns.enabled?(:craps)
  end

  test "replenishes a player's craps chips from the add-ons panel", %{conn: conn} do
    admin = user_fixture()
    player = user_fixture(%{username: "brokeplayer"})
    Veejr.AddOns.Craps.put_chip_balance(player.id, 0)

    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/admin")

    # A full starting stack is the default, since that is what replenishing
    # nearly always means.
    assert has_element?(view, "#craps-chips-form input[name='chips[amount]'][value='1000']")
    assert has_element?(view, "#craps-chips-form option", "@brokeplayer")

    view
    |> form("#craps-chips-form", %{"chips" => %{"user_id" => "#{player.id}", "amount" => "2500"}})
    |> render_submit()

    assert Veejr.AddOns.Craps.chip_balance(player) == 2500
    assert render(view) =~ "now has 2500 chips"
    assert has_element?(view, "#admin-audit", "Craps chips set")
  end

  test "refuses a stack nobody meant to hand out", %{conn: conn} do
    admin = user_fixture()
    player = user_fixture()

    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/admin")

    html =
      view
      |> form("#craps-chips-form", %{
        "chips" => %{"user_id" => "#{player.id}", "amount" => "999999999"}
      })
      |> render_submit()

    assert html =~ "Enter a whole number"
    assert Veejr.AddOns.Craps.chip_balance(player) == 0
  end

  test "asks for a player when none was picked", %{conn: conn} do
    admin = user_fixture()

    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/admin")

    assert view
           |> form("#craps-chips-form", %{"chips" => %{"user_id" => "", "amount" => "1000"}})
           |> render_submit() =~ "Pick a player"
  end

  test "updates instance settings and tests mail delivery", %{conn: conn} do
    admin = user_fixture()
    assert_email_sent()

    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/admin")

    view
    |> form("#instance-settings-form", %{
      "settings" => %{
        "name" => "Veejr Test Community",
        "description" => "Test description",
        "registration_policy" => "invite_only",
        "invitation_lifetime_days" => "3",
        "max_upload_mb" => "20",
        "storage_quota_mb" => "200",
        "default_retention_hours" => "24",
        "mail_from_name" => "Veejr Test",
        "mail_from_address" => "sender@example.com"
      }
    })
    |> render_submit()

    assert has_element?(view, "#instance-settings-form input[value='Veejr Test Community']")
    assert has_element?(view, "#admin-audit", "Settings updated")

    view |> element("button[phx-click='test_mail']") |> render_click()
    assert_email_sent(subject: "Veejr email delivery test")
    assert has_element?(view, "#admin-audit", "Mail tested")
  end

  test "expires an invitation", %{conn: conn} do
    admin = user_fixture()
    {:ok, invitation, token} = Accounts.create_invitation(admin)
    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/admin")

    view |> element("#invitation-#{invitation.id} button", "Expire") |> render_click()

    assert has_element?(view, "#invitation-#{invitation.id}", "Expired")
    refute Accounts.get_open_invitation(token)
    assert has_element?(view, "#admin-audit", "Invitation expired")
  end

  test "shows content-free operational failures", %{conn: conn} do
    admin = user_fixture()
    assert {:ok, _failure} = Operations.record_failure("email", "login_link", :timeout)

    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/admin")

    assert has_element?(view, "#metric-email-failures", "1")
    assert has_element?(view, "#admin-failures", "login_link")
    assert has_element?(view, "#admin-failures", "timeout")
  end

  test "revokes an active invitation", %{conn: conn} do
    admin = user_fixture()
    {:ok, invitation, token} = Accounts.create_invitation(admin)

    {:ok, view, _html} =
      conn
      |> log_in_user(admin)
      |> live(~p"/admin")

    view
    |> element("#invitation-#{invitation.id} button", "Revoke")
    |> render_click()

    assert has_element?(view, "#invitation-#{invitation.id}", "Revoked")
    refute has_element?(view, "#invitation-#{invitation.id} button", "Revoke")
    refute Accounts.get_open_invitation(token)
    assert has_element?(view, "#admin-audit", "Invitation revoked")
  end

  test "lists local accounts and revokes member sessions", %{conn: conn} do
    admin = user_fixture()
    member = user_fixture(%{display_name: "Session Member"})
    web_token = Accounts.generate_user_session_token(member)

    {:ok, _device_session, api_tokens} =
      Accounts.create_api_device_session(member, %{
        "device_name" => "Test Pixel",
        "platform" => "android",
        "app_version" => "test"
      })

    {:ok, view, _html} =
      conn
      |> log_in_user(admin)
      |> live(~p"/admin")

    assert has_element?(view, "#account-#{admin.id}", "Instance admin")
    assert has_element?(view, "#account-#{member.id}", "Session Member")
    assert has_element?(view, "#account-#{member.id}", "Test Pixel") == false

    assert has_element?(
             view,
             "#account-#{member.id} button[phx-click='revoke_user_sessions']",
             "Revoke sessions"
           )

    view
    |> element("#account-#{member.id} button[phx-click='revoke_user_sessions']")
    |> render_click()

    refute has_element?(view, "#account-#{member.id} button", "Revoke sessions")
    assert has_element?(view, "#account-#{member.id}", "Never")
    assert has_element?(view, "#admin-audit", "1 web / 1 Android")
    refute Accounts.get_user_by_session_token(web_token)
    refute Accounts.get_user_and_api_session_by_access_token(api_tokens.access_token)
  end

  test "suspends and reactivates a member", %{conn: conn} do
    admin = user_fixture()
    member = user_fixture()
    token = Accounts.generate_user_session_token(member)

    {:ok, view, _html} =
      conn
      |> log_in_user(admin)
      |> live(~p"/admin")

    assert has_element?(view, "#account-#{member.id} button", "Suspend")

    view
    |> element("#account-#{member.id} button[phx-click='suspend_user']")
    |> render_click()

    assert has_element?(view, "#account-#{member.id}", "Suspended")
    assert has_element?(view, "#account-#{member.id} button", "Reactivate")
    assert has_element?(view, "#admin-audit", "Account suspended")
    refute Accounts.get_user_by_session_token(token)

    view
    |> element("#account-#{member.id} button[phx-click='reactivate_user']")
    |> render_click()

    assert has_element?(view, "#account-#{member.id}", "Confirmed")
    assert has_element?(view, "#account-#{member.id} button", "Suspend")
    assert has_element?(view, "#admin-audit", "Account reactivated")
  end

  test "blocks and unblocks a federation peer", %{conn: conn} do
    admin = user_fixture()

    peer =
      %Peer{authority: "remote.example", public_key: Base.encode64("peer-key")}
      |> Ecto.Changeset.change()
      |> Repo.insert!()

    {:ok, view, _html} =
      conn
      |> log_in_user(admin)
      |> live(~p"/admin")

    assert has_element?(view, "#peer-#{peer.id}", "Allowed")
    assert has_element?(view, "#peer-#{peer.id} button", "Block")

    view |> element("#peer-#{peer.id} button[phx-click='block_peer']") |> render_click()

    assert has_element?(view, "#peer-#{peer.id}", "Blocked")
    assert has_element?(view, "#peer-#{peer.id} button", "Unblock")
    assert has_element?(view, "#admin-audit", "Peer blocked")

    view |> element("#peer-#{peer.id} button[phx-click='unblock_peer']") |> render_click()

    assert has_element?(view, "#peer-#{peer.id}", "Allowed")
    assert has_element?(view, "#admin-audit", "Peer unblocked")
  end

  test "redirects ordinary members", %{conn: conn} do
    _admin = user_fixture()
    member = user_fixture()

    assert {:error, {:redirect, %{to: path, flash: flash}}} =
             conn
             |> log_in_user(member)
             |> live(~p"/admin")

    assert path == ~p"/contacts"
    assert flash["error"] =~ "Only the instance administrator"
  end

  test "requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin")
    assert path == ~p"/users/log-in"
  end
end
