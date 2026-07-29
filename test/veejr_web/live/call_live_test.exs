defmodule VeejrWeb.CallLiveTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Calls, Messaging, Social}

  setup %{conn: conn} do
    user = user_fixture()

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        "public_key" => Base.encode64(String.pad_trailing("public-key", 32, "x")),
        "enc_secret_key" => Base.encode64(String.pad_trailing("wrapped-key", 48, "x")),
        "key_salt" => Base.encode64(String.pad_trailing("salt", 16, "x")),
        "key_nonce" => Base.encode64(String.pad_trailing("nonce", 24, "x"))
      })

    friend = user_fixture()
    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _friendship} = Social.accept_friend_request(friend, request.id)

    %{conn: log_in_user(conn, user), user: user, friend: friend}
  end

  test "cancelling an outgoing invitation returns to the exact originating conversation", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, call} = Calls.start_call(user, friend.id)
    return_to = "/messages?conversation=restored-thread-key"
    call_path = "/call/#{call.public_id}?" <> URI.encode_query(%{"return_to" => return_to})

    {:ok, view, _html} = live(conn, call_path)

    assert has_element?(view, "#hang-up[data-call-exit]", "Cancel invitation")
    view |> element("#hang-up") |> render_click()

    assert_redirect(view, return_to)
    assert {:ok, %{state: "cancelled"}} = Calls.get_call(user, call.public_id)
  end

  test "an accepted call labels the control as End call", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, call} = Calls.start_call(user, friend.id)
    {:ok, _accepted} = Calls.join_call(friend, call.public_id)

    {:ok, view, _html} = live(conn, "/call/#{call.public_id}")

    assert has_element?(view, "#hang-up[data-call-exit]", "End call")
  end

  test "the callee can reject with the busy quick response", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, call} = Calls.start_call(friend, user.id)
    key = Messaging.conversation_key([Social.Address.handle(friend)])
    expected_path = "/messages?conversation=#{key}"

    assert {:error, {:live_redirect, %{to: ^expected_path}}} =
             live(conn, "/call/#{call.public_id}?busy=1")

    assert {:ok, %{state: "declined"}} = Calls.get_call(user, call.public_id)
  end

  test "renders local call quality feedback", %{conn: conn, user: user, friend: friend} do
    {:ok, call} = Calls.start_call(user, friend.id)

    {:ok, view, _html} = live(conn, "/call/#{call.public_id}")

    assert has_element?(view, "#call-quality[data-role='call-quality']")
    assert has_element?(view, "#call-network-adjustment[data-role='call-notice']")
    assert has_element?(view, "#call-duration[data-role='call-duration']")
    assert has_element?(view, "#call-peer-muted[data-role='peer-muted']")
    assert has_element?(view, "#call-peer-camera-off[data-role='peer-camera-off']")
  end

  test "renders remote video viewing controls", %{conn: conn, user: user, friend: friend} do
    {:ok, call} = Calls.start_call(user, friend.id)

    {:ok, view, _html} = live(conn, "/call/#{call.public_id}")

    assert has_element?(view, "#call-stage[data-role='call-stage']")
    assert has_element?(view, "#call-remote-video[data-role='remote-video']")
    assert has_element?(view, "#call-share-status[data-role='remote-share-status']")
    assert has_element?(view, "#call-fit[data-role='toggle-fit']")
    assert has_element?(view, "#call-pip[data-role='toggle-pip']")
    assert has_element?(view, "#call-popout[data-role='popout-share']")
    assert has_element?(view, "#call-fullscreen[data-role='toggle-fullscreen']")
  end

  test "renders peer-to-peer YouTube sharing controls", %{conn: conn, user: user, friend: friend} do
    {:ok, call} = Calls.start_call(user, friend.id)

    {:ok, view, _html} = live(conn, "/call/#{call.public_id}")

    assert has_element?(view, "#call-session[data-youtube-active='false']")
    assert has_element?(view, "#call-youtube[data-role='share-youtube'][disabled]")
    assert has_element?(view, "[data-role='call-youtube-stage']")
    assert has_element?(view, "#call-youtube-input[data-role='call-youtube-input']")
    assert has_element?(view, "[data-role='youtube-unlock']")
    assert has_element?(view, "[data-role='end-youtube']")
  end

  test "renders the peer-to-peer call chat and file drop target", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, call} = Calls.start_call(user, friend.id)

    {:ok, view, _html} = live(conn, "/call/#{call.public_id}")

    assert has_element?(view, "#call-chat-toggle[data-role='toggle-chat']")
    assert has_element?(view, "#call-chat-panel[data-role='chat-panel']")
    assert has_element?(view, "#call-chat-messages[aria-live='polite']")
    assert has_element?(view, "#call-chat-dropzone[data-role='chat-dropzone']")
    assert has_element?(view, "#call-chat-input[maxlength='4000']")
    assert has_element?(view, "#call-chat-files[type='file'][multiple]")
    assert has_element?(view, "#call-chat-send[disabled]")
  end

  test "renders the private device setup before joining", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, call} = Calls.start_call(user, friend.id)

    {:ok, view, _html} = live(conn, "/call/#{call.public_id}")

    assert has_element?(view, "#call-device-setup[data-role='device-setup']")
    assert has_element?(view, "#call-microphone[data-role='microphone-select']")
    assert has_element?(view, "#call-camera[data-role='camera-select']")
    assert has_element?(view, "#call-speaker[data-role='speaker-select']")
    assert has_element?(view, "#call-join[disabled]")
    assert has_element?(view, "#call-devices[data-role='open-devices']")
    assert has_element?(view, "#call-key-unlock[data-role='call-key-unlock']")

    assert has_element?(
             view,
             "#call-passphrase[type='password'][autocomplete='current-password']"
           )

    assert has_element?(view, "#call-unlock-submit[data-role='unlock-call']")
    assert has_element?(view, "#call-unlock-cancel[data-call-exit]")
  end

  test "an incoming call without an origin returns to the peer conversation", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, call} = Calls.start_call(friend, user.id)
    key = Messaging.conversation_key([Social.Address.handle(friend)])

    {:ok, view, _html} = live(conn, "/call/#{call.public_id}")

    refute_push_event view, "veejr:ring", %{call_id: _, from: _}
    assert {:ok, %{state: "accepted"}} = Calls.get_call(user, call.public_id)

    send(view.pid, {:call_ended, call.public_id, "ended"})

    assert_redirect(view, "/messages?conversation=#{key}")
  end

  test "the initiator can offer a fresh invitation after the callee disconnects", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, call} = Calls.start_call(user, friend.id)
    {:ok, _accepted} = Calls.join_call(friend, call.public_id)
    {:ok, view, _html} = live(conn, "/call/#{call.public_id}")

    assert has_element?(view, "#call-reinvite[data-role='call-reinvite']")
    assert has_element?(view, "#call-reinvite-submit[phx-click='reinvite']")

    send(view.pid, {:call_disconnected, call.public_id, friend.id})
    assert_push_event view, "call:peer_disconnected", %{}
  end

  test "does not accept an external return destination", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, call} = Calls.start_call(user, friend.id)
    key = Messaging.conversation_key([Social.Address.handle(friend)])
    query = URI.encode_query(%{"return_to" => "https://example.com/phishing"})

    {:ok, view, _html} = live(conn, "/call/#{call.public_id}?#{query}")

    view |> element("#hang-up") |> render_click()

    assert_redirect(view, "/messages?conversation=#{key}")
  end

  describe "three-way calls" do
    setup %{user: user} do
      other = user_fixture()
      {:ok, request} = Social.send_friend_request(user, other.username)
      {:ok, _friendship} = Social.accept_friend_request(other, request.id)
      %{other: other}
    end

    defp accepted_pair(caller, callee) do
      {:ok, call} = Calls.start_call(caller, callee.id)
      {:ok, call} = Calls.join_call(callee, call.public_id)
      call
    end

    test "the person who started the call can add another contact", %{
      conn: conn,
      user: user,
      friend: friend,
      other: other
    } do
      call = accepted_pair(user, friend)

      {:ok, view, _html} = live(conn, "/call/#{call.public_id}")

      assert has_element?(view, "#call-add-someone[phx-click='open_add_participant']")
      view |> element("#call-add-someone") |> render_click()

      invite = "#call-add-participant button[phx-value-id='#{other.id}']"
      assert has_element?(view, invite)
      # Whoever is already on the call is not offered again.
      refute has_element?(view, "#call-add-participant button[phx-value-id='#{friend.id}']")

      view |> element(invite) |> render_click()

      assert Calls.participant(call, other.id).state == "ringing"
      # The roster the hook meshes over now names both of them.
      assert_push_event view, "call:peers", %{peers: [_, _] = peers}
      assert Enum.sort(Enum.map(peers, & &1.id)) == Enum.sort([friend.id, other.id])
    end

    test "someone who did not start the call gets no add control", %{
      conn: conn,
      user: user,
      friend: friend
    } do
      {:ok, call} = Calls.start_call(friend, user.id)

      {:ok, view, _html} = live(conn, "/call/#{call.public_id}")

      refute has_element?(view, "#call-add-someone")
      refute has_element?(view, "#call-add-participant")
    end

    test "a full call offers nobody, whoever is left over", %{
      conn: conn,
      user: user,
      friend: friend,
      other: other
    } do
      spare = user_fixture()
      {:ok, request} = Social.send_friend_request(user, spare.username)
      {:ok, _friendship} = Social.accept_friend_request(spare, request.id)

      call = accepted_pair(user, friend)
      {:ok, _call} = Calls.add_participant(user, call.public_id, other.id)

      {:ok, view, _html} = live(conn, "/call/#{call.public_id}")
      view |> element("#call-add-someone") |> render_click()

      refute has_element?(view, "#call-add-participant button[phx-value-id='#{spare.id}']")
      assert has_element?(view, "#call-add-participant-title")
    end

    test "the page carries a roster for every other participant", %{
      conn: conn,
      user: user,
      friend: friend,
      other: other
    } do
      call = accepted_pair(user, friend)
      {:ok, _call} = Calls.add_participant(user, call.public_id, other.id)
      {:ok, _call} = Calls.join_call(other, call.public_id)

      {:ok, view, _html} = live(conn, "/call/#{call.public_id}")

      # One tile grid, and the first paint already knows who is in the call:
      # the hook's element is phx-update="ignore", so it reads this once.
      assert has_element?(view, "#call-remote-tiles[data-role='remote-tiles']")
      assert has_element?(view, "#call-session[data-local-id='#{user.id}']")
      assert has_element?(view, ~s|#call-session[data-peers*="#{friend.id}"]|)
      assert has_element?(view, ~s|#call-session[data-peers*="#{other.id}"]|)

      assert_push_event view, "call:peers", %{peers: [_, _] = peers}
      assert Enum.sort(Enum.map(peers, & &1.id)) == Enum.sort([friend.id, other.id])
    end

    test "one participant leaving keeps the call and names who to drop", %{
      conn: conn,
      user: user,
      friend: friend,
      other: other
    } do
      call = accepted_pair(user, friend)
      {:ok, _call} = Calls.add_participant(user, call.public_id, other.id)
      {:ok, _call} = Calls.join_call(other, call.public_id)

      {:ok, view, _html} = live(conn, "/call/#{call.public_id}")

      :ok = Calls.end_call(other, call.public_id)

      assert_push_event view, "call:peer_left", %{peer: departed}
      assert departed == other.id
      # The remaining mesh is a pair again, and the call did not end.
      assert_push_event view, "call:peers", %{peers: [%{id: remaining}]}
      assert remaining == friend.id
      refute_redirected(view, "/messages")
    end

    test "a third participant's own page authorises on membership alone", %{
      conn: conn,
      user: user,
      friend: friend,
      other: other
    } do
      # `friend` hosts, so `user` is neither caller nor first invitee.
      {:ok, request} = Social.send_friend_request(friend, other.username)
      {:ok, _friendship} = Social.accept_friend_request(other, request.id)
      call = accepted_pair(friend, other)
      {:ok, _call} = Calls.add_participant(friend, call.public_id, user.id)

      {:ok, view, _html} = live(conn, "/call/#{call.public_id}")

      refute call.caller_id == user.id
      refute call.callee_id == user.id
      assert has_element?(view, "#call-session")
      assert_push_event view, "call:peers", %{peers: [_, _] = peers}
      assert Enum.sort(Enum.map(peers, & &1.id)) == Enum.sort([friend.id, other.id])
    end
  end
end
