defmodule Veejr.Accounts.DeviceLink do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "device_links" do
    field :token_hash, :binary
    field :public_key, :string
    belongs_to :user, Veejr.Accounts.User
    field :sealed_key, :map
    field :expires_at, :utc_datetime
  end
end
