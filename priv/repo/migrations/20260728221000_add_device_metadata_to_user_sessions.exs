defmodule Veejr.Repo.Migrations.AddDeviceMetadataToUserSessions do
  use Ecto.Migration

  def change do
    alter table(:users_tokens) do
      add :device_name, :string
      add :last_used_at, :utc_datetime
    end
  end
end
