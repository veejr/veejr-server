defmodule Veejr.Accounts.KeySlot do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "key_slots" do
    belongs_to :user, Veejr.Accounts.User
    belongs_to :passkey, Veejr.Accounts.Passkey, type: :binary_id
    field :kind, :string
    field :public_key, :string
    field :wrapped, :map
    timestamps(type: :utc_datetime)
  end
end
