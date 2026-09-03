defmodule Veejr.InstanceSettings do
  use Ecto.Schema
  import Ecto.Changeset

  alias Veejr.Repo

  @primary_key {:id, :integer, autogenerate: false}
  schema "instance_settings" do
    field :name, :string
    field :description, :string
    field :registration_policy, :string, default: "mode_default"
    field :invitation_lifetime_hours, :integer, default: 168
    field :max_upload_bytes, :integer, default: 25 * 1024 * 1024
    field :storage_quota_bytes, :integer
    field :default_retention_hours, :integer
    field :mail_from_name, :string
    field :mail_from_address, :string
    field :craps_enabled, :boolean, default: false
    field :craps_dice_mode, :string, default: "fair"

    # Interface switches, id => boolean, described by the catalogue in
    # `Veejr.Features`. Deliberately absent from `change/2`: it is written only
    # by `Veejr.Admin.update_features/2`, which normalises against that
    # catalogue, so a post to the settings form cannot reach it.
    field :features, :map, default: %{}

    field :invitation_lifetime_days, :integer, virtual: true
    field :max_upload_mb, :integer, virtual: true
    field :storage_quota_mb, :integer, virtual: true

    timestamps(type: :utc_datetime)
  end

  def get do
    Repo.get!(__MODULE__, 1)
  end

  def change(settings \\ get(), attrs \\ %{}) do
    settings
    |> with_display_units()
    |> cast(attrs, [
      :name,
      :description,
      :registration_policy,
      :invitation_lifetime_days,
      :max_upload_mb,
      :storage_quota_mb,
      :default_retention_hours,
      :mail_from_name,
      :mail_from_address,
      :craps_enabled,
      :craps_dice_mode
    ])
    |> validate_inclusion(:registration_policy, ["mode_default", "open", "invite_only", "closed"])
    |> validate_inclusion(:craps_dice_mode, Veejr.AddOns.dice_modes())
    |> validate_number(:invitation_lifetime_days,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 30
    )
    |> validate_number(:max_upload_mb, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
    |> validate_number(:storage_quota_mb,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 1_000_000
    )
    |> validate_number(:default_retention_hours,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 720
    )
    |> validate_length(:name, max: 100)
    |> validate_length(:description, max: 500)
    |> validate_length(:mail_from_name, max: 100)
    |> validate_format(:mail_from_address, ~r/^[^@,;\s]+@[^@,;\s]+$/)
    |> copy_display_units()
  end

  def effective_name(settings \\ get()) do
    present(settings.name) ||
      Application.get_env(:veejr, :instance_name, "veejr @ #{Veejr.instance_host()}")
  end

  def effective_description(settings \\ get()), do: present(settings.description)

  def registration_policy(settings \\ get()), do: settings.registration_policy

  def invitation_lifetime_hours(settings \\ get()), do: settings.invitation_lifetime_hours

  def max_upload_bytes(settings \\ get()), do: settings.max_upload_bytes

  def storage_quota_bytes(settings \\ get()), do: settings.storage_quota_bytes

  def default_retention_hours(settings \\ get()), do: settings.default_retention_hours

  def mail_from(settings \\ get()) do
    {fallback_name, fallback_address} = Application.fetch_env!(:veejr, :mail_from)

    {
      present(settings.mail_from_name) || fallback_name,
      present(settings.mail_from_address) || fallback_address
    }
  end

  defp with_display_units(settings) do
    %{
      settings
      | invitation_lifetime_days: div(settings.invitation_lifetime_hours, 24),
        max_upload_mb: div(settings.max_upload_bytes, 1024 * 1024),
        storage_quota_mb: maybe_div(settings.storage_quota_bytes, 1024 * 1024)
    }
  end

  defp copy_display_units(changeset) do
    changeset
    |> maybe_copy(:invitation_lifetime_days, :invitation_lifetime_hours, &(&1 * 24))
    |> maybe_copy(:max_upload_mb, :max_upload_bytes, &(&1 * 1024 * 1024))
    |> maybe_copy(:storage_quota_mb, :storage_quota_bytes, fn
      nil -> nil
      value -> value * 1024 * 1024
    end)
  end

  defp maybe_copy(changeset, source, destination, convert) do
    if Map.has_key?(changeset.changes, source) do
      put_change(changeset, destination, convert.(get_change(changeset, source)))
    else
      changeset
    end
  end

  defp maybe_div(nil, _divisor), do: nil
  defp maybe_div(value, divisor), do: div(value, divisor)

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
