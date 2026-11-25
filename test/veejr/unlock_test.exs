defmodule Veejr.UnlockTest do
  use Veejr.DataCase
  import Veejr.AccountsFixtures
  alias Veejr.{Repo, Unlock}
  alias Veejr.Accounts.{Passkey, Scope}

  test "challenges are bound to a browser and purpose and consumed once" do
    user = user_fixture()
    challenge = Unlock.challenge("registration", "browser", user.id, %{value: 1})

    assert {:error, _} =
             Unlock.consume_challenge(challenge.id, "authentication", "browser", user.id)

    assert {:error, _} =
             Unlock.consume_challenge(challenge.id, "registration", "other-browser", user.id)

    assert {:ok, %{value: 1}} =
             Unlock.consume_challenge(challenge.id, "registration", "browser", user.id)

    assert {:error, _} =
             Unlock.consume_challenge(challenge.id, "registration", "browser", user.id)
  end

  test "a signed assertion verifies its origin, RP, user verification, signature and counter" do
    scope = Scope.for_user(user_fixture())
    handle = Unlock.user_handle(scope)

    {<<4, x::binary-size(32), y::binary-size(32)>>, private} =
      :crypto.generate_key(:ecdh, :secp256r1)

    raw_id = :crypto.strong_rand_bytes(32)
    key = %{1 => 2, 3 => -7, -1 => 1, -2 => x, -3 => y}

    Repo.insert!(%Passkey{
      user_id: scope.user.id,
      credential_id: Unlock.encode(raw_id),
      cose_key: :erlang.term_to_binary(key),
      label: "Test",
      sign_count: 0
    })

    challenge =
      Wax.new_authentication_challenge(
        origin: "https://example.com",
        rp_id: "example.com",
        user_verification: "required"
      )

    credential = assertion(challenge, raw_id, private, handle, "https://example.com", 5, 1)
    assert {:ok, user, _} = Unlock.authenticate(challenge, credential, nil)
    assert user.id == scope.user.id
    assert {:error, _} = Unlock.authenticate(challenge, credential, nil)

    assert {:error, _} =
             Unlock.authenticate(
               challenge,
               assertion(challenge, raw_id, private, handle, "https://evil.com", 5, 2),
               nil
             )

    assert {:error, _} =
             Unlock.authenticate(
               challenge,
               assertion(challenge, raw_id, private, handle, "https://example.com", 1, 2),
               nil
             )
  end

  test "device grants require approval, a secret claim token and a single claim" do
    user =
      user_fixture()
      |> Ecto.Changeset.change(public_key: Base.encode64(:crypto.strong_rand_bytes(32)))
      |> Repo.update!()

    scope = Scope.for_user(user)
    {:ok, link, token} = Unlock.start_link(Base.encode64(:crypto.strong_rand_bytes(32)))
    assert {:error, :pending} = Unlock.claim_link(link.id, token)

    sealed = %{
      "sender_key" => user.public_key,
      "nonce" => Base.encode64(:crypto.strong_rand_bytes(24)),
      "ciphertext" => "sealed"
    }

    assert :ok = Unlock.approve_link(scope, link.id, sealed)
    assert {:error, :pending} = Unlock.claim_link(link.id, "wrong")
    assert {:ok, claimed, ^sealed} = Unlock.claim_link(link.id, token)
    assert claimed.id == user.id
    assert {:error, :pending} = Unlock.claim_link(link.id, token)
  end

  test "registers a genuine none-attestation credential and rejects a duplicate" do
    scope = Scope.for_user(user_fixture())

    {<<4, x::binary-size(32), y::binary-size(32)>>, _private} =
      :crypto.generate_key(:ecdh, :secp256r1)

    key = %{
      1 => 2,
      3 => -7,
      -1 => 1,
      -2 => %CBOR.Tag{tag: :bytes, value: x},
      -3 => %CBOR.Tag{tag: :bytes, value: y}
    }

    raw_id = :crypto.strong_rand_bytes(32)

    challenge =
      Wax.new_registration_challenge(
        origin: "https://example.com",
        rp_id: "example.com",
        user_verification: "required",
        attestation: "none",
        trusted_attestation_types: [:none],
        verify_trust_root: false
      )

    client =
      Jason.encode!(%{
        type: "webauthn.create",
        challenge: Unlock.encode(challenge.bytes),
        origin: "https://example.com"
      })

    auth =
      :crypto.hash(:sha256, "example.com") <>
        <<69, 0::32, 0::128, 32::16>> <> raw_id <> CBOR.encode(key)

    attestation =
      CBOR.encode(%{
        "fmt" => "none",
        "attStmt" => %{},
        "authData" => %CBOR.Tag{tag: :bytes, value: auth}
      })

    credential = %{
      "response" => %{
        "attestationObject" => Unlock.encode(attestation),
        "clientDataJSON" => Unlock.encode(client)
      }
    }

    assert {:ok, passkey} = Unlock.register(scope, challenge, credential, "Phone")
    assert passkey.credential_id == Unlock.encode(raw_id)

    assert {:error, %Ecto.Changeset{}} =
             Unlock.register(scope, challenge, credential, "Duplicate")
  end

  defp assertion(challenge, raw_id, private, handle, origin, flags, count) do
    client =
      Jason.encode!(%{
        type: "webauthn.get",
        challenge: Unlock.encode(challenge.bytes),
        origin: origin
      })

    auth = :crypto.hash(:sha256, "example.com") <> <<flags, count::32>>

    signature =
      :crypto.sign(:ecdsa, :sha256, auth <> :crypto.hash(:sha256, client), [private, :secp256r1])

    %{
      "id" => Unlock.encode(raw_id),
      "response" => %{
        "clientDataJSON" => Unlock.encode(client),
        "authenticatorData" => Unlock.encode(auth),
        "signature" => Unlock.encode(signature),
        "userHandle" => Unlock.encode(handle)
      }
    }
  end
end
