defmodule VeejrWeb.UserLive.SettingsTest do
  use VeejrWeb.ConnCase

  alias Veejr.Accounts
  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  describe "Settings page" do
    test "renders settings page and protects the administrator account", %{conn: conn} do
      {:ok, view, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert html =~ "Change Email"
      assert html =~ "Save Password"
      assert has_element?(view, "#avatar-upload")
      assert has_element?(view, "#settings-avatar [role='img']")
      assert has_element?(view, "#account-backup")
      assert has_element?(view, "#export-account-backup[href='/export']")
      assert has_element?(view, "#restore-backup-form")
      assert has_element?(view, "#restore-account-backup[disabled]")
      assert has_element?(view, "#admin-account-protection")
      refute has_element?(view, "button[phx-click='delete_account']")
    end

    test "turns online status off and stops recording it", %{conn: conn} do
      user = user_fixture()
      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/users/settings")

      # Mounting the settings page is itself an open page.
      assert has_element?(view, "#presence-sharing-toggle[checked]")
      assert Veejr.Presence.state(user) == :online

      view |> element("#presence-sharing-toggle") |> render_click()

      refute has_element?(view, "#presence-sharing-toggle[checked]")
      refute Accounts.get_user!(user.id).presence_sharing
      # Off means the record is gone, not merely hidden from viewers.
      refute :ets.member(Veejr.Presence, user.id)

      view |> element("#presence-sharing-toggle") |> render_click()

      assert has_element?(view, "#presence-sharing-toggle[checked]")
      assert Accounts.get_user!(user.id).presence_sharing
      assert Veejr.Presence.state(Accounts.get_user!(user.id)) == :online
    end

    test "removes an uploaded profile image", %{conn: conn} do
      user = user_fixture()
      {:ok, user} = Accounts.put_user_avatar(user, jpeg())

      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/users/settings")
      assert has_element?(view, "#settings-avatar img[src='/avatars/#{user.username}?v=1']")

      view |> element("button[phx-click='remove_avatar']") |> render_click()

      assert has_element?(view, "#settings-avatar [role='img']")
      refute Accounts.get_user!(user.id).has_avatar
    end

    test "opens the current user's image consistently", %{conn: conn} do
      user = user_fixture(%{display_name: "Current Profile"})
      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/users/settings")

      view |> element("#settings-avatar") |> render_click()

      assert has_element?(view, "#profile-dialog", "Current Profile")
      refute has_element?(view, "#profile-dialog form")
    end

    test "restores an uploaded backup for the current key identity", %{conn: conn} do
      user = user_fixture(%{username: "settings_restore"})

      {:ok, user} =
        Accounts.setup_user_keys(user, %{
          "public_key" => Base.encode64("settings-public-key"),
          "enc_secret_key" => Base.encode64("settings-wrapped-key"),
          "key_salt" => Base.encode64("settings-salt"),
          "key_nonce" => Base.encode64("settings-nonce")
        })

      {:ok, _, zip} = Veejr.Export.build(user)
      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/users/settings")

      upload =
        file_input(view, "#restore-backup-form", :backup, [
          %{
            last_modified: 1_700_000_000_000,
            name: "veejr-backup.zip",
            content: zip,
            type: "application/zip"
          }
        ])

      assert render_upload(upload, "veejr-backup.zip") =~ "veejr-backup.zip"
      view |> form("#restore-backup-form", %{}) |> render_submit()

      assert render(view) =~ "Backup restored: 0 messages and 0 attachments added."
    end

    test "keeps account deletion available to ordinary members", %{conn: conn} do
      _admin = user_fixture()
      member = user_fixture()

      {:ok, view, _html} =
        conn
        |> log_in_user(member)
        |> live(~p"/users/settings")

      refute has_element?(view, "#admin-account-protection")
      assert has_element?(view, "button[phx-click='delete_account']")
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "returns to settings after re-authentication", %{conn: conn} do
      user = user_fixture() |> set_password()

      stale_conn =
        log_in_user(conn, user,
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )

      assert {:error, {:redirect, %{to: login_path, flash: flash}}} =
               live(stale_conn, ~p"/users/settings")

      assert URI.decode_query(URI.parse(login_path).query)["return_to"] == ~p"/users/settings"
      assert %{"error" => "You must re-authenticate to access this page."} = flash

      {:ok, login_live, _html} = live(stale_conn, login_path)

      login_form =
        form(login_live, "#login_form_password",
          user: %{identifier: user.username, password: valid_user_password()}
        )

      authenticated_conn = submit_form(login_form, stale_conn)

      assert redirected_to(authenticated_conn) == ~p"/users/settings"
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user email", %{conn: conn, user: user} do
      new_email = unique_user_email()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => new_email}
        })
        |> render_submit()

      assert result =~ "A link to confirm your email"
      assert Accounts.get_user_by_email(user.email)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "user" => %{"email" => "with spaces"}
        })

      assert result =~ "Change Email"
      assert result =~ "must have the @ sign and no spaces"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => user.email}
        })
        |> render_submit()

      assert result =~ "Change Email"
      assert result =~ "did not change"
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user password", %{conn: conn, user: user} do
      new_password = valid_user_password()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      form =
        form(lv, "#password_form", %{
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/users/settings"

      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_user_by_email_and_password(user.email, new_password)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#password_form", %{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      user = user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{conn: log_in_user(conn, user), token: token, email: email, user: user}
    end

    test "updates the user email once", %{conn: conn, user: user, token: token, email: email} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"info" => message} = flash
      assert message == "Email changed successfully."
      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
    end

    test "does not update email with invalid token", %{conn: conn, user: user} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
      assert Accounts.get_user_by_email(user.email)
    end

    test "redirects if user is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => message} = flash
      assert message == "You must log in to access this page."
    end
  end

  defp jpeg do
    <<0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 512::16, 512::16, 0::size(12)-unit(8), 0xFF,
      0xD9>>
  end
end
