defmodule Veejr.Import do
  @moduledoc """
  Restores a `Veejr.Export` zip into this instance — the migration path from
  a community server to a personal instance.

  What comes back:

    * the owner account (email, username, wrapped key material), already
      confirmed — unlock with the same passphrase as before
    * **ghost contacts**: local stub users for everyone who ever sent the
      owner an envelope, carrying just their username and public key so old
      ciphertext still decrypts. Ghosts cannot log in (their email is on a
      reserved `.invalid` domain) and hold no key material of their own.
      When federation lands, ghosts are the natural seed for remote contacts.
    * the full envelope history with original ids and timestamps; received
      envelopes get an already-`accepted` notification so history renders
    * the owner's own uploaded attachment blobs

  Friendships and groups are *not* recreated as live links — the friends
  still live on the old instance and there is no federation yet. Their data
  stays in the manifest for a future importer version.

  Idempotent-ish: envelopes and blobs are deduplicated by their public ids,
  so re-running an import does not duplicate history.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Veejr.Accounts.User
  alias Veejr.Messaging
  alias Veejr.Messaging.{Blob, BlobReference, Envelope, Notification}
  alias Veejr.Repo
  alias Veejr.Social.Friendship

  @supported_versions [1]
  @max_archive_bytes 512 * 1024 * 1024
  @max_expanded_bytes 1024 * 1024 * 1024
  @max_entries 20_000

  def max_archive_bytes, do: @max_archive_bytes

  @doc "Imports an export zip (binary). Returns `{:ok, summary}` or `{:error, reason}`."
  def from_zip(zip_binary) when is_binary(zip_binary) do
    with {:ok, files} <- unzip(zip_binary),
         {:ok, manifest} <- parse_manifest(files),
         :ok <- validate_hashes(manifest, files),
         :ok <- validate_owner_available(manifest),
         :ok <- validate_new_import_ids(manifest, files) do
      Repo.transaction(fn ->
        owner = create_owner!(manifest)
        avatar_restored = restore_avatar!(files, owner)
        restore_friendships!(owner, manifest["friends"] || [])
        ghosts = create_ghosts!(manifest, owner)
        envelope_count = import_envelopes!(manifest, owner, ghosts)
        blob_count = import_blobs!(files, owner)
        restore_blob_references!(manifest, owner)

        %{
          owner: owner.username,
          owner_user: owner,
          avatar: avatar_restored,
          friends: manifest["friends"] || [],
          ghost_contacts: map_size(ghosts),
          envelopes: envelope_count,
          blobs: blob_count
        }
      end)
    end
  end

  @doc """
  Restores a backup into an existing signed-in account.

  The restore is additive and idempotent. Account credentials and key material
  are never replaced; the archive must match the account's complete wrapped-key
  identity before any data is written.
  """
  def restore(zip_binary, %User{} = owner) when is_binary(zip_binary) do
    with {:ok, files} <- unzip(zip_binary),
         {:ok, manifest} <- parse_manifest(files),
         :ok <- validate_hashes(manifest, files),
         :ok <- validate_identity(manifest, owner),
         :ok <- validate_ownership(manifest, files, owner) do
      Repo.transaction(fn ->
        avatar_restored = restore_existing_avatar!(files, owner)
        restore_friendships!(owner, manifest["friends"] || [])
        ghosts = create_ghosts!(manifest, owner)
        envelope_count = import_envelopes!(manifest, owner, ghosts)
        blob_count = import_blobs!(files, owner)
        restore_blob_references!(manifest, owner)

        %{
          owner: owner.username,
          avatar: avatar_restored,
          ghost_contacts: map_size(ghosts),
          envelopes: envelope_count,
          blobs: blob_count
        }
      end)
    end
  end

  @doc """
  Re-establishes friendships from the export over federation: each old friend
  gets a normal friend request from the owner's new home, which they accept
  on their side like any other. Local-instance friends (rare: someone who
  also moved here) get a local request. Returns `[{handle, result}]`.
  """
  def reconnect_friends(%Veejr.Accounts.User{} = owner, friends) when is_list(friends) do
    ours = Veejr.instance_authority()

    for %{"username" => username, "host" => host} <- friends do
      handle = "@#{username}@#{host}"

      result =
        if host == ours do
          Veejr.Social.send_friend_request(owner, username)
        else
          Veejr.Social.send_remote_friend_request(owner, username, host)
        end

      {handle,
       case result do
         {:ok, _} -> :request_sent
         {:error, :already_friends} -> :already_friends
         {:error, :already_requested} -> :already_requested
         {:error, {:http, 404}} -> :unknown_user
         {:error, :key_changed} -> :key_changed
         {:error, _} -> :unreachable
       end}
    end
  end

  defp unzip(zip_binary) when byte_size(zip_binary) <= @max_archive_bytes do
    with {:ok, entries} <- archive_entries(zip_binary),
         :ok <- validate_entries(entries),
         {:ok, files} <- :zip.unzip(zip_binary, [:memory]) do
      {:ok, Map.new(files, fn {name, bin} -> {to_string(name), bin} end)}
    else
      {:error, reason} when reason in [:unsafe_archive, :archive_too_large] ->
        {:error, reason}

      _ ->
        {:error, :not_a_zip}
    end
  end

  defp unzip(_zip_binary), do: {:error, :archive_too_large}

  defp archive_entries(zip_binary) do
    case :zip.table(zip_binary) do
      {:ok, table} ->
        entries =
          for {:zip_file, name, file_info, _comment, _offset, _compressed_size} <- table do
            %{name: to_string(name), size: elem(file_info, 1)}
          end

        {:ok, entries}

      {:error, _} ->
        {:error, :not_a_zip}
    end
  end

  defp validate_entries(entries) do
    names = Enum.map(entries, & &1.name)

    safe? =
      entries != [] and
        length(entries) <= @max_entries and
        length(names) == length(Enum.uniq(names)) and
        Enum.sum_by(entries, & &1.size) <= @max_expanded_bytes and
        Enum.all?(names, &allowed_archive_path?/1)

    if safe?, do: :ok, else: {:error, :unsafe_archive}
  end

  defp allowed_archive_path?("export.json"), do: true
  defp allowed_archive_path?("avatar.jpg"), do: true

  defp allowed_archive_path?(name) do
    Regex.match?(~r/\Ablobs\/[A-Za-z0-9_-]{1,128}\.bin\z/, name)
  end

  defp parse_manifest(%{"export.json" => json}) do
    case Jason.decode(json) do
      {:ok, %{"veejr_export" => v} = manifest}
      when v in @supported_versions and is_map_key(manifest, "profile") and
             is_map_key(manifest, "keys") and is_map_key(manifest, "envelopes") ->
        if valid_manifest?(manifest), do: {:ok, manifest}, else: {:error, :invalid_manifest}

      {:ok, %{"veejr_export" => v}} ->
        {:error, {:unsupported_version, v}}

      _ ->
        {:error, :invalid_manifest}
    end
  end

  defp parse_manifest(_files), do: {:error, :missing_manifest}

  defp valid_manifest?(manifest) do
    profile = manifest["profile"]
    keys = manifest["keys"]
    envelopes = manifest["envelopes"]
    friends = manifest["friends"] || []
    groups = manifest["groups"] || []
    blob_references = manifest["blob_references"] || []

    is_map(profile) and is_map(keys) and is_list(envelopes) and
      is_list(friends) and is_list(groups) and is_list(blob_references) and
      is_binary(profile["username"]) and is_binary(profile["email"]) and
      Enum.all?(~w(public_key enc_secret_key key_salt key_nonce), &is_binary(keys[&1])) and
      Enum.all?(envelopes, &valid_envelope?/1) and
      Enum.all?(friends, &valid_friend?/1) and
      Enum.all?(blob_references, &valid_blob_reference?/1)
  end

  defp valid_envelope?(entry) when is_map(entry) do
    sender = entry["sender"]
    recipients = entry["recipients"] || []

    Enum.all?(~w(public_id batch_id kind ciphertext nonce inserted_at), &is_binary(entry[&1])) and
      entry["kind"] in Envelope.kinds() and is_map(sender) and
      is_binary(sender["username"]) and is_binary(sender["public_key"]) and
      valid_optional_binary?(sender["host"]) and
      is_list(recipients) and Enum.all?(recipients, &is_binary/1) and
      entry["resealed"] in [nil, true, false] and
      byte_size(entry["public_id"]) in 1..128 and byte_size(entry["batch_id"]) in 1..128 and
      byte_size(entry["ciphertext"]) <= 350_000 and byte_size(entry["nonce"]) <= 256 and
      valid_iso8601?(entry["inserted_at"])
  end

  defp valid_envelope?(_entry), do: false

  defp valid_friend?(friend) when is_map(friend) do
    is_binary(friend["username"]) and is_binary(friend["host"]) and
      valid_optional_binary?(friend["display_name"]) and
      valid_optional_binary?(friend["public_key"])
  end

  defp valid_friend?(_friend), do: false

  defp valid_blob_reference?(reference) when is_map(reference) do
    is_binary(reference["public_id"]) and is_binary(reference["batch_id"])
  end

  defp valid_blob_reference?(_reference), do: false

  defp valid_optional_binary?(value), do: is_nil(value) or is_binary(value)

  defp valid_iso8601?(value) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))
  end

  defp validate_identity(%{"profile" => profile, "keys" => keys}, owner) do
    matches? =
      profile["username"] == owner.username and
        Enum.all?(~w(public_key enc_secret_key key_salt key_nonce), fn field ->
          keys[field] == Map.fetch!(owner, String.to_existing_atom(field))
        end)

    if matches?, do: :ok, else: {:error, :account_mismatch}
  end

  defp validate_hashes(%{"file_hashes" => hashes}, files) when is_map(hashes) do
    payload_files = Map.drop(files, ["export.json"])

    valid? =
      Enum.sort(Map.keys(hashes)) == Enum.sort(Map.keys(payload_files)) and
        Enum.all?(payload_files, fn {name, binary} ->
          hashes[name] == sha256(binary)
        end)

    if valid?, do: :ok, else: {:error, :integrity_check_failed}
  end

  # Early version-1 backups predate embedded hashes. They remain importable,
  # while every newly generated backup takes the verified branch above.
  defp validate_hashes(_manifest, _files), do: :ok

  defp validate_ownership(manifest, files, owner) do
    envelope_ids = Enum.map(manifest["envelopes"], & &1["public_id"])

    blob_ids =
      for {name, _binary} <- files, String.starts_with?(name, "blobs/"), do: blob_id(name)

    referenced_blob_ids = Enum.map(manifest["blob_references"] || [], & &1["public_id"])

    duplicate_ids? =
      length(envelope_ids) != length(Enum.uniq(envelope_ids)) or
        length(blob_ids) != length(Enum.uniq(blob_ids)) or
        not Enum.all?(referenced_blob_ids, &(&1 in blob_ids))

    envelope_conflict? =
      Repo.exists?(
        from(e in Envelope,
          where: e.public_id in ^envelope_ids and e.recipient_id != ^owner.id
        )
      )

    blob_conflict? =
      Repo.exists?(from(b in Blob, where: b.public_id in ^blob_ids and b.owner_id != ^owner.id))

    if duplicate_ids? or envelope_conflict? or blob_conflict?,
      do: {:error, :ownership_conflict},
      else: :ok
  end

  defp validate_new_import_ids(manifest, files) do
    envelope_ids = Enum.map(manifest["envelopes"], & &1["public_id"])

    blob_ids =
      for {name, _binary} <- files, String.starts_with?(name, "blobs/"), do: blob_id(name)

    referenced_blob_ids = Enum.map(manifest["blob_references"] || [], & &1["public_id"])

    conflict? =
      length(envelope_ids) != length(Enum.uniq(envelope_ids)) or
        length(blob_ids) != length(Enum.uniq(blob_ids)) or
        not Enum.all?(referenced_blob_ids, &(&1 in blob_ids)) or
        Repo.exists?(from(e in Envelope, where: e.public_id in ^envelope_ids)) or
        Repo.exists?(from(b in Blob, where: b.public_id in ^blob_ids))

    if conflict?, do: {:error, :ownership_conflict}, else: :ok
  end

  defp validate_owner_available(%{"profile" => profile}) do
    if Repo.get_by(User, username: profile["username"]) ||
         Repo.get_by(User, email: profile["email"]),
       do: {:error, :owner_already_exists},
       else: :ok
  end

  defp restore_existing_avatar!(%{"avatar.jpg" => image}, owner) do
    if Veejr.Accounts.get_user_avatar_image(owner) == image do
      false
    else
      restore_avatar!(%{"avatar.jpg" => image}, owner)
    end
  end

  defp restore_existing_avatar!(_files, _owner), do: false

  defp create_owner!(%{"profile" => profile, "keys" => keys}) do
    if Repo.get_by(User, username: profile["username"]) ||
         Repo.get_by(User, email: profile["email"]) do
      Repo.rollback(:owner_already_exists)
    end

    %User{}
    |> User.registration_changeset(%{
      "email" => profile["email"],
      "username" => profile["username"],
      "display_name" => profile["display_name"]
    })
    |> User.keys_changeset(keys)
    |> Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
    |> Repo.insert()
    |> case do
      {:ok, owner} -> owner
      {:error, changeset} -> Repo.rollback({:owner_invalid, changeset})
    end
  end

  defp restore_avatar!(%{"avatar.jpg" => image}, owner) do
    case Veejr.Accounts.put_user_avatar(owner, image) do
      {:ok, _owner} -> true
      {:error, reason} -> Repo.rollback({:avatar_invalid, reason})
    end
  end

  defp restore_avatar!(_files, _owner), do: false

  @doc "Restores exported accepted friendships idempotently for an imported owner."
  def restore_friendships!(%User{} = owner, friends) when is_list(friends) do
    for friend <- friends do
      contact = import_contact!(friend)

      unless Veejr.Social.get_friendship_between(owner.id, contact.id) do
        %Friendship{}
        |> Friendship.changeset(%{
          requester_id: owner.id,
          addressee_id: contact.id,
          status: "accepted"
        })
        |> Repo.insert!()
      end
    end
  end

  defp import_contact!(%{"username" => username, "host" => host} = profile) do
    local = host == Veejr.instance_authority() && Veejr.Accounts.get_user_by_username(username)

    local ||
      Repo.get_by(User, username: username, host: host) ||
      Repo.insert!(
        Changeset.change(%User{},
          email: "remote+#{username}@#{String.replace(host, ":", ".")}.invalid",
          username: username,
          host: host,
          display_name: profile["display_name"],
          public_key: profile["public_key"]
        )
      )
  end

  # One remote-contact row per distinct envelope sender (keyed by their home
  # instance), so received ciphertext keeps a resolvable sender with a public
  # key to decrypt against. These are ordinary remote users — once federation
  # can reach their instance again, friendships can be re-established.
  defp create_ghosts!(%{"envelopes" => envelopes} = manifest, owner) do
    export_host = get_in(manifest, ["instance", "host"]) || "unknown.invalid"

    envelopes
    |> Enum.map(& &1["sender"])
    |> Enum.reject(&(&1["username"] == owner.username))
    |> Enum.uniq_by(&{&1["username"], &1["host"]})
    |> Map.new(fn sender ->
      username = sender["username"]
      host = sender["host"] || export_host

      local = host == Veejr.instance_authority() && Veejr.Accounts.get_user_by_username(username)

      ghost =
        local || Repo.get_by(User, username: username, host: host) ||
          Repo.insert!(
            Changeset.change(%User{},
              email: "remote+#{username}@#{String.replace(host, ":", ".")}.invalid",
              username: username,
              host: host,
              display_name: sender["display_name"],
              public_key: sender["public_key"]
            )
          )

      {{username, host}, ghost}
    end)
  end

  defp import_envelopes!(%{"envelopes" => envelopes} = manifest, owner, ghosts) do
    export_host = get_in(manifest, ["instance", "host"]) || "unknown.invalid"

    existing =
      from(e in Envelope, where: e.recipient_id == ^owner.id, select: e.public_id)
      |> Repo.all()
      |> MapSet.new()

    envelopes
    |> Enum.reject(&MapSet.member?(existing, &1["public_id"]))
    |> Enum.map(fn entry ->
      sender = entry["sender"]

      {sender_id, sender_struct} =
        if sender["username"] == owner.username,
          do: {owner.id, owner},
          else:
            (
              ghost = ghosts[{sender["username"], sender["host"] || export_host}]
              {ghost.id, ghost}
            )

      {:ok, inserted_at, _} = DateTime.from_iso8601(entry["inserted_at"])
      inserted_at = DateTime.truncate(inserted_at, :second)

      participants = import_participants(entry, sender_id == owner.id, sender_struct, export_host)

      envelope =
        Repo.insert!(%Envelope{
          public_id: entry["public_id"],
          batch_id: entry["batch_id"],
          sender_id: sender_id,
          recipient_id: owner.id,
          kind: entry["kind"],
          ciphertext: entry["ciphertext"],
          nonce: entry["nonce"],
          sender_public_key: entry["sender"]["public_key"],
          resealed: entry["resealed"] || false,
          thread_key: Messaging.conversation_key(participants),
          participants: Jason.encode!(participants),
          inserted_at: inserted_at,
          updated_at: inserted_at
        })

      if sender_id != owner.id do
        Repo.insert!(%Notification{
          envelope_id: envelope.id,
          user_id: owner.id,
          state: "accepted"
        })
      end

      envelope
    end)
    |> length()
  end

  # Thread identity for a restored envelope. Received copies thread by the
  # (ghost) sender's handle on this instance. Self-copies thread by the
  # exported recipient handles, qualified with the export host so they stay
  # meaningful away from the origin instance — better than the pre-thread-key
  # behavior, which collapsed all imported sent history into notes-to-self
  # because the other copies of each batch are never exported.
  defp import_participants(entry, self_copy?, sender_struct, export_host) do
    if self_copy? do
      (entry["recipients"] || [])
      |> Enum.map(&qualify_handle(&1, export_host))
      |> Enum.sort()
      |> case do
        [] -> ["notes to yourself"]
        handles -> handles
      end
    else
      [Veejr.Social.Address.handle(sender_struct)]
    end
  end

  defp qualify_handle(handle, export_host) do
    case handle |> to_string() |> String.trim_leading("@") |> String.split("@", parts: 2) do
      [username] -> local_or_remote_handle(username, export_host)
      [username, host] -> local_or_remote_handle(username, host)
    end
  end

  defp local_or_remote_handle(username, host) do
    if host == Veejr.instance_authority(),
      do: "@#{username}",
      else: "@#{username}@#{host}"
  end

  defp import_blobs!(files, owner) do
    dir = Messaging.blob_dir()
    File.mkdir_p!(dir)

    files
    |> Enum.filter(fn {name, _} -> String.starts_with?(name, "blobs/") end)
    |> Enum.reject(fn {name, _} ->
      public_id = blob_id(name)
      Repo.exists?(from(b in Blob, where: b.public_id == ^public_id))
    end)
    |> Enum.map(fn {name, binary} ->
      public_id = blob_id(name)
      path = Path.join(dir, public_id <> ".bin")
      File.write!(path, binary)

      Repo.insert!(%Blob{
        public_id: public_id,
        owner_id: owner.id,
        size: byte_size(binary),
        path: path
      })
    end)
    |> length()
  end

  defp restore_blob_references!(manifest, owner) do
    public_ids = Enum.map(manifest["blob_references"] || [], & &1["public_id"])

    owned_batch_ids =
      Repo.all(from(e in Envelope, where: e.sender_id == ^owner.id, select: e.batch_id))
      |> MapSet.new()

    blob_ids =
      Repo.all(
        from(b in Blob,
          where: b.owner_id == ^owner.id and b.public_id in ^public_ids,
          select: {b.public_id, b.id}
        )
      )
      |> Map.new()

    now = DateTime.utc_now(:second)

    rows =
      for %{"public_id" => public_id, "batch_id" => batch_id} <-
            manifest["blob_references"] || [],
          blob_id = blob_ids[public_id],
          is_integer(blob_id),
          MapSet.member?(owned_batch_ids, batch_id) do
        %{blob_id: blob_id, batch_id: batch_id, inserted_at: now, updated_at: now}
      end

    Repo.insert_all(BlobReference, rows,
      on_conflict: :nothing,
      conflict_target: [:blob_id, :batch_id]
    )

    tracked_blob_ids = Enum.map(rows, & &1.blob_id)

    from(b in Blob, where: b.id in ^tracked_blob_ids)
    |> Repo.update_all(set: [reference_tracking: true])

    :ok
  end

  defp blob_id(name), do: name |> Path.basename() |> Path.rootname(".bin")

  defp sha256(binary) do
    :crypto.hash(:sha256, binary)
    |> Base.encode16(case: :lower)
  end
end
