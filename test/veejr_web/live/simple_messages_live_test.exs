defmodule VeejrWeb.SimpleMessagesLiveTest do
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

    %{
      conn: log_in_user(conn, user),
      user: user,
      friend: friend,
      key: Messaging.conversation_key([Social.Address.handle(friend)])
    }
  end

  defp send_to_friend(user, friend) do
    {:ok, _batch_id, _queued} =
      Messaging.send_batch(user, "message", [
        %{"recipient_id" => friend.id, "ciphertext" => "for-friend", "nonce" => "nonce-1"},
        %{"recipient_id" => user.id, "ciphertext" => "my-copy", "nonce" => "nonce-2"}
      ])

    :ok
  end

  test "lists a conversation with the face of the person in it", %{
    conn: conn,
    user: user,
    friend: friend,
    key: key
  } do
    :ok = send_to_friend(user, friend)

    {:ok, view, _html} = live(conn, "/messages/simple")

    assert has_element?(
             view,
             "#simple-conversations #simple-conversation-#{key}[href='/messages/simple?conversation=#{key}']"
           )

    assert has_element?(view, "#simple-conversation-#{key}", "@#{friend.username}")

    assert has_element?(
             view,
             "#simple-preview-#{key}[phx-hook='ConversationPreview'][data-ciphertext='my-copy']"
           )

    refute has_element?(view, "#simple-messages-layout")
    refute has_element?(view, "#messages-page-header")
    refute has_element?(view, ".messages-rail")
  end

  test "opens a contact's thread and hands each message to the browser to decrypt", %{
    conn: conn,
    user: user,
    friend: friend,
    key: key
  } do
    :ok = send_to_friend(user, friend)
    envelope = Repo.get_by!(Envelope, recipient_id: user.id, thread_key: key)

    {:ok, view, _html} = live(conn, "/messages/simple?friend=#{friend.id}")

    assert has_element?(view, "#simple-thread-#{key}[phx-hook='ScrollBottom']")
    assert has_element?(view, "#message-shell-#{envelope.public_id}[data-message-mine='true']")

    assert has_element?(
             view,
             "#env-#{envelope.public_id}[phx-hook='Decrypt'][data-ciphertext='my-copy']"
           )

    assert has_element?(view, "#message-shell-#{envelope.public_id}", "You")

    assert has_element?(
             view,
             "#simple-message-composer[phx-hook='Composer'] input[name='friends[]'][value='#{friend.id}']"
           )

    assert has_element?(view, "#simple-back[href='/messages/simple']")
    refute has_element?(view, "#simple-message-composer [data-role='toggle-options']")
  end

  test "keeps every attachment type behind one closed paper clip", %{
    conn: conn,
    friend: friend
  } do
    {:ok, view, _html} = live(conn, "/messages/simple?friend=#{friend.id}")

    menu = "#simple-message-composer-attachments"
    assert has_element?(view, "details#{menu}:not([open]) > [data-role='attach-menu']")

    for role <- ~w(files audio-toggle video-toggle video-facing-toggle) do
      assert has_element?(view, "#{menu} [data-role='#{role}']")
    end

    # One control in the row, not five: the inline strip stays on the full page.
    refute has_element?(
             view,
             "#simple-message-composer > div > label[data-role='file-toggle']"
           )
  end

  test "opens an empty thread for a contact who has never written", %{
    conn: conn,
    friend: friend,
    key: key
  } do
    {:ok, view, _html} = live(conn, "/messages/simple?friend=#{friend.id}")

    assert has_element?(view, "#simple-thread-#{key}")
    assert has_element?(view, "#simple-thread-empty", "No messages yet")

    assert has_element?(
             view,
             "#simple-message-composer input[name='friends[]'][value='#{friend.id}']"
           )
  end

  test "accepts a waiting message without leaving the page", %{
    conn: conn,
    user: user,
    friend: friend,
    key: key
  } do
    {:ok, _batch_id, _queued} =
      Messaging.send_batch(friend, "message", [
        %{"recipient_id" => user.id, "ciphertext" => "from-friend", "nonce" => "nonce-3"}
      ])

    [notification] = Messaging.list_pending_notifications(user)

    {:ok, view, _html} = live(conn, "/messages/simple?friend=#{friend.id}")

    assert has_element?(view, "#simple-pending-#{notification.id}", "@#{friend.username}")
    refute has_element?(view, "#simple-thread-#{key} [phx-hook='Decrypt']")

    view |> element("#simple-accept-#{notification.id}") |> render_click()

    refute has_element?(view, "#simple-pending-#{notification.id}")
    envelope = Repo.get_by!(Envelope, recipient_id: user.id, thread_key: key)

    assert has_element?(
             view,
             "#env-#{envelope.public_id}[phx-hook='Decrypt'][data-ciphertext='from-friend']"
           )

    assert has_element?(view, "#message-shell-#{envelope.public_id}", "@#{friend.username}")
  end

  test "marks the open conversation read", %{conn: conn, user: user, friend: friend, key: key} do
    {:ok, _batch_id, _queued} =
      Messaging.send_batch(friend, "message", [
        %{"recipient_id" => user.id, "ciphertext" => "from-friend", "nonce" => "nonce-4"}
      ])

    [notification] = Messaging.list_pending_notifications(user)
    {:ok, _notification} = Messaging.accept_notification(user, notification.id)

    {:ok, _view, _html} = live(conn, "/messages/simple?conversation=#{key}")

    assert Repo.get_by!(Envelope, recipient_id: user.id, thread_key: key).read_at
  end
end
