defmodule Veejr.ConversationWindowTest do
  use Veejr.DataCase, async: false

  import Veejr.AccountsFixtures

  alias Veejr.Messaging.ConversationWindow
  alias Veejr.{Accounts, Messaging, Repo, Social}

  defp user_with_keys(username) do
    user = user_fixture(%{username: username})

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        "public_key" => Base.encode64("pub-" <> username),
        "enc_secret_key" => Base.encode64("wrapped-" <> username),
        "key_salt" => Base.encode64("salt"),
        "key_nonce" => Base.encode64("nonce")
      })

    user
  end

  defp befriend(a, b) do
    {:ok, fr} = Social.send_friend_request(a, b.username)
    {:ok, _} = Social.accept_friend_request(b, fr.id)
    :ok
  end

  defp send_msg(from, to, ct) do
    {:ok, _batch, []} =
      Messaging.send_batch(from, "message", [
        %{"recipient_id" => to.id, "ciphertext" => ct, "nonce" => "n"},
        %{"recipient_id" => from.id, "ciphertext" => ct <> "-self", "nonce" => "n"}
      ])
  end

  defp expire_window(user_id, peer_id) do
    Repo.get_by!(ConversationWindow, user_id: user_id, peer_id: peer_id)
    |> Ecto.Changeset.change(active_until: DateTime.add(DateTime.utc_now(:second), -1, :second))
    |> Repo.update!()
  end

  setup do
    alice = user_with_keys("alice")
    bob = user_with_keys("bob")
    befriend(alice, bob)

    {:ok, _policy} =
      Messaging.put_delivery_policy(bob, "contact", alice.id, %{
        "acceptance" => "ask",
        "notification" => "normal"
      })

    %{alice: alice, bob: bob}
  end

  test "the first message is a pending request, not auto-accepted", %{alice: alice, bob: bob} do
    send_msg(alice, bob, "hello")

    assert [notification] = Messaging.list_pending_notifications(bob)
    assert notification.state == "pending"
    # bob has not opened a window for alice yet
    refute Messaging.conversation_active?(bob.id, alice.id)
  end

  test "sender deletion removes every envelope copy in the sent batch", %{
    alice: alice,
    bob: bob
  } do
    {:ok, batch_id, []} =
      Messaging.send_batch(alice, "message", [
        %{"recipient_id" => bob.id, "ciphertext" => "ct-bob", "nonce" => "n"},
        %{"recipient_id" => alice.id, "ciphertext" => "ct-self", "nonce" => "n"}
      ])

    self_copy = Repo.get_by!(Veejr.Messaging.Envelope, batch_id: batch_id, recipient_id: alice.id)

    assert {:ok, {:deleted, 2}} = Messaging.delete_envelope(alice, self_copy.public_id)
    assert Repo.all(Veejr.Messaging.Envelope) == []
    assert Messaging.list_pending_notifications(bob) == []
  end

  test "recipient deletion hides an accepted message without deleting sender history", %{
    alice: alice,
    bob: bob
  } do
    send_msg(alice, bob, "hello")
    [notification] = Messaging.list_pending_notifications(bob)
    {:ok, _} = Messaging.accept_notification(bob, notification.id)

    [received] = Messaging.list_history(bob)
    assert {:ok, :hidden} = Messaging.delete_envelope(bob, received.public_id)

    assert Messaging.list_history(bob) == []
    assert [_self_copy] = Messaging.list_history(alice)
  end

  test "time limited messages disappear from pending and history after expiry", %{
    alice: alice,
    bob: bob
  } do
    expires_at = DateTime.add(DateTime.utc_now(:second), 60, :second)

    {:ok, batch_id, []} =
      Messaging.send_batch(
        alice,
        "message",
        [
          %{"recipient_id" => bob.id, "ciphertext" => "ct-bob", "nonce" => "n"},
          %{"recipient_id" => alice.id, "ciphertext" => "ct-self", "nonce" => "n"}
        ],
        expires_at: expires_at
      )

    assert [_notification] = Messaging.list_pending_notifications(bob)

    Veejr.Messaging.Envelope
    |> Repo.get_by!(batch_id: batch_id, recipient_id: bob.id)
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second))
    |> Repo.update!()

    assert Messaging.list_pending_notifications(bob) == []
  end

  test "time limits apply to the sender's self-copy", %{alice: alice, bob: bob} do
    expires_at = DateTime.add(DateTime.utc_now(:second), -1, :second)

    {:ok, batch_id, []} =
      Messaging.send_batch(
        alice,
        "message",
        [
          %{"recipient_id" => bob.id, "ciphertext" => "ct-bob", "nonce" => "n"},
          %{"recipient_id" => alice.id, "ciphertext" => "ct-self", "nonce" => "n"}
        ],
        expires_at: DateTime.add(DateTime.utc_now(:second), 60, :second)
      )

    Repo.get_by!(Veejr.Messaging.Envelope, batch_id: batch_id, recipient_id: alice.id)
    |> Ecto.Changeset.change(expires_at: expires_at)
    |> Repo.update!()

    assert Messaging.list_history(alice) == []
  end

  test "display limited messages are readable once, then hidden on the next history load", %{
    alice: alice,
    bob: bob
  } do
    send_msg(alice, bob, "hello")
    [notification] = Messaging.list_pending_notifications(bob)
    {:ok, _} = Messaging.accept_notification(bob, notification.id)
    [received] = Messaging.list_history(bob)

    received
    |> Ecto.Changeset.change(max_displays: 1)
    |> Repo.update!()

    assert {:ok, updated} = Messaging.record_display(bob, received.public_id)
    assert updated.display_count == 1
    assert updated.ciphertext == received.ciphertext
    assert Messaging.list_history(bob) == []
  end

  test "display limits apply to the sender's self-copy", %{alice: alice, bob: bob} do
    {:ok, batch_id, []} =
      Messaging.send_batch(
        alice,
        "message",
        [
          %{"recipient_id" => bob.id, "ciphertext" => "ct-bob", "nonce" => "n"},
          %{"recipient_id" => alice.id, "ciphertext" => "ct-self", "nonce" => "n"}
        ],
        max_displays: 1
      )

    self_copy =
      Repo.get_by!(Veejr.Messaging.Envelope, batch_id: batch_id, recipient_id: alice.id)

    assert {:ok, updated} = Messaging.record_display(alice, self_copy.public_id)
    assert updated.display_count == 1
    assert Messaging.list_history(alice) == []
  end

  test "sender can replace ciphertext for every copy in a sent batch", %{
    alice: alice,
    bob: bob
  } do
    {:ok, batch_id, []} =
      Messaging.send_batch(alice, "message", [
        %{"recipient_id" => bob.id, "ciphertext" => "ct-bob", "nonce" => "n"},
        %{"recipient_id" => alice.id, "ciphertext" => "ct-self", "nonce" => "n"}
      ])

    self_copy = Repo.get_by!(Veejr.Messaging.Envelope, batch_id: batch_id, recipient_id: alice.id)
    bob_copy = Repo.get_by!(Veejr.Messaging.Envelope, batch_id: batch_id, recipient_id: bob.id)

    assert {:ok, %{copies: copies}} = Messaging.editable_batch(alice, self_copy.public_id)

    assert Enum.map(copies, & &1.public_id) |> Enum.sort() ==
             [bob_copy.public_id, self_copy.public_id] |> Enum.sort()

    assert {:ok, 2} =
             Messaging.edit_sent_batch(alice, self_copy.public_id, [
               %{
                 "public_id" => self_copy.public_id,
                 "ciphertext" => "ct-self-2",
                 "nonce" => "n2"
               },
               %{"public_id" => bob_copy.public_id, "ciphertext" => "ct-bob-2", "nonce" => "n2"}
             ])

    assert Repo.reload!(self_copy).ciphertext == "ct-self-2"
    assert Repo.reload!(bob_copy).ciphertext == "ct-bob-2"
    assert Repo.reload!(self_copy).edited_at
  end

  test "malformed recipient ids return an error instead of raising", %{alice: alice} do
    assert {:error, :bad_recipient_id} =
             Messaging.send_batch(alice, "message", [
               %{"recipient_id" => "not-an-id", "ciphertext" => "ct", "nonce" => "n"}
             ])
  end

  test "accepting opens a window; the next message auto-shows without a request",
       %{alice: alice, bob: bob} do
    send_msg(alice, bob, "hello")
    [notification] = Messaging.list_pending_notifications(bob)
    {:ok, _} = Messaging.accept_notification(bob, notification.id)

    assert Messaging.conversation_active?(bob.id, alice.id)

    # alice sends again within the window
    send_msg(alice, bob, "still there?")

    # no new pending request — it landed straight in the chat
    assert Messaging.list_pending_notifications(bob) == []
    assert length(Messaging.list_history(bob)) == 2
  end

  test "sending re-ups the sender's own window so replies auto-accept",
       %{alice: alice, bob: bob} do
    # alice sends -> alice's window for bob opens (she's actively conversing)
    send_msg(alice, bob, "hi bob")
    assert Messaging.conversation_active?(alice.id, bob.id)

    # bob replies; because alice's window for bob is open, it auto-accepts on
    # alice's side with no pending request
    send_msg(bob, alice, "hi alice")
    assert Messaging.list_pending_notifications(alice) == []
    assert length(Messaging.list_history(alice)) == 2
  end

  test "receiving re-ups the window (rolling), keeping the conversation flowing",
       %{alice: alice, bob: bob} do
    send_msg(alice, bob, "1")
    [n] = Messaging.list_pending_notifications(bob)
    {:ok, _} = Messaging.accept_notification(bob, n.id)

    before = Repo.get_by!(ConversationWindow, user_id: bob.id, peer_id: alice.id).active_until

    # an auto-accepted receive should push active_until further out
    Process.sleep(1000)
    send_msg(alice, bob, "2")

    after_ = Repo.get_by!(ConversationWindow, user_id: bob.id, peer_id: alice.id).active_until
    assert DateTime.compare(after_, before) == :gt
    assert Messaging.list_pending_notifications(bob) == []
  end

  test "once the window lapses, the next message requires a fresh request",
       %{alice: alice, bob: bob} do
    send_msg(alice, bob, "1")
    [n] = Messaging.list_pending_notifications(bob)
    {:ok, _} = Messaging.accept_notification(bob, n.id)

    expire_window(bob.id, alice.id)
    refute Messaging.conversation_active?(bob.id, alice.id)

    send_msg(alice, bob, "2 (after a long gap)")

    assert [pending] = Messaging.list_pending_notifications(bob)
    assert pending.state == "pending"
  end
end
