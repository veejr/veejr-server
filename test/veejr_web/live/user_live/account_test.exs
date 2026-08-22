defmodule VeejrWeb.UserLive.AccountTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Push, Repo}

  test "renders account links from the username destination", %{conn: conn} do
    user = user_fixture()

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account")

    assert html =~ user.username
    assert html =~ ~p"/users/settings"
    assert html =~ ~p"/keys"
    assert html =~ ~p"/account/archives"
    assert html =~ "Instance administrator"
    assert html =~ ~p"/admin"
  end

  test "renders profile, identity, and FCM registration status", %{conn: conn} do
    user = user_fixture(%{display_name: "My nickname"})

    {:ok, session, _tokens} =
      Accounts.create_api_device_session(user, %{
        "device_name" => "Test Pixel",
        "platform" => "android",
        "app_version" => "test"
      })

    assert :ok = Push.register_android_token(user, session.id, "fcm-token")

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account")

    assert has_element?(view, "#account-nickname", "My nickname")
    assert has_element?(view, "#account-username", "@#{user.username}")
    assert has_element?(view, "#account-status[phx-hook=AccountStatus]")
    assert has_element?(view, "#account-fcm-status", "Registered")
  end

  test "reports FCM as not registered when no Android token exists", %{conn: conn} do
    user = user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account")

    assert has_element?(view, "#account-fcm-status", "Not registered")
  end

  test "lists and revokes an Android device session", %{conn: conn} do
    user = user_fixture()

    {:ok, android, _tokens} =
      Accounts.create_api_device_session(user, %{
        "device_name" => "Travel phone",
        "platform" => "android",
        "app_version" => "2.0"
      })

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account")

    assert has_element?(view, "#account-device-sessions")
    assert has_element?(view, "#device-session-list li", "Current")
    assert has_element?(view, "#device-session-android-#{android.id}", "Travel phone")

    view
    |> element("#revoke-device-session-android-#{android.id}")
    |> render_click()

    refute has_element?(view, "#device-session-android-#{android.id}")
  end

  test "reports an ordinary member role", %{conn: conn} do
    _admin = user_fixture()
    member = user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(member)
      |> live(~p"/account")

    assert has_element?(view, "#account-role", "Member")
    refute has_element?(view, "#account-admin-link")
  end

  test "chooses one persistent experience mode from the account", %{conn: conn} do
    user = user_fixture()

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/account")

    assert has_element?(view, "#experience-mode")
    assert has_element?(view, "#experience-mode-simple[aria-checked='true']")
    assert has_element?(view, "#primary-navigation-links a[href='/contacts/simple']")
    assert has_element?(view, "#primary-navigation-links a[href='/messages/simple']")
    refute has_element?(view, "#primary-navigation-links a[href='/calls']")
    refute has_element?(view, "#primary-navigation-themes")

    view |> element("#experience-mode-full") |> render_click()

    assert has_element?(view, "#experience-mode-full[aria-checked='true']")
    assert has_element?(view, "#primary-navigation-links a[href='/messages?self_notes=true']")
    assert has_element?(view, "#primary-navigation-links a[href='/calls']")

    view |> element("#experience-mode-simple") |> render_click()

    assert has_element?(view, "#experience-mode-simple[aria-checked='true']")
    assert has_element?(view, "#primary-navigation-links a[href='/contacts/simple']")
    assert has_element?(view, "#primary-navigation-links a[href='/messages/simple']")
    refute has_element?(view, "#primary-navigation-links a[href='/calls']")
    refute has_element?(view, "#primary-navigation-themes")
    assert Repo.reload!(user).page_layout == "simple"
  end

  test "requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/account")
    assert path == ~p"/users/log-in"
  end
end
