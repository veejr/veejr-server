defmodule Veejr.Calls.CallParticipant do
  @moduledoc """
  One person's membership of one call.

  Lifecycle state lives here rather than on the call because with more than
  two people "declined" is no longer a property of the call — one invitee can
  decline while the rest carry on talking. `Veejr.Calls` derives the call's own
  state from these rows.
  """
  use Ecto.Schema

  @states ~w(ringing joined declined busy missed left)
  @roles ~w(caller invitee)

  schema "call_participants" do
    field :role, :string, default: "invitee"
    field :state, :string, default: "ringing"
    field :joined_at, :utc_datetime
    field :left_at, :utc_datetime

    belongs_to :call, Veejr.Calls.Call
    belongs_to :user, Veejr.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def states, do: @states
  def roles, do: @roles

  @doc "States in which a participant is still meaningfully in the call."
  def active_states, do: ~w(ringing joined)

  @doc "States in which a participant has media flowing."
  def connected_states, do: ~w(joined)
end
