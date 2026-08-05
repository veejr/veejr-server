defmodule Veejr.Repo.Migrations.AddAddOnSettings do
  use Ecto.Migration

  def change do
    alter table(:instance_settings) do
      add :craps_enabled, :boolean, null: false, default: false
      add :craps_dice_mode, :string, null: false, default: "fair"
    end
  end
end
