defmodule Veejr.Accounts.SecurityChallenge do
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "security_challenges" do
    field :binding, :string
    field :purpose, :string
    belongs_to :user, Veejr.Accounts.User
    field :data, :binary
    field :expires_at, :utc_datetime
  end
end
