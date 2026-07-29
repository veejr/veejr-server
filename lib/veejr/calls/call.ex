defmodule Veejr.Calls.Call do
  use Ecto.Schema

  @states ~w(ringing accepted declined cancelled missed ended failed)

  schema "calls" do
    field :public_id, :string
    field :state, :string, default: "ringing"

    # caller is the host: the only participant who may add someone else.
    # callee is the *first* invitee, kept because federated invites are
    # strictly 1:1. `participants` is the source of truth for membership.
    belongs_to :caller, Veejr.Accounts.User
    belongs_to :callee, Veejr.Accounts.User

    has_many :participants, Veejr.Calls.CallParticipant
    has_many :participant_users, through: [:participants, :user]

    timestamps(type: :utc_datetime)
  end

  def states, do: @states
end
