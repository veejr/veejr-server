defmodule Veejr.Repo.Migrations.AddPresenceSharingToUsers do
  use Ecto.Migration

  def change do
    # On by default: friendship is already mutual and consented, and a dot
    # nobody ever finds the setting to enable is a dot that reads as broken.
    # Turning it off is enforced where presence is recorded, not where it is
    # displayed.
    alter table(:users) do
      add :presence_sharing, :boolean, null: false, default: true
    end
  end
end
