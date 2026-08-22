defmodule VeejrWeb.KeysLiveTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  alias Veejr.Accounts

  test "returns a user without keys to the full calling conversation URL", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    assert {:error, {:redirect, %{to: to}}} = live(conn, "/messages?conversation=friend-42")
    assert to == "/keys?return_to=%2Fmessages%3Fconversation%3Dfriend-42"
  end

  test "carries a valid caller path through key setup", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    {:ok, _view, html} = live(conn, "/keys?return_to=%2Fmessages%3Fconversation%3Dfriend-42")

    assert html =~ ~s(data-return-to="/messages?conversation=friend-42")
  end

  test "recommends an optional login password alongside the initial passphrase", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    {:ok, view, _html} = live(conn, "/keys")

    assert has_element?(view, "#key-setup-passphrase")

    assert has_element?(
             view,
             "#key-setup-passphrase-password-visibility-toggle[aria-label='Show passphrase']"
           )

    assert has_element?(view, "#initial-password-setup", "Add a login password (recommended)")

    assert has_element?(
             view,
             "#initial-password-setup",
             "instead of requesting another email link"
           )

    assert has_element?(
             view,
             "#key-setup-password[data-role='account-password'][minlength='12'][maxlength='72']"
           )

    assert has_element?(
             view,
             "#key-setup-password-confirmation[data-role='account-password-confirmation']"
           )

    assert has_element?(
             view,
             "#key-setup-password-password-visibility-toggle[aria-label='Show password']"
           )

    assert has_element?(
             view,
             "#key-setup-password-confirmation-password-visibility-toggle[aria-label='Show password']"
           )
  end

  test "stores a requested login password when initial keys are generated", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    password = valid_user_password()

    {:ok, view, _html} = live(conn, "/keys")

    render_hook(view, "keys_generated", %{
      "public_key" => Base.encode64(:binary.copy(<<1>>, 32)),
      "enc_secret_key" => Base.encode64(:binary.copy(<<2>>, 48)),
      "key_salt" => Base.encode64(:binary.copy(<<3>>, 16)),
      "key_nonce" => Base.encode64(:binary.copy(<<4>>, 24)),
      "password" => password,
      "password_confirmation" => password
    })

    assert_redirect(view, "/")
    assert Accounts.get_user_by_email_and_password(user.email, password)
  end

  test "does not render an external return destination", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    {:ok, _view, html} = live(conn, "/keys?return_to=https%3A%2F%2Fexample.com")

    refute html =~ "data-return-to=\"https://example.com\""
  end
end
