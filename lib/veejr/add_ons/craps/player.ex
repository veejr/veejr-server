defmodule Veejr.AddOns.Craps.Player do
  @moduledoc """
  A member's craps stack.

  Play money, and the only thing the craps add-on stores about a person. It
  lives in its own table rather than as a column on `users` so the add-on owns
  its data outright: turning craps off and dropping this table takes nothing
  else with it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "craps_players" do
    field :chip_balance, :integer, default: 0

    belongs_to :user, Veejr.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(player, attrs) do
    player
    |> cast(attrs, [:user_id, :chip_balance])
    |> validate_required([:user_id, :chip_balance])
    |> validate_number(:chip_balance, greater_than_or_equal_to: 0)
    |> unique_constraint(:user_id)
  end
end
