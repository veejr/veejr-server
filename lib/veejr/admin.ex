defmodule Veejr.Admin do
  @moduledoc "Operational information and guarded instance administration actions."

  import Ecto.Query, warn: false

  alias Veejr.Accounts.{ApiDeviceSession, Invitation, User, UserToken}
  alias Veejr.Accounts.UserNotifier
  alias Veejr.Admin.AuditEvent
  alias Veejr.Federation.Outbox
  alias Veejr.Federation.Outbox.Delivery
  alias Veejr.Federation.Peers.Peer
  alias Veejr.Messaging.{Blob, Envelope, Notification}
  alias Veejr.{Features, InstanceSettings, Operations}
  alias Veejr.Repo

  @max_craps_chips 1_000_000

  @doc "Returns a content-free snapshot of instance usage and health."
  def snapshot do
    now = DateTime.utc_now(:second)
    week_ago = DateTime.add(now, -7, :day)

    {blob_count, blob_bytes} =
      Repo.one(from(b in Blob, select: {count(b.id), coalesce(sum(b.size), 0)}))

    %{
      captured_at: now,
      users: %{
        local: Repo.aggregate(from(u in User, where: is_nil(u.host)), :count),
        remote: Repo.aggregate(from(u in User, where: not is_nil(u.host)), :count),
        joined_last_7_days:
          Repo.aggregate(
            from(u in User, where: is_nil(u.host) and u.inserted_at >= ^week_ago),
            :count
          )
      },
      data: %{
        envelopes: Repo.aggregate(Envelope, :count),
        blobs: blob_count,
        blob_bytes: blob_bytes,
        pending_notifications:
          Repo.aggregate(from(n in Notification, where: n.state == "pending"), :count)
      },
      operations: %{
        active_invitations:
          Repo.aggregate(
            from(i in Invitation,
              where: is_nil(i.accepted_at) and is_nil(i.revoked_at) and i.expires_at > ^now
            ),
            :count
          ),
        federation_queue: Outbox.pending_count(),
        email_failures: Operations.count_failures("email"),
        pending_key_changes:
          Repo.aggregate(
            from(u in User, where: not is_nil(u.host) and not is_nil(u.pending_public_key)),
            :count
          ),
        pinned_peers: Repo.aggregate(Peer, :count)
      },
      health: %{
        database: database_health(),
        endpoint: process_health(VeejrWeb.Endpoint),
        federation_outbox: process_health(Outbox)
      },
      software: %{
        veejr: Veejr.version(),
        elixir: System.version(),
        otp: System.otp_release(),
        database: database_version()
      }
    }
  end

  @doc "Lists the most recent tracked invitations with their participants."
  def list_invitations(limit \\ 50) do
    Repo.all(
      from(i in Invitation,
        order_by: [desc: i.inserted_at, desc: i.id],
        limit: ^limit,
        preload: [:inviter, :accepted_by, :revoked_by]
      )
    )
  end

  @doc "Lists local accounts with content-free session counts."
  def list_local_accounts do
    web_sessions =
      from(t in UserToken,
        where: t.context == "session",
        group_by: t.user_id,
        select: %{
          user_id: t.user_id,
          count: count(t.id),
          last_authenticated_at: max(t.authenticated_at)
        }
      )

    device_sessions =
      from(s in ApiDeviceSession,
        group_by: s.user_id,
        select: %{
          user_id: s.user_id,
          count: count(s.id),
          last_used_at: max(s.last_used_at)
        }
      )

    storage =
      from(b in Blob,
        group_by: b.owner_id,
        select: %{user_id: b.owner_id, bytes: sum(b.size)}
      )

    Repo.all(
      from(u in User,
        where: is_nil(u.host),
        left_join: web in subquery(web_sessions),
        on: web.user_id == u.id,
        left_join: device in subquery(device_sessions),
        on: device.user_id == u.id,
        left_join: stored in subquery(storage),
        on: stored.user_id == u.id,
        order_by: [asc: u.inserted_at, asc: u.id],
        select: %{
          user: u,
          web_sessions: coalesce(web.count, 0),
          last_web_authenticated_at: web.last_authenticated_at,
          device_sessions: coalesce(device.count, 0),
          last_device_used_at: device.last_used_at,
          storage_bytes: coalesce(stored.bytes, 0)
        }
      )
    )
  end

  @doc "Lists the most recent append-only administrator actions."
  def list_audit_events(limit \\ 50) do
    Repo.all(
      from(event in AuditEvent,
        order_by: [desc: event.inserted_at, desc: event.id],
        limit: ^limit,
        preload: [:actor]
      )
    )
  end

  @doc "Lists pinned federation peers for instance administration."
  def list_peers do
    pending =
      from(d in Delivery,
        group_by: d.authority,
        select: %{
          authority: d.authority,
          count: count(d.id),
          attempts: max(d.attempts),
          last_error: max(d.last_error)
        }
      )

    Repo.all(
      from(peer in Peer,
        left_join: pending in subquery(pending),
        on: pending.authority == peer.authority,
        order_by: [asc: peer.authority],
        select: %{
          peer: peer,
          pending_deliveries: coalesce(pending.count, 0),
          delivery_attempts: coalesce(pending.attempts, 0),
          last_error: pending.last_error
        }
      )
    )
  end

  def list_operational_failures, do: Operations.list_failures()

  def list_pending_key_changes do
    Repo.all(
      from(u in User,
        where: not is_nil(u.host) and not is_nil(u.pending_public_key),
        order_by: [asc: u.host, asc: u.username]
      )
    )
  end

  def change_instance_settings(attrs \\ %{}),
    do: InstanceSettings.change(InstanceSettings.get(), attrs)

  def update_instance_settings(%User{} = actor, attrs) do
    if Veejr.Accounts.instance_admin?(actor) do
      changeset = change_instance_settings(attrs)
      changed_fields = changeset.changes |> Map.keys() |> Enum.reject(&(&1 in [:updated_at]))

      Repo.transaction(fn ->
        case Repo.update(changeset) do
          {:ok, settings} ->
            audit!(actor, "instance.settings_updated", "instance", 1, %{
              "fields" => Enum.map(changed_fields, &to_string/1)
            })

            settings

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Turns the instance's interface controls on and off.

  Separate from `update_instance_settings/2` because features are a catalogue
  in code rather than a column each: the whole set is normalised against
  `Veejr.Features` and written as one map, so a new control ships without a
  migration and an unknown id submitted here is dropped rather than stored.

  The audit entry records what ended up **off** rather than what changed. The
  question anyone reads this log to answer is which controls this instance is
  currently hiding, and the switched-off list answers it from a single row.
  """
  def update_features(%User{} = actor, params) when is_map(params) do
    if Veejr.Accounts.instance_admin?(actor) do
      changeset =
        InstanceSettings.get()
        |> Ecto.Changeset.change(features: Features.normalize(params))

      Repo.transaction(fn ->
        case Repo.update(changeset) do
          {:ok, settings} ->
            audit!(actor, "instance.features_updated", "instance", 1, %{
              "off" => settings |> Features.disabled_ids() |> Enum.map(&to_string/1)
            })

            settings

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Sets a member's craps stack.

  The add-on tops a broke player back up on its own when they sit, so this is
  for the cases that does not cover: somebody who wants a bigger stack than
  the house default, or a table whose play money has drifted somewhere silly.

  Audited like every other thing an administrator can do to an account, and
  capped so a slipped keystroke cannot mint a fortune.
  """
  @spec set_craps_chips(User.t(), integer(), integer()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found | :not_local | :invalid_amount}
  def set_craps_chips(%User{} = actor, user_id, amount) do
    cond do
      not Veejr.Accounts.instance_admin?(actor) ->
        {:error, :unauthorized}

      not (is_integer(amount) and amount >= 0 and amount <= @max_craps_chips) ->
        {:error, :invalid_amount}

      true ->
        case Repo.get(User, user_id) do
          nil ->
            {:error, :not_found}

          # A remote account's stack belongs to their own instance.
          %User{host: host} when not is_nil(host) ->
            {:error, :not_local}

          user ->
            Veejr.AddOns.Craps.put_chip_balance(user.id, amount)
            audit!(actor, "craps.chips_set", "user", user.id, %{"chips" => amount})
            {:ok, user}
        end
    end
  end

  @doc "The largest stack an administrator may hand out in one go."
  def max_craps_chips, do: @max_craps_chips

  @doc "Returns the current lifecycle state of a tracked invitation."
  def invitation_status(%Invitation{} = invitation, now \\ DateTime.utc_now(:second)) do
    cond do
      invitation.accepted_at -> :accepted
      invitation.revoked_at -> :revoked
      DateTime.after?(invitation.expires_at, now) -> :active
      true -> :expired
    end
  end

  @doc "Revokes an active invitation. Only the permanent administrator may do this."
  def revoke_invitation(%User{} = actor, invitation_id) do
    if Veejr.Accounts.instance_admin?(actor) do
      case Repo.get(Invitation, invitation_id) do
        nil ->
          {:error, :not_found}

        invitation ->
          if invitation_status(invitation) == :active do
            Repo.transaction(fn ->
              invitation =
                invitation
                |> Ecto.Changeset.change(
                  revoked_at: DateTime.utc_now(:second),
                  revoked_by_id: actor.id
                )
                |> Repo.update!()

              audit!(actor, "invitation.revoked", "invitation", invitation.id)
              invitation
            end)
          else
            {:error, :not_revocable}
          end
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc "Expires an active invitation immediately."
  def expire_invitation(%User{} = actor, invitation_id) do
    if Veejr.Accounts.instance_admin?(actor) do
      case Repo.get(Invitation, invitation_id) do
        %Invitation{} = invitation
        when is_nil(invitation.accepted_at) and is_nil(invitation.revoked_at) ->
          if invitation_status(invitation) == :active do
            Repo.transaction(fn ->
              invitation =
                invitation
                |> Ecto.Changeset.change(expires_at: DateTime.utc_now(:second))
                |> Repo.update!()

              audit!(actor, "invitation.expired", "invitation", invitation.id)
              invitation
            end)
          else
            {:error, :not_expirable}
          end

        _ ->
          {:error, :not_expirable}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc "Revokes every web and Android session for a local member account."
  def revoke_user_sessions(%User{} = actor, user_id) do
    cond do
      not Veejr.Accounts.instance_admin?(actor) ->
        {:error, :unauthorized}

      target = Repo.get(User, user_id) ->
        cond do
          target.host ->
            {:error, :not_found}

          Veejr.Accounts.instance_admin?(target) ->
            {:error, :protected_admin}

          true ->
            Repo.transaction(fn ->
              result = revoke_sessions(target)

              audit!(actor, "sessions.revoked", "user", target.id, %{
                "username" => target.username,
                "web_sessions" => result.web_count,
                "device_sessions" => result.device_count
              })

              result
            end)
        end

      true ->
        {:error, :not_found}
    end
  end

  @doc "Suspends a local member and revokes all of their sessions."
  def suspend_user(%User{} = actor, user_id) do
    with {:ok, target} <- manageable_user(actor, user_id),
         false <- not is_nil(target.suspended_at) do
      Repo.transaction(fn ->
        target =
          target
          |> Ecto.Changeset.change(
            suspended_at: DateTime.utc_now(:second),
            suspended_by_id: actor.id
          )
          |> Repo.update!()

        result = revoke_sessions(target)
        Repo.delete_all(from(t in UserToken, where: t.user_id == ^target.id))

        audit!(actor, "account.suspended", "user", target.id, %{
          "username" => target.username,
          "web_sessions" => result.web_count,
          "device_sessions" => result.device_count
        })

        result
      end)
    else
      true -> {:error, :already_suspended}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Reactivates a suspended local member without restoring old sessions."
  def reactivate_user(%User{} = actor, user_id) do
    with {:ok, target} <- manageable_user(actor, user_id),
         true <- not is_nil(target.suspended_at) do
      Repo.transaction(fn ->
        target =
          target
          |> Ecto.Changeset.change(suspended_at: nil, suspended_by_id: nil)
          |> Repo.update!()

        audit!(actor, "account.reactivated", "user", target.id, %{
          "username" => target.username
        })

        target
      end)
    else
      false -> {:error, :not_suspended}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Blocks all inbound and outbound federation traffic for a pinned peer."
  def block_peer(%User{} = actor, peer_id) do
    with {:ok, peer} <- manageable_peer(actor, peer_id),
         false <- not is_nil(peer.blocked_at) do
      Repo.transaction(fn ->
        peer =
          peer
          |> Ecto.Changeset.change(
            blocked_at: DateTime.utc_now(:second),
            blocked_by_id: actor.id
          )
          |> Repo.update!()

        dropped = Veejr.Federation.Outbox.drop_for_authority(peer.authority)

        audit!(actor, "peer.blocked", "peer", peer.id, %{
          "authority" => peer.authority,
          "outbound_deliveries_dropped" => dropped
        })

        %{peer: peer, outbound_deliveries_dropped: dropped}
      end)
    else
      true -> {:error, :already_blocked}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Restores federation traffic for a blocked peer without restoring discarded deliveries."
  def unblock_peer(%User{} = actor, peer_id) do
    with {:ok, peer} <- manageable_peer(actor, peer_id),
         true <- not is_nil(peer.blocked_at) do
      Repo.transaction(fn ->
        peer =
          peer
          |> Ecto.Changeset.change(blocked_at: nil, blocked_by_id: nil)
          |> Repo.update!()

        audit!(actor, "peer.unblocked", "peer", peer.id, %{"authority" => peer.authority})
        peer
      end)
    else
      false -> {:error, :not_blocked}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Starts the in-place software upgrade to `tag` and records it in the audit trail."
  def start_upgrade(%User{} = actor, tag) when is_binary(tag) do
    if Veejr.Accounts.instance_admin?(actor) do
      with :ok <- Veejr.Updates.Upgrader.start(tag) do
        {:ok, _event} = audit(actor, "instance.upgrade_started", "instance", 1, %{"tag" => tag})
        :ok
      end
    else
      {:error, :unauthorized}
    end
  end

  def retry_federation(%User{} = actor) do
    if Veejr.Accounts.instance_admin?(actor) do
      result = Outbox.retry_all()
      {:ok, _event} = audit(actor, "federation.retried", "instance", 1, stringify_keys(result))
      {:ok, result}
    else
      {:error, :unauthorized}
    end
  end

  def test_mail_delivery(%User{} = actor) do
    if Veejr.Accounts.instance_admin?(actor) do
      result = UserNotifier.deliver_admin_test(actor)

      audit_result = if match?({:ok, _}, result), do: "success", else: "failure"

      {:ok, _event} =
        audit(actor, "instance.mail_tested", "instance", 1, %{"result" => audit_result})

      result
    else
      {:error, :unauthorized}
    end
  end

  defp manageable_user(actor, user_id) do
    cond do
      not Veejr.Accounts.instance_admin?(actor) ->
        {:error, :unauthorized}

      target = Repo.get(User, user_id) ->
        cond do
          target.host -> {:error, :not_found}
          Veejr.Accounts.instance_admin?(target) -> {:error, :protected_admin}
          true -> {:ok, target}
        end

      true ->
        {:error, :not_found}
    end
  end

  defp manageable_peer(actor, peer_id) do
    cond do
      not Veejr.Accounts.instance_admin?(actor) -> {:error, :unauthorized}
      peer = Repo.get(Peer, peer_id) -> {:ok, peer}
      true -> {:error, :not_found}
    end
  end

  defp revoke_sessions(target) do
    web_tokens =
      Repo.all(
        from(t in UserToken,
          where: t.user_id == ^target.id and t.context == "session"
        )
      )

    {web_count, _} =
      Repo.delete_all(
        from(t in UserToken,
          where: t.user_id == ^target.id and t.context == "session"
        )
      )

    {device_count, _} =
      Repo.delete_all(from(s in ApiDeviceSession, where: s.user_id == ^target.id))

    %{
      user: target,
      web_tokens: web_tokens,
      web_count: web_count,
      device_count: device_count
    }
  end

  defp audit!(actor, action, target_type, target_id, details \\ %{}) do
    case audit(actor, action, target_type, target_id, details) do
      {:ok, event} ->
        event

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  defp audit(actor, action, target_type, target_id, details) do
    %AuditEvent{}
    |> AuditEvent.changeset(%{
      action: action,
      target_type: target_type,
      target_id: target_id,
      details: Map.put_new(details, "result", "success"),
      actor_user_id: actor.id
    })
    |> Repo.insert()
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp database_health do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _} -> :ok
      {:error, _} -> :error
    end
  end

  defp database_version do
    case Ecto.Adapters.SQL.query(Repo, "SELECT sqlite_version()", []) do
      {:ok, %{rows: [[version]]}} -> "SQLite #{version}"
      _ -> "Unavailable"
    end
  end

  defp process_health(name) do
    if Process.whereis(name), do: :ok, else: :error
  end
end
