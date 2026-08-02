defmodule Veejr.Repo.Migrations.AddPageLayoutToUsers do
  use Ecto.Migration

  def change do
    # Which Contacts and Messages to render: the full pages, or the plain
    # pair. A per-user column rather than browser storage, because the choice
    # decides what the server renders — and because someone who wants the
    # plain pages wants them on their phone too.
    alter table(:users) do
      add :page_layout, :string, null: false, default: "full"
    end
  end
end
