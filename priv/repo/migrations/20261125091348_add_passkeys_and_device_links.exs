defmodule Veejr.Repo.Migrations.AddPasskeysAndDeviceLinks do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :passkey_handle, :binary
    end

    create table(:passkeys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :credential_id, :string, null: false
      add :cose_key, :binary, null: false
      add :sign_count, :integer, null: false, default: 0
      add :label, :string, null: false
      add :last_used_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:passkeys, [:credential_id])
    create index(:passkeys, [:user_id])

    create table(:key_slots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :passkey_id, references(:passkeys, type: :binary_id, on_delete: :delete_all)
      add :kind, :string, null: false
      add :public_key, :string, null: false
      add :wrapped, :map, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:key_slots, [:passkey_id])
    create unique_index(:key_slots, [:user_id, :kind], where: "kind = 'recovery_code'")

    create table(:security_challenges, primary_key: false) do
      add :id, :string, primary_key: true
      add :binding, :string, null: false
      add :purpose, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :data, :binary, null: false
      add :expires_at, :utc_datetime, null: false
    end

    create index(:security_challenges, [:expires_at])

    create table(:device_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_hash, :binary, null: false
      add :public_key, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :sealed_key, :map
      add :expires_at, :utc_datetime, null: false
    end

    create index(:device_links, [:expires_at])
  end
end
