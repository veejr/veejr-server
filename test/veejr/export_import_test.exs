defmodule Veejr.ExportImportTest do
  use Veejr.DataCase, async: false

  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Export, Import, Messaging, Repo, Social}
  alias Veejr.Accounts.User

  defp user_with_keys(username) do
    user = user_fixture(%{username: username})

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        "public_key" => Base.encode64("pub-" <> username),
        "enc_secret_key" => Base.encode64("wrapped-" <> username),
        "key_salt" => Base.encode64("salt"),
        "key_nonce" => Base.encode64("nonce")
      })

    user
  end

  defp befriend(a, b) do
    {:ok, fr} = Social.send_friend_request(a, b.username)
    {:ok, _} = Social.accept_friend_request(b, fr.id)

    {:ok, _policy} =
      Messaging.put_delivery_policy(b, "contact", a.id, %{"acceptance" => "ask"})

    :ok
  end

  test "export → delete → import round-trips an account" do
    alice = user_with_keys("alice")
    bob = user_with_keys("bob")
    befriend(alice, bob)
    avatar = jpeg(512, 512)
    {:ok, bob} = Accounts.put_user_avatar(bob, avatar)

    # alice sends bob a message (with her self-copy)
    {:ok, _batch, []} =
      Messaging.send_batch(alice, "message", [
        %{"recipient_id" => bob.id, "ciphertext" => "ct-for-bob", "nonce" => "n1"},
        %{"recipient_id" => alice.id, "ciphertext" => "ct-for-alice", "nonce" => "n2"}
      ])

    [notification] = Messaging.list_pending_notifications(bob)
    {:ok, _} = Messaging.accept_notification(bob, notification.id)

    # bob uploads an (already encrypted) attachment blob
    {:ok, blob} = Messaging.create_blob(bob, "encrypted-bytes")

    # export bob
    {:ok, filename, zip} = Export.build(bob)
    assert filename == "veejr-bob-export.zip"

    {:ok, files} = :zip.unzip(zip, [:memory])
    files = Map.new(files, fn {name, bin} -> {to_string(name), bin} end)
    manifest = Jason.decode!(files["export.json"])

    assert manifest["veejr_export"] == 1
    assert manifest["profile"]["username"] == "bob"
    assert manifest["keys"]["public_key"] == bob.public_key
    assert [%{"username" => "alice"}] = manifest["friends"]
    assert [envelope_entry] = manifest["envelopes"]
    assert envelope_entry["ciphertext"] == "ct-for-bob"
    assert envelope_entry["sender"]["username"] == "alice"
    assert envelope_entry["sender"]["public_key"] == alice.public_key
    assert files["blobs/#{blob.public_id}.bin"] == "encrypted-bytes"
    assert files["avatar.jpg"] == avatar

    # bob leaves the community server
    {:ok, _} = Accounts.delete_user(bob)
    refute Accounts.get_user_by_username("bob")
    assert Messaging.get_blob(blob.public_id) == nil
    refute File.exists?(blob.path)

    # ... and restores on a "personal instance"
    {:ok, summary} = Import.from_zip(zip)
    assert summary.owner == "bob"
    assert summary.envelopes == 1
    assert summary.blobs == 1
    assert summary.avatar

    new_bob = Accounts.get_user_by_username("bob")
    assert new_bob.public_key == bob.public_key
    assert new_bob.enc_secret_key == bob.enc_secret_key
    assert new_bob.confirmed_at
    assert new_bob.has_avatar
    assert new_bob.avatar_version == 1
    assert Accounts.get_user_avatar_image(new_bob) == avatar
    assert Social.friends?(new_bob.id, alice.id)

    # history is back, sender resolves (alice still exists here, so no ghost)
    [restored] = Messaging.list_history(new_bob)
    assert restored.ciphertext == "ct-for-bob"
    assert restored.public_id == envelope_entry["public_id"]
    assert restored.sender.username == "alice"

    # blob is back on disk
    restored_blob = Messaging.get_blob(blob.public_id)
    assert File.read!(restored_blob.path) == "encrypted-bytes"

    # re-import is rejected (owner exists)
    assert {:error, :owner_already_exists} = Import.from_zip(zip)
  end

  test "import creates ghost contacts for senders unknown to this instance" do
    _admin = user_with_keys("instance_admin")
    alice = user_with_keys("alice")
    bob = user_with_keys("bob")
    befriend(alice, bob)

    {:ok, _, []} =
      Messaging.send_batch(alice, "message", [
        %{"recipient_id" => bob.id, "ciphertext" => "ct", "nonce" => "n"}
      ])

    [notification] = Messaging.list_pending_notifications(bob)
    {:ok, _} = Messaging.accept_notification(bob, notification.id)
    {:ok, _, zip} = Export.build(bob)

    # Neither exported user remains; the permanent instance admin stays.
    {:ok, _} = Accounts.delete_user(bob)
    {:ok, _} = Accounts.delete_user(alice)

    {:ok, summary} = Import.from_zip(zip)
    assert summary.ghost_contacts == 1

    # senders are restored as remote contacts of the export's origin instance
    ghost = Repo.get_by(User, username: "alice", host: Veejr.instance_authority())
    assert ghost.public_key == alice.public_key
    assert ghost.email =~ ".invalid"
    # ghosts have no wrapped secret key and can never log in or decrypt
    refute ghost.enc_secret_key
    # local username lookups (login, directory) never see them
    refute Accounts.get_user_by_username("alice")

    new_bob = Accounts.get_user_by_username("bob")
    [restored] = Messaging.list_history(new_bob)
    assert restored.sender_id == ghost.id
    assert Veejr.Social.Address.handle(restored.sender) =~ "@alice@"
  end

  test "export requires nothing beyond ciphertext — plaintext never appears" do
    bob = user_with_keys("bob")
    {:ok, _, zip} = Export.build(bob)
    {:ok, files} = :zip.unzip(zip, [:memory])
    manifest = Jason.decode!(Map.new(files, fn {n, b} -> {to_string(n), b} end)["export.json"])

    # the wrapped secret key is present, a raw secret key is not a concept
    # the server ever has — spot-check the manifest keys
    assert Map.keys(manifest["keys"]) |> Enum.sort() ==
             ["enc_secret_key", "key_nonce", "key_salt", "public_key"]
  end

  test "export and import preserve attachment references for later deletion" do
    _admin = user_with_keys("portable_admin")
    user = user_with_keys("portable_attachment_owner")
    {:ok, blob} = Messaging.create_blob(user, "portable-video-ciphertext")

    assert {:ok, _batch_id, []} =
             Messaging.send_batch(
               user,
               "message",
               [%{"recipient_id" => user.id, "ciphertext" => "ct", "nonce" => "nonce"}],
               attachment_ids: [blob.public_id]
             )

    {:ok, _, zip} = Export.build(user)
    {:ok, _} = Accounts.delete_user(user)
    {:ok, _summary} = Import.from_zip(zip)

    restored_user = Accounts.get_user_by_username("portable_attachment_owner")
    restored_blob = Messaging.get_blob(blob.public_id)
    assert restored_blob
    [restored_envelope] = Messaging.list_history(restored_user)

    assert {:ok, {:deleted, 1}} =
             Messaging.delete_envelope(restored_user, restored_envelope.public_id)

    refute Messaging.get_blob(blob.public_id)
    refute File.exists?(restored_blob.path)
  end

  test "restore adds missing backup data to the matching existing account idempotently" do
    user = user_with_keys("restore_owner")

    assert {:ok, _batch_id, []} =
             Messaging.send_batch(user, "self_note", [
               %{"recipient_id" => user.id, "ciphertext" => "backup-ct", "nonce" => "nonce"}
             ])

    {:ok, blob} = Messaging.create_blob(user, "backup-blob")
    {:ok, _, zip} = Export.build(user)

    Repo.delete_all(Veejr.Messaging.BlobReference)
    Repo.delete_all(Veejr.Messaging.Envelope)
    Repo.delete_all(Veejr.Messaging.Blob)

    assert {:ok, summary} = Import.restore(zip, user)
    assert summary.envelopes == 1
    assert summary.blobs == 1
    assert [restored] = Messaging.list_history(user)
    assert restored.ciphertext == "backup-ct"
    assert File.read!(Messaging.get_blob(blob.public_id).path) == "backup-blob"

    assert {:ok, second_summary} = Import.restore(zip, user)
    assert second_summary.envelopes == 0
    assert second_summary.blobs == 0
  end

  test "restore rejects a backup from a different key identity" do
    alice = user_with_keys("restore_alice")
    bob = user_with_keys("restore_bob")
    {:ok, _, zip} = Export.build(alice)

    assert {:error, :account_mismatch} = Import.restore(zip, bob)
  end

  test "restore rejects unsafe archive paths before extraction" do
    user = user_with_keys("restore_safe")
    {:ok, _, zip} = Export.build(user)
    {:ok, files} = :zip.unzip(zip, [:memory])

    {:ok, {_name, unsafe_zip}} =
      :zip.create(~c"unsafe.zip", [{~c"../outside.txt", "nope"} | files], [:memory])

    assert {:error, :unsafe_archive} = Import.restore(unsafe_zip, user)
  end

  test "restore detects a changed encrypted blob" do
    user = user_with_keys("restore_integrity")
    {:ok, blob} = Messaging.create_blob(user, "original-ciphertext")
    {:ok, _, zip} = Export.build(user)
    {:ok, files} = :zip.unzip(zip, [:memory])
    blob_name = String.to_charlist("blobs/#{blob.public_id}.bin")

    tampered_files =
      Enum.map(files, fn
        {name, _binary} when name == blob_name ->
          {name, "changed-ciphertext"}

        file ->
          file
      end)

    {:ok, {_name, tampered_zip}} =
      :zip.create(~c"tampered.zip", tampered_files, [:memory])

    assert {:error, :integrity_check_failed} = Import.restore(tampered_zip, user)
  end

  test "delete_user withdraws sent envelopes from recipients" do
    bob = user_with_keys("bob")
    alice = user_with_keys("alice")
    befriend(alice, bob)

    {:ok, _, []} =
      Messaging.send_batch(alice, "message", [
        %{"recipient_id" => bob.id, "ciphertext" => "ct", "nonce" => "n"}
      ])

    [notification] = Messaging.list_pending_notifications(bob)
    {:ok, _} = Messaging.accept_notification(bob, notification.id)
    assert [_] = Messaging.list_history(bob)

    {:ok, _} = Accounts.delete_user(alice)

    # sender owns the data: deletion withdraws it everywhere
    assert Messaging.list_history(bob) == []
    assert Repo.aggregate(User, :count) == 1
  end

  defp jpeg(width, height) do
    component_data = :binary.copy(<<0>>, 12)

    <<
      0xFF,
      0xD8,
      0xFF,
      0xC0,
      0x00,
      0x11,
      0x08,
      height::16,
      width::16,
      component_data::binary,
      0xFF,
      0xD9
    >>
  end
end
