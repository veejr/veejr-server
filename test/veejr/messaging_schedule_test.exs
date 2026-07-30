defmodule Veejr.MessagingScheduleTest do
  use Veejr.DataCase

  alias Veejr.{Accounts, Messaging, Repo, Social}
  alias Veejr.Messaging.{Envelope, Notification}
  import Veejr.AccountsFixtures

  describe "normalize_deliver_at/2" do
    test "accepts a future time and rejects one past the horizon" do
      now = ~U[2026-07-30 12:00:00Z]

      assert Messaging.normalize_deliver_at("2026-07-30T12:05:00Z", now) ==
               ~U[2026-07-30 12:05:00Z]

      assert Messaging.normalize_deliver_at(DateTime.add(now, 400, :day), now) == :invalid
    end

    test "treats a just-passed time as send now, but a stale one as a mistake" do
      now = ~U[2026-07-30 12:00:00Z]

      # Round-trip lag, not an error: send it immediately.
      assert Messaging.normalize_deliver_at(DateTime.add(now, -5, :second), now) == nil

      # A mistyped date should be visible, not silently sent.
      assert Messaging.normalize_deliver_at(DateTime.add(now, -1, :hour), now) == :invalid
      assert Messaging.normalize_deliver_at("not a time", now) == :invalid
    end
  end

  describe "scheduling a send" do
    test "stores ciphertext but releases nothing until it is due" do
      %{sender: sender, recipient: recipient} = pair()
      deliver_at = DateTime.add(DateTime.utc_now(:second), 3600)

      {:ok, _batch, []} = schedule(sender, recipient, deliver_at)

      # The recipient has nothing: no notification row means the envelope is
      # unreachable through every read path, not merely hidden from one list.
      assert Messaging.list_pending_notifications(recipient) == []
      assert Messaging.list_history(recipient) == []
      assert Repo.aggregate(Notification, :count) == 0

      envelope = Repo.get_by!(Envelope, recipient_id: recipient.id)
      assert {:error, :unauthorized} = Messaging.fetch_envelope(recipient, envelope.public_id)

      # The sender sees their own copy so the thread can show it as pending.
      assert [scheduled] = Messaging.list_scheduled_envelopes(sender)
      assert scheduled.deliver_at == deliver_at
    end

    test "releases to a local recipient once due and only once" do
      %{sender: sender, recipient: recipient} = pair()
      deliver_at = DateTime.add(DateTime.utc_now(:second), 60)

      {:ok, _batch, []} = schedule(sender, recipient, deliver_at)

      assert %{released: 0} = Messaging.dispatch_due_sends(DateTime.utc_now(:second))
      assert Messaging.list_pending_notifications(recipient) == []

      later = DateTime.add(deliver_at, 1)
      assert %{released: 2} = Messaging.dispatch_due_sends(later)

      assert [notification] = Messaging.list_pending_notifications(recipient)
      assert notification.envelope.ciphertext == "for-recipient"

      # A second sweep must not deliver it again.
      assert %{released: 0, refused: 0} = Messaging.dispatch_due_sends(later)
      assert length(Messaging.list_pending_notifications(recipient)) == 1
      assert Messaging.list_scheduled_envelopes(sender) == []
    end

    test "decides consent at release, not at compose" do
      %{sender: sender, recipient: recipient} = pair()
      deliver_at = DateTime.add(DateTime.utc_now(:second), 60)

      {:ok, _batch, []} = schedule(sender, recipient, deliver_at)

      # The conversation becomes active only after the message was written.
      Messaging.touch_conversation(recipient.id, sender.id)

      Messaging.dispatch_due_sends(DateTime.add(deliver_at, 1))

      # Auto-accepted because the window was open when it actually arrived.
      assert Messaging.list_pending_notifications(recipient) == []
      assert [envelope] = Messaging.list_history(recipient)
      assert envelope.ciphertext == "for-recipient"
    end

    test "refuses to deliver ciphertext sealed to a key the recipient rotated away from" do
      %{sender: sender, recipient: recipient} = pair()
      deliver_at = DateTime.add(DateTime.utc_now(:second), 60)

      {:ok, _batch, []} = schedule(sender, recipient, deliver_at)

      # Rotation cannot reseal a scheduled envelope — it has no accepted
      # notification, so list_resealable/1 never sees it. Delivering anyway
      # would produce a message that silently never opens.
      {:ok, _} = rotate_key(recipient)

      Messaging.subscribe(sender)
      assert %{released: 1, refused: 1} = Messaging.dispatch_due_sends(DateTime.add(deliver_at, 1))

      assert Messaging.list_pending_notifications(recipient) == []
      assert Messaging.list_history(recipient) == []

      envelope = Repo.get_by!(Envelope, recipient_id: recipient.id)
      assert envelope.release_error == "recipient_key_changed"
      assert envelope.released_at

      assert_receive {:veejr_schedule_failed, _public_id, "recipient_key_changed"}
    end

    test "the sender can cancel or reschedule before release" do
      %{sender: sender, recipient: recipient} = pair()
      deliver_at = DateTime.add(DateTime.utc_now(:second), 3600)

      {:ok, _batch, []} = schedule(sender, recipient, deliver_at)
      [scheduled] = Messaging.list_scheduled_envelopes(sender)

      later = DateTime.add(deliver_at, 7200)
      assert {:ok, 2} = Messaging.reschedule_batch(sender, scheduled.public_id, later)
      assert [%{deliver_at: ^later}] = Messaging.list_scheduled_envelopes(sender)

      assert {:ok, {:deleted, 2}} = Messaging.delete_envelope(sender, scheduled.public_id)
      assert Messaging.list_scheduled_envelopes(sender) == []
      assert Repo.aggregate(Envelope, :count) == 0
    end

    test "rejects a schedule on an owner-only kind" do
      user = user_with_keys("solo")

      assert {:error, :invalid_self_item} =
               Messaging.send_batch(
                 user,
                 "self_note",
                 [%{"recipient_id" => user.id, "ciphertext" => "ct", "nonce" => "n"}],
                 deliver_at: DateTime.add(DateTime.utc_now(:second), 60)
               )
    end

    test "rejects an unparseable schedule rather than sending immediately" do
      %{sender: sender, recipient: recipient} = pair()

      assert {:error, :invalid_deliver_at} =
               Messaging.send_batch(
                 sender,
                 "message",
                 [%{"recipient_id" => recipient.id, "ciphertext" => "ct", "nonce" => "n"}],
                 deliver_at: "yesterday"
               )

      assert Repo.aggregate(Envelope, :count) == 0
    end
  end

  describe "note reminders" do
    test "fires once, carries no note content, and can be re-armed" do
      user = user_with_keys("owner")

      {:ok, _batch, []} =
        Messaging.send_batch(user, "self_note", [
          %{"recipient_id" => user.id, "ciphertext" => "encrypted", "nonce" => "n"}
        ])

      [note] = Messaging.list_self_envelopes(user)
      remind_at = DateTime.add(DateTime.utc_now(:second), 60)

      assert {:ok, _} = Messaging.set_reminder(user, note.public_id, remind_at)
      assert %{reminded: 0} = Messaging.dispatch_due_note_reminders(DateTime.utc_now(:second))

      Messaging.subscribe(user)
      assert %{reminded: 1} = Messaging.dispatch_due_note_reminders(DateTime.add(remind_at, 1))
      assert_receive {:veejr_note_reminder, public_id}
      assert public_id == note.public_id

      # Once only.
      assert %{reminded: 0} = Messaging.dispatch_due_note_reminders(DateTime.add(remind_at, 2))

      # Setting a new time re-arms it.
      again = DateTime.add(DateTime.utc_now(:second), 120)
      assert {:ok, _} = Messaging.set_reminder(user, note.public_id, again)
      assert %{reminded: 1} = Messaging.dispatch_due_note_reminders(DateTime.add(again, 1))
    end

    test "clears with a nil time and refuses another user's item" do
      user = user_with_keys("owner")
      stranger = user_with_keys("stranger")

      {:ok, _batch, []} =
        Messaging.send_batch(user, "self_note", [
          %{"recipient_id" => user.id, "ciphertext" => "encrypted", "nonce" => "n"}
        ])

      [note] = Messaging.list_self_envelopes(user)

      {:ok, _} = Messaging.set_reminder(user, note.public_id, DateTime.add(DateTime.utc_now(), 60))
      assert {:ok, cleared} = Messaging.set_reminder(user, note.public_id, nil)
      assert is_nil(cleared.remind_at)

      assert {:error, :not_found} = Messaging.set_reminder(stranger, note.public_id, nil)
    end

    test "refuses to set a reminder on an ordinary message" do
      %{sender: sender, recipient: recipient} = pair()

      {:ok, _batch, []} =
        Messaging.send_batch(sender, "message", [
          %{"recipient_id" => recipient.id, "ciphertext" => "ct", "nonce" => "n"}
        ])

      envelope = Repo.get_by!(Envelope, recipient_id: recipient.id)
      assert {:error, :not_found} = Messaging.set_reminder(sender, envelope.public_id, nil)
    end
  end

  describe "self documents" do
    test "store and list alongside notes, and can be narrowed by kind" do
      user = user_with_keys("author")

      for {kind, ciphertext} <- [{"self_note", "note"}, {"self_doc", "sheet"}] do
        {:ok, _batch, []} =
          Messaging.send_batch(user, kind, [
            %{"recipient_id" => user.id, "ciphertext" => ciphertext, "nonce" => "n"}
          ])
      end

      assert length(Messaging.list_self_envelopes(user)) == 2
      assert Messaging.count_self_envelopes(user) == 2
      assert [%{kind: "self_doc"}] = Messaging.list_self_envelopes(user, kinds: ["self_doc"])
      assert Messaging.count_self_envelopes(user, kinds: ["self_note"]) == 1

      # No notification, no federation, exactly like a note.
      assert Messaging.list_pending_notifications(user) == []
    end

    test "a document is deletable through the owner-only path and a message is not" do
      %{sender: sender, recipient: recipient} = pair()

      {:ok, _batch, []} =
        Messaging.send_batch(sender, "self_doc", [
          %{"recipient_id" => sender.id, "ciphertext" => "doc", "nonce" => "n"}
        ])

      {:ok, _batch, []} =
        Messaging.send_batch(sender, "message", [
          %{"recipient_id" => recipient.id, "ciphertext" => "ct", "nonce" => "n"}
        ])

      [doc] = Messaging.list_self_envelopes(sender, kinds: ["self_doc"])
      message = Repo.get_by!(Envelope, recipient_id: recipient.id)

      assert {:error, :not_found} = Messaging.delete_self_item(sender, message.public_id)
      assert {:ok, {:deleted, 1}} = Messaging.delete_self_item(sender, doc.public_id)
      assert Messaging.list_self_envelopes(sender) == []
    end
  end

  defp pair do
    sender = user_with_keys("sender")
    recipient = user_with_keys("recipient")
    befriend(sender, recipient)
    %{sender: sender, recipient: recipient}
  end

  defp schedule(sender, recipient, deliver_at) do
    Messaging.send_batch(
      sender,
      "message",
      [
        %{"recipient_id" => sender.id, "ciphertext" => "self-copy", "nonce" => "n1"},
        %{"recipient_id" => recipient.id, "ciphertext" => "for-recipient", "nonce" => "n2"}
      ],
      deliver_at: deliver_at
    )
  end

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

  defp rotate_key(user) do
    user
    |> Ecto.Changeset.change(public_key: Base.encode64("rotated-" <> user.username))
    |> Repo.update()
  end

  defp befriend(a, b) do
    {:ok, request} = Social.send_friend_request(a, b.username)
    {:ok, _} = Social.accept_friend_request(b, request.id)
    :ok
  end
end
