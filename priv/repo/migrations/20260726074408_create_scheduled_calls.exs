defmodule Veejr.Repo.Migrations.CreateScheduledCalls do
  use Ecto.Migration

  def change do
    create table(:scheduled_calls) do
      add :public_id, :string, null: false
      add :organizer_id, references(:users, on_delete: :delete_all), null: false
      add :invitee_id, references(:users, on_delete: :delete_all), null: false
      add :scheduled_for, :utc_datetime, null: false
      add :reminder_minutes, :integer, null: false, default: 15
      add :note, :string
      add :status, :string, null: false, default: "scheduled"
      add :reminded_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:scheduled_calls, [:public_id])
    create index(:scheduled_calls, [:organizer_id, :status, :scheduled_for])
    create index(:scheduled_calls, [:invitee_id, :status, :scheduled_for])
    create index(:scheduled_calls, [:status, :reminded_at, :scheduled_for])
  end
end
