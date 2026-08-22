defmodule VeejrWeb.ContactsLiveTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Messaging, Repo, Social}
  alias Veejr.Messaging.Envelope

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

    {:ok, user} = Accounts.set_page_layout(user, "full")

    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _friendship} = Social.accept_friend_request(friend, request.id)
    {:ok, group} = Social.create_group(user, %{name: "Close friends"})
    {:ok, _membership} = Social.add_group_member(user, group.id, friend.id)

    %{conn: log_in_user(conn, user), user: user, friend: friend, group: group}
  end

  test "starts a new multi-selected conversation", %{conn: conn, friend: friend, group: group} do
    {:ok, view, _html} = live(conn, "/contacts")

    assert has_element?(view, "#conversation-builder")
    assert has_element?(view, "input[name='selection[friend_ids][]'][value='#{friend.id}']")
    assert has_element?(view, "input[name='selection[group_ids][]'][value='#{group.id}']")

    view
    |> form("#conversation-builder-form", %{
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

  test "defaults automatic message opening on and allows it to be disabled", %{
    conn: conn,
    friend: friend,
    group: group
  } do
    {:ok, view, _html} = live(conn, "/contacts")

    assert has_element?(view, "#auto-open-contact-#{friend.id}[aria-checked='true']")
    assert has_element?(view, "#auto-open-group-#{group.id}[aria-checked='true']")

    view
    |> element("#auto-open-contact-#{friend.id}")
    |> render_click()

    assert has_element?(view, "#auto-open-contact-#{friend.id}[aria-checked='false']")
  end

  test "starts secondary contact tools collapsed in full mode", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/contacts")

    assert has_element?(view, "details#contacts-tools:not([open])")

    assert has_element?(
             view,
             "header > #contacts-tools > #contacts-tools-toggle[aria-label='Contact tools'][title='Contact tools'] .hero-cog-6-tooth"
           )

    assert has_element?(
             view,
             "#contacts-tools-content",
             "Conversations, friends, and groups in one place."
           )

    assert has_element?(
             view,
             "#contacts-tools-content label.contacts-theme-control",
             "Appearance"
           )

    assert has_element?(view, "#contacts-tools-content #contacts-invite-person", "Invite person")
    assert has_element?(view, "#contacts-tools-content #conversation-builder", "New conversation")
  end

  test "links to a scannable invitation", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/contacts")

    assert has_element?(view, "a[href='/invites/new']", "Invite person")

    {:ok, invite_view, html} = live(conn, "/invites/new")
    assert html =~ "Invite someone"
    assert has_element?(invite_view, "img[alt='QR code for this invitation']")
    assert has_element?(invite_view, "#invite-url[value^='http']")
    assert has_element?(invite_view, "#invite-actions[data-url^='http']")
    assert has_element?(invite_view, "#invite-actions [data-role='copy-invite']", "Copy link")
    assert has_element?(invite_view, "#invite-actions [data-role='share-invite']", "Share invite")
  end

  test "puts primary destinations in the far-left navigation menu", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/contacts")

    assert has_element?(
             view,
             "header > details#primary-navigation-menu > summary#primary-navigation-trigger"
           )

    assert has_element?(view, "header > a[href='/']", "veejr")
    assert has_element?(view, "#primary-navigation-links a[href='/contacts']", "Contacts")
    assert has_element?(view, "#primary-navigation-links a[href='/messages']", "Messages")
    assert has_element?(view, "#primary-navigation-links a[href='/calls']", "Calls")
    assert has_element?(view, "#primary-navigation-links a[href='/map']", "Map")
    assert has_element?(view, "#primary-navigation-links a[href='/history']", "History")
    assert has_element?(view, "#primary-navigation-links a[href='/watch']", "Watch")
    assert has_element?(view, "#primary-navigation-themes", "Themes")
    assert has_element?(view, "#primary-navigation-links.app-menu-surface")

    assert has_element?(
             view,
             "#primary-navigation-links #theme-system.theme-choice[data-phx-theme='system'][aria-pressed='false']",
             "System"
           )

    assert has_element?(
             view,
             "#primary-navigation-links #theme-light[data-phx-theme='light']",
             "Light"
           )

    assert has_element?(
             view,
             "#primary-navigation-links #theme-dark[data-phx-theme='dark']",
             "Dark"
           )

    assert has_element?(
             view,
             "#primary-navigation-links #theme-artdeco[data-phx-theme='artdeco']",
             "Art Deco"
           )

    refute has_element?(view, "header > div #theme-choices")
    refute has_element?(view, "header > nav")
  end

  test "labels the contacts appearance control and keeps its dropdown themeable", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/contacts")

    assert has_element?(view, "label.contacts-theme-control", "Appearance")

    assert has_element?(
             view,
             "label.contacts-theme-control #contacts-theme-select.contacts-theme-select[data-contacts-theme-select]"
           )
  end

  test "shows a friend's uploaded image", %{conn: conn, friend: friend} do
    {:ok, _friend} = Accounts.put_user_avatar(friend, jpeg())
    {:ok, view, _html} = live(conn, "/contacts")

    assert has_element?(
             view,
             "#friend-avatar-#{friend.id} img[src='/avatars/#{friend.username}?v=1']"
           )
  end

  test "opens a friend's profile and edits private notes", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, _friend} = Accounts.put_user_avatar(friend, jpeg())
    {:ok, _note} = Social.upsert_contact_note(user, friend.id, "Met at the lake")
    {:ok, view, _html} = live(conn, "/contacts")

    view |> element("#friend-avatar-#{friend.id}") |> render_click()

    assert has_element?(view, "#profile-dialog")
    assert has_element?(view, "#profile-dialog img[src='/avatars/#{friend.username}?v=1']")
    assert has_element?(view, "#profile-note", "Met at the lake")

    view
    |> form("#profile-dialog form", %{
      "contact_id" => to_string(friend.id),
      "body" => "Prefers weekend calls"
    })
    |> render_submit()

    assert Social.list_contact_notes(user)[friend.id] == "Prefers weekend calls"
    assert has_element?(view, "#profile-note", "Prefers weekend calls")

    view |> element("button[phx-click='close_profile']") |> render_click()
    refute has_element?(view, "#profile-dialog")
  end

  test "shows and dismisses a joined invitation notice", %{conn: conn, user: user} do
    {:ok, invitation, token} = Accounts.create_invitation(user)
    {:ok, invited} = Accounts.register_user(valid_user_attributes(username: "new_joiner"), token)

    {:ok, view, html} = live(conn, "/contacts")
    assert html =~ "@new_joiner"
    assert has_element?(view, "#invitation-acceptances")

    view
    |> element(
      "button[phx-click='dismiss_invitation_acceptance'][phx-value-id='#{invitation.id}']"
    )
    |> render_click()

    refute has_element?(view, "#invitation-acceptances")
    assert Enum.any?(Social.list_friends(user), &(&1.id == invited.id))
  end

  test "opens an existing selected conversation", %{conn: conn, user: user, friend: friend} do
    {:ok, _batch_id, []} =
      Messaging.send_batch(user, "message", [
        %{"recipient_id" => friend.id, "ciphertext" => "friend", "nonce" => "nonce-1"},
        %{"recipient_id" => user.id, "ciphertext" => "self", "nonce" => "nonce-2"}
      ])

    key = Messaging.conversation_key([Social.Address.handle(friend)])
    {:ok, view, _html} = live(conn, "/contacts")

    assert has_element?(
             view,
             "input[name='selection[conversation_keys][]'][value='#{key}']"
           )

    assert has_element?(view, "#open-conversation-#{key} span.ml-auto", "Open")

    view |> element("#conversation-avatar-#{key}") |> render_click()
    assert has_element?(view, "#profile-dialog", friend.display_name || friend.username)

    view |> element("button[phx-click='close_profile']") |> render_click()
    refute has_element?(view, "#profile-dialog")

    view
    |> form("#conversation-builder-form", %{
      "selection" => %{"conversation_keys" => [key]}
    })
    |> render_submit()

    assert_redirect(view, "/messages?conversation=#{key}")
  end

  test "highlights unread conversations, previews the latest item, and hides Compose", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, _policy} =
      Messaging.put_delivery_policy(user, "contact", friend.id, %{
        "acceptance" => "ask",
        "notification" => "normal"
      })

    {:ok, _batch_id, []} =
      Messaging.send_batch(friend, "message", [
        %{"recipient_id" => user.id, "ciphertext" => "encrypted-preview", "nonce" => "nonce"}
      ])

    [notification] = Messaging.list_pending_notifications(user)
    assert {:ok, _notification} = Messaging.accept_notification(user, notification.id)

    key = Messaging.conversation_key([Social.Address.handle(friend)])
    assert [%{unread_count: 1}] = Messaging.list_conversation_summaries(user)
    {:ok, view, _html} = live(conn, "/contacts")

    assert has_element?(view, "li.conversation-unread[data-unread]")

    assert has_element?(
             view,
             "#conversation-preview-#{key}[phx-hook='ConversationPreview'][data-ciphertext='encrypted-preview']"
           )

    refute has_element?(view, "a", "Compose")

    {:ok, _messages_view, _html} = live(conn, "/messages?conversation=#{key}")

    envelope = Repo.get_by!(Envelope, recipient_id: user.id, thread_key: key)
    assert envelope.read_at
  end

  describe "section layout" do
    test "all contact sections start collapsed", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/contacts")

      refute has_element?(view, "details.contacts-section[open] h2", "Conversations")
      refute has_element?(view, "details.contacts-section[open] h2", "Friends")
      refute has_element?(view, "details.contacts-section[open] h2", "Groups")
      refute has_element?(view, "details.contacts-section[data-default-open]")
    end
  end

  describe "presence" do
    test "an offline friend gets an offline dot", %{conn: conn, friend: friend} do
      {:ok, view, _html} = live(conn, "/contacts")

      assert has_element?(view, "#friend-presence-#{friend.id}[data-presence='offline']")
    end

    test "a friend with veejr open reads as online", %{conn: conn, friend: friend} do
      open_page(friend)

      {:ok, view, _html} = live(conn, "/contacts")

      assert has_element?(view, "#friend-presence-#{friend.id}[data-presence='online']")
    end

    test "the dot follows a friend arriving, without a reload", %{conn: conn, friend: friend} do
      {:ok, view, _html} = live(conn, "/contacts")
      assert has_element?(view, "#friend-presence-#{friend.id}[data-presence='offline']")

      # The broadcast is issued before track/1 returns, so it is already in the
      # view's mailbox and render/1 processes it before replying.
      open_page(friend)

      assert has_element?(view, "#friend-presence-#{friend.id}[data-presence='online']")
    end

    test "a friend on another instance gets no dot until their server says so", %{
      conn: conn,
      user: user
    } do
      remote = remote_friend(user)

      {:ok, view, _html} = live(conn, "/contacts")

      # Unknown is not offline, and a dot that guesses is worse than none.
      refute has_element?(view, "#friend-presence-#{remote.id}")
      assert has_element?(view, "#friend-avatar-#{remote.id}")
    end

    test "a friend on another instance lights up when their server says so", %{
      conn: conn,
      user: user
    } do
      remote = remote_friend(user)
      {:ok, view, _html} = live(conn, "/contacts")

      {:ok, :accepted} =
        Veejr.Federation.handle_presence(
          %{
            "from" => %{"authority" => "other.example"},
            "users" => [%{"username" => "zoe", "state" => "online"}]
          },
          "other.example"
        )

      assert has_element?(view, "#friend-presence-#{remote.id}[data-presence='online']")
    end

    test "a friend who turned sharing off gets no dot", %{conn: conn, friend: friend} do
      open_page(friend)
      {:ok, _hidden} = Accounts.set_presence_sharing(friend, false)

      {:ok, view, _html} = live(conn, "/contacts")

      refute has_element?(view, "#friend-presence-#{friend.id}")
    end
  end

  # A stand-in for another person having veejr open in a browser somewhere.
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

  describe "page layout preference" do
    test "sends an account that chose the plain pages there before rendering", %{
      conn: conn,
      user: user
    } do
      {:ok, _user} = Accounts.set_page_layout(user, "simple")

      assert {:error, {_kind, %{to: "/contacts/simple"}}} = live(conn, "/contacts")
    end

    test "keeps the full tools collapsed and leaves mode selection in account settings", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/contacts")

      assert has_element?(view, "details#contacts-tools:not([open])")
      refute has_element?(view, "#contacts-layout")
      assert has_element?(view, "a[href='/account']")
    end
  end

  defp remote_friend(user) do
    {:ok, remote} =
      %Veejr.Accounts.User{}
      |> Ecto.Changeset.change(
        email: "remote+zoe@other.example.invalid",
        username: "zoe",
        host: "other.example",
        public_key: Base.encode64(String.pad_trailing("remote-key", 32, "x"))
      )
      |> Repo.insert()

    {:ok, _friendship} =
      %Social.Friendship{}
      |> Ecto.Changeset.change(
        requester_id: user.id,
        addressee_id: remote.id,
        status: "accepted"
      )
      |> Repo.insert()

    remote
  end

  defp jpeg do
    <<0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 512::16, 512::16, 0::size(12)-unit(8), 0xFF,
      0xD9>>
  end
end
