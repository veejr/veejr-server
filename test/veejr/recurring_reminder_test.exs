defmodule Veejr.RecurringReminderTest do
  use Veejr.DataCase
  import Veejr.AccountsFixtures
  alias Veejr.{Messaging, Repo}

  test "snooze postpones one occurrence and done advances the original schedule" do
    user = user_fixture()
    scope = Veejr.Accounts.Scope.for_user(user)

    {:ok, _, _} =
      Messaging.send_batch(user, "self_note", [
        %{"recipient_id" => user.id, "ciphertext" => "encrypted", "nonce" => "nonce"}
      ])

    [note] = Messaging.list_self_envelopes(user)
    original = DateTime.add(DateTime.utc_now(:second), 3600)
    {:ok, _} = Messaging.set_reminder(user, note.public_id, original, "daily")
    {:ok, snoozed} = Messaging.reminder_action(scope, note.public_id, "snooze")
    assert snoozed.remind_at == DateTime.add(original, 600)
    assert %{reminded: 1} = Messaging.dispatch_due_note_reminders(snoozed.remind_at)
    recurring = Repo.reload!(snoozed)
    assert recurring.remind_at == DateTime.add(original, 86_400)
    assert %{reminded: 0} = Messaging.dispatch_due_note_reminders(snoozed.remind_at)
    {:ok, done} = Messaging.reminder_action(scope, note.public_id, "done")
    assert done.remind_at == DateTime.add(original, 2 * 86_400)
  end
end
