defmodule VeejrWeb.OutboxController do
  use VeejrWeb, :controller

  def recipients(conn, %{"friend_ids" => friends, "group_ids" => groups} = params)
      when is_list(friends) and is_list(groups) and length(friends) <= 100 and
             length(groups) <= 100 do
    json(conn, VeejrWeb.RecipientResolver.resolve(conn.assigns.current_scope.user, params))
  end

  def recipients(conn, _params),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "Invalid recipients."})

  def create(conn, %{"kind" => kind, "envelopes" => envelopes} = params)
      when is_list(envelopes) do
    opts = Map.take(params, ~w(client_batch_id attachment_ids expires_at max_displays deliver_at))

    case Veejr.Messaging.send_batch(conn.assigns.current_scope.user, kind, envelopes, opts) do
      {:ok, batch, _} ->
        Veejr.Messaging.broadcast_outbox_sent(conn.assigns.current_scope)
        json(conn, %{ok: true, batch_id: batch})

      {:error, _} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Sending failed. Check recipients and scheduling options."})
    end
  end

  def create(conn, _params),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "Invalid message."})
end
