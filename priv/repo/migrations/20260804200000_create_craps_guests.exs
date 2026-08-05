defmodule Veejr.Repo.Migrations.CreateCrapsGuests do
  use Ecto.Migration

  def change do
    create table(:craps_guests) do
      add :host_id, references(:users, on_delete: :delete_all), null: false
      add :public_id, :string, null: false
      add :token_hash, :string, null: false
      add :invited_email, :string, null: false
      add :display_name, :string
      add :expires_at, :utc_datetime, null: false
      add :joined_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:craps_guests, [:public_id])
    create unique_index(:craps_guests, [:token_hash])
    create index(:craps_guests, [:host_id])
  end
end
