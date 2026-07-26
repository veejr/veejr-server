defmodule Veejr.Export do
  @moduledoc """
  Account export: everything a user needs to leave this instance.

  Produces a zip (in memory) containing:

    * `export.json` — profile, wrapped key material, friends (with their
      public keys), groups, and the user's full decryptable envelope history.
      Sender public keys are inlined so ciphertext remains decryptable after
      import, without the original instance.
    * `blobs/<id>.bin` — the user's own uploaded (already encrypted)
      attachments.

  Everything sensitive in the export is ciphertext: the secret key is still
  wrapped with the passphrase-derived key, and envelope bodies stay encrypted.
  The file is safe-ish at rest, but it does reveal social metadata — treat it
  like a private backup.

  Known limit: attachments *received* from friends can't be included, because
  the server cannot know which blobs a user's envelopes reference (blob ids
  travel inside encrypted payloads — by design). Download anything you need
  from friends before their account disappears.
  """

  import Ecto.Query, warn: false

  alias Veejr.{Accounts, Repo}
  alias Veejr.Accounts.User
  alias Veejr.Messaging
  alias Veejr.Messaging.{Blob, BlobReference}
  alias Veejr.Social

  @format_version 1

  @doc "Builds the export zip for a user. Returns `{:ok, filename, zip_binary}`."
  def build(%User{} = user) do
    blobs = Repo.all(from(b in Blob, where: b.owner_id == ^user.id))

    avatar_files =
      case Accounts.get_user_avatar_image(user) do
        image when is_binary(image) -> [{"avatar.jpg", image}]
        nil -> []
      end

    blob_files =
      for blob <- blobs,
          path = Veejr.Messaging.blob_file_path(blob),
          File.exists?(path) do
        {"blobs/#{blob.public_id}.bin", File.read!(path)}
      end

    payload_files = avatar_files ++ blob_files

    manifest = %{
      veejr_export: @format_version,
      exported_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      instance: %{host: Veejr.instance_authority(), version: Veejr.version()},
      profile: %{
        email: user.email,
        username: user.username,
        display_name: user.display_name
      },
      keys: %{
        public_key: user.public_key,
        enc_secret_key: user.enc_secret_key,
        key_salt: user.key_salt,
        key_nonce: user.key_nonce
      },
      friends: export_friends(user),
      groups: export_groups(user),
      envelopes: export_envelopes(user),
      blob_references: export_blob_references(user),
      file_hashes: Map.new(payload_files, fn {name, binary} -> {name, sha256(binary)} end)
    }

    files =
      [{~c"export.json", Jason.encode!(manifest, pretty: true)}] ++
        Enum.map(payload_files, fn {name, binary} -> {String.to_charlist(name), binary} end)

    {:ok, {_name, zip_binary}} = :zip.create(~c"veejr-export.zip", files, [:memory])
    {:ok, "veejr-#{user.username}-export.zip", zip_binary}
  end

  defp export_friends(user) do
    for friend <- Social.list_friends(user) do
      %{
        username: friend.username,
        display_name: friend.display_name,
        public_key: friend.public_key,
        host: friend.host || Veejr.instance_authority()
      }
    end
  end

  defp export_groups(user) do
    for group <- Social.list_groups(user) do
      %{name: group.name, members: Enum.map(group.members, & &1.username)}
    end
  end

  defp export_envelopes(user) do
    for envelope <- Messaging.list_history(user) do
      recipients =
        if envelope.sender_id == user.id do
          Messaging.batch_recipients(user, envelope.batch_id)
        else
          [user.username]
        end

      %{
        public_id: envelope.public_id,
        batch_id: envelope.batch_id,
        kind: envelope.kind,
        ciphertext: envelope.ciphertext,
        nonce: envelope.nonce,
        resealed: envelope.resealed,
        inserted_at: DateTime.to_iso8601(envelope.inserted_at),
        sender: %{
          username: envelope.sender.username,
          display_name: envelope.sender.display_name,
          # the key the envelope was sealed with, not the sender's current one
          public_key: envelope.sender_public_key || envelope.sender.public_key,
          host: envelope.sender.host || Veejr.instance_authority()
        },
        recipients: recipients
      }
    end
  end

  defp export_blob_references(user) do
    Repo.all(
      from(r in BlobReference,
        join: b in Blob,
        on: b.id == r.blob_id,
        where: b.owner_id == ^user.id,
        select: %{public_id: b.public_id, batch_id: r.batch_id}
      )
    )
  end

  defp sha256(binary) do
    :crypto.hash(:sha256, binary)
    |> Base.encode16(case: :lower)
  end
end
