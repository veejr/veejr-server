defmodule Veejr.Repo.Migrations.AddRecurringNoteReminders do
  use Ecto.Migration

  def change do
    alter table(:envelopes) do
      add :reminder_repeat, :string, null: false, default: "once"
      add :reminder_day, :integer
    end
  end
end
