defmodule Veejr.Repo.Migrations.AddScheduledCallCancellationDetails do
  use Ecto.Migration

  def change do
    alter table(:scheduled_calls) do
      add :cancellation_reason, :string
      add :cancelled_by_id, references(:users, on_delete: :nilify_all)
    end
  end
end
