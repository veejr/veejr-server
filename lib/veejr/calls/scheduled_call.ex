defmodule Veejr.Calls.ScheduledCall do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(scheduled cancelled started)
  @reminder_minutes [5, 10, 15, 30, 60, 1_440]

  schema "scheduled_calls" do
    field :public_id, :string
    field :scheduled_for, :utc_datetime
    field :reminder_minutes, :integer, default: 15
    field :note, :string
    field :status, :string, default: "scheduled"
    field :cancellation_reason, :string
    field :reminded_at, :utc_datetime
    field :organizer_email_reminded_at, :utc_datetime
    field :invitee_email_reminded_at, :utc_datetime

    belongs_to :organizer, Veejr.Accounts.User
    belongs_to :invitee, Veejr.Accounts.User
    belongs_to :cancelled_by, Veejr.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def reminder_minutes, do: @reminder_minutes

  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [:scheduled_for, :reminder_minutes, :note])
    |> validate_required([:scheduled_for, :reminder_minutes])
    |> validate_inclusion(:reminder_minutes, @reminder_minutes)
    |> validate_length(:note, max: 500)
    |> validate_future()
  end

  def note_changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [:note])
    |> validate_length(:note, max: 500)
  end

  def cancellation_changeset(schedule, attrs, cancelled_by_id) do
    schedule
    |> cast(attrs, [:cancellation_reason])
    |> update_change(:cancellation_reason, fn
      reason when is_binary(reason) ->
        case String.trim(reason) do
          "" -> nil
          trimmed -> trimmed
        end

      _reason ->
        nil
    end)
    |> validate_length(:cancellation_reason, max: 500)
    |> put_change(:cancelled_by_id, cancelled_by_id)
    |> put_change(:status, "cancelled")
  end

  defp validate_future(changeset) do
    validate_change(changeset, :scheduled_for, fn :scheduled_for, scheduled_for ->
      if DateTime.compare(scheduled_for, DateTime.utc_now(:second)) == :gt do
        []
      else
        [scheduled_for: "must be in the future"]
      end
    end)
  end
end
