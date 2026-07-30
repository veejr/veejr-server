defmodule Veejr.Repo.Migrations.AddSchedulingToEnvelopes do
  use Ecto.Migration

  @moduledoc """
  Scheduled sends and self-note/self-document reminders.

  Both ride on the existing envelope rather than a side table: a scheduled
  message *is* an envelope, sealed in the browser at compose time, whose
  release the server merely withholds until `deliver_at`. Nothing about the
  ciphertext changes, so the server still cannot read a scheduled message —
  it only knows one exists and when it is due.

  `recipient_public_key` is the load-bearing one. Key rotation reseals a
  user's history through `Messaging.list_resealable/1`, which walks
  `list_history/2` — and that query requires an *accepted* notification. A
  scheduled envelope has none, so rotation cannot see it. Without a snapshot
  of the key the copy was sealed to, a recipient who rotates between compose
  and release would receive ciphertext that looks fine and never opens.
  Recording the key lets the release step detect that and fail loudly.

  Reminder times are necessarily server-visible: the server has to know when
  to fire. The reminder payload stays content-free — it names no note text,
  title, or label, only that something is due.
  """

  def change do
    alter table(:envelopes) do
      # Release time for a scheduled send. NULL for ordinary immediate sends.
      add :deliver_at, :utc_datetime
      # Set when the scheduler has acted on the row, successfully or not, so a
      # restart mid-sweep cannot deliver the same envelope twice.
      add :released_at, :utc_datetime
      # NULL on success; otherwise why release refused (e.g. key_changed).
      add :release_error, :string
      # The recipient key this copy was sealed to; see the moduledoc.
      add :recipient_public_key, :string
      # Reminder for an owner-only self note or document.
      add :remind_at, :utc_datetime
      add :reminded_at, :utc_datetime
    end

    # Partial indexes: the scheduler sweeps for due work every tick, and all
    # but a handful of rows have NULL here. Keeping the pending set out of the
    # index means the sweep stays proportional to outstanding work rather than
    # to history size.
    create index(:envelopes, [:deliver_at],
             where: "deliver_at IS NOT NULL AND released_at IS NULL",
             name: :envelopes_pending_release_index
           )

    create index(:envelopes, [:remind_at],
             where: "remind_at IS NOT NULL AND reminded_at IS NULL",
             name: :envelopes_pending_reminder_index
           )
  end
end
