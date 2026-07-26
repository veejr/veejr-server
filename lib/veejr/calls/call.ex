defmodule Veejr.Calls.Call do
  use Ecto.Schema

  @states ~w(ringing accepted declined cancelled missed ended failed)

  schema "calls" do
    field :public_id, :string
    field :state, :string, default: "ringing"

    belongs_to :caller, Veejr.Accounts.User
    belongs_to :callee, Veejr.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def states, do: @states
end
