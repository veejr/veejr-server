defmodule Veejr.Repo.Migrations.CreateCrapsPlayers do
  use Ecto.Migration

  def change do
    create table(:craps_players) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :chip_balance, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:craps_players, [:user_id])
  end
end
