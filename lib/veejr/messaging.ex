defmodule Veejr.Messaging do
  @moduledoc """
  Encrypted envelopes, pull-based notifications, and attachment blobs.

  The server's role is deliberately dumb: it stores ciphertext produced in the
  sender's browser and hands it out only after the recipient explicitly
  accepts the notification ("no data is sent unless the receiver has
  requested it"). Plaintext never exists server-side.
  """

  import Ecto.Query, warn: false

  alias Veejr.Repo
  alias Veejr.Accounts.User

  alias Veejr.Messaging.{
    Blob,
    BlobReference,
    ConversationArchive,
    ConversationWindow,
    Envelope,
    MessageDeliveryPolicy,
    Notification
  }

  alias Veejr.Social

  # How long an active conversation keeps auto-accepting new messages without
  # a fresh request. Re-upped on every send or receive.
  @window_seconds 5 * 60
  @max_expiry_seconds 60 * 60 * 24 * 30
  # How far ahead a message or reminder may be scheduled, and how much lateness
  # counts as clock skew rather than a mistyped date.
  @max_schedule_seconds 60 * 60 * 24 * 365
  @schedule_grace_seconds 120
  # Work per scheduler tick. Bounded so a backlog (a long outage, a clock
  # jump) drains over several ticks instead of one very long transaction.
  @schedule_batch_size 200

  # Participant sentinel for a batch with no recipients besides the sender.
  # Part of stored conversation keys — do not change.
  @self_thread ["notes to yourself"]

  ## PubSub

  def subscribe(%User{id: id}), do: Phoenix.PubSub.subscribe(Veejr.PubSub, topic(id))

  defp topic(user_id), do: "user:#{user_id}"

  defp broadcast_notification(%Notification{} = notification) do
    Phoenix.PubSub.broadcast(
      Veejr.PubSub,
      topic(notification.user_id),
      {:veejr_notification, notification}
    )

    envelope = notification.envelope

    should_push? =
      notification.state == "pending" or
        (notification.state == "accepted" and
           automatic_delivery?(notification.user, envelope.sender) and
           delivery_notification_mode(notification.user, envelope.sender) != "silent")

    if should_push?, do: Veejr.Push.notify_async(notification)
    :ok
  end

  @doc """
  Broadcasts notifications created for a batch, and kicks the federation
  outbox for any remote notifies it enqueued, after the surrounding
  transaction has committed.

  API callers use this when idempotency handling wraps `send_batch/4` in a
  larger transaction: subscribers must not refresh against uncommitted
  message data, and the outbox cannot see uncommitted delivery rows.
  """
  def broadcast_batch_notifications(%User{id: sender_id}, batch_id) do
    notifications =
      from(n in Notification,
        join: e in assoc(n, :envelope),
        where: e.sender_id == ^sender_id and e.batch_id == ^batch_id
      )
      |> Repo.all()
      |> Repo.preload([:user, envelope: [:sender]])

    Enum.each(notifications, &broadcast_notification/1)
    Veejr.Federation.Outbox.kick()
    :ok
  end

  ## Active-conversation windows

  @doc """
  Is `peer`'s conversation with `user` currently active — i.e. should a new
  message from `peer` be auto-accepted for `user` rather than held as a
  request?
  """
  def conversation_active?(user_id, peer_id) do
    now = DateTime.utc_now(:second)

    case Repo.get_by(ConversationWindow, user_id: user_id, peer_id: peer_id) do
      %ConversationWindow{active_until: until} -> DateTime.compare(until, now) == :gt
      nil -> false
    end
  end

  @doc """
  Re-ups `user`'s auto-accept window for `peer` to #{@window_seconds} seconds
  from now. Called on every send to, and accepted receive from, `peer`.
  """
  def touch_conversation(user_id, peer_id) do
    now = DateTime.utc_now(:second)
    until = DateTime.add(now, @window_seconds, :second)

    Repo.insert!(
      %ConversationWindow{
        user_id: user_id,
        peer_id: peer_id,
        active_until: until,
        inserted_at: now,
        updated_at: now
      },
      on_conflict: [set: [active_until: until, updated_at: now]],
      conflict_target: [:user_id, :peer_id]
    )

    :ok
  end

  ## Sending

  @doc """
  Stores a batch of envelopes — one per recipient, each encrypted client-side
  to that recipient's key — and notifies every recipient other than the
  sender. The sender's self-copy keeps their history readable.

  Every recipient must be the sender or an accepted friend of the sender.
  """
  def send_batch(%User{} = sender, kind, envelopes, opts \\ []) when is_list(envelopes) do
    batch_id = random_id()
    expires_at = effective_expires_at(opt(opts, :expires_at))
    max_displays = normalize_max_displays(opt(opts, :max_displays))

    result =
      Repo.transaction(fn ->
        deliver_at =
          case normalize_deliver_at(opt(opts, :deliver_at)) do
            :invalid -> Repo.rollback(:invalid_deliver_at)
            value -> value
          end

        attachment_ids = normalize_attachment_ids(opt(opts, :attachment_ids))
        link_batch_blobs!(sender, batch_id, attachment_ids)

        recipient_ids =
          Enum.map(envelopes, fn attrs ->
            case parse_id(attrs["recipient_id"] || attrs[:recipient_id]) do
              {:ok, id} -> id
              :error -> Repo.rollback(:bad_recipient_id)
            end
          end)

        if length(Enum.uniq(recipient_ids)) != length(recipient_ids) do
          Repo.rollback(:duplicate_recipients)
        end

        # Owner-only kinds are one copy addressed to yourself, with no expiry,
        # display limit, or scheduling: there is no second party for any of
        # those to mean anything to.
        if Envelope.self_kind?(kind) and
             (length(recipient_ids) != 1 or recipient_ids != [sender.id] or
                not is_nil(effective_expires_at(opt(opts, :expires_at))) or
                not is_nil(deliver_at) or
                not is_nil(normalize_max_displays(opt(opts, :max_displays)))) do
          Repo.rollback(:invalid_self_item)
        end

        recipients =
          Enum.map(recipient_ids, fn recipient_id ->
            Repo.get(User, recipient_id) || Repo.rollback({:no_such_user, recipient_id})
          end)

        self_participants = self_copy_participants(sender, recipients)

        for {attrs, recipient} <- Enum.zip(envelopes, recipients) do
          unless recipient.id == sender.id or Social.friends?(sender.id, recipient.id) do
            Repo.rollback({:not_a_friend, recipient.id})
          end

          # Thread identity from this copy's viewer: the self-copy groups by
          # who the batch went to, a received copy groups by who sent it.
          participants =
            if recipient.id == sender.id,
              do: self_participants,
              else: [Social.Address.handle(sender)]

          envelope =
            %Envelope{
              sender_id: sender.id,
              public_id: random_id(),
              batch_id: batch_id,
              sender_public_key: sender.public_key,
              thread_key: conversation_key(participants),
              participants: Jason.encode!(participants),
              deliver_at: deliver_at,
              # Only for copies addressed to someone else. The sender's own
              # self-copy is resealed normally by key rotation, so a snapshot
              # of it would go stale and produce a false mismatch at release.
              recipient_public_key:
                if(deliver_at && recipient.id != sender.id, do: recipient.public_key)
            }
            |> Envelope.changeset(%{
              recipient_id: recipient.id,
              kind: kind,
              ciphertext: attrs["ciphertext"] || attrs[:ciphertext],
              nonce: attrs["nonce"] || attrs[:nonce],
              expires_at: expires_at,
              max_displays: max_displays
            })
            |> case do
              %{valid?: true} = changeset -> Repo.insert!(changeset)
              changeset -> Repo.rollback(changeset)
            end

          cond do
            recipient.id == sender.id ->
              {envelope, nil}

            # Scheduled: store the ciphertext and stop. No notification row is
            # created for either a local or a remote recipient, which is what
            # keeps the message unreachable until it is due — `fetch_envelope/2`
            # and `list_history/2` both require an accepted notification, so
            # there is nothing to guess at and nothing to enumerate. The
            # consent decision is deliberately *not* made here; it is made from
            # the conversation state that exists at release time.
            not is_nil(deliver_at) ->
              {envelope, nil}

            # Local recipient: notify in-place. If their conversation with the
            # sender is active, the message is auto-accepted and just shows up.
            is_nil(recipient.host) ->
              # sending re-ups the sender's own window for this recipient
              touch_conversation(sender.id, recipient.id)

              state =
                if conversation_active?(recipient.id, sender.id) or
                     automatic_delivery?(recipient, sender) do
                  touch_conversation(recipient.id, sender.id)
                  "accepted"
                else
                  "pending"
                end

              notification =
                Repo.insert!(%Notification{
                  envelope_id: envelope.id,
                  user_id: recipient.id,
                  state: state
                })

              {envelope, notification}

            # Remote recipient: the envelope stays here; a content-free notify
            # is enqueued in this same transaction (crash-safe, no network I/O)
            # and delivered by the outbox after commit. The auto-accept
            # decision happens on their instance in receive_remote_notify/4.
            true ->
              touch_conversation(sender.id, recipient.id)
              status = Veejr.Federation.enqueue_notify(sender, envelope, recipient)
              {envelope, {:remote, recipient, status}}
          end
        end
      end)

    with {:ok, pairs} <- result do
      queued =
        for {_envelope, {:remote, recipient, :ok}} <- pairs do
          Veejr.Social.Address.handle(recipient)
        end

      # With `:defer_notifications` the caller's own transaction is still
      # open; it broadcasts and kicks via broadcast_batch_notifications/2
      # after committing.
      unless opt(opts, :defer_notifications) do
        for {_envelope, %Notification{} = notification} <- pairs do
          broadcast_notification(Repo.preload(notification, [:user, envelope: [:sender]]))
        end

        if queued != [], do: Veejr.Federation.Outbox.kick()
      end

      {:ok, batch_id, queued}
    end
  end

  ## Scheduled delivery

  @doc """
  Releases scheduled envelopes that have come due, and returns a tally.

  A scheduled message is ordinary ciphertext that was sealed in the browser at
  compose time; releasing it is exactly the notification and federation work
  `send_batch/4` would have done immediately. Doing that work *here* rather
  than at compose time is deliberate: consent is evaluated against the
  conversation as it stands when the message actually arrives, not as it stood
  when it was written.

  `released_at` is set for every outcome, including refusal, so a crash
  mid-sweep cannot deliver the same envelope twice.
  """
  def dispatch_due_sends(now \\ DateTime.utc_now(:second)) do
    due =
      from(e in Envelope,
        where: not is_nil(e.deliver_at) and is_nil(e.released_at) and e.deliver_at <= ^now,
        order_by: [asc: e.deliver_at, asc: e.id],
        limit: @schedule_batch_size,
        preload: [:sender, :recipient]
      )
      |> Repo.all()

    tally =
      Enum.reduce(due, %{released: 0, refused: 0, queued: 0}, fn envelope, tally ->
        case release_envelope(envelope, now) do
          {:ok, {:refused, reason}} ->
            notify_sender_of_failed_release(envelope, reason)
            %{tally | refused: tally.refused + 1}

          {:ok, :remote} ->
            %{tally | released: tally.released + 1, queued: tally.queued + 1}

          {:ok, {:local, notification}} ->
            broadcast_notification(Repo.preload(notification, [:user, envelope: [:sender]]))
            %{tally | released: tally.released + 1}

          {:ok, :self} ->
            %{tally | released: tally.released + 1}

          {:error, _reason} ->
            tally
        end
      end)

    if tally.queued > 0, do: Veejr.Federation.Outbox.kick()
    if tally.released > 0 or tally.refused > 0, do: broadcast_schedule_change(due)

    tally
  end

  defp release_envelope(%Envelope{} = envelope, now) do
    %{sender: sender, recipient: recipient} = envelope

    Repo.transaction(fn ->
      cond do
        # The sender's own copy of a scheduled batch. Nothing to deliver — it
        # just stops being labelled "scheduled" in their own thread.
        recipient.id == sender.id ->
          mark_released!(envelope, now, nil)
          :self

        # The recipient rotated their identity key while the message waited.
        # `list_resealable/1` could not have re-encrypted this copy, because
        # rotation only walks history the user may already read and a
        # scheduled envelope has no accepted notification. Delivering it now
        # would hand them ciphertext that silently never opens, so refuse and
        # let the sender decide whether to send it again.
        not is_nil(envelope.recipient_public_key) and
            recipient.public_key != envelope.recipient_public_key ->
          mark_released!(envelope, now, "recipient_key_changed")
          {:refused, "recipient_key_changed"}

        is_nil(recipient.host) ->
          touch_conversation(sender.id, recipient.id)

          state =
            if conversation_active?(recipient.id, sender.id) or
                 automatic_delivery?(recipient, sender) do
              touch_conversation(recipient.id, sender.id)
              "accepted"
            else
              "pending"
            end

          notification =
            Repo.insert!(%Notification{
              envelope_id: envelope.id,
              user_id: recipient.id,
              state: state
            })

          mark_released!(envelope, now, nil)
          {:local, notification}

        true ->
          touch_conversation(sender.id, recipient.id)
          Veejr.Federation.enqueue_notify(sender, envelope, recipient)
          mark_released!(envelope, now, nil)
          :remote
      end
    end)
  end

  defp mark_released!(%Envelope{} = envelope, now, error) do
    envelope
    |> Ecto.Changeset.change(released_at: now, release_error: error)
    |> Repo.update!()
  end

  # Content-free: the sender is told *that* a scheduled message could not be
  # released and which one, never its plaintext.
  defp notify_sender_of_failed_release(%Envelope{} = envelope, reason) do
    Phoenix.PubSub.broadcast(
      Veejr.PubSub,
      topic(envelope.sender_id),
      {:veejr_schedule_failed, envelope.public_id, reason}
    )

    Veejr.Push.notify_user_async(envelope.sender, %{
      title: "Scheduled message not sent",
      body: "The recipient's encryption key changed. Open veejr to send it again.",
      url: "/messages"
    })
  end

  # Senders watching a thread should see a "Scheduled" chip disappear when the
  # message actually goes out.
  defp broadcast_schedule_change(envelopes) do
    envelopes
    |> Enum.map(& &1.sender_id)
    |> Enum.uniq()
    |> Enum.each(fn sender_id ->
      Phoenix.PubSub.broadcast(Veejr.PubSub, topic(sender_id), {:veejr_schedule_released})
    end)
  end

  @doc """
  Lists the caller's own scheduled-but-unreleased copies, newest due first.

  Only the self-copy of each batch is returned, so a message scheduled to
  several people appears once.
  """
  def list_scheduled_envelopes(%User{id: id}) do
    from(e in Envelope,
      where:
        e.sender_id == ^id and e.recipient_id == ^id and not is_nil(e.deliver_at) and
          is_nil(e.released_at),
      order_by: [asc: e.deliver_at, asc: e.id],
      preload: [:sender]
    )
    |> Repo.all()
  end

  @doc """
  Reschedules an unreleased scheduled batch. Cancelling is `delete_envelope/2`,
  which already removes every copy of a batch for its sender.
  """
  def reschedule_batch(%User{id: user_id}, public_id, deliver_at)
      when is_binary(public_id) do
    with %Envelope{} = envelope <-
           Repo.get_by(Envelope, public_id: public_id, sender_id: user_id),
         true <- is_nil(envelope.released_at) and not is_nil(envelope.deliver_at),
         value when value not in [:invalid, nil] <- normalize_deliver_at(deliver_at) do
      {count, _} =
        from(e in Envelope,
          where:
            e.sender_id == ^user_id and e.batch_id == ^envelope.batch_id and
              is_nil(e.released_at)
        )
        |> Repo.update_all(set: [deliver_at: value])

      {:ok, count}
    else
      nil -> {:error, :not_found}
      false -> {:error, :already_released}
      _ -> {:error, :invalid_deliver_at}
    end
  end

  ## Reminders

  @doc """
  Sets or clears a one-shot reminder on one of the caller's own board items.

  The time is necessarily server-visible — something has to know when to fire —
  but the reminder that fires carries no note content. Setting a new time
  re-arms an already-fired reminder.
  """
  def set_reminder(%User{id: user_id}, public_id, remind_at) when is_binary(public_id) do
    with %Envelope{} = envelope <- self_item(user_id, public_id),
         value <- normalize_deliver_at(remind_at),
         true <- value != :invalid do
      envelope
      |> Ecto.Changeset.change(remind_at: value, reminded_at: nil)
      |> Repo.update()
      |> case do
        {:ok, envelope} -> {:ok, envelope}
        error -> error
      end
    else
      nil -> {:error, :not_found}
      false -> {:error, :invalid_remind_at}
    end
  end

  defp self_item(user_id, public_id) do
    from(e in Envelope,
      where:
        e.public_id == ^public_id and e.sender_id == ^user_id and e.recipient_id == ^user_id and
          e.kind in ^Envelope.self_kinds()
    )
    |> Repo.one()
  end

  @doc """
  Fires due note and document reminders exactly once each.

  The payload names no title, body, label, or attachment — only that a
  reminder is due and which encrypted card it belongs to. The browser opens
  the board and decrypts the card itself.
  """
  def dispatch_due_note_reminders(now \\ DateTime.utc_now(:second)) do
    due =
      from(e in Envelope,
        where: not is_nil(e.remind_at) and is_nil(e.reminded_at) and e.remind_at <= ^now,
        order_by: [asc: e.remind_at, asc: e.id],
        limit: @schedule_batch_size,
        preload: [:recipient]
      )
      |> Repo.all()

    Enum.each(due, fn envelope ->
      envelope
      |> Ecto.Changeset.change(reminded_at: now)
      |> Repo.update!()

      Phoenix.PubSub.broadcast(
        Veejr.PubSub,
        topic(envelope.recipient_id),
        {:veejr_note_reminder, envelope.public_id}
      )

      Veejr.Push.notify_user_async(envelope.recipient, %{
        title: "Note reminder",
        body: "A note you set a reminder on is due.",
        url: "/messages?self_notes=true"
      })
    end)

    %{reminded: length(due)}
  end

  @doc """
  For the given dedup `keys`, returns a `%{dedup_key => dedup_version}` map of
  the ones already imported as this user's self-notes. The client compares the
  stored version (an opaque content fingerprint) against a fresh one to decide
  skip (same) vs update (changed); keys absent from the map are new.
  """
  def self_note_dedup_versions(%User{id: id}, keys) when is_list(keys) do
    keys = keys |> Enum.filter(&is_binary/1) |> Enum.uniq()

    if keys == [] do
      %{}
    else
      from(e in Envelope,
        where: e.recipient_id == ^id and e.kind == "self_note" and e.dedup_key in ^keys,
        select: {e.dedup_key, e.dedup_version}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  @doc """
  Persists one imported self-note idempotently. If no envelope with this
  `dedup_key` exists it is inserted (`{:ok, :imported}`); if one exists it is
  updated in place with the new ciphertext, fingerprint, and re-linked
  attachments, releasing the previous version's blobs (`{:ok, :updated}`). The
  client only sends new or changed notes — unchanged ones are filtered out by
  the dedup pre-check — and the unique `(recipient_id, dedup_key)` index keeps
  concurrent re-imports safe.
  """
  def import_self_note(%User{} = user, attrs) do
    dedup_key = attrs["dedup_key"] || attrs[:dedup_key]
    dedup_version = attrs["dedup_version"] || attrs[:dedup_version]
    ciphertext = attrs["ciphertext"] || attrs[:ciphertext]
    nonce = attrs["nonce"] || attrs[:nonce]

    Repo.transaction(fn ->
      attachment_ids = normalize_attachment_ids(attrs["attachment_ids"] || attrs[:attachment_ids])

      existing =
        dedup_key &&
          Repo.one(
            from(e in Envelope,
              where:
                e.recipient_id == ^user.id and e.kind == "self_note" and
                  e.dedup_key == ^dedup_key
            )
          )

      case existing do
        %Envelope{} = envelope ->
          new_batch = random_id()
          release_batch_blobs!(user.id, envelope.batch_id)

          envelope
          |> Envelope.changeset(%{
            ciphertext: ciphertext,
            nonce: nonce,
            dedup_version: dedup_version
          })
          |> Ecto.Changeset.put_change(:batch_id, new_batch)
          |> case do
            %{valid?: true} = changeset -> Repo.update!(changeset)
            changeset -> Repo.rollback(changeset)
          end

          link_batch_blobs!(user, new_batch, attachment_ids)
          :updated

        _ ->
          batch_id = random_id()
          participants = self_copy_participants(user, [user])

          changeset =
            %Envelope{
              sender_id: user.id,
              public_id: random_id(),
              batch_id: batch_id,
              sender_public_key: user.public_key,
              thread_key: conversation_key(participants),
              participants: Jason.encode!(participants)
            }
            |> Envelope.changeset(%{
              recipient_id: user.id,
              kind: "self_note",
              ciphertext: ciphertext,
              nonce: nonce,
              dedup_key: dedup_key,
              dedup_version: dedup_version
            })

          unless changeset.valid?, do: Repo.rollback(changeset)

          case Repo.insert(changeset,
                 on_conflict: :nothing,
                 conflict_target: [:recipient_id, :dedup_key]
               ) do
            {:ok, %Envelope{id: nil}} ->
              :skipped

            {:ok, %Envelope{}} ->
              link_batch_blobs!(user, batch_id, attachment_ids)
              :imported

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
      end
    end)
  end

  defp self_copy_participants(%User{} = sender, recipients) do
    recipients
    |> Enum.reject(&(&1.id == sender.id))
    |> Enum.map(&Social.Address.handle/1)
    |> Enum.sort()
    |> case do
      [] -> @self_thread
      handles -> handles
    end
  end

  defp parse_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  def list_batch_copies(%User{id: sender_id}, batch_id) do
    from(e in Envelope,
      where: e.sender_id == ^sender_id and e.batch_id == ^batch_id,
      select: %{recipient_id: e.recipient_id, public_id: e.public_id}
    )
    |> Repo.all()
  end

  @doc "Returns the sender's readable self-copy for a newly created batch."
  def get_sent_self_copy(%User{id: user_id}, batch_id) when is_binary(batch_id) do
    from(e in Envelope,
      where: e.sender_id == ^user_id and e.recipient_id == ^user_id and e.batch_id == ^batch_id,
      preload: [:sender]
    )
    |> Repo.one()
  end

  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)

  defp opt(opts, key) when is_map(opts),
    do: Map.get(opts, Atom.to_string(key)) || Map.get(opts, key)

  defp opt(_opts, _key), do: nil

  defp normalize_expires_at(nil), do: nil
  defp normalize_expires_at(""), do: nil

  defp normalize_expires_at(value) when is_binary(value) do
    with {:ok, datetime, _} <- DateTime.from_iso8601(value) do
      normalize_expires_at(datetime)
    else
      _ -> nil
    end
  end

  defp normalize_expires_at(%DateTime{} = datetime) do
    now = DateTime.utc_now(:second)
    latest = DateTime.add(now, @max_expiry_seconds, :second)
    datetime = DateTime.truncate(datetime, :second)

    cond do
      DateTime.compare(datetime, now) != :gt -> nil
      DateTime.compare(datetime, latest) == :gt -> latest
      true -> datetime
    end
  end

  defp normalize_expires_at(_), do: nil

  defp effective_expires_at(value) do
    case normalize_expires_at(value) do
      nil ->
        case Veejr.InstanceSettings.default_retention_hours() do
          nil -> nil
          hours -> DateTime.add(DateTime.utc_now(:second), hours * 60 * 60, :second)
        end

      expires_at ->
        expires_at
    end
  end

  defp normalize_max_displays(nil), do: nil
  defp normalize_max_displays(""), do: nil
  defp normalize_max_displays(count) when is_integer(count) and count > 0, do: min(count, 100)

  defp normalize_max_displays(count) when is_binary(count) do
    case Integer.parse(count) do
      {int, ""} when int > 0 -> normalize_max_displays(int)
      _ -> nil
    end
  end

  defp normalize_max_displays(_), do: nil

  @doc false
  # A schedule far enough in the past to be a mistake is rejected rather than
  # silently sent now — a mistyped year should not fire immediately. A few
  # seconds of clock skew or round-trip lag is not a mistake, so anything
  # already due simply sends immediately (nil = no schedule).
  def normalize_deliver_at(value, now \\ DateTime.utc_now(:second))
  def normalize_deliver_at(nil, _now), do: nil
  def normalize_deliver_at("", _now), do: nil

  def normalize_deliver_at(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> normalize_deliver_at(datetime, now)
      _ -> :invalid
    end
  end

  def normalize_deliver_at(%DateTime{} = value, now) do
    value = DateTime.truncate(value, :second)

    cond do
      DateTime.compare(value, DateTime.add(now, -@schedule_grace_seconds, :second)) == :lt ->
        :invalid

      DateTime.compare(value, DateTime.add(now, @max_schedule_seconds, :second)) == :gt ->
        :invalid

      DateTime.compare(value, now) != :gt ->
        nil

      true ->
        value
    end
  end

  def normalize_deliver_at(_value, _now), do: :invalid

  ## Notifications (the pull side)

  @doc "Pending notifications for `user`, newest first, sender preloaded."
  def list_pending_notifications(%User{id: id}) do
    now = DateTime.utc_now(:second)

    from(n in Notification,
      join: e in assoc(n, :envelope),
      where:
        n.user_id == ^id and n.state == "pending" and
          (is_nil(e.expires_at) or e.expires_at > ^now) and
          (is_nil(e.max_displays) or e.display_count < e.max_displays),
      preload: [envelope: [:sender]],
      order_by: [desc: n.id]
    )
    |> Repo.all()
  end

  def count_pending_notifications(%User{id: id}) do
    now = DateTime.utc_now(:second)

    from(n in Notification,
      join: e in assoc(n, :envelope),
      where:
        n.user_id == ^id and n.state == "pending" and
          (is_nil(e.expires_at) or e.expires_at > ^now) and
          (is_nil(e.max_displays) or e.display_count < e.max_displays)
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  The recipient requests the data: only after this does the ciphertext move.

  For envelopes that originated on another instance, this is the moment the
  content is fetched from the origin server. If the origin is unreachable the
  notification stays pending so the user can retry.
  """
  def accept_notification(%User{} = user, id) do
    case Repo.get_by(Notification, id: id, user_id: user.id, state: "pending") do
      nil ->
        {:error, :not_found}

      notification ->
        envelope = Repo.preload(notification, envelope: [:sender]).envelope

        with false <- expired?(envelope),
             :ok <- maybe_fetch_remote_content(envelope) do
          # accepting opens/extends the active-conversation window
          touch_conversation(user.id, envelope.sender_id)

          case notification |> Ecto.Changeset.change(state: "accepted") |> Repo.update() do
            {:ok, updated} -> {:ok, Repo.preload(updated, [envelope: [:sender]], force: true)}
            error -> error
          end
        else
          true -> {:error, :not_found}
          error -> error
        end
    end
  end

  # Local envelopes already hold their ciphertext; remote stubs are empty
  # until the recipient asks.
  defp maybe_fetch_remote_content(%Envelope{ciphertext: ""} = envelope) do
    case Veejr.Federation.fetch_envelope_content(envelope) do
      {:ok, ciphertext, nonce} ->
        {:ok, _} =
          envelope
          |> Ecto.Changeset.change(ciphertext: ciphertext, nonce: nonce)
          |> Repo.update()

        :ok

      {:error, _reason} ->
        {:error, :origin_unreachable}
    end
  end

  defp maybe_fetch_remote_content(_envelope), do: :ok

  @doc "The recipient declines; the ciphertext is never served to them."
  def decline_notification(%User{} = user, id), do: set_notification_state(user, id, "declined")

  defp set_notification_state(%User{id: user_id}, id, state) do
    case Repo.get_by(Notification, id: id, user_id: user_id, state: "pending") do
      nil ->
        {:error, :not_found}

      notification ->
        notification
        |> Ecto.Changeset.change(state: state)
        |> Repo.update()
    end
  end

  ## Federation

  @doc """
  Records an incoming cross-instance announcement as a content-free stub
  envelope plus a pending notification. The ciphertext stays on the origin
  instance until the recipient accepts.
  """
  def receive_remote_notify(%User{} = remote_sender, %User{} = local_recipient, kind, public_id) do
    cond do
      kind not in Envelope.kinds() ->
        {:error, :bad_request}

      Repo.get_by(Envelope, public_id: public_id) ->
        # replay or duplicate delivery — already recorded
        {:ok, :duplicate}

      true ->
        participants = [Social.Address.handle(remote_sender)]

        envelope =
          Repo.insert!(%Envelope{
            public_id: public_id,
            batch_id: public_id,
            sender_id: remote_sender.id,
            recipient_id: local_recipient.id,
            kind: kind,
            ciphertext: "",
            nonce: "",
            sender_public_key: remote_sender.public_key,
            thread_key: conversation_key(participants),
            participants: Jason.encode!(participants)
          })

        # Active conversation: fetch the ciphertext now and auto-accept so it
        # lands straight in the chat. If the fetch fails, fall back to a
        # pending request the recipient can retry.
        state =
          if (conversation_active?(local_recipient.id, remote_sender.id) or
                automatic_delivery?(local_recipient, remote_sender)) and
               maybe_fetch_remote_content(Repo.preload(envelope, :sender)) == :ok do
            touch_conversation(local_recipient.id, remote_sender.id)
            "accepted"
          else
            "pending"
          end

        notification =
          Repo.insert!(%Notification{
            envelope_id: envelope.id,
            user_id: local_recipient.id,
            state: state
          })

        broadcast_notification(Repo.preload(notification, [:user, envelope: [:sender]]))
        {:ok, :created}
    end
  end

  @doc """
  Serves an envelope over the federation capability endpoint. Only envelopes
  addressed to remote recipients are ever served this way — local users read
  through their authenticated session. Possession of the unguessable
  public_id (delivered only to the recipient's instance) is the capability.
  """
  def get_public_envelope(public_id) do
    envelope =
      from(e in Envelope,
        join: r in assoc(e, :recipient),
        where: e.public_id == ^public_id and not is_nil(r.host)
      )
      |> Repo.one()

    cond do
      is_nil(envelope) -> {:error, :not_found}
      expired?(envelope) -> {:error, :not_found}
      true -> {:ok, mark_delivered(envelope)}
    end
  end

  @doc """
  The public key an envelope's ciphertext must be opened against, for `user`
  as the reader. Resealed envelopes use the reader's own current key; all
  others use the sender-key snapshot taken at send time, so history stays
  readable across key rotations.
  """
  def peer_key(%Envelope{resealed: true}, %User{} = user), do: user.public_key

  def peer_key(%Envelope{sender_id: uid, sender_public_key: snapshot}, %User{id: uid} = user),
    do: snapshot || user.public_key

  def peer_key(%Envelope{sender_public_key: snapshot} = envelope, _user),
    do: snapshot || envelope.sender.public_key

  ## Reading envelopes

  @doc """
  Fetches an envelope's ciphertext for `user`.

  Authorized when the user is the sender (their own copies) or an accepted
  recipient. Marks first delivery.
  """
  def fetch_envelope(%User{id: user_id}, public_id) do
    envelope =
      from(e in Envelope,
        where: e.public_id == ^public_id,
        left_join: n in assoc(e, :notification),
        preload: [:sender, :recipient, notification: n]
      )
      |> Repo.one()

    cond do
      is_nil(envelope) ->
        {:error, :not_found}

      # Expiry/display limits apply to every copy, including the sender's
      # own — checked before ownership so a self-copy cannot outlive them.
      expired?(envelope) ->
        {:error, :not_found}

      envelope.recipient_id == user_id and envelope.sender_id == user_id ->
        {:ok, envelope}

      envelope.recipient_id == user_id and accepted?(envelope.notification) ->
        {:ok, mark_delivered(envelope)}

      true ->
        {:error, :unauthorized}
    end
  end

  defp accepted?(%Notification{state: "accepted"}), do: true
  defp accepted?(_), do: false

  defp mark_delivered(%Envelope{delivered_at: nil} = envelope) do
    {:ok, envelope} =
      envelope
      |> Ecto.Changeset.change(delivered_at: DateTime.utc_now(:second))
      |> Repo.update()

    envelope
  end

  defp mark_delivered(envelope), do: envelope

  ## History

  @doc "Returns the stable key used to identify a conversation by participants."
  def conversation_key(participants) when is_list(participants) do
    participants
    |> Enum.sort()
    |> Enum.join("|")
    |> then(fn value -> :crypto.hash(:md5, value) end)
    |> Base.url_encode64(padding: false)
  end

  @doc "Lists the current user's archived conversations, newest archive first."
  def list_archived_conversations(%User{id: user_id}) do
    from(a in ConversationArchive,
      where: a.user_id == ^user_id and a.archived,
      order_by: [desc: a.updated_at]
    )
    |> Repo.all()
    |> Enum.map(fn archive ->
      %{
        key: archive.conversation_key,
        participant_key: archive.participant_key,
        participants: decode_participants(archive.participants),
        started_at: archive.started_at,
        archived: archive.archived,
        archived_at: archive.updated_at
      }
    end)
  end

  @doc "The user's conversation-instance records, keyed by conversation key."
  def list_thread_archives(%User{id: user_id}) do
    from(a in ConversationArchive, where: a.user_id == ^user_id)
    |> Repo.all()
    |> Map.new(&{&1.conversation_key, &1})
  end

  @doc """
  Archives one conversation instance without hiding later messages from the
  same people. A current conversation is frozen by stamping its member
  envelopes with a fresh instance key, so a future exchange with the same
  participants starts a new thread under the original participant key.
  """
  def archive_conversation(%User{id: user_id}, key) when is_binary(key) do
    case Repo.get_by(ConversationArchive, user_id: user_id, conversation_key: key) do
      %ConversationArchive{} = archive ->
        archive
        |> ConversationArchive.changeset(%{archived: true})
        |> Repo.update()

      nil ->
        Repo.transaction(fn ->
          first =
            from(e in Envelope,
              where: e.recipient_id == ^user_id and e.thread_key == ^key,
              order_by: [asc: e.id],
              limit: 1
            )
            |> Repo.one()

          if is_nil(first), do: Repo.rollback(:invalid_conversation)

          archive_key = archived_conversation_key(key, first.inserted_at, [first.public_id])

          archive =
            %ConversationArchive{}
            |> ConversationArchive.changeset(%{
              user_id: user_id,
              conversation_key: archive_key,
              participant_key: key,
              participants: first.participants,
              envelope_ids: "[]",
              started_at: first.inserted_at,
              archived: true
            })
            |> Repo.insert()
            |> case do
              {:ok, archive} -> archive
              {:error, changeset} -> Repo.rollback(changeset)
            end

          from(e in Envelope,
            where: e.recipient_id == ^user_id and e.thread_key == ^key
          )
          |> Repo.update_all(set: [thread_key: archive_key])

          archive
        end)
    end
  end

  @doc "Makes an archived conversation visible while retaining its boundary."
  def unarchive_conversation(%User{id: user_id}, key) when is_binary(key) do
    case Repo.get_by(ConversationArchive,
           user_id: user_id,
           conversation_key: key,
           archived: true
         ) do
      nil ->
        {:error, :not_archived}

      archive ->
        archive
        |> ConversationArchive.changeset(%{archived: false})
        |> Repo.update!()

        :ok
    end
  end

  @doc """
  Conversation summaries for the current user, newest activity first — one
  row per thread, plus the newest envelope for the client-side preview.
  Every kind participates: messages, location shares, and geo-notes are all
  first-class conversation items. Includes archived instances; callers
  overlay `list_thread_archives/1` to filter or label them.
  """
  def list_conversation_summaries(%User{id: id}) do
    now = DateTime.utc_now(:second)

    summaries =
      from(e in Envelope,
        left_join: n in assoc(e, :notification),
        where:
          e.recipient_id == ^id and not is_nil(e.thread_key) and
            (e.sender_id == ^id or n.state == "accepted") and
            (is_nil(e.expires_at) or e.expires_at > ^now) and
            (is_nil(e.max_displays) or e.display_count < e.max_displays),
        group_by: [e.thread_key, e.participants],
        order_by: [desc: max(e.id)],
        select: %{
          key: e.thread_key,
          participants: e.participants,
          message_count: count(e.id),
          unread_count: filter(count(e.id), e.sender_id != ^id and is_nil(e.read_at)),
          latest_id: max(e.id),
          latest_at: type(max(e.inserted_at), :utc_datetime),
          started_at: type(min(e.inserted_at), :utc_datetime)
        }
      )
      |> Repo.all()

    latest_envelopes =
      from(e in Envelope,
        where: e.recipient_id == ^id and e.id in ^Enum.map(summaries, & &1.latest_id),
        preload: [:sender]
      )
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.map(summaries, fn summary ->
      summary
      |> Map.update!(:participants, &decode_participants/1)
      |> Map.put(:latest_envelope, latest_envelopes[summary.latest_id])
    end)
  end

  @doc "Marks every accepted incoming item in a conversation as read."
  def mark_conversation_read(%User{id: id}, thread_key) when is_binary(thread_key) do
    now = DateTime.utc_now(:second)

    from(e in Envelope,
      left_join: n in assoc(e, :notification),
      where:
        e.recipient_id == ^id and e.sender_id != ^id and e.thread_key == ^thread_key and
          n.state == "accepted" and is_nil(e.read_at)
    )
    |> Repo.update_all(set: [read_at: now])

    :ok
  end

  @doc "Marks accepted incoming items in the selected conversations as read."
  def mark_conversations_read(%User{id: id}, thread_keys) when is_list(thread_keys) do
    keys = thread_keys |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.take(100)
    now = DateTime.utc_now(:second)

    {count, _} =
      from(e in Envelope,
        left_join: n in assoc(e, :notification),
        where:
          e.recipient_id == ^id and e.sender_id != ^id and e.thread_key in ^keys and
            n.state == "accepted" and is_nil(e.read_at)
      )
      |> Repo.update_all(set: [read_at: now])

    {:ok, count}
  end

  @doc "Archives several owner-visible conversation instances as one operation."
  def archive_conversations(%User{} = user, thread_keys) when is_list(thread_keys) do
    keys = thread_keys |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.take(100)

    Repo.transaction(fn ->
      Enum.map(keys, fn key ->
        case archive_conversation(user, key) do
          {:ok, archive} -> archive
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end)
  end

  @doc """
  The newest page of one conversation's envelopes — all kinds, returned
  oldest-first for display. `:limit` bounds the page; older rows load by
  raising it.
  """
  def list_thread_envelopes(%User{id: id}, thread_key, opts \\ [])
      when is_binary(thread_key) do
    now = DateTime.utc_now(:second)

    query =
      from(e in Envelope,
        left_join: n in assoc(e, :notification),
        where:
          e.recipient_id == ^id and e.thread_key == ^thread_key and
            (e.sender_id == ^id or n.state == "accepted") and
            (is_nil(e.expires_at) or e.expires_at > ^now) and
            (is_nil(e.max_displays) or e.display_count < e.max_displays),
        preload: [:sender],
        order_by: [desc: e.id]
      )

    query =
      case opts[:limit] do
        nil -> query
        limit -> limit(query, ^limit)
      end

    query |> Repo.all() |> Enum.reverse()
  end

  @doc """
  Returns the owner's encrypted board items — note cards and documents alike —
  newest edit first.

  Notes and documents share one board and one query because they are the same
  owner-only envelope shape; only the encrypted payload differs. Pass `:kinds`
  to narrow to one of them.
  """
  def list_self_envelopes(%User{id: id}, opts \\ []) do
    kinds = self_kinds_option(opts)

    query =
      from(e in Envelope,
        where: e.sender_id == ^id and e.recipient_id == ^id and e.kind in ^kinds,
        preload: [:sender],
        order_by: [desc: e.edited_at, desc: e.inserted_at, desc: e.id]
      )

    query =
      case Keyword.get(opts, :limit, 50) do
        :all -> query
        limit when is_integer(limit) -> limit(query, ^max(limit, 1))
        _ -> limit(query, 50)
      end

    query
    |> Repo.all()
  end

  @doc "Counts the owner's board items without loading their ciphertext."
  def count_self_envelopes(%User{id: id}, opts \\ []) do
    kinds = self_kinds_option(opts)

    from(e in Envelope,
      where: e.sender_id == ^id and e.recipient_id == ^id and e.kind in ^kinds
    )
    |> Repo.aggregate(:count)
  end

  defp self_kinds_option(opts) do
    case Keyword.get(opts, :kinds) do
      nil -> Envelope.self_kinds()
      kinds when is_list(kinds) -> Enum.filter(kinds, &Envelope.self_kind?/1)
      kind when is_binary(kind) -> Enum.filter([kind], &Envelope.self_kind?/1)
    end
  end

  @doc "Returns legacy self-addressed messages that a browser may copy into self notes."
  def list_legacy_self_messages(%User{id: id}) do
    from(e in Envelope,
      where: e.sender_id == ^id and e.recipient_id == ^id and e.kind == "message",
      preload: [:sender],
      order_by: [asc: e.inserted_at, asc: e.id]
    )
    |> Repo.all()
  end

  @doc """
  Everything `user` can decrypt, newest first: their own self-copies (sent
  items) and received envelopes they accepted. Filterable by `:kind`.
  """
  def list_history(%User{id: id}, opts \\ []) do
    now = DateTime.utc_now(:second)

    query =
      from(e in Envelope,
        left_join: n in assoc(e, :notification),
        where:
          e.recipient_id == ^id and
            (e.sender_id == ^id or n.state == "accepted") and
            (is_nil(e.expires_at) or e.expires_at > ^now) and
            (is_nil(e.max_displays) or e.display_count < e.max_displays),
        preload: [:sender],
        order_by: [desc: e.id]
      )

    query =
      case opts[:kind] do
        nil -> query
        kind -> where(query, [e], e.kind == ^kind)
      end

    query =
      case opts[:before_id] do
        nil -> query
        before_id -> where(query, [e], e.id < ^before_id)
      end

    query =
      case opts[:limit] do
        nil -> query
        limit -> limit(query, ^limit)
      end

    Repo.all(query)
  end

  @doc "Returns an envelope id usable as a history cursor only when it belongs to `user`."
  def history_cursor_id(%User{id: user_id}, public_id) when is_binary(public_id) do
    from(e in Envelope,
      where: e.recipient_id == ^user_id and e.public_id == ^public_id,
      select: e.id
    )
    |> Repo.one()
  end

  defp expired?(%Envelope{expires_at: %DateTime{} = expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now(:second)) != :gt
  end

  defp expired?(%Envelope{max_displays: max, display_count: count})
       when is_integer(max) and is_integer(count) do
    count >= max
  end

  defp expired?(_), do: false

  defp decode_participants(value) do
    case Jason.decode(value) do
      {:ok, participants} when is_list(participants) -> participants
      _ -> []
    end
  end

  @doc false
  # Instance key for an archived conversation: the participant key plus the
  # thread's start time and a digest of its first envelope id. Also used by
  # the thread-key backfill migration.
  def archived_conversation_key(participant_key, started_at, [first_envelope_id | _]) do
    date = Calendar.strftime(started_at, "%Y%m%dT%H%M%S")

    suffix =
      :crypto.hash(:sha256, first_envelope_id)
      |> binary_part(0, 6)
      |> Base.url_encode64(padding: false)

    "#{participant_key}-#{date}-#{suffix}"
  end

  ## Message delivery policies

  def list_delivery_policies(%User{id: user_id}) do
    from(p in MessageDeliveryPolicy,
      where: p.user_id == ^user_id,
      order_by: [asc: p.subject_type, asc: p.subject_id]
    )
    |> Repo.all()
  end

  def put_delivery_policy(%User{} = user, subject_type, subject_id, attrs)
      when subject_type in ~w(contact group conversation) do
    with {:ok, subject_id} <- parse_policy_subject_id(subject_id),
         :ok <- authorize_policy_subject(user, subject_type, subject_id) do
      policy =
        Repo.get_by(MessageDeliveryPolicy,
          user_id: user.id,
          subject_type: subject_type,
          subject_id: subject_id
        ) ||
          %MessageDeliveryPolicy{
            user_id: user.id,
            subject_type: subject_type,
            subject_id: subject_id
          }

      policy
      |> MessageDeliveryPolicy.changeset(attrs)
      |> Repo.insert_or_update()
    end
  end

  def put_delivery_policy(_user, _subject_type, _subject_id, _attrs),
    do: {:error, :not_found}

  def delete_delivery_policy(%User{id: user_id} = user, subject_type, subject_id) do
    with {:ok, subject_id} <- parse_policy_subject_id(subject_id),
         :ok <- authorize_policy_subject(user, subject_type, subject_id) do
      from(p in MessageDeliveryPolicy,
        where:
          p.user_id == ^user_id and p.subject_type == ^subject_type and
            p.subject_id == ^subject_id
      )
      |> Repo.delete_all()

      :ok
    end
  end

  @doc "Returns whether `sender` may bypass the recipient's per-message consent prompt."
  def automatic_delivery?(%User{} = recipient, %User{} = sender) do
    if Social.friends?(recipient.id, sender.id) and is_nil(sender.pending_public_key) do
      case direct_policy(recipient.id, sender.id, "conversation") do
        %MessageDeliveryPolicy{acceptance: acceptance} -> acceptance == "automatic"
        nil -> contact_or_group_automatic?(recipient.id, sender.id)
      end
    else
      false
    end
  end

  def delivery_notification_mode(%User{} = recipient, %User{} = sender) do
    case effective_delivery_policy(recipient.id, sender.id) do
      %MessageDeliveryPolicy{notification: notification} -> notification
      nil -> "normal"
    end
  end

  defp effective_delivery_policy(recipient_id, sender_id) do
    direct_policy(recipient_id, sender_id, "conversation") ||
      direct_policy(recipient_id, sender_id, "contact") ||
      effective_group_policy(recipient_id, sender_id)
  end

  defp contact_or_group_automatic?(recipient_id, sender_id) do
    case direct_policy(recipient_id, sender_id, "contact") do
      %MessageDeliveryPolicy{acceptance: acceptance} ->
        acceptance == "automatic"

      nil ->
        policies = group_policies(recipient_id, sender_id)
        policies != [] and Enum.all?(policies, &(&1.acceptance == "automatic"))
    end
  end

  defp effective_group_policy(recipient_id, sender_id) do
    policies = group_policies(recipient_id, sender_id)

    Enum.find(policies, &(&1.acceptance == "ask")) ||
      Enum.find(policies, &(&1.notification != "silent")) ||
      List.first(policies)
  end

  defp direct_policy(user_id, subject_id, subject_type) do
    Repo.get_by(MessageDeliveryPolicy,
      user_id: user_id,
      subject_type: subject_type,
      subject_id: subject_id
    )
  end

  defp group_policies(user_id, sender_id) do
    from(p in MessageDeliveryPolicy,
      join: g in Veejr.Social.Group,
      on: g.id == p.subject_id,
      join: gm in Veejr.Social.GroupMember,
      on: gm.group_id == g.id,
      where:
        p.user_id == ^user_id and p.subject_type == "group" and g.owner_id == ^user_id and
          gm.user_id == ^sender_id
    )
    |> Repo.all()
  end

  defp parse_policy_subject_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp parse_policy_subject_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :not_found}
    end
  end

  defp parse_policy_subject_id(_id), do: {:error, :not_found}

  defp authorize_policy_subject(user, subject_type, subject_id)
       when subject_type in ~w(contact conversation) do
    if Social.friends?(user.id, subject_id), do: :ok, else: {:error, :not_found}
  end

  defp authorize_policy_subject(user, "group", subject_id) do
    case Social.get_owned_group(user, subject_id) do
      %Veejr.Social.Group{} -> :ok
      _ -> {:error, :not_found}
    end
  end

  defp authorize_policy_subject(_user, _subject_type, _subject_id),
    do: {:error, :not_found}

  @doc """
  Records a successful client-side display of an envelope visible to `user`.
  Display-limited messages disappear from that user's history after the
  configured count is reached.
  """
  def record_display(%User{id: user_id}, public_id) when is_binary(public_id) do
    envelope =
      from(e in Envelope,
        where: e.public_id == ^public_id and e.recipient_id == ^user_id,
        left_join: n in assoc(e, :notification),
        preload: [notification: n]
      )
      |> Repo.one()

    cond do
      is_nil(envelope) ->
        {:error, :not_found}

      envelope.sender_id != user_id and not accepted?(envelope.notification) ->
        {:error, :unauthorized}

      is_nil(envelope.max_displays) ->
        {:ok, envelope}

      expired?(envelope) ->
        {:ok, envelope}

      true ->
        _updated =
          from(e in Envelope,
            where:
              e.id == ^envelope.id and e.display_count < ^envelope.max_displays and
                (is_nil(e.expires_at) or e.expires_at > ^DateTime.utc_now(:second))
          )
          |> Repo.update_all(inc: [display_count: 1])

        {:ok, Repo.get!(Envelope, envelope.id)}
    end
  end

  @doc """
  Metadata the browser needs to re-encrypt a sent batch edit.
  """
  def editable_batch(%User{id: user_id} = user, public_id) when is_binary(public_id) do
    with %Envelope{} = envelope <- Repo.get_by(Envelope, public_id: public_id, sender_id: user_id) do
      copies =
        from(e in Envelope,
          join: r in assoc(e, :recipient),
          where: e.sender_id == ^user_id and e.batch_id == ^envelope.batch_id,
          select: %{
            public_id: e.public_id,
            recipient_id: r.id,
            public_key: r.public_key,
            handle:
              fragment("CASE WHEN ? IS NULL THEN ? ELSE ? END", r.host, r.username, r.username)
          },
          order_by: [asc: e.id]
        )
        |> Repo.all()

      {:ok,
       %{
         batch_id: envelope.batch_id,
         copies: copies,
         current: %{
           public_id: envelope.public_id,
           ciphertext: envelope.ciphertext,
           nonce: envelope.nonce,
           peer_key: peer_key(envelope, user),
           updated_at: DateTime.to_iso8601(envelope.updated_at)
         }
       }}
    else
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Replaces every copy in a sent batch with ciphertext produced in the browser.
  The server validates ownership and copy ids but never sees plaintext.
  """
  def edit_sent_batch(%User{id: user_id} = user, public_id, entries, opts \\ [])
      when is_binary(public_id) do
    expected_updated_at = normalize_expected_updated_at(opt(opts, :expected_updated_at))

    with %Envelope{} = envelope <- Repo.get_by(Envelope, public_id: public_id, sender_id: user_id),
         true <- expected_updated_at?(envelope.updated_at, expected_updated_at),
         true <- is_list(entries) do
      now = DateTime.utc_now(:second)

      Repo.transaction(fn ->
        link_batch_blobs!(
          user,
          envelope.batch_id,
          normalize_attachment_ids(opt(opts, :attachment_ids))
        )

        for entry <- entries, reduce: 0 do
          count ->
            entry_public_id = entry["public_id"] || entry[:public_id]

            {updated, _} =
              from(e in Envelope,
                where:
                  e.sender_id == ^user_id and e.batch_id == ^envelope.batch_id and
                    e.public_id == ^entry_public_id
              )
              |> Repo.update_all(
                set: [
                  ciphertext: entry["ciphertext"] || entry[:ciphertext],
                  nonce: entry["nonce"] || entry[:nonce],
                  edited_at: now,
                  updated_at: now
                ]
              )

            count + updated
        end
      end)
      |> case do
        {:ok, count} when count > 0 -> {:ok, count}
        {:ok, _} -> {:error, :not_found}
        error -> error
      end
    else
      nil -> {:error, :not_found}
      false -> {:error, :stale}
      _ -> {:error, :bad_request}
    end
  end

  defp normalize_expected_updated_at(nil), do: nil

  defp normalize_expected_updated_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _ -> :invalid
    end
  end

  defp normalize_expected_updated_at(_), do: :invalid

  defp expected_updated_at?(_actual, nil), do: true
  defp expected_updated_at?(_actual, :invalid), do: false

  defp expected_updated_at?(actual, expected),
    do: DateTime.compare(DateTime.truncate(actual, :second), expected) == :eq

  @doc """
  Removes an envelope from the user's visible history.

  Senders delete the whole batch permanently, including copies that have not
  yet been fetched by remote recipients. Recipients keep the ciphertext from
  being displayed again by moving their notification to `declined`.
  """
  def delete_envelope(%User{id: user_id}, public_id) when is_binary(public_id) do
    envelope =
      from(e in Envelope,
        where: e.public_id == ^public_id,
        left_join: n in assoc(e, :notification),
        preload: [notification: n]
      )
      |> Repo.one()

    cond do
      is_nil(envelope) ->
        {:error, :not_found}

      envelope.sender_id == user_id ->
        Repo.transaction(fn ->
          {count, _} =
            from(e in Envelope,
              where: e.sender_id == ^user_id and e.batch_id == ^envelope.batch_id
            )
            |> Repo.delete_all()

          release_batch_blobs!(user_id, envelope.batch_id)
          {:deleted, count}
        end)

      envelope.recipient_id == user_id and not is_nil(envelope.notification) ->
        envelope.notification
        |> Ecto.Changeset.change(state: "declined")
        |> Repo.update()
        |> case do
          {:ok, _notification} -> {:ok, :hidden}
          error -> error
        end

      true ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Permanently removes one owner-only board item — a note or a document — and
  never an envelope of any other kind.
  """
  def delete_self_item(%User{id: user_id} = user, public_id) when is_binary(public_id) do
    case self_item(user_id, public_id) do
      nil -> {:error, :not_found}
      _envelope -> delete_envelope(user, public_id)
    end
  end

  @doc """
  For a batch the user sent: who else received it (handles like `@bob` or
  `@carol@other.host`), so the sent view can say who it went to.
  """
  def batch_recipients(%User{id: id}, batch_id) do
    from(e in Envelope,
      join: u in assoc(e, :recipient),
      where: e.batch_id == ^batch_id and e.sender_id == ^id and e.recipient_id != ^id,
      select: %{username: u.username, host: u.host},
      order_by: u.username
    )
    |> Repo.all()
    |> Enum.map(&Veejr.Social.Address.handle/1)
  end

  ## Key rotation support

  @doc """
  Everything the user can decrypt, in the shape the rotation hook needs to
  re-encrypt it: ciphertext + the key it must be opened against.
  """
  def list_resealable(%User{} = user) do
    for envelope <- list_history(user) do
      %{
        public_id: envelope.public_id,
        kind: envelope.kind,
        ciphertext: envelope.ciphertext,
        nonce: envelope.nonce,
        peer_key: peer_key(envelope, user)
      }
    end
  end

  @doc """
  Replaces ciphertext with copies re-encrypted (client-side) to the user's
  new key. Only the user's own received/self copies are touched.
  """
  def reseal_envelopes(%User{id: user_id}, entries) when is_list(entries) do
    {:ok, count} =
      Repo.transaction(fn ->
        for entry <- entries, reduce: 0 do
          count ->
            public_id = entry["public_id"] || entry[:public_id]

            {n, _} =
              from(e in Envelope, where: e.public_id == ^public_id and e.recipient_id == ^user_id)
              |> Repo.update_all(
                set: [
                  ciphertext: entry["ciphertext"] || entry[:ciphertext],
                  nonce: entry["nonce"] || entry[:nonce],
                  resealed: true
                ]
              )

            count + n
        end
      end)

    {:ok, count}
  end

  @doc """
  Deletes every envelope copy addressed to the user (key reset: they are
  undecryptable forever). Copies held by other recipients are untouched.
  """
  def purge_received_envelopes(%User{id: user_id}) do
    {count, _} = from(e in Envelope, where: e.recipient_id == ^user_id) |> Repo.delete_all()
    {:ok, count}
  end

  ## Blobs (encrypted attachments)

  def max_blob_size, do: Veejr.InstanceSettings.max_upload_bytes()

  @doc """
  Stores an already-encrypted attachment body and returns the blob. The
  content is opaque to the server; the decryption key travels inside the
  message envelope.
  """
  def create_blob(%User{} = owner, binary) when is_binary(binary) do
    cond do
      byte_size(binary) > max_blob_size() ->
        {:error, :too_large}

      storage_quota_exceeded?(byte_size(binary)) ->
        {:error, :storage_quota_exceeded}

      true ->
        public_id = random_id()
        dir = blob_dir()
        File.mkdir_p!(dir)
        path = Path.join(dir, public_id <> ".bin")
        File.write!(path, binary)

        case Repo.insert(%Blob{
               public_id: public_id,
               owner_id: owner.id,
               size: byte_size(binary),
               path: path,
               reference_tracking: true
             }) do
          {:ok, blob} ->
            {:ok, blob}

          {:error, _changeset} = error ->
            File.rm(path)
            error
        end
    end
  end

  defp storage_quota_exceeded?(incoming_bytes) do
    case Veejr.InstanceSettings.storage_quota_bytes() do
      nil -> false
      quota -> (Repo.aggregate(Blob, :sum, :size) || 0) + incoming_bytes > quota
    end
  end

  @doc """
  Looks up a blob by its unguessable id. Possession of the id is the
  capability: the id only ever travels inside encrypted envelopes, and the
  content is itself ciphertext.
  """
  def get_blob(public_id) do
    Repo.get_by(Blob, public_id: public_id)
  end

  @doc """
  Filesystem location of a blob's encrypted bytes. Files are always written
  as `<public_id>.bin` inside `blob_dir/0`, so the path is derived from the
  *current* directory setting — relocating `VEEJR_BLOB_DIR` keeps existing
  rows servable. The recorded absolute path is only a fallback for files
  that were not moved along with the directory.
  """
  def blob_file_path(%Blob{} = blob) do
    derived = Path.join(blob_dir(), blob.public_id <> ".bin")
    if File.exists?(derived), do: derived, else: blob.path
  end

  @doc "Purges tracked uploads left unattached for more than 24 hours. Legacy blobs are excluded."
  def purge_abandoned_blobs do
    cutoff = DateTime.add(DateTime.utc_now(:second), -24, :hour)
    referenced_blob_ids = from(r in BlobReference, select: r.blob_id)

    blobs =
      Repo.all(
        from(b in Blob,
          where:
            b.reference_tracking == true and b.inserted_at < ^cutoff and
              b.id not in subquery(referenced_blob_ids)
        )
      )

    Enum.reduce(blobs, %{files: 0, bytes: 0}, fn blob, totals ->
      case File.rm(blob_file_path(blob)) do
        :ok ->
          Repo.delete!(blob)
          %{files: totals.files + 1, bytes: totals.bytes + blob.size}

        {:error, :enoent} ->
          Repo.delete!(blob)
          %{files: totals.files + 1, bytes: totals.bytes + blob.size}

        {:error, _reason} ->
          totals
      end
    end)
  end

  defp normalize_attachment_ids(nil), do: []

  defp normalize_attachment_ids(ids) when is_list(ids) and length(ids) <= 20 do
    if Enum.all?(ids, &(is_binary(&1) and byte_size(&1) >= 16 and byte_size(&1) <= 100)) and
         length(Enum.uniq(ids)) == length(ids) do
      ids
    else
      Repo.rollback(:invalid_attachments)
    end
  end

  defp normalize_attachment_ids(_), do: Repo.rollback(:invalid_attachments)

  defp link_batch_blobs!(_owner, _batch_id, []), do: :ok

  defp link_batch_blobs!(%User{id: owner_id}, batch_id, public_ids) do
    blobs =
      Repo.all(
        from(b in Blob,
          where: b.owner_id == ^owner_id and b.public_id in ^public_ids
        )
      )

    if length(blobs) != length(public_ids), do: Repo.rollback(:invalid_attachments)

    now = DateTime.utc_now(:second)

    Repo.insert_all(
      BlobReference,
      Enum.map(blobs, fn blob ->
        %{blob_id: blob.id, batch_id: batch_id, inserted_at: now, updated_at: now}
      end),
      on_conflict: :nothing,
      conflict_target: [:blob_id, :batch_id]
    )

    :ok
  end

  defp release_batch_blobs!(owner_id, batch_id) do
    blobs =
      Repo.all(
        from(b in Blob,
          join: r in BlobReference,
          on: r.blob_id == b.id,
          where: r.batch_id == ^batch_id and b.owner_id == ^owner_id
        )
      )

    blob_ids = Enum.map(blobs, & &1.id)

    Repo.delete_all(
      from(r in BlobReference, where: r.batch_id == ^batch_id and r.blob_id in ^blob_ids)
    )

    Enum.each(blobs, fn blob ->
      unless Repo.exists?(from(r in BlobReference, where: r.blob_id == ^blob.id)) do
        case File.rm(blob_file_path(blob)) do
          :ok -> Repo.delete!(blob)
          {:error, :enoent} -> Repo.delete!(blob)
          {:error, _reason} -> :ok
        end
      end
    end)
  end

  @doc """
  Removes a user's blob files from disk (rows go with the user via FK
  cascade, files don't).
  """
  def purge_blob_files(%User{id: id}) do
    for blob <- Repo.all(from(b in Blob, where: b.owner_id == ^id)) do
      File.rm(blob_file_path(blob))
    end

    :ok
  end

  def blob_dir do
    Application.get_env(
      :veejr,
      :blob_dir,
      Path.join(Application.app_dir(:veejr, "priv"), "uploads")
    )
  end

  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
end
