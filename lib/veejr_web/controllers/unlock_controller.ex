defmodule VeejrWeb.UnlockController do
  use VeejrWeb, :controller
  alias Veejr.{Accounts, Unlock}
  alias VeejrWeb.UserAuth

  plug :no_store
  plug :validate_id when action in [:show_link, :approve_link, :claim_link, :delete_passkey]

  plug :recent_auth
       when action in [
              :registration_options,
              :registration_verify,
              :put_slot,
              :delete_passkey,
              :approve_link
            ]

  def options(conn, _params) do
    {conn, binding} = flow_binding(conn)
    scope = conn.assigns.current_scope
    challenge = Wax.new_authentication_challenge(wax_options())
    record = Unlock.challenge("authentication", binding, scope && scope.user.id, challenge)

    json(conn, %{
      challenge_id: record.id,
      options: %{
        challenge: Unlock.encode(challenge.bytes),
        rpId: challenge.rp_id,
        timeout: 300_000,
        userVerification: "required"
      }
    })
  end

  def verify(conn, %{"challenge_id" => id, "credential" => credential}) do
    scope = conn.assigns.current_scope

    with {:ok, challenge} <-
           Unlock.consume_challenge(
             id,
             "authentication",
             get_session(conn, :unlock_binding),
             scope && scope.user.id
           ),
         {:ok, user, passkey} <-
           Unlock.authenticate(challenge, credential, scope && scope.user.id) do
      slot =
        Enum.find(Unlock.slots(Accounts.Scope.for_user(user)), &(&1.passkey_id == passkey.id))

      UserAuth.log_in_user_json(conn, user, %{
        user_id: user.id,
        public_key: user.public_key,
        passkey_id: passkey.id,
        slot: slot && slot.wrapped
      })
    else
      _ -> failure(conn)
    end
  rescue
    _ -> failure(conn)
  end

  def registration_options(conn, _params) do
    scope = conn.assigns.current_scope
    {conn, binding} = flow_binding(conn)
    challenge = Wax.new_registration_challenge(wax_options())
    record = Unlock.challenge("registration", binding, scope.user.id, challenge)

    json(conn, %{
      challenge_id: record.id,
      options: %{
        challenge: Unlock.encode(challenge.bytes),
        timeout: 300_000,
        rp: %{id: challenge.rp_id, name: "Veejr"},
        user: %{
          id: Unlock.encode(Unlock.user_handle(scope)),
          name: scope.user.username,
          displayName: scope.user.username
        },
        pubKeyCredParams: [%{type: "public-key", alg: -7}, %{type: "public-key", alg: -257}],
        authenticatorSelection: %{residentKey: "required", userVerification: "required"},
        attestation: "none",
        excludeCredentials:
          Enum.map(Unlock.passkeys(scope), &%{id: &1.credential_id, type: "public-key"})
      }
    })
  end

  def registration_verify(conn, %{"challenge_id" => id, "credential" => credential} = params) do
    scope = conn.assigns.current_scope

    with {:ok, challenge} <-
           Unlock.consume_challenge(
             id,
             "registration",
             get_session(conn, :unlock_binding),
             scope.user.id
           ),
         {:ok, passkey} <- Unlock.register(scope, challenge, credential, params["label"]) do
      json(conn, %{id: passkey.id})
    else
      _ -> failure(conn)
    end
  rescue
    _ -> failure(conn)
  end

  def index(conn, _params) do
    scope = conn.assigns.current_scope

    json(conn, %{
      passkeys: Enum.map(Unlock.passkeys(scope), &Map.take(&1, [:id, :label, :last_used_at])),
      slots: Enum.map(Unlock.slots(scope), &Map.take(&1, [:id, :kind, :passkey_id, :wrapped]))
    })
  end

  def put_slot(conn, params) do
    case Unlock.put_slot(conn.assigns.current_scope, params) do
      {:ok, _} -> json(conn, %{ok: true})
      _ -> failure(conn)
    end
  end

  def delete_passkey(conn, %{"id" => id}) do
    Unlock.delete_passkey(conn.assigns.current_scope, id)
    json(conn, %{ok: true})
  end

  def start_link(conn, %{"public_key" => key}) do
    with {:ok, link, token} <- Unlock.start_link(key) do
      url = VeejrWeb.Endpoint.url() <> "/keys?link=" <> link.id
      {:ok, qr} = url |> QRCode.create(:medium) |> QRCode.render(:svg) |> QRCode.to_base64()
      json(conn, %{id: link.id, token: token, url: url, qr: qr})
    else
      _ -> failure(conn)
    end
  end

  def show_link(conn, %{"id" => id}) do
    case Unlock.link(id) do
      nil -> failure(conn)
      link -> json(conn, %{id: link.id, public_key: link.public_key})
    end
  end

  def approve_link(conn, %{"id" => id, "sealed" => sealed}) do
    case Unlock.approve_link(conn.assigns.current_scope, id, sealed) do
      :ok -> json(conn, %{ok: true})
      _ -> failure(conn)
    end
  end

  def claim_link(conn, %{"id" => id, "token" => token}) do
    case Unlock.claim_link(id, token) do
      {:ok, user, sealed} ->
        UserAuth.log_in_user_json(conn, user, %{
          user_id: user.id,
          public_key: user.public_key,
          sealed: sealed
        })

      {:error, :pending} ->
        json(conn, %{pending: true})

      _ ->
        failure(conn)
    end
  end

  defp no_store(conn, _), do: put_resp_header(conn, "cache-control", "no-store")

  defp validate_id(conn, _) do
    case Ecto.UUID.cast(conn.params["id"]) do
      {:ok, _} -> conn
      _ -> conn |> failure() |> halt()
    end
  end

  defp recent_auth(conn, _) do
    if conn.assigns.current_scope && Accounts.sudo_mode?(conn.assigns.current_scope.user) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Sign in again to manage unlock methods."})
      |> halt()
    end
  end

  defp wax_options do
    origin = VeejrWeb.Endpoint.url()

    [
      origin: origin,
      rp_id: URI.parse(origin).host,
      user_verification: "required",
      timeout: 300,
      attestation: "none",
      trusted_attestation_types: [:none],
      verify_trust_root: false
    ]
  end

  defp flow_binding(conn) do
    value = get_session(conn, :unlock_binding) || Unlock.encode(:crypto.strong_rand_bytes(32))
    {put_session(conn, :unlock_binding, value), value}
  end

  defp failure(conn),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "Unlock request failed or expired. Start again."})
end
