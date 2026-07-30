defmodule Veejr.Messaging.Envelope do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(message location note self_note self_doc)

  # Owner-only kinds: exactly one copy, addressed to the sender, never
  # notified or federated. `self_doc` carries its document type (spreadsheet,
  # page) *inside* the encrypted payload, so adding a document format does not
  # add a kind — and the server cannot tell one document type from another.
  @self_kinds ~w(self_note self_doc)

  schema "envelopes" do
    field :public_id, :string
    field :batch_id, :string
    field :kind, :string
    field :ciphertext, :string
    field :nonce, :string
    field :delivered_at, :utc_datetime
    field :read_at, :utc_datetime
    field :edited_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :max_displays, :integer
    field :display_count, :integer, default: 0
    # the sender's public key at send time — decryption survives rotation
    field :sender_public_key, :string
    # re-encrypted to the recipient's own key during their rotation
    field :resealed, :boolean, default: false
    # conversation identity, materialized at insert so threads are queryable:
    # the stable key of `participants` (a JSON-encoded sorted handle list),
    # rewritten to an instance key when the viewer archives the conversation
    field :thread_key, :string
    field :participants, :string
    # opaque, client-computed idempotency token for imported self-notes; NULL for
    # everything else. Unique per recipient so re-importing skips existing notes.
    field :dedup_key, :string
    # opaque content fingerprint of an imported note, so a re-import can tell a
    # changed note (update) from an unchanged one (skip).
    field :dedup_version, :string
    # Scheduled send. The ciphertext is stored at compose time and withheld
    # until `deliver_at`; `released_at` marks the scheduler's decision (once),
    # and `release_error` records a refusal such as a rotated recipient key.
    field :deliver_at, :utc_datetime
    field :released_at, :utc_datetime
    field :release_error, :string
    # The recipient key this copy was sealed to, so release can detect a
    # rotation that happened while the message waited. See the migration.
    field :recipient_public_key, :string
    # One-shot reminder for an owner-only self note or document.
    field :remind_at, :utc_datetime
    field :reminded_at, :utc_datetime

    belongs_to :sender, Veejr.Accounts.User
    belongs_to :recipient, Veejr.Accounts.User
    has_one :notification, Veejr.Messaging.Notification

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  @doc "Kinds that must be a single owner-addressed copy with no notification."
  def self_kinds, do: @self_kinds

  @doc "True for the owner-only kinds (`self_note`, `self_doc`)."
  def self_kind?(kind), do: kind in @self_kinds

  def changeset(envelope, attrs) do
    envelope
    |> cast(attrs, [
      :recipient_id,
      :kind,
      :ciphertext,
      :nonce,
      :expires_at,
      :max_displays,
      :dedup_key,
      :dedup_version
    ])
    |> validate_required([:recipient_id, :kind, :ciphertext, :nonce])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:max_displays, greater_than: 0, less_than_or_equal_to: 100)
    # ~256 KB of base64 keeps envelope bodies light; bulk data goes in blobs.
    |> validate_length(:ciphertext, max: 350_000)
    |> unique_constraint(:public_id)
    |> unique_constraint([:batch_id, :recipient_id])
    |> unique_constraint([:recipient_id, :dedup_key])
  end
end
