defmodule VeejrWeb.MessagesLiveTest do
  use VeejrWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Messaging, Repo, Social}

  setup %{conn: conn} do
    user = user_fixture()

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        "public_key" => Base.encode64(String.pad_trailing("public-key", 32, "x")),
        "enc_secret_key" => Base.encode64(String.pad_trailing("wrapped-key", 48, "x")),
        "key_salt" => Base.encode64(String.pad_trailing("salt", 16, "x")),
        "key_nonce" => Base.encode64(String.pad_trailing("nonce", 24, "x"))
      })

    %{conn: log_in_user(conn, user), user: user}
  end

  test "offers direct invite and new-conversation actions", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "#back-to-contacts[href='/contacts']", "Back to contacts")
    assert has_element?(view, "#messages-invite-person[href='/invites/new']", "Invite person")
    assert has_element?(view, "#messages-conversation-builder", "New conversation")
    assert has_element?(view, "#messages-conversation-builder-form")
  end

  test "offers four persistent chat appearances and an arrival celebration", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(
             view,
             "#messages-workspace[phx-hook='ChatTheme'][data-chat-theme='classic']"
           )

    assert has_element?(view, "#chat-theme-picker[aria-label='Chat appearance']")
    assert has_element?(view, "#chat-theme-classic[data-chat-theme-option='classic']")
    assert has_element?(view, "#chat-theme-salon[data-chat-theme-option='salon']")
    assert has_element?(view, "#chat-theme-party[data-chat-theme-option='party']")
    assert has_element?(view, "#chat-theme-comic[data-chat-theme-option='comic']")

    assert has_element?(
             view,
             "#new-message-celebration[role='status'][aria-live='polite']",
             "New message!"
           )
  end

  test "puts pending message consent front and center with a busy quick reply", %{
    conn: conn,
    user: user
  } do
    friend = user_fixture()

    {:ok, friend} =
      Accounts.setup_user_keys(friend, %{
        "public_key" => Base.encode64(String.pad_trailing("friend-public-key", 32, "x")),
        "enc_secret_key" => Base.encode64(String.pad_trailing("friend-wrapped-key", 48, "x")),
        "key_salt" => Base.encode64(String.pad_trailing("friend-salt", 16, "x")),
        "key_nonce" => Base.encode64(String.pad_trailing("friend-nonce", 24, "x"))
      })

    {:ok, request} = Social.send_friend_request(friend, user.username)
    {:ok, _friendship} = Social.accept_friend_request(user, request.id)

    {:ok, _batch_id, []} =
      Messaging.send_batch(friend, "message", [
        %{"recipient_id" => user.id, "ciphertext" => "for-user", "nonce" => "user-nonce"},
        %{"recipient_id" => friend.id, "ciphertext" => "self-copy", "nonce" => "self-nonce"}
      ])

    [notification] = Messaging.list_pending_notifications(user)
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "#message-consent-dialog[role='dialog'][aria-modal='true']")
    assert has_element?(view, "#accept-message-#{notification.id}", "Accept")
    assert has_element?(view, "#reject-message-#{notification.id}", "Reject")

    assert has_element?(
             view,
             "#busy-later-message-#{notification.id}[data-role='busy-later']",
             "Busy now, laters"
           )

    render_hook(view, "busy_later", %{
      "id" => notification.id,
      "envelopes" => [
        %{"recipient_id" => friend.id, "ciphertext" => "reply", "nonce" => "reply-nonce"},
        %{"recipient_id" => user.id, "ciphertext" => "reply-self", "nonce" => "self-nonce"}
      ]
    })

    assert Messaging.list_pending_notifications(user) == []
    refute has_element?(view, "#message-consent-dialog")

    sent =
      Repo.all(
        from(e in Veejr.Messaging.Envelope,
          where: e.sender_id == ^user.id and e.kind == "message"
        )
      )

    assert Enum.sort(Enum.map(sent, & &1.recipient_id)) == Enum.sort([user.id, friend.id])
  end

  test "defaults the unselected composer to a self note", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "#message-composer[data-kind='self_note']")
    assert has_element?(view, "#message-composer input[type='hidden'][name='self']")
    assert has_element?(view, "#message-composer textarea[placeholder='Take a note…']")
    refute has_element?(view, "#message-composer [data-role='toggle-options']")
  end

  test "opens the notes board after the unselected composer saves", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, "/messages")

    render_hook(view, "send_batch", %{
      "kind" => "self_note",
      "envelopes" => [
        %{"recipient_id" => user.id, "ciphertext" => "ciphertext", "nonce" => "nonce"}
      ]
    })

    assert_patch(view, "/messages?self_notes=true")
    [note] = Messaging.list_self_note_envelopes(user)
    assert has_element?(view, "#self-note-#{note.public_id}")
  end

  test "shows the redesigned self-notes command center", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/messages?self_notes=true")

    assert has_element?(view, "#self-notes-command-center[aria-label='Create and find notes']")
    assert has_element?(view, "#self-notes-quick-create[data-role='new-note']")
    assert has_element?(view, "#self-notes-search[data-role='search']")
    assert has_element?(view, "#self-notes-date-filters")
  end

  test "loads every self note in one action", %{conn: conn, user: user} do
    for index <- 1..51 do
      assert {:ok, _batch_id, []} =
               Messaging.send_batch(user, "self_note", [
                 %{
                   "recipient_id" => user.id,
                   "ciphertext" => "encrypted-note-#{index}",
                   "nonce" => "nonce-#{index}"
                 }
               ])
    end

    oldest_note =
      user
      |> Messaging.list_self_note_envelopes(limit: :all)
      |> List.last()

    {:ok, view, _html} = live(conn, "/messages?self_notes=true")

    assert has_element?(view, "#self-notes-load-more")
    assert has_element?(view, "#self-notes-load-all[data-role='load-all-notes']")
    refute has_element?(view, "#self-note-#{oldest_note.public_id}")

    view
    |> element("#self-notes-load-all")
    |> render_click()

    assert has_element?(view, "#self-note-#{oldest_note.public_id}")
    refute has_element?(view, "#self-notes-load-more")
    refute has_element?(view, "#self-notes-load-all")
  end

  test "starts a multi-selected conversation from the Messages dropdown", %{
    conn: conn,
    user: user
  } do
    friend = user_fixture()
    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _friendship} = Social.accept_friend_request(friend, request.id)
    {:ok, group} = Social.create_group(user, %{name: "Weekend crew"})
    {:ok, _membership} = Social.add_group_member(user, group.id, friend.id)

    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(
             view,
             "#messages-conversation-builder-form input[name='selection[friend_ids][]'][value='#{friend.id}']"
           )

    assert has_element?(
             view,
             "#messages-conversation-builder-form input[name='selection[group_ids][]'][value='#{group.id}']"
           )

    view
    |> form("#messages-conversation-builder-form", %{
      "selection" => %{
        "friend_ids" => [to_string(friend.id)],
        "group_ids" => [to_string(group.id)]
      }
    })
    |> render_submit()

    assert_redirect(
      view,
      "/messages?friend_ids=#{friend.id}&group_ids=#{group.id}&include_self=false"
    )
  end

  test "offers encrypted voice and video recording controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(
             view,
             "#message-composer label.messages-composer-action[data-role='file-toggle'][aria-label='Attach files'] .hero-paper-clip"
           )

    assert has_element?(view, "#message-composer [data-role='audio-toggle']")

    assert has_element?(
             view,
             "#message-composer [data-role='video-toggle'][aria-pressed='false']"
           )

    assert has_element?(view, "#message-composer [data-role='video-facing-toggle']")
    assert has_element?(view, "#message-composer [data-role='video-status'][aria-live='polite']")
    assert has_element?(view, "#message-composer [data-role='video-preview']")
  end

  test "opens a new conversation with multiple recipients preselected", %{
    conn: conn,
    user: user
  } do
    friend = user_fixture()
    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _friendship} = Social.accept_friend_request(friend, request.id)

    {:ok, view, html} =
      live(conn, "/messages?friend_ids=#{friend.id}&group_ids=&include_self=false")

    assert html =~ "New conversation"
    assert html =~ "1 selected recipient"

    assert has_element?(
             view,
             "#message-composer input[type='hidden'][name='friends[]'][value='#{friend.id}']"
           )
  end

  test "shows a friend's image when starting a conversation", %{conn: conn, user: user} do
    friend = user_fixture()
    {:ok, friend} = Accounts.put_user_avatar(friend, jpeg())
    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _friendship} = Social.accept_friend_request(friend, request.id)

    {:ok, view, _html} = live(conn, "/messages?friend_id=#{friend.id}")

    assert has_element?(
             view,
             "#message-friend-avatar-#{friend.id} img[src='/avatars/#{friend.username}?v=1']"
           )

    assert has_element?(view, "main img[src='/avatars/#{friend.username}?v=1']")
  end

  test "opens a contact profile and saves notes from messages", %{conn: conn, user: user} do
    friend = user_fixture(%{display_name: "Profile Friend"})
    {:ok, friend} = Accounts.put_user_avatar(friend, jpeg())
    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _friendship} = Social.accept_friend_request(friend, request.id)
    {:ok, view, _html} = live(conn, "/messages?friend_id=#{friend.id}")

    view |> element("#selected-recipient-avatar") |> render_click()

    assert has_element?(view, "#profile-dialog", "Profile Friend")
    assert has_element?(view, "#profile-dialog img[src='/avatars/#{friend.username}?v=1']")

    view
    |> form("#profile-dialog form", %{
      "contact_id" => to_string(friend.id),
      "body" => "Follow up next Tuesday"
    })
    |> render_submit()

    assert Social.list_contact_notes(user)[friend.id] == "Follow up next Tuesday"
    assert has_element?(view, "#profile-note", "Follow up next Tuesday")
  end

  test "conversation rail avatar opens the profile instead of selecting the thread", %{
    conn: conn,
    user: user
  } do
    friend = user_fixture(%{display_name: "Rail Profile"})
    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _friendship} = Social.accept_friend_request(friend, request.id)

    {:ok, _batch_id, []} =
      Messaging.send_batch(user, "message", [
        %{"recipient_id" => friend.id, "ciphertext" => "friend", "nonce" => "nonce-1"},
        %{"recipient_id" => user.id, "ciphertext" => "self", "nonce" => "nonce-2"}
      ])

    key = Messaging.conversation_key([Social.Address.handle(friend)])
    {:ok, view, _html} = live(conn, "/messages")

    view |> element("#rail-conversation-avatar-#{key}") |> render_click()

    assert has_element?(view, "#profile-dialog", "Rail Profile")
    refute has_element?(view, "#thread-#{key}")

    view |> element("button[phx-click='close_profile']") |> render_click()
    view |> element("#conversation-#{key}") |> render_click()
    assert_patch(view, "/messages?conversation=#{key}")
    assert has_element?(view, "#thread-#{key}")
  end

  test "starts a call with the selected conversation as its return destination", %{
    conn: conn,
    user: user
  } do
    friend = user_fixture()
    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _friendship} = Social.accept_friend_request(friend, request.id)

    {:ok, _batch_id, []} =
      Messaging.send_batch(user, "message", [
        %{"recipient_id" => friend.id, "ciphertext" => "friend", "nonce" => "nonce-1"},
        %{"recipient_id" => user.id, "ciphertext" => "self", "nonce" => "nonce-2"}
      ])

    key = Messaging.conversation_key([Social.Address.handle(friend)])
    {:ok, view, _html} = live(conn, "/messages?conversation=#{key}")

    assert has_element?(
             view,
             "#schedule-call[href='/calls?friend_id=#{friend.id}']",
             "Schedule"
           )

    view |> element("#start-call") |> render_click()
    {call_path, _flash} = assert_redirect(view)
    call_uri = URI.parse(call_path)

    assert String.starts_with?(call_uri.path, "/call/")
    assert URI.decode_query(call_uri.query)["return_to"] == "/messages?conversation=#{key}"
  end

  test "starts with the newest 50 messages and loads older rows on demand", %{
    conn: conn,
    user: user
  } do
    friend = user_fixture()
    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _friendship} = Social.accept_friend_request(friend, request.id)

    copies =
      for index <- 1..55 do
        {:ok, batch_id, []} =
          Messaging.send_batch(user, "message", [
            %{
              "recipient_id" => friend.id,
              "ciphertext" => "friend-ciphertext-#{index}",
              "nonce" => "friend-nonce-#{index}"
            },
            %{
              "recipient_id" => user.id,
              "ciphertext" => "ciphertext-#{index}",
              "nonce" => "nonce-#{index}"
            }
          ])

        Repo.get_by!(Veejr.Messaging.Envelope,
          batch_id: batch_id,
          recipient_id: user.id
        )
      end

    oldest = hd(copies)
    newest = List.last(copies)
    key = Messaging.conversation_key([Social.Address.handle(friend)])

    {:ok, view, _html} = live(conn, "/messages?conversation=#{key}")

    assert has_element?(view, "#message-shell-#{newest.public_id}[data-message-mine='true']")

    assert has_element?(
             view,
             "#message-shell-#{newest.public_id} [data-role='salon-self-avatar']"
           )

    assert has_element?(
             view,
             "#message-shell-#{newest.public_id} [data-role='salon-self-author']"
           )

    refute has_element?(view, "#message-shell-#{oldest.public_id}")
    assert has_element?(view, "#load-more-messages")

    view
    |> element("#load-more-messages")
    |> render_click()

    assert has_element?(view, "#message-shell-#{oldest.public_id}")
  end

  test "starts with the newest 50 for the selected conversation", %{conn: conn, user: user} do
    selected_peer = user_fixture()
    {:ok, selected_request} = Social.send_friend_request(user, selected_peer.username)
    {:ok, _friendship} = Social.accept_friend_request(selected_peer, selected_request.id)

    other = user_fixture()
    {:ok, friendship} = Social.send_friend_request(other, user.username)
    {:ok, _friendship} = Social.accept_friend_request(user, friendship.id)

    self_copies =
      for index <- 1..55 do
        {:ok, batch_id, []} =
          Messaging.send_batch(user, "message", [
            %{
              "recipient_id" => selected_peer.id,
              "ciphertext" => "peer-ciphertext-#{index}",
              "nonce" => "peer-nonce-#{index}"
            },
            %{
              "recipient_id" => user.id,
              "ciphertext" => "self-ciphertext-#{index}",
              "nonce" => "self-nonce-#{index}"
            }
          ])

        Repo.get_by!(Veejr.Messaging.Envelope,
          batch_id: batch_id,
          recipient_id: user.id
        )
      end

    for index <- 1..60 do
      {:ok, _batch_id, []} =
        Messaging.send_batch(other, "message", [
          %{
            "recipient_id" => user.id,
            "ciphertext" => "other-ciphertext-#{index}",
            "nonce" => "other-nonce-#{index}"
          }
        ])
    end

    Repo.update_all(
      from(n in Veejr.Messaging.Notification, where: n.user_id == ^user.id),
      set: [state: "accepted"]
    )

    oldest = hd(self_copies)
    newest_visible = Enum.at(self_copies, 5)
    oldest_hidden = Enum.at(self_copies, 4)
    newest = List.last(self_copies)
    key = Messaging.conversation_key([Social.Address.handle(selected_peer)])

    {:ok, view, _html} = live(conn, "/messages?conversation=#{key}")

    assert has_element?(view, "#message-shell-#{newest.public_id}")
    assert has_element?(view, "#message-shell-#{newest_visible.public_id}")

    assert has_element?(
             view,
             "#message-meta-#{newest.public_id} time[data-role='message-timestamp'][datetime='#{DateTime.to_iso8601(newest.inserted_at)}']",
             Calendar.strftime(newest.inserted_at, "%b %d, %Y · %H:%M UTC")
           )

    refute has_element?(view, "#message-shell-#{oldest_hidden.public_id}")
    refute has_element?(view, "#message-shell-#{oldest.public_id}")
    assert has_element?(view, "#load-more-messages")
  end

  test "labels a restored conversation with its start date", %{conn: conn, user: user} do
    friend = user_fixture()
    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _friendship} = Social.accept_friend_request(friend, request.id)

    {:ok, batch_id, []} =
      Messaging.send_batch(user, "message", [
        %{"recipient_id" => friend.id, "ciphertext" => "friend", "nonce" => "friend-nonce"},
        %{"recipient_id" => user.id, "ciphertext" => "first", "nonce" => "nonce"}
      ])

    envelope =
      Repo.get_by!(Veejr.Messaging.Envelope,
        batch_id: batch_id,
        recipient_id: user.id
      )

    friend_handle = Social.Address.handle(friend)
    current_key = Messaging.conversation_key([friend_handle])

    assert {:ok, archive} = Messaging.archive_conversation(user, current_key)
    assert :ok = Messaging.unarchive_conversation(user, archive.conversation_key)

    {:ok, _view, html} = live(conn, "/messages?conversation=#{archive.conversation_key}")

    assert html =~
             "#{friend_handle} · #{Calendar.strftime(envelope.inserted_at, "%b %d, %Y")}"
  end

  defp jpeg do
    <<0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 512::16, 512::16, 0::size(12)-unit(8), 0xFF,
      0xD9>>
  end
end
