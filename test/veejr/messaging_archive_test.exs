defmodule Veejr.MessagingArchiveTest do
  use Veejr.DataCase

  alias Veejr.Messaging
  alias Veejr.Messaging.Envelope
  import Veejr.AccountsFixtures

  test "archives and unarchives a conversation instance" do
    user = user_fixture()
    envelope = self_message(user, "first")
    key = Messaging.conversation_key(["notes to yourself"])
    assert envelope.thread_key == key

    assert {:ok, archive} = Messaging.archive_conversation(user, key)
    archive_key = archive.conversation_key
    assert archive_key != key
    assert archive_key =~ Calendar.strftime(envelope.inserted_at, "%Y%m%dT%H%M%S")

    # the member envelope moved under the instance key
    assert Repo.get!(Envelope, envelope.id).thread_key == archive_key

    assert [
             %{
               key: ^archive_key,
               participant_key: ^key,
               participants: ["notes to yourself"]
             }
           ] = Messaging.list_archived_conversations(user)

    assert :ok = Messaging.unarchive_conversation(user, archive_key)
    assert Messaging.list_archived_conversations(user) == []
  end

  test "archiving a conversation that does not exist is rejected" do
    user = user_fixture()

    assert {:error, :invalid_conversation} =
             Messaging.archive_conversation(user, "not-a-key")
  end

  test "unarchived history stays separate from a newer conversation" do
    user = user_fixture()

    first = self_message(user, "first")
    current_key = Messaging.conversation_key(["notes to yourself"])

    assert {:ok, archive} = Messaging.archive_conversation(user, current_key)
    archive_key = archive.conversation_key

    second = self_message(user, "second")

    # both instances exist side by side, each with its own single message
    summaries = Messaging.list_conversation_summaries(user)

    assert summaries |> Enum.map(&{&1.key, &1.message_count}) |> Enum.sort() ==
             Enum.sort([{archive_key, 1}, {current_key, 1}])

    assert %{archived: true} = Messaging.list_thread_archives(user)[archive_key]

    assert :ok = Messaging.unarchive_conversation(user, archive_key)
    assert %{archived: false} = Messaging.list_thread_archives(user)[archive_key]

    assert Enum.map(Messaging.list_thread_envelopes(user, archive_key), & &1.public_id) ==
             [first.public_id]

    assert Enum.map(Messaging.list_thread_envelopes(user, current_key), & &1.public_id) ==
             [second.public_id]
  end

  test "locations and notes are first-class conversation items" do
    user = user_fixture()
    message = self_envelope(user, "message", "hello")
    note = self_envelope(user, "note", "geo-ciphertext")
    location = self_envelope(user, "location", "loc-ciphertext")
    key = Messaging.conversation_key(["notes to yourself"])

    assert [%{key: ^key, message_count: 3}] = Messaging.list_conversation_summaries(user)

    assert Enum.map(Messaging.list_thread_envelopes(user, key), & &1.kind) ==
             ["message", "note", "location"]

    # archiving carries the whole thread, not just the messages
    assert {:ok, archive} = Messaging.archive_conversation(user, key)

    for envelope <- [message, note, location] do
      assert Repo.get!(Envelope, envelope.id).thread_key == archive.conversation_key
    end
  end

  test "thread envelopes page from the newest side" do
    user = user_fixture()
    envelopes = for index <- 1..5, do: self_message(user, "message-#{index}")
    key = Messaging.conversation_key(["notes to yourself"])

    page = Messaging.list_thread_envelopes(user, key, limit: 2)

    assert Enum.map(page, & &1.public_id) ==
             envelopes |> Enum.take(-2) |> Enum.map(& &1.public_id)
  end

  test "bulk read and archive stay scoped to the owner" do
    user = user_fixture()
    other = user_fixture()
    {:ok, request} = Veejr.Social.send_friend_request(other, user.username)
    {:ok, _friendship} = Veejr.Social.accept_friend_request(user, request.id)

    {:ok, _policy} =
      Messaging.put_delivery_policy(user, "contact", other.id, %{"acceptance" => "ask"})

    {:ok, batch_id, []} =
      Messaging.send_batch(other, "message", [
        %{"recipient_id" => user.id, "ciphertext" => "incoming", "nonce" => "nonce"}
      ])

    [notification] = Messaging.list_pending_notifications(user)
    assert {:ok, _} = Messaging.accept_notification(user, notification.id)

    envelope = Veejr.Repo.get_by!(Envelope, batch_id: batch_id, recipient_id: user.id)
    key = envelope.thread_key

    assert {:ok, 1} = Messaging.mark_conversations_read(user, [key])
    assert Veejr.Repo.get!(Envelope, envelope.id).read_at

    assert {:ok, [archive]} = Messaging.archive_conversations(user, [key])
    assert archive.archived
    assert Messaging.list_conversation_summaries(other) == []
  end

  defp self_message(user, ciphertext), do: self_envelope(user, "message", ciphertext)

  defp self_envelope(user, kind, ciphertext) do
    {:ok, batch_id, []} =
      Messaging.send_batch(user, kind, [
        %{"recipient_id" => user.id, "ciphertext" => ciphertext, "nonce" => "nonce"}
      ])

    Veejr.Repo.get_by!(Envelope, batch_id: batch_id, recipient_id: user.id)
  end
end
