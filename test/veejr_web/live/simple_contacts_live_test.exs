defmodule VeejrWeb.SimpleContactsLiveTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  alias Veejr.Messaging.Envelope
  alias Veejr.{Accounts, Admin, Calls, Repo, Social}

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

  test "rings each photo with the things you do with a person", %{conn: conn, friend: friend} do
    {:ok, view, _html} = live(conn, "/contacts/simple")

    assert has_element?(
             view,
             "#simple-contact-call-#{friend.id}[aria-controls='simple-call-dialog']"
           )

    assert has_element?(
             view,
             "#simple-contact-location-#{friend.id}[aria-controls='simple-location-dialog']"
           )

    # A new instance offers no add-ons, so there is nothing to play yet and
    # the button that would ask is not drawn.
    refute has_element?(view, "#simple-contact-game-#{friend.id}")
  end

  test "hides a control the instance has switched off", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, _settings} = Admin.update_instance_settings(user, %{"craps_enabled" => "true"})

    {:ok, _settings} =
      Admin.update_features(user, %{
        "simple_contact_call" => "true",
        "simple_contact_game" => "false",
        "simple_contact_location" => "false"
      })

    {:ok, view, _html} = live(conn, "/contacts/simple")

    assert has_element?(view, "#simple-contact-call-#{friend.id}")
    refute has_element?(view, "#simple-contact-game-#{friend.id}")
    refute has_element?(view, "#simple-contact-location-#{friend.id}")

    # The photo and the way into the conversation are not features; they are
    # the page.
    assert has_element?(view, "#simple-contact-#{friend.id}")
  end

  test "a switched-off control opens nothing even if its event arrives", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, _settings} = Admin.update_features(user, %{"simple_contact_location" => "false"})

    {:ok, view, _html} = live(conn, "/contacts/simple")

    render_click(view, "open_location_note", %{"id" => to_string(friend.id)})
    refute has_element?(view, "#simple-location-dialog")
  end

  test "asks which game to play and nudges them to the table", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, _settings} = Admin.update_instance_settings(user, %{"craps_enabled" => "true"})

    {:ok, view, _html} = live(conn, "/contacts/simple")
    view |> element("#simple-contact-game-#{friend.id}") |> render_click()

    assert has_element?(view, "#simple-game-dialog[role='dialog'][aria-modal='true']")
    assert has_element?(view, "#simple-game-dialog-title", "@#{friend.username}")
    assert has_element?(view, "#simple-game-craps", "Craps")

    Phoenix.PubSub.subscribe(Veejr.PubSub, "user:#{friend.id}")
    view |> element("#simple-game-craps") |> render_click()

    assert_receive {:craps_invite, _host}
    assert_redirect(view, "/craps")
  end

  test "asks whether a location note is about where you are now", %{conn: conn, friend: friend} do
    {:ok, view, _html} = live(conn, "/contacts/simple")

    view |> element("#simple-contact-location-#{friend.id}") |> render_click()

    assert has_element?(view, "#simple-location-dialog-title", "@#{friend.username}")

    assert has_element?(
             view,
             "#simple-location-dialog",
             "Is this note about where you are right now?"
           )

    assert has_element?(
             view,
             "#simple-location-elsewhere[href='/map?friend=#{friend.id}']",
             "somewhere else"
           )

    refute has_element?(view, "#simple-location-composer")

    view |> element("#simple-location-here") |> render_click()

    assert has_element?(
             view,
             "#simple-location-note[phx-hook='CurrentLocation'][data-composer-id='simple-location-composer']"
           )

    # Addressed to them and only them: the form carries the recipient rather
    # than asking again, and never offers the "also me" copy.
    assert has_element?(
             view,
             "#simple-location-composer[phx-hook='Composer'][data-kind='location']"
           )

    assert has_element?(
             view,
             "#simple-location-composer input[type='hidden'][name='friends[]'][value='#{friend.id}']"
           )

    refute has_element?(view, "#simple-location-composer input[name='self']")
  end

  test "sends the location note the browser sealed and closes the sheet", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, view, _html} = live(conn, "/contacts/simple")

    view |> element("#simple-contact-location-#{friend.id}") |> render_click()
    view |> element("#simple-location-here") |> render_click()

    html =
      render_hook(view, "send_batch", %{
        "kind" => "location",
        "envelopes" => [
          %{"recipient_id" => friend.id, "ciphertext" => "ciphertext", "nonce" => "nonce"}
        ]
      })

    assert html =~ "Sent — it will show on their map."
    refute has_element?(view, "#simple-location-dialog")

    user_id = user.id
    friend_id = friend.id

    assert [
             %Envelope{
               kind: "location",
               ciphertext: "ciphertext",
               sender_id: ^user_id,
               recipient_id: ^friend_id
             }
           ] = Repo.all(Envelope)
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
