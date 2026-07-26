defmodule Veejr.Repo.Migrations.AddEmailReminderToScheduledCalls do
  use Ecto.Migration

  def change do
    alter table(:scheduled_calls) do
      add :organizer_email_reminded_at, :utc_datetime
      add :invitee_email_reminded_at, :utc_datetime
    end

    create index(:scheduled_calls, [:status, :organizer_email_reminded_at, :scheduled_for])
    create index(:scheduled_calls, [:status, :invitee_email_reminded_at, :scheduled_for])
  end
end
