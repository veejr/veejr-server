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

  test "keeps secondary contact tools in a closed disclosure", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/contacts")

    assert has_element?(view, "details#contacts-tools:not([open])")
    assert has_element?(view, "#contacts-tools-toggle", "Contact tools")

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

  defp jpeg do
    <<0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 512::16, 512::16, 0::size(12)-unit(8), 0xFF,
      0xD9>>
  end
end
