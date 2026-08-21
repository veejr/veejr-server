defmodule Veejr.MessagingSendTest do
  use Veejr.DataCase

  alias Veejr.{Messaging, Repo, Social}
  alias Veejr.Messaging.BlobReference
  import Veejr.AccountsFixtures

  test "rejects duplicate copies for the same recipient" do
    user = user_fixture()

    envelopes = [
      %{"recipient_id" => to_string(user.id), "ciphertext" => "first", "nonce" => "nonce-1"},
      %{"recipient_id" => user.id, "ciphertext" => "second", "nonce" => "nonce-2"}
    ]

    assert {:error, :duplicate_recipients} =
             Messaging.send_batch(user, "message", envelopes)

    assert Messaging.list_history(user) == []
  end

  test "stores a self note as one owner-only envelope" do
    user = user_fixture()

    assert {:ok, _batch_id, []} =
             Messaging.send_batch(user, "self_note", [
               %{"recipient_id" => user.id, "ciphertext" => "encrypted note", "nonce" => "nonce"}
             ])

    [note] = Messaging.list_self_envelopes(user)
    assert note.kind == "self_note"
    assert note.sender_id == user.id
    assert note.recipient_id == user.id
    assert Messaging.list_pending_notifications(user) == []
  end

  test "retries a client batch without creating duplicate envelopes" do
    user = user_fixture()
    client_batch_id = "offline-retry-batch-1234567890"

    envelopes = [
      %{"recipient_id" => user.id, "ciphertext" => "encrypted", "nonce" => "nonce"}
    ]

    assert {:ok, ^client_batch_id, []} =
             Messaging.send_batch(user, "message", envelopes, client_batch_id: client_batch_id)

    assert {:ok, ^client_batch_id, []} =
             Messaging.send_batch(user, "message", envelopes, client_batch_id: client_batch_id)

    assert [%{batch_id: ^client_batch_id}] = Messaging.list_history(user)
  end

  test "bounds self-note loading while retaining the newest notes" do
    user = user_fixture()

    for index <- 1..55 do
      assert {:ok, _batch_id, []} =
               Messaging.send_batch(user, "self_note", [
                 %{
                   "recipient_id" => user.id,
                   "ciphertext" => "encrypted-note-#{index}",
                   "nonce" => "nonce-#{index}"
                 }
               ])
    end

    notes = Messaging.list_self_envelopes(user, limit: 50)

    assert length(notes) == 50
    assert hd(notes).ciphertext == "encrypted-note-55"
    refute Enum.any?(notes, &(&1.ciphertext == "encrypted-note-1"))

    all_notes = Messaging.list_self_envelopes(user, limit: :all)

    assert length(all_notes) == 55
    assert List.last(all_notes).ciphertext == "encrypted-note-1"
    assert Messaging.count_self_envelopes(user) == 55
  end

  test "rejects a self note with expiry or another recipient" do
    user = user_fixture()
    other = user_fixture()

    assert {:error, :invalid_self_item} =
             Messaging.send_batch(
               user,
               "self_note",
               [%{"recipient_id" => other.id, "ciphertext" => "ct", "nonce" => "nonce"}]
             )

    assert {:error, :invalid_self_item} =
             Messaging.send_batch(
               user,
               "self_note",
               [%{"recipient_id" => user.id, "ciphertext" => "ct", "nonce" => "nonce"}],
               expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
             )
  end

  test "self note deletion cannot delete a normal message" do
    user = user_fixture()

    assert {:ok, _, []} =
             Messaging.send_batch(user, "message", [
               %{"recipient_id" => user.id, "ciphertext" => "message", "nonce" => "nonce"}
             ])

    [message] = Messaging.list_history(user)
    assert {:error, :not_found} = Messaging.delete_self_item(user, message.public_id)
    assert Enum.any?(Messaging.list_history(user), &(&1.public_id == message.public_id))
  end

  test "legacy self-message listing excludes self notes" do
    user = user_fixture()

    for {kind, ciphertext} <- [{"message", "legacy"}, {"self_note", "note"}] do
      assert {:ok, _, []} =
               Messaging.send_batch(user, kind, [
                 %{
                   "recipient_id" => user.id,
                   "ciphertext" => ciphertext,
                   "nonce" => "nonce-#{kind}"
                 }
               ])
    end

    assert [%{kind: "message", ciphertext: "legacy"}] = Messaging.list_legacy_self_messages(user)
  end

  test "sender deletion frees a batch's tracked attachment" do
    user = user_fixture()
    {:ok, blob} = Messaging.create_blob(user, "encrypted-video")

    assert {:ok, batch_id, []} =
             Messaging.send_batch(
               user,
               "message",
               [%{"recipient_id" => user.id, "ciphertext" => "ct", "nonce" => "nonce"}],
               attachment_ids: [blob.public_id]
             )

    assert Repo.get_by!(BlobReference, blob_id: blob.id, batch_id: batch_id)
    assert File.exists?(blob.path)

    [envelope] = Messaging.list_history(user)
    assert {:ok, {:deleted, 1}} = Messaging.delete_envelope(user, envelope.public_id)
    refute Messaging.get_blob(blob.public_id)
    refute File.exists?(blob.path)
  end

  test "recipient hide retains the sender's attachment" do
    alice = user_fixture(%{username: "attachment_alice"})
    bob = user_fixture(%{username: "attachment_bob"})
    befriend(alice, bob)
    {:ok, blob} = Messaging.create_blob(alice, "encrypted-video")

    assert {:ok, _batch_id, []} =
             Messaging.send_batch(
               alice,
               "message",
               [
                 %{"recipient_id" => bob.id, "ciphertext" => "bob", "nonce" => "nonce"},
                 %{"recipient_id" => alice.id, "ciphertext" => "self", "nonce" => "nonce"}
               ],
               attachment_ids: [blob.public_id]
             )

    [notification] = Messaging.list_pending_notifications(bob)
    {:ok, _} = Messaging.accept_notification(bob, notification.id)
    [received] = Messaging.list_history(bob)
    assert {:ok, :hidden} = Messaging.delete_envelope(bob, received.public_id)
    assert Messaging.get_blob(blob.public_id)
    assert File.exists?(blob.path)
  end

  test "a reused attachment is freed only after its final batch is deleted" do
    user = user_fixture()
    {:ok, blob} = Messaging.create_blob(user, "shared-ciphertext")

    for ciphertext <- ["first", "second"] do
      assert {:ok, _batch_id, []} =
               Messaging.send_batch(
                 user,
                 "message",
                 [%{"recipient_id" => user.id, "ciphertext" => ciphertext, "nonce" => "nonce"}],
                 attachment_ids: [blob.public_id]
               )
    end

    [first, second] = Messaging.list_history(user) |> Enum.sort_by(& &1.inserted_at)
    assert {:ok, {:deleted, 1}} = Messaging.delete_envelope(user, first.public_id)
    assert Messaging.get_blob(blob.public_id)
    assert {:ok, {:deleted, 1}} = Messaging.delete_envelope(user, second.public_id)
    refute Messaging.get_blob(blob.public_id)
  end

  test "a sender cannot attach another user's blob" do
    owner = user_fixture()
    sender = user_fixture()
    {:ok, blob} = Messaging.create_blob(owner, "private-ciphertext")

    assert {:error, :invalid_attachments} =
             Messaging.send_batch(
               sender,
               "message",
               [%{"recipient_id" => sender.id, "ciphertext" => "ct", "nonce" => "nonce"}],
               attachment_ids: [blob.public_id]
             )

    assert Messaging.get_blob(blob.public_id)
    assert Messaging.list_history(sender) == []
  end

  test "stale unattached tracked uploads are purged without touching legacy blobs" do
    user = user_fixture()
    {:ok, abandoned} = Messaging.create_blob(user, "abandoned")
    {:ok, legacy} = Messaging.create_blob(user, "legacy")
    old = DateTime.add(DateTime.utc_now(:second), -25, :hour)

    abandoned |> Ecto.Changeset.change(inserted_at: old) |> Repo.update!()

    legacy
    |> Ecto.Changeset.change(inserted_at: old, reference_tracking: false)
    |> Repo.update!()

    assert %{files: 1, bytes: 9} = Messaging.purge_abandoned_blobs()
    refute Messaging.get_blob(abandoned.public_id)
    assert Messaging.get_blob(legacy.public_id)
    assert File.exists?(legacy.path)
  end

  defp befriend(a, b) do
    {:ok, request} = Social.send_friend_request(a, b.username)
    {:ok, _} = Social.accept_friend_request(b, request.id)
  end
end
