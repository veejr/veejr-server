defmodule Veejr.Accounts.Passkey do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "passkeys" do
    belongs_to :user, Veejr.Accounts.User
    field :credential_id, :string
    field :cose_key, :binary
    field :sign_count, :integer, default: 0
    field :label, :string
    field :last_used_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end
