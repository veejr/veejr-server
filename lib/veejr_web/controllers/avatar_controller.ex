defmodule VeejrWeb.AvatarController do
  use VeejrWeb, :controller

  alias Veejr.{Accounts, Social}
  alias Veejr.Accounts.Avatar
  alias Veejr.Federation.Client

  def show(conn, %{"username" => username}) do
    case Accounts.get_user_by_username(username) do
      %{has_avatar: true, avatar_version: version} = user when version > 0 ->
        case Accounts.get_user_avatar_image(user) do
          image when is_binary(image) ->
            conn
            |> put_resp_content_type("image/jpeg")
            |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
            |> put_resp_header("content-disposition", "inline")
            |> put_resp_header("x-content-type-options", "nosniff")
            |> put_resp_header("access-control-allow-origin", "*")
            |> send_resp(:ok, image)

          _ ->
            send_resp(conn, :not_found, "not found")
        end

      _ ->
        send_resp(conn, :not_found, "not found")
    end
  end

  def texture(conn, %{"id" => id}) do
    with {friend_id, ""} <- Integer.parse(id),
         %{host: host, username: username, avatar_version: version} <-
           Social.get_federated_friend(conn.assigns.current_scope, friend_id),
         {:ok, image} <- Client.get_avatar(host, username, version, Avatar.max_bytes()),
         :ok <- Avatar.validate(image) do
      conn
      |> put_resp_content_type("image/jpeg")
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> put_resp_header("content-disposition", "inline")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_resp(:ok, image)
    else
      _ -> send_resp(conn, :not_found, "not found")
    end
  end

  def create(conn, _params) do
    user = conn.assigns.current_scope.user

    case read_body(conn, length: Avatar.max_bytes()) do
      {:ok, body, conn} ->
        case Accounts.put_user_avatar(user, body) do
          {:ok, updated_user} ->
            json(conn, %{
              avatar_url: Accounts.avatar_url(updated_user),
              version: updated_user.avatar_version
            })

          {:error, reason} when reason in [:invalid_image, :invalid_dimensions] ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Please choose a valid image."})

          {:error, :too_large} ->
            too_large(conn)

          {:error, _changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Avatar could not be saved."})
        end

      {:more, _partial, conn} ->
        too_large(conn)
    end
  end

  defp too_large(conn) do
    conn
    |> put_status(:request_entity_too_large)
    |> json(%{error: "Avatar is too large."})
  end
end
