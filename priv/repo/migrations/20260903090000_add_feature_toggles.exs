defmodule Veejr.Repo.Migrations.AddFeatureToggles do
  use Ecto.Migration

  def change do
    # One map of id => boolean for every interface control an administrator has
    # switched, rather than a column per switch: the catalogue lives in
    # Veejr.Features, so a new toggle ships without a migration. An id absent
    # from the map takes the default declared there, which is what lets a
    # feature added later reach existing instances switched on.
    alter table(:instance_settings) do
      add :features, :map, null: false, default: %{}
    end
  end
end
