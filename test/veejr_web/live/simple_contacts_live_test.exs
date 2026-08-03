defmodule VeejrWeb.SimpleContactsLiveTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Repo, Social}

  setup %{conn: conn} do
    user = user_fixture()
    friend = user_fixture()

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        "public_key" => Base.encode64(String.pad_trailing("public-key", 32, "x")),
        "enc_secret_key" => Base.encode64(String.pad_trailing("wrapped-key", 48, "x")),
        "key_salt" => Base.encode64(String.pad_trailing("salt", 16, "x")),
        "key_nonce" => Base.encode64(String.pad_trailing("nonce", 24, "x"))
      })

    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _friendship} = Social.accept_friend_request(friend, request.id)

    %{conn: log_in_user(conn, user), user: user, friend: friend}
  end

  test "gives each contact a face, a name, and a way into the conversation", %{
    conn: conn,
    friend: friend
  } do
    {:ok, view, _html} = live(conn, "/contacts/simple")

    assert has_element?(
             view,
             "#simple-contacts-list #simple-contact-#{friend.id}[href='/messages/simple?friend=#{friend.id}']"
           )

    assert has_element?(view, "#simple-contact-#{friend.id}", "@#{friend.username}")
    assert has_element?(view, "#simple-contact-#{friend.id} [aria-label*='profile image']")
    assert has_element?(view, "#simple-contacts-layout[role='switch'][aria-checked='true']")
  end

  test "switching back to the full layout saves the choice and goes there", %{
    conn: conn,
    user: user
  } do
    {:ok, _user} = Accounts.set_page_layout(user, "simple")
    {:ok, view, _html} = live(conn, "/contacts/simple")

    view |> element("#simple-contacts-layout") |> render_click()

    assert_redirect(view, "/contacts")
    assert Repo.reload!(user).page_layout == "full"

    # And the full page stays put now that it is the saved layout.
    {:ok, contacts, _html} = live(conn, "/contacts")
    assert has_element?(contacts, "#contacts-workspace")
  end

  test "leaves the full page's tools, forms, and sections behind", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/contacts/simple")

    refute has_element?(view, "#contacts-tools")
    refute has_element?(view, ".contacts-section")
    refute has_element?(view, "form")
  end

  test "says so when there is nobody to show yet", %{conn: conn} do
    stranger = user_fixture()

    {:ok, stranger} =
      Accounts.setup_user_keys(stranger, %{
        "public_key" => Base.encode64(String.pad_trailing("public-key", 32, "y")),
        "enc_secret_key" => Base.encode64(String.pad_trailing("wrapped-key", 48, "y")),
        "key_salt" => Base.encode64(String.pad_trailing("salt", 16, "y")),
        "key_nonce" => Base.encode64(String.pad_trailing("nonce", 24, "y"))
      })

    {:ok, view, _html} = live(log_in_user(conn, stranger), "/contacts/simple")

    assert has_element?(view, "#simple-contacts-empty", "No contacts yet")
    refute has_element?(view, "#simple-contacts-list")
  end
end
