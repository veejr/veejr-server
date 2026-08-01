defmodule Veejr.Social do
  @moduledoc """
  Friends and groups.

  Friendships are symmetric once accepted: a single row records who asked
  (`requester`) and who answered (`addressee`), and `status` moves from
  `"pending"` to `"accepted"`. Groups are personal address-book labels — each
  user organizes their own accepted friends, and a friend may sit in many
  groups at once.
  """

  import Ecto.Query, warn: false

  alias Veejr.Repo
  alias Veejr.Accounts.{Scope, User}
  alias Veejr.Social.{ContactNote, Friendship, Group, GroupMember, GroupNote}

  ## Friendships

  @doc """
  Sends a friend request to the user with the given username.

  If the other user already sent us a pending request, this accepts it
  instead of creating a duplicate in the opposite direction.
  """
  def send_friend_request(%User{} = from, username) when is_binary(username) do
    case Veejr.Accounts.get_user_by_username(username) do
      nil ->
        {:error, :not_found}

      %User{id: id} when id == from.id ->
        {:error, :self}

      %User{} = to ->
        case get_friendship_between(from.id, to.id) do
          %Friendship{status: "accepted"} ->
            {:error, :already_friends}

          %Friendship{status: "pending", addressee_id: addressee_id} = fr
          when addressee_id == from.id ->
            accept_friend_request(from, fr.id)

          %Friendship{status: "pending"} ->
            {:error, :already_requested}

          nil ->
            %Friendship{}
            |> Friendship.changeset(%{
              requester_id: from.id,
              addressee_id: to.id,
              status: "pending"
            })
            |> Repo.insert()
            |> case do
              {:ok, fr} -> {:ok, Repo.preload(fr, [:requester, :addressee])}
              error -> error
            end
        end
    end
  end

  @doc """
  Sends a friend request to someone on another instance.

  Their instance's directory is consulted (pinning their public key), a
  pending friendship is created locally, and the request is delivered to
  their server. If delivery fails, nothing is left behind.
  """
  def send_remote_friend_request(%User{host: nil} = from, username, authority) do
    with {:ok, remote} <- Veejr.Federation.ensure_remote_user(username, authority) do
      case get_friendship_between(from.id, remote.id) do
        %Friendship{status: "accepted"} ->
          {:error, :already_friends}

        %Friendship{status: "pending", addressee_id: addressee_id} = fr
        when addressee_id == from.id ->
          accept_friend_request(from, fr.id)

        %Friendship{status: "pending"} ->
          {:error, :already_requested}

        nil ->
          {:ok, fr} =
            %Friendship{}
            |> Friendship.changeset(%{
              requester_id: from.id,
              addressee_id: remote.id,
              status: "pending"
            })
            |> Repo.insert()

          case Veejr.Federation.deliver_friend_request(from, remote) do
            :ok ->
              {:ok, Repo.preload(fr, [:requester, :addressee])}

            {:error, _} = error ->
              Repo.delete(fr)
              error
          end
      end
    end
  end

  @doc "Handles a friend request arriving over federation (idempotent)."
  def receive_remote_friend_request(%User{} = remote, %User{host: nil} = local) do
    case get_friendship_between(remote.id, local.id) do
      nil ->
        %Friendship{}
        |> Friendship.changeset(%{
          requester_id: remote.id,
          addressee_id: local.id,
          status: "pending"
        })
        |> Repo.insert()

      %Friendship{status: "pending", requester_id: requester_id} = fr
      when requester_id == local.id ->
        fr
        |> Ecto.Changeset.change(status: "accepted")
        |> Repo.update()
        |> case do
          {:ok, fr} ->
            Veejr.Federation.deliver_friend_response(local, remote, "accepted")
            {:ok, fr}

          error ->
            error
        end

      %Friendship{} = fr ->
        {:ok, fr}
    end
  end

  @doc "Handles the answer to a request we previously sent over federation."
  def receive_remote_friend_response(%User{} = remote, %User{host: nil} = local, action) do
    case Repo.get_by(Friendship, requester_id: local.id, addressee_id: remote.id) do
      nil ->
        {:error, :not_found}

      fr when action == "accepted" ->
        fr |> Ecto.Changeset.change(status: "accepted") |> Repo.update()

      fr when action == "declined" ->
        Repo.delete(fr)
    end
  end

  @doc """
  Accepts a pending request addressed to `user`. If the requester lives on
  another instance, their server is told (best effort — state converges when
  they can be reached).
  """
  def accept_friend_request(%User{} = user, friendship_id) do
    case Repo.get_by(Friendship, id: friendship_id, addressee_id: user.id, status: "pending") do
      nil ->
        {:error, :not_found}

      fr ->
        fr
        |> Ecto.Changeset.change(status: "accepted")
        |> Repo.update()
        |> case do
          {:ok, fr} ->
            fr = Repo.preload(fr, [:requester, :addressee])

            if fr.requester.host do
              Veejr.Federation.deliver_friend_response(user, fr.requester, "accepted")
            end

            {:ok, fr}

          error ->
            error
        end
    end
  end

  @doc "Declines a pending request addressed to `user` (deletes the row)."
  def decline_friend_request(%User{} = user, friendship_id) do
    case Repo.get_by(Friendship, id: friendship_id, addressee_id: user.id, status: "pending") do
      nil ->
        {:error, :not_found}

      fr ->
        fr = Repo.preload(fr, :requester)

        if fr.requester.host do
          Veejr.Federation.deliver_friend_response(user, fr.requester, "declined")
        end

        Repo.delete(fr)
    end
  end

  @doc "Removes an accepted friend (either side may do this). Also drops them from the remover's groups."
  def remove_friend(%User{} = user, friend_id) do
    case get_friendship_between(user.id, friend_id) do
      %Friendship{status: "accepted"} = fr ->
        Repo.transaction(fn ->
          delete_group_memberships(user.id, friend_id)
          delete_group_memberships(friend_id, user.id)
          delete_friend_delivery_policies(user.id, friend_id)
          delete_friend_delivery_policies(friend_id, user.id)
          Repo.delete!(fr)
        end)

      _ ->
        {:error, :not_found}
    end
  end

  defp delete_group_memberships(owner_id, member_id) do
    owned_group_ids =
      from(g in Group,
        where: g.owner_id == ^owner_id,
        select: g.id
      )

    from(gm in GroupMember,
      where: gm.user_id == ^member_id and gm.group_id in subquery(owned_group_ids)
    )
    |> Repo.delete_all()
  end

  defp delete_friend_delivery_policies(owner_id, friend_id) do
    from(p in Veejr.Messaging.MessageDeliveryPolicy,
      where:
        p.user_id == ^owner_id and p.subject_id == ^friend_id and
          p.subject_type in ["contact", "conversation"]
    )
    |> Repo.delete_all()
  end

  @doc """
  Confirms a remote friend's announced key change: the pinned key is swapped
  only on this explicit human decision. Old messages remain readable — they
  decrypt against the per-envelope sender-key snapshot.
  """
  def confirm_new_key(%User{} = user, friend_id) do
    with %Friendship{status: "accepted"} <- get_friendship_between(user.id, friend_id),
         %User{host: host, pending_public_key: pending} = friend
         when is_binary(host) and is_binary(pending) <-
           Repo.get(User, friend_id) do
      friend
      |> Ecto.Changeset.change(public_key: pending, pending_public_key: nil)
      |> Repo.update()
    else
      _ -> {:error, :not_applicable}
    end
  end

  def get_friendship_between(user_a_id, user_b_id) do
    from(f in Friendship,
      where:
        (f.requester_id == ^user_a_id and f.addressee_id == ^user_b_id) or
          (f.requester_id == ^user_b_id and f.addressee_id == ^user_a_id)
    )
    |> Repo.one()
  end

  def friends?(user_a_id, user_b_id) do
    case get_friendship_between(user_a_id, user_b_id) do
      %Friendship{status: "accepted"} -> true
      _ -> false
    end
  end

  @doc "Returns an accepted federated friend visible to the authenticated scope."
  def get_federated_friend(%Scope{user: %User{id: owner_id}}, friend_id) do
    from(u in User,
      join: f in Friendship,
      on:
        (f.requester_id == ^owner_id and f.addressee_id == u.id) or
          (f.addressee_id == ^owner_id and f.requester_id == u.id),
      where:
        u.id == ^friend_id and f.status == "accepted" and not is_nil(u.host) and
          u.has_avatar == true and u.avatar_version > 0
    )
    |> Repo.one()
  end

  @doc "All accepted friends of `user`, as `%User{}` structs sorted by name."
  def list_friends(%User{id: id}) do
    from(u in User,
      join: f in Friendship,
      on:
        (f.requester_id == ^id and f.addressee_id == u.id) or
          (f.addressee_id == ^id and f.requester_id == u.id),
      where: f.status == "accepted",
      order_by: [asc: coalesce(u.display_name, u.username)]
    )
    |> Repo.all()
  end

  @doc """
  Ids of `user_id`'s accepted friends who live on this instance.

  Presence fan-out uses this: remote friends have no LiveView here to notify,
  and loading whole structs to read one field each would be wasteful on a
  path that runs on every online/offline transition.
  """
  def local_friend_ids(user_id) do
    from(u in User,
      join: f in Friendship,
      on:
        (f.requester_id == ^user_id and f.addressee_id == u.id) or
          (f.addressee_id == ^user_id and f.requester_id == u.id),
      where: f.status == "accepted" and is_nil(u.host),
      select: u.id
    )
    |> Repo.all()
  end

  @doc """
  For each of `user_ids`, the instances hosting their accepted remote friends.

  Returns `{user_id, username, authority}` rows — the username is the local
  user whose presence is being announced, the authority the peer that needs
  telling. Presence fan-out groups these by authority so a peer gets one
  request no matter how many of its users are involved.
  """
  def remote_friend_authorities([]), do: []

  def remote_friend_authorities(user_ids) when is_list(user_ids) do
    from(u in User,
      join: f in Friendship,
      on: f.requester_id == u.id or f.addressee_id == u.id,
      join: r in User,
      on:
        (f.requester_id == u.id and f.addressee_id == r.id) or
          (f.addressee_id == u.id and f.requester_id == r.id),
      where: u.id in ^user_ids and f.status == "accepted" and not is_nil(r.host),
      distinct: true,
      select: {u.id, u.username, r.host}
    )
    |> Repo.all()
  end

  @doc "Pending requests addressed to `user`, requester preloaded."
  def list_incoming_requests(%User{id: id}) do
    from(f in Friendship,
      where: f.addressee_id == ^id and f.status == "pending",
      preload: [:requester],
      order_by: [desc: f.inserted_at]
    )
    |> Repo.all()
  end

  @doc "Pending requests `user` has sent, addressee preloaded."
  def list_outgoing_requests(%User{id: id}) do
    from(f in Friendship,
      where: f.requester_id == ^id and f.status == "pending",
      preload: [:addressee],
      order_by: [desc: f.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Replaces an accepted contact with the same person at a new home instance.

  Only relationships owned by local users are moved. Their accepted friendship,
  group memberships, private notes, and contact delivery policies keep pointing
  at the replacement contact.
  """
  def relocate_contact(%User{} = old_contact, %User{} = replacement) do
    Repo.transaction(fn ->
      friendships =
        from(f in Friendship,
          join: other in User,
          on:
            (f.requester_id == ^old_contact.id and f.addressee_id == other.id) or
              (f.addressee_id == ^old_contact.id and f.requester_id == other.id),
          where: f.status == "accepted" and is_nil(other.host) and other.id != ^old_contact.id,
          select: {f, other.id}
        )
        |> Repo.all()

      Enum.each(friendships, fn {friendship, local_id} ->
        case get_friendship_between(local_id, replacement.id) do
          nil ->
            attrs =
              if friendship.requester_id == old_contact.id,
                do: %{requester_id: replacement.id},
                else: %{addressee_id: replacement.id}

            friendship |> Ecto.Changeset.change(attrs) |> Repo.update!()

          existing ->
            existing |> Ecto.Changeset.change(status: "accepted") |> Repo.update!()
            Repo.delete!(friendship)
        end
      end)

      relocate_group_memberships(old_contact.id, replacement.id)
      relocate_contact_notes(old_contact.id, replacement.id)
      relocate_delivery_policies(old_contact.id, replacement.id)

      %{friendships: length(friendships)}
    end)
  end

  defp relocate_group_memberships(old_id, replacement_id) do
    from(gm in GroupMember,
      join: g in Group,
      on: g.id == gm.group_id,
      join: owner in User,
      on: owner.id == g.owner_id,
      where: gm.user_id == ^old_id and is_nil(owner.host) and owner.id != ^old_id
    )
    |> Repo.all()
    |> Enum.each(fn membership ->
      if Repo.get_by(GroupMember, group_id: membership.group_id, user_id: replacement_id) do
        Repo.delete!(membership)
      else
        membership |> Ecto.Changeset.change(user_id: replacement_id) |> Repo.update!()
      end
    end)
  end

  defp relocate_contact_notes(old_id, replacement_id) do
    from(n in ContactNote,
      join: owner in User,
      on: owner.id == n.owner_id,
      where: n.contact_id == ^old_id and is_nil(owner.host) and owner.id != ^old_id
    )
    |> Repo.all()
    |> Enum.each(fn note ->
      case Repo.get_by(ContactNote, owner_id: note.owner_id, contact_id: replacement_id) do
        nil ->
          note |> Ecto.Changeset.change(contact_id: replacement_id) |> Repo.update!()

        existing ->
          if existing.body == "" and note.body != "" do
            existing |> Ecto.Changeset.change(body: note.body) |> Repo.update!()
          end

          Repo.delete!(note)
      end
    end)
  end

  defp relocate_delivery_policies(old_id, replacement_id) do
    from(p in Veejr.Messaging.MessageDeliveryPolicy,
      join: owner in User,
      on: owner.id == p.user_id,
      where:
        p.subject_id == ^old_id and p.subject_type in ["contact", "conversation"] and
          is_nil(owner.host) and owner.id != ^old_id
    )
    |> Repo.all()
    |> Enum.each(fn policy ->
      existing =
        Repo.get_by(Veejr.Messaging.MessageDeliveryPolicy,
          user_id: policy.user_id,
          subject_type: policy.subject_type,
          subject_id: replacement_id
        )

      if existing do
        Repo.delete!(policy)
      else
        policy |> Ecto.Changeset.change(subject_id: replacement_id) |> Repo.update!()
      end
    end)
  end

  @doc "Personal notes the owner has written about accepted friends, keyed by contact id."
  def list_contact_notes(%User{} = owner) do
    friend_ids =
      owner
      |> list_friends()
      |> Enum.map(& &1.id)

    from(n in ContactNote,
      where: n.owner_id == ^owner.id and n.contact_id in ^friend_ids
    )
    |> Repo.all()
    |> Map.new(&{&1.contact_id, &1.body})
  end

  @doc "Creates or updates the owner's private note for an accepted friend."
  def upsert_contact_note(%User{} = owner, contact_id, body) do
    with {contact_id, ""} <- Integer.parse(to_string(contact_id)),
         %Friendship{status: "accepted"} <- get_friendship_between(owner.id, contact_id) do
      body = body |> to_string() |> String.trim()

      case Repo.get_by(ContactNote, owner_id: owner.id, contact_id: contact_id) do
        nil ->
          %ContactNote{}
          |> ContactNote.changeset(%{
            owner_id: owner.id,
            contact_id: contact_id,
            body: body
          })
          |> Repo.insert()

        note ->
          note
          |> ContactNote.changeset(%{body: body})
          |> Repo.update()
      end
    else
      _ -> {:error, :not_a_friend}
    end
  end

  ## Groups

  def create_group(%User{} = owner, attrs) do
    %Group{owner_id: owner.id}
    |> Group.changeset(attrs)
    |> Repo.insert()
  end

  def rename_group(%User{} = owner, group_id, attrs) do
    with %Group{} = group <- get_owned_group(owner, group_id) do
      group |> Group.changeset(attrs) |> Repo.update()
    end
  end

  def delete_group(%User{} = owner, group_id) do
    with %Group{} = group <- get_owned_group(owner, group_id) do
      Repo.transaction(fn ->
        from(p in Veejr.Messaging.MessageDeliveryPolicy,
          where:
            p.user_id == ^owner.id and p.subject_type == "group" and
              p.subject_id == ^group.id
        )
        |> Repo.delete_all()

        Repo.delete!(group)
      end)
    end
  end

  @doc "Groups owned by `user`, members preloaded."
  def list_groups(%User{id: id}) do
    from(g in Group, where: g.owner_id == ^id, order_by: [asc: g.name], preload: [:members])
    |> Repo.all()
  end

  def get_owned_group(%User{id: id}, group_id) do
    Repo.get_by(Group, id: group_id, owner_id: id) || {:error, :not_found}
  end

  @doc "Personal notes the owner has written about their own groups, keyed by group id."
  def list_group_notes(%User{} = owner) do
    group_ids =
      owner
      |> list_groups()
      |> Enum.map(& &1.id)

    from(n in GroupNote,
      where: n.owner_id == ^owner.id and n.group_id in ^group_ids
    )
    |> Repo.all()
    |> Map.new(&{&1.group_id, &1.body})
  end

  @doc "Creates or updates the owner's private note for one of their groups."
  def upsert_group_note(%User{} = owner, group_id, body) do
    with {group_id, ""} <- Integer.parse(to_string(group_id)),
         %Group{} <- get_owned_group(owner, group_id) do
      body = body |> to_string() |> String.trim()

      case Repo.get_by(GroupNote, owner_id: owner.id, group_id: group_id) do
        nil ->
          %GroupNote{}
          |> GroupNote.changeset(%{
            owner_id: owner.id,
            group_id: group_id,
            body: body
          })
          |> Repo.insert()

        note ->
          note
          |> GroupNote.changeset(%{body: body})
          |> Repo.update()
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Adds an accepted friend to one of the owner's groups."
  def add_group_member(%User{} = owner, group_id, friend_id) do
    with %Group{} = group <- get_owned_group(owner, group_id),
         true <- friends?(owner.id, friend_id) || {:error, :not_a_friend} do
      %GroupMember{group_id: group.id, user_id: friend_id}
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint([:group_id, :user_id])
      |> Repo.insert()
    end
  end

  def remove_group_member(%User{} = owner, group_id, friend_id) do
    with %Group{} = group <- get_owned_group(owner, group_id) do
      from(gm in GroupMember, where: gm.group_id == ^group.id and gm.user_id == ^friend_id)
      |> Repo.delete_all()

      :ok
    end
  end

  @doc "Members of one of the owner's groups, as `%User{}` structs."
  def group_members(%User{} = owner, group_id) do
    with %Group{} = group <- get_owned_group(owner, group_id) do
      from(u in User,
        join: gm in GroupMember,
        on: gm.user_id == u.id,
        where: gm.group_id == ^group.id,
        order_by: [asc: coalesce(u.display_name, u.username)]
      )
      |> Repo.all()
    end
  end
end
