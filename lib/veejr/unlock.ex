defmodule Veejr.Unlock do
  @moduledoc "Web passkeys, factor-wrapped identity keys, and single-use device grants."
  import Ecto.Query
  alias Veejr.Repo
  alias Veejr.Accounts.{DeviceLink, KeySlot, Passkey, Scope, SecurityChallenge, User}

  def passkeys(%Scope{user: user}) do
    Repo.all(from(p in Passkey, where: p.user_id == ^user.id, order_by: p.inserted_at))
  end

  def slots(%Scope{user: user}) do
    Repo.all(
      from(s in KeySlot, where: s.user_id == ^user.id and s.public_key == ^user.public_key)
    )
  end

  def user_handle(%Scope{user: user}) do
    handle = :crypto.strong_rand_bytes(32)

    from(u in User, where: u.id == ^user.id and is_nil(u.passkey_handle))
    |> Repo.update_all(set: [passkey_handle: handle])

    Repo.get!(User, user.id).passkey_handle
  end

  def challenge(purpose, binding, user_id, data) do
    now = DateTime.utc_now(:second)
    Repo.delete_all(from(c in SecurityChallenge, where: c.expires_at <= ^now))
    Repo.delete_all(from(l in DeviceLink, where: l.expires_at <= ^now))

    Repo.insert!(%SecurityChallenge{
      id: random_token(),
      binding: binding,
      purpose: purpose,
      user_id: user_id,
      data: :erlang.term_to_binary(data),
      expires_at: DateTime.add(now, 300)
    })
  end

  def consume_challenge(id, purpose, binding, user_id) when is_binary(id) do
    now = DateTime.utc_now(:second)

    query =
      from(c in SecurityChallenge,
        where:
          c.id == ^id and c.purpose == ^purpose and c.binding == ^binding and c.expires_at > ^now,
        select: c
      )

    case Repo.delete_all(query) do
      {1, [challenge]} when challenge.user_id == user_id ->
        {:ok, :erlang.binary_to_term(challenge.data, [:safe])}

      _ ->
        {:error, :invalid_challenge}
    end
  end

  def consume_challenge(_, _, _, _), do: {:error, :invalid_challenge}

  def register(%Scope{user: user}, challenge, credential, label) do
    with {:ok, attestation} <- decode(credential["response"]["attestationObject"]),
         {:ok, client_data} <- decode(credential["response"]["clientDataJSON"]),
         {:ok, {auth, _}} <- Wax.register(attestation, client_data, challenge) do
      data = auth.attested_credential_data

      %Passkey{
        user_id: user.id,
        credential_id: encode(data.credential_id),
        cose_key: :erlang.term_to_binary(data.credential_public_key),
        sign_count: auth.sign_count,
        label: String.slice(to_string(label || "Passkey"), 0, 80)
      }
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint(:credential_id)
      |> Repo.insert()
    end
  end

  def authenticate(challenge, credential, expected_user_id) do
    with %Passkey{} = passkey <- Repo.get_by(Passkey, credential_id: credential["id"]),
         true <- is_nil(expected_user_id) or passkey.user_id == expected_user_id,
         %User{suspended_at: nil} = user <- Repo.get(User, passkey.user_id),
         {:ok, raw_id} <- decode(passkey.credential_id),
         {:ok, auth_data} <- decode(credential["response"]["authenticatorData"]),
         {:ok, signature} <- decode(credential["response"]["signature"]),
         {:ok, client_data} <- decode(credential["response"]["clientDataJSON"]),
         {:ok, auth} <-
           Wax.authenticate(raw_id, auth_data, signature, client_data, challenge, [
             {raw_id, :erlang.binary_to_term(passkey.cose_key, [:safe])}
           ]),
         true <- valid_user_handle?(credential["response"]["userHandle"], user.passkey_handle),
         true <-
           (auth.sign_count == 0 and passkey.sign_count == 0) or
             auth.sign_count > passkey.sign_count do
      # Compare-and-swap protects counters when two assertions arrive together.
      {count, _} =
        from(p in Passkey, where: p.id == ^passkey.id and p.sign_count == ^passkey.sign_count)
        |> Repo.update_all(
          set: [sign_count: auth.sign_count, last_used_at: DateTime.utc_now(:second)]
        )

      if count == 1, do: {:ok, user, passkey}, else: {:error, :counter_changed}
    else
      _ -> {:error, :invalid_passkey}
    end
  end

  defp valid_user_handle?(nil, _), do: true
  defp valid_user_handle?(value, handle), do: decode(value) == {:ok, handle}

  def put_slot(%Scope{user: user}, params) do
    kind = params["kind"]
    passkey_id = if kind == "passkey_prf", do: params["passkey_id"]
    wrapped = params["wrapped"]

    with true <- kind in ~w(passkey_prf recovery_code),
         true <- is_binary(user.public_key) and params["public_key"] == user.public_key,
         true <- valid_wrap?(wrapped, kind),
         true <- kind == "recovery_code" or valid_passkey?(user.id, passkey_id) do
      Repo.transact(fn ->
        query = from(s in KeySlot, where: s.user_id == ^user.id and s.kind == ^kind)

        query =
          if kind == "passkey_prf",
            do: where(query, [s], s.passkey_id == ^passkey_id),
            else: query

        Repo.delete_all(query)

        Repo.insert(%KeySlot{
          user_id: user.id,
          kind: kind,
          passkey_id: passkey_id,
          public_key: user.public_key,
          wrapped: wrapped
        })
      end)
    else
      _ -> {:error, :invalid_slot}
    end
  end

  defp valid_passkey?(id, passkey_id) when is_binary(passkey_id) do
    case Ecto.UUID.cast(passkey_id) do
      {:ok, uuid} -> Repo.exists?(from(p in Passkey, where: p.user_id == ^id and p.id == ^uuid))
      :error -> false
    end
  end

  defp valid_passkey?(_, _), do: false

  defp valid_wrap?(
         %{"salt" => salt, "nonce" => nonce, "ciphertext" => ciphertext, "info" => info},
         kind
       ) do
    info == "veejr key-slot v1 " <> String.replace(kind, "_", "-") and
      base64_size?(salt, 16) and base64_size?(nonce, 24) and base64_size?(ciphertext, 48)
  end

  defp valid_wrap?(_, _), do: false

  def delete_passkey(%Scope{user: user}, id) do
    Repo.delete_all(from(p in Passkey, where: p.user_id == ^user.id and p.id == ^id))
    :ok
  end

  def start_link(public_key) do
    now = DateTime.utc_now(:second)
    Repo.delete_all(from(l in DeviceLink, where: l.expires_at <= ^now))

    if base64_size?(public_key, 32) do
      token = random_token()

      case Repo.insert(%DeviceLink{
             token_hash: :crypto.hash(:sha256, token),
             public_key: public_key,
             expires_at: DateTime.add(DateTime.utc_now(:second), 300)
           }) do
        {:ok, link} -> {:ok, link, token}
        error -> error
      end
    else
      {:error, :invalid_key}
    end
  end

  def link(id) do
    now = DateTime.utc_now(:second)

    Repo.one(
      from(l in DeviceLink, where: l.id == ^id and l.expires_at > ^now and is_nil(l.user_id))
    )
  end

  def approve_link(%Scope{user: user}, id, sealed) do
    with true <- base64_size?(sealed["nonce"], 24),
         true <- is_binary(sealed["ciphertext"]) and byte_size(sealed["ciphertext"]) < 2000,
         true <- sealed["sender_key"] == user.public_key do
      now = DateTime.utc_now(:second)

      {count, _} =
        from(l in DeviceLink, where: l.id == ^id and is_nil(l.user_id) and l.expires_at > ^now)
        |> Repo.update_all(set: [user_id: user.id, sealed_key: sealed])

      if count == 1, do: :ok, else: {:error, :invalid_link}
    else
      _ -> {:error, :invalid_key}
    end
  end

  def claim_link(id, token) when is_binary(token) do
    now = DateTime.utc_now(:second)
    hash = :crypto.hash(:sha256, token)

    query =
      from(l in DeviceLink,
        where:
          l.id == ^id and l.token_hash == ^hash and l.expires_at > ^now and not is_nil(l.user_id),
        select: l
      )

    case Repo.delete_all(query) do
      {1, [link]} ->
        sender_key = link.sealed_key["sender_key"]

        case Repo.get(User, link.user_id) do
          %User{suspended_at: nil} = user when user.public_key == sender_key ->
            {:ok, user, link.sealed_key}

          _ ->
            {:error, :invalid_link}
        end

      _ ->
        {:error, :pending}
    end
  end

  def base64_size?(value, length) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, bytes} -> byte_size(bytes) == length
      _ -> false
    end
  end

  def base64_size?(_, _), do: false
  def encode(bytes), do: Base.url_encode64(bytes, padding: false)

  def decode(value) when is_binary(value) and byte_size(value) < 100_000,
    do: Base.url_decode64(value, padding: false)

  def decode(_), do: :error
  defp random_token, do: encode(:crypto.strong_rand_bytes(32))
end
