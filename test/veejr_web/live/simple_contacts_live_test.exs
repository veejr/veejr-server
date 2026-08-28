defmodule VeejrWeb.SimpleContactsLiveTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Calls, Repo, Social}

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
    assert has_element?(view, "#simple-contact-presence-#{friend.id}")
    assert has_element?(view, "a[href='/contacts?manage=true']", "Manage")

    assert has_element?(
             view,
             "#simple-contacts-list #simple-self-notes[href='/messages?self_notes=true']",
             "Notes to yourself"
           )
  end

  test "asks whether to call now or schedule from the contact photo", %{
    conn: conn,
    friend: friend
  } do
    {:ok, view, _html} = live(conn, "/contacts/simple")

    assert has_element?(
             view,
             "#simple-contact-call-#{friend.id}[aria-haspopup='dialog'][aria-controls='simple-call-dialog']"
           )

    refute has_element?(view, "#simple-call-dialog")
    view |> element("#simple-contact-call-#{friend.id}") |> render_click()

    assert has_element?(view, "#simple-call-dialog[role='dialog'][aria-modal='true']")
    assert has_element?(view, "#simple-call-dialog-title", "@#{friend.username}")
    assert has_element?(view, "#simple-call-now[phx-click='start_call']", "Call now")

    assert has_element?(
             view,
             "#simple-schedule-call[href='/calls?friend_id=#{friend.id}']",
             "Schedule a call"
           )

    view |> element("#simple-call-cancel") |> render_click()
    refute has_element?(view, "#simple-call-dialog")
  end

  test "starts an immediate call and returns to simple contacts afterwards", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, view, _html} = live(conn, "/contacts/simple")

    view |> element("#simple-contact-call-#{friend.id}") |> render_click()
    view |> element("#simple-call-now") |> render_click()

    {call_path, _flash} = assert_redirect(view)
    uri = URI.parse(call_path)
    assert "/call/" <> public_id = uri.path
    assert URI.decode_query(uri.query)["return_to"] == "/contacts/simple"
    user_id = user.id
    friend_id = friend.id

    assert {:ok, %{state: "ringing", caller_id: ^user_id, callee_id: ^friend_id}} =
             Calls.get_call(user, public_id)
  end

  test "opens contact management without changing the saved simple mode", %{
    conn: conn,
    user: user
  } do
    {:ok, _user} = Accounts.set_page_layout(user, "simple")
    {:ok, view, _html} = live(conn, "/contacts?manage=true")

    assert has_element?(view, "#contacts-workspace")
    assert Repo.reload!(user).page_layout == "simple"
  end

  test "leaves the full page's tools, forms, and sections behind", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/contacts/simple")

    refute has_element?(view, "#contacts-tools")
    refute has_element?(view, ".contacts-section")
    refute has_element?(view, "main form")
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
    assert has_element?(view, "#simple-contacts-list #simple-self-notes")
    refute has_element?(view, "#simple-contacts-list a[id^='simple-contact-']")
  end
end
