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

  test "opens the full page header and its tools for immediate access", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(
             view,
             "details#messages-page-header[aria-label='Messages header'][open]"
           )

    assert has_element?(view, "#messages-page-header-toggle", "Messages")
    assert has_element?(view, "#messages-page-header-toggle", "Collapse")
    refute has_element?(view, "#messages-layout")

    assert has_element?(
             view,
             "#messages-page-header-content #back-to-contacts[href='/contacts']",
             "Back to contacts"
           )

    assert has_element?(
             view,
             "#messages-page-header-content details#messages-tools[aria-label='Message tools'][open]"
           )

    assert has_element?(
             view,
             "#messages-tools > #messages-tools-toggle[aria-label='Message tools'][title='Message tools'] .hero-cog-6-tooth"
           )

    assert has_element?(
             view,
             "#inline-key-unlock[phx-hook='InlineKeyUnlock'] #inline-key-passphrase[type='password']"
           )

    assert has_element?(
             view,
             "#messages-tools-content #messages-invite-person[href='/invites/new']",
             "Invite person"
           )

    assert has_element?(
             view,
             "#messages-tools-content #messages-conversation-builder",
             "New conversation"
           )

    assert has_element?(view, "#messages-tools-content #messages-conversation-builder-form")
    refute has_element?(view, "#messages-page-header-content #self-notes-command-center")
  end

  test "spends the layout's vertical padding on the thread instead", %{conn: conn} do
    {:ok, messages, _html} = live(conn, "/messages")

    # The workspace is sized to the viewport rather than scrolling with the
    # page, so the layout's `py-10` would come straight out of the thread.
    refute has_element?(messages, "main.py-10")
    assert has_element?(messages, "main.flex-1 #messages-workspace")

    # Notes to yourself is the same workspace with the notes pane swapped in,
    # so it gets the height back too.
    {:ok, notes, _html} = live(conn, "/messages?self_notes=true")
    refute has_element?(notes, "main.py-10")
    assert has_element?(notes, "main.flex-1 #self-notes-pane-header")

    # Pages that do scroll keep it.
    {:ok, contacts, _html} = live(conn, "/contacts")
    assert has_element?(contacts, "main.py-10")
  end

  test "offers four persistent chat appearances and an arrival celebration", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(
             view,
             "#messages-workspace[phx-hook='ChatTheme'][data-chat-theme='classic']"
           )

    assert has_element?(
             view,
             "#messages-appearance-tool #chat-theme-picker[aria-label='Chat appearance'] .chat-theme-picker-label",
             "Style"
           )

    assert has_element?(
             view,
             "#chat-theme-classic[data-chat-theme-option='classic'] .chat-theme-swatch"
           )

    assert has_element?(view, "#chat-theme-salon[data-chat-theme-option='salon']", "Salon")
    assert has_element?(view, "#chat-theme-party[data-chat-theme-option='party']", "Party")
    assert has_element?(view, "#chat-theme-comic[data-chat-theme-option='comic']", "Comic")

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

    assert has_element?(view, "#messages-workspace.flex.h-full.min-h-0.flex-col")
    assert has_element?(view, "#messages-workspace > .messages-layout.flex.min-h-0.flex-1")
    assert has_element?(view, ".messages-composer-dock.sticky.bottom-0")
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
    [note] = Messaging.list_self_envelopes(user)
    assert has_element?(view, "#self-note-#{note.public_id}")
  end

  test "uses the notes title and moves search into the notes pane header", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/messages?self_notes=true")

    assert has_element?(view, "#messages-page-header-toggle", "Notes to yourself")

    assert has_element?(
             view,
             "details#messages-page-header[aria-label='Messages header']:not([open])"
           )

    assert has_element?(
             view,
             "#self-notes-pane-header > #self-notes-search-bar #self-notes-search[data-role='search'][aria-label='Search notes']"
           )

    refute has_element?(view, "#self-notes-board #self-notes-search-bar")

    assert has_element?(
             view,
             "#self-notes-sort[data-role='sort'][aria-label='Sort notes by'] option[value='updated'][selected]",
             "Last edited"
           )

    assert has_element?(
             view,
             "#self-notes-sort option[value='created']",
             "Creation date"
           )

    assert has_element?(view, "#self-notes-sort option[value='title']", "Title")

    assert has_element?(
             view,
             "#messages-page-header-content > details#self-notes-command-center[aria-label='Create and filter notes'][open]"
           )

    refute has_element?(view, "#self-notes-board #self-notes-command-center")
    assert has_element?(view, "#self-notes-command-center-toggle")
    assert has_element?(view, "#self-notes-quick-create[data-role='new-note']")
    assert has_element?(view, "#self-notes-date-filters")
    assert has_element?(view, "#self-notes-new-sheet[data-role='new-sheet']")
    assert has_element?(view, "#self-notes-new-page[data-role='new-page']")
  end

  test "creates a document on the notes board", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, "/messages")

    render_hook(view, "send_batch", %{
      "kind" => "self_doc",
      "envelopes" => [
        %{"recipient_id" => user.id, "ciphertext" => "encrypted-sheet", "nonce" => "nonce"}
      ]
    })

    assert_patch(view, "/messages?self_notes=true")
    [doc] = Messaging.list_self_envelopes(user, kinds: ["self_doc"])
    assert has_element?(view, "#self-note-content-#{doc.public_id}[data-kind='self_doc']")
  end

  test "sets and clears a reminder on a board item", %{conn: conn, user: user} do
    {:ok, _batch, []} =
      Messaging.send_batch(user, "self_note", [
        %{"recipient_id" => user.id, "ciphertext" => "encrypted", "nonce" => "nonce"}
      ])

    [note] = Messaging.list_self_envelopes(user)
    {:ok, view, _html} = live(conn, "/messages?self_notes=true")

    remind_at = DateTime.utc_now(:second) |> DateTime.add(3600) |> DateTime.to_iso8601()

    assert render_hook(view, "set_reminder", %{"id" => note.public_id, "remind_at" => remind_at}) =~
             "Reminder set."

    assert has_element?(view, "#self-note-#{note.public_id} [data-remind-at]")

    assert render_hook(view, "set_reminder", %{"id" => note.public_id, "remind_at" => nil}) =~
             "Reminder cleared."
  end

  test "refuses a reminder on someone else's item", %{conn: conn, user: user} do
    stranger = user_fixture(%{username: "stranger"})

    {:ok, _batch, []} =
      Messaging.send_batch(stranger, "self_note", [
        %{"recipient_id" => stranger.id, "ciphertext" => "theirs", "nonce" => "nonce"}
      ])

    [theirs] = Messaging.list_self_envelopes(stranger)
    {:ok, view, _html} = live(conn, "/messages?self_notes=true")

    render_hook(view, "set_reminder", %{"id" => theirs.public_id, "remind_at" => nil})

    # Unchanged, and the caller learns nothing about what exists.
    assert Repo.get_by!(Veejr.Messaging.Envelope, public_id: theirs.public_id).recipient_id ==
             stranger.id

    assert Messaging.list_self_envelopes(user) == []
  end

  test "schedules a message and cancels it before release", %{conn: conn, user: user} do
    friend = user_fixture(%{username: "scheduled_friend"})
    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _} = Social.accept_friend_request(friend, request.id)

    {:ok, view, _html} = live(conn, "/messages")
    deliver_at = DateTime.utc_now(:second) |> DateTime.add(3600) |> DateTime.to_iso8601()

    assert render_hook(view, "send_batch", %{
             "kind" => "message",
             "deliver_at" => deliver_at,
             "envelopes" => [
               %{"recipient_id" => user.id, "ciphertext" => "self", "nonce" => "n1"},
               %{"recipient_id" => friend.id, "ciphertext" => "theirs", "nonce" => "n2"}
             ]
           }) =~ "Encrypted and scheduled."

    # Nothing released: the recipient has no notification to see.
    assert Messaging.list_pending_notifications(friend) == []
    assert [scheduled] = Messaging.list_scheduled_envelopes(user)

    render_hook(view, "cancel_scheduled", %{"id" => scheduled.public_id})
    assert Messaging.list_scheduled_envelopes(user) == []
  end

  test "rejects an unusable send time", %{conn: conn, user: user} do
    friend = user_fixture(%{username: "bad_time_friend"})
    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _} = Social.accept_friend_request(friend, request.id)

    {:ok, view, _html} = live(conn, "/messages")

    render_hook(view, "send_batch", %{
      "kind" => "message",
      "deliver_at" => "whenever",
      "envelopes" => [
        %{"recipient_id" => friend.id, "ciphertext" => "theirs", "nonce" => "n"}
      ]
    })

    assert Messaging.list_scheduled_envelopes(user) == []
    assert Messaging.list_history(friend) == []
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
      |> Messaging.list_self_envelopes(limit: :all)
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
    assert has_element?(view, "#message-composer [data-role='recording-stage'].hidden")
    assert has_element?(view, "#message-composer [data-role='recording-pause']", "Pause")
    assert has_element?(view, "#message-composer [data-role='recording-stop']", "Stop")

    assert has_element?(
             view,
             "#message-composer [data-role='video-toggle'][aria-pressed='false']"
           )

    assert has_element?(view, "#message-composer [data-role='video-facing-toggle']")
    assert has_element?(view, "#message-composer [data-role='video-status'][aria-live='polite']")
    assert has_element?(view, "#message-composer [data-role='video-preview']")
    assert has_element?(view, "#connection-status[role='status'][aria-live='polite']")
  end

  test "offers pasted and dropped attachments", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/messages")

    # Attachments were invisible until send; the strip is what makes a paste
    # visible at all, since the file input is sr-only behind the paper clip.
    assert has_element?(view, "#message-composer [data-role='file-preview'][aria-live='polite']")

    # The browser refuses an oversize file up front rather than after a 413,
    # which needs the instance's own limit.
    limit = Veejr.InstanceSettings.max_upload_bytes()
    assert has_element?(view, "#message-composer[data-max-upload-bytes='#{limit}']")

    # A drop is accepted across the whole conversation pane, not just the
    # composer row.
    assert has_element?(view, "[data-composer-dropzone][data-drop-label='Drop to attach']")
  end

  test "offers to unlock in place rather than losing a composed message", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "#message-composer [data-role='composer-unlock']")

    assert has_element?(
             view,
             "#message-composer [data-role='composer-passphrase'][type='password'][autocomplete='current-password']"
           )

    assert has_element?(view, "#message-composer [data-role='composer-unlock-submit']")
    assert has_element?(view, "#message-composer [data-role='composer-unlock-cancel']")

    assert has_element?(
             view,
             "#message-composer [data-role='composer-unlock-error'][role='alert']"
           )
  end

  test "carries the wrapped key so unlocking never needs a round trip", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, "/messages")

    # The passphrase is unwrapped in the browser; only this already-encrypted
    # material is served, exactly as the keys and call pages do it.
    assert has_element?(view, "#message-composer[data-enc-secret-key='#{user.enc_secret_key}']")
    assert has_element?(view, "#message-composer[data-key-salt='#{user.key_salt}']")
    assert has_element?(view, "#message-composer[data-key-nonce='#{user.key_nonce}']")
  end

  test "renders encrypted draft, reply, expiry, and bulk-action affordances", %{
    conn: conn,
    user: user
  } do
    friend = user_fixture()
    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _friendship} = Social.accept_friend_request(friend, request.id)

    {:ok, batch_id, []} =
      Messaging.send_batch(user, "message", [
        %{"recipient_id" => friend.id, "ciphertext" => "friend", "nonce" => "nonce-1"},
        %{"recipient_id" => user.id, "ciphertext" => "self", "nonce" => "nonce-2"}
      ])

    envelope =
      Repo.get_by!(Veejr.Messaging.Envelope, batch_id: batch_id, recipient_id: user.id)

    key = envelope.thread_key
    {:ok, view, _html} = live(conn, "/messages?conversation=#{key}")

    assert has_element?(view, "#message-composer[data-draft-key='#{key}']")
    assert has_element?(view, "#message-composer textarea[placeholder='what say you?']")
    assert has_element?(view, "#message-composer [data-role='draft-status'][aria-live='polite']")
    assert has_element?(view, "#message-composer [data-role='reply-preview']")
    assert has_element?(view, "#message-composer [data-role='expiry-summary']")
    assert has_element?(view, "#message-shell-#{envelope.public_id} [data-role='reply-message']")
    assert has_element?(view, "#conversation-bulk-actions", "0 selected")

    view
    |> element("#select-conversation-#{key}")
    |> render_click()

    assert has_element?(view, "#conversation-bulk-actions", "1 selected")
    assert has_element?(view, "#bulk-mark-conversations-read:not([disabled])")
    assert has_element?(view, "#bulk-archive-conversations:not([disabled])")
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

  describe "presence" do
    setup %{user: user} do
      friend = user_fixture(%{display_name: "Dot Friend"})
      {:ok, request} = Social.send_friend_request(user, friend.username)
      {:ok, _friendship} = Social.accept_friend_request(friend, request.id)

      %{friend: friend}
    end

    test "the rail marks a friend who is offline", %{conn: conn, friend: friend} do
      {:ok, view, _html} = live(conn, "/messages")

      assert has_element?(view, "#start-friend-presence-#{friend.id}[data-presence='offline']")
    end

    test "the rail follows a friend arriving", %{conn: conn, friend: friend} do
      {:ok, view, _html} = live(conn, "/messages")
      assert has_element?(view, "#start-friend-presence-#{friend.id}[data-presence='offline']")

      open_page(friend)

      assert has_element?(view, "#start-friend-presence-#{friend.id}[data-presence='online']")
    end

    test "an open thread names the state in words", %{conn: conn, user: user, friend: friend} do
      {:ok, _batch_id, []} =
        Messaging.send_batch(user, "message", [
          %{"recipient_id" => friend.id, "ciphertext" => "hi", "nonce" => "nonce-1"},
          %{"recipient_id" => user.id, "ciphertext" => "hi", "nonce" => "nonce-2"}
        ])

      key = Messaging.conversation_key([Social.Address.handle(friend)])
      open_page(friend)

      {:ok, view, _html} = live(conn, "/messages?conversation=#{key}")

      assert has_element?(view, "#thread-peer-presence[data-presence='online']")
      assert render(view) =~ "Online"
    end

    test "a quiet thread shows the dot but does not nag", %{
      conn: conn,
      user: user,
      friend: friend
    } do
      {:ok, _batch_id, []} =
        Messaging.send_batch(user, "message", [
          %{"recipient_id" => friend.id, "ciphertext" => "hi", "nonce" => "nonce-1"},
          %{"recipient_id" => user.id, "ciphertext" => "hi", "nonce" => "nonce-2"}
        ])

      key = Messaging.conversation_key([Social.Address.handle(friend)])

      {:ok, view, _html} = live(conn, "/messages?conversation=#{key}")

      assert has_element?(view, "#thread-peer-presence[data-presence='offline']")
      refute render(view) =~ "· Offline"
    end
  end

  # A stand-in for the friend having veejr open in a browser somewhere.
  describe "page layout preference" do
    setup %{user: user} do
      {:ok, user} = Accounts.set_page_layout(user, "simple")
      %{user: user}
    end

    test "sends the plain entry points to the plain page", %{conn: conn} do
      assert {:error, {_kind, %{to: "/messages/simple"}}} = live(conn, "/messages")

      assert {:error, {_kind, %{to: "/messages/simple?conversation=abc"}}} =
               live(conn, "/messages?conversation=abc")

      assert {:error, {_kind, %{to: "/messages/simple?friend=9"}}} =
               live(conn, "/messages?friend_id=9")
    end

    test "keeps deep links the plain page cannot serve", %{conn: conn} do
      {:ok, notes, _html} = live(conn, "/messages?self_notes=true")
      assert has_element?(notes, "#self-notes-board")

      {:ok, group, _html} = live(conn, "/messages?group_id=1")
      assert has_element?(group, "#messages-workspace")
    end

    test "keeps the simple page focused without a recurring mode switch", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/messages/simple")

      refute has_element?(view, "#simple-messages-layout")
      refute has_element?(view, "#messages-page-header")
    end
  end

  defp open_page(user) do
    test = self()

    pid =
      spawn(fn ->
        Veejr.Presence.track(user)
        send(test, :tracked)
        Process.sleep(:infinity)
      end)

    assert_receive :tracked
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp jpeg do
    <<0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 512::16, 512::16, 0::size(12)-unit(8), 0xFF,
      0xD9>>
  end
end
