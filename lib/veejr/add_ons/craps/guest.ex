defmodule Veejr.AddOns.Craps.Guest do
  @moduledoc """
  An emailed capability to sit at the craps table without an account.

  Stored rather than held in memory, because `joined_at` has to survive a
  restart: it is what stops one guest turning a single invitation into an
  endless supply of membership invitations.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "craps_guests" do
    field :public_id, :string
    field :token_hash, :string
    field :invited_email, :string
    field :display_name, :string
    field :expires_at, :utc_datetime
    field :joined_at, :utc_datetime

    belongs_to :host, Veejr.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def invitation_changeset(guest, attrs) do
    guest
    |> cast(attrs, [:invited_email])
    |> update_change(:invited_email, &normalize_email/1)
    |> validate_required([:invited_email])
    |> validate_format(:invited_email, ~r/^[^\s]+@[^\s]+$/,
      message: "must be a valid email address"
    )
    |> validate_length(:invited_email, max: 160)
  end

  def create_changeset(guest, attrs) do
    guest
    |> cast(attrs, [:host_id, :public_id, :token_hash, :invited_email, :expires_at])
    |> update_change(:invited_email, &normalize_email/1)
    |> validate_required([:host_id, :public_id, :token_hash, :invited_email, :expires_at])
    |> validate_format(:invited_email, ~r/^[^\s]+@[^\s]+$/)
    |> unique_constraint(:public_id)
    |> unique_constraint(:token_hash)
  end

  def name_changeset(guest, attrs) do
    guest
    |> cast(attrs, [:display_name])
    |> update_change(:display_name, &String.trim/1)
    |> validate_required([:display_name])
    |> validate_length(:display_name, min: 1, max: 40)
  end

  defp normalize_email(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_email(value), do: value
end
