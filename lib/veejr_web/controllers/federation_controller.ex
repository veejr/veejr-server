defmodule VeejrWeb.FederationController do
  @moduledoc """
  Inbound half of the instance-to-instance protocol. All identity claims are
  verified by callback to the claimed instance's directory — see
  `Veejr.Federation` for the trust model.
  """
  use VeejrWeb, :controller

  alias Veejr.{Federation, Messaging}

  # Presence is chattier than anything else a peer sends, so it gets its own
  # budget on top of the pipeline's: a peer flapping its users must not be
  # able to spend the allowance that friend requests and message notices
  # share.
  plug VeejrWeb.Plugs.RateLimit,
       [bucket: :federation_presence, by: :federation_authority] when action == :presence

  def friend_request(conn, params),
    do: respond(conn, Federation.handle_friend_request(params, conn.assigns.federation_peer))

  def friend_response(conn, params),
    do: respond(conn, Federation.handle_friend_response(params, conn.assigns.federation_peer))

  def notify(conn, params),
    do: respond(conn, Federation.handle_notify(params, conn.assigns.federation_peer))

  def key_update(conn, params),
    do: respond(conn, Federation.handle_key_update(params, conn.assigns.federation_peer))

  def account_move(conn, params),
    do: respond(conn, Federation.handle_account_move(params, conn.assigns.federation_peer))

  def call_invite(conn, params),
    do: respond(conn, Federation.handle_call_invite(params, conn.assigns.federation_peer))

  def call_update(conn, params),
    do: respond(conn, Federation.handle_call_update(params, conn.assigns.federation_peer))

  def call_signal(conn, params),
    do: respond(conn, Federation.handle_call_signal(params, conn.assigns.federation_peer))

  def call_schedule(conn, params),
    do: respond(conn, Federation.handle_call_schedule(params, conn.assigns.federation_peer))

  def presence(conn, params),
    do: respond(conn, Federation.handle_presence(params, conn.assigns.federation_peer))

  # Capability fetch: the recipient's instance retrieves ciphertext after the
  # recipient accepted. Only envelopes addressed to remote users are served.
  def envelope(conn, %{"public_id" => public_id}) do
    case Messaging.get_public_envelope(public_id) do
      {:ok, envelope} ->
        json(conn, %{kind: envelope.kind, ciphertext: envelope.ciphertext, nonce: envelope.nonce})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})
    end
  end

  defp respond(conn, result) do
    case result do
      {:ok, _} -> json(conn, %{ok: true})
      {:error, :unknown_recipient} -> error(conn, :not_found, "unknown recipient")
      {:error, :not_friends} -> error(conn, :forbidden, "not friends")
      {:error, :origin_mismatch} -> error(conn, :forbidden, "origin does not match signature")
      {:error, :key_changed} -> error(conn, :conflict, "pinned key mismatch")
      {:error, :bad_request} -> error(conn, :bad_request, "malformed request")
      {:error, {:unreachable, _}} -> error(conn, :bad_gateway, "could not verify origin")
      {:error, {:http, _}} -> error(conn, :bad_gateway, "could not verify origin")
      {:error, _} -> error(conn, :unprocessable_entity, "rejected")
    end
  end

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end
end
