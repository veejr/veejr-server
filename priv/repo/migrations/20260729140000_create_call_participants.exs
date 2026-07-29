defmodule Veejr.Repo.Migrations.CreateCallParticipants do
  use Ecto.Migration

  @moduledoc """
  Membership for calls with more than two people.

  `calls.caller_id` and `calls.callee_id` stay exactly as they are.
  `caller_id` is now meaningfully "the host" — the only participant who may
  add someone — and `callee_id` remains the *first* invitee. Federation call
  invites are strictly 1:1 and multi-party is local-only, so leaving both
  columns in place means the federated path needs no changes, and no column on
  a live production table has to be altered.

  `call_participants` is the source of truth for who is actually in a call.
  """

  def up do
    create table(:call_participants) do
      add :call_id, references(:calls, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # "caller" (the host) or "invitee".
      add :role, :string, null: false, default: "invitee"
      # ringing | joined | declined | busy | missed | left
      add :state, :string, null: false, default: "ringing"
      add :joined_at, :utc_datetime
      add :left_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:call_participants, [:call_id, :user_id])
    create index(:call_participants, [:user_id, :state])
    create index(:call_participants, [:call_id, :state])

    # Backfill every existing call so participant queries do not have to fall
    # back to the legacy columns. The caller has always been present from the
    # moment they dialled; the callee's participant state mirrors the call.
    execute """
    INSERT INTO call_participants
      (call_id, user_id, role, state, joined_at, left_at, inserted_at, updated_at)
    SELECT
      c.id,
      c.caller_id,
      'caller',
      CASE WHEN c.state IN ('ringing', 'accepted') THEN 'joined' ELSE 'left' END,
      c.inserted_at,
      CASE WHEN c.state IN ('ringing', 'accepted') THEN NULL ELSE c.updated_at END,
      c.inserted_at,
      c.updated_at
    FROM calls AS c
    """

    execute """
    INSERT INTO call_participants
      (call_id, user_id, role, state, joined_at, left_at, inserted_at, updated_at)
    SELECT
      c.id,
      c.callee_id,
      'invitee',
      CASE
        WHEN c.state = 'ringing' THEN 'ringing'
        WHEN c.state = 'accepted' THEN 'joined'
        WHEN c.state IN ('declined', 'missed') THEN c.state
        ELSE 'left'
      END,
      CASE WHEN c.state = 'accepted' THEN c.updated_at ELSE NULL END,
      CASE WHEN c.state IN ('ringing', 'accepted') THEN NULL ELSE c.updated_at END,
      c.inserted_at,
      c.updated_at
    FROM calls AS c
    """
  end

  def down do
    drop table(:call_participants)
  end
end
