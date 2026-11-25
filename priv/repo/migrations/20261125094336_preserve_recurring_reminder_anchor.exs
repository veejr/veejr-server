defmodule Veejr.Repo.Migrations.PreserveRecurringReminderAnchor do
  use Ecto.Migration

  def change do
    alter table(:envelopes) do
      add :reminder_anchor_at, :utc_datetime
    end

    execute "UPDATE envelopes SET reminder_anchor_at = remind_at", "SELECT 1"
  end
end
