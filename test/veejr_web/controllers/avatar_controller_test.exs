defmodule VeejrWeb.AvatarControllerTest do
  use VeejrWeb.ConnCase

  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Repo}
  alias Veejr.Accounts.User
  alias Veejr.Social.Friendship

  test "uploads and serves a normalized avatar", %{conn: conn} do
    user = user_fixture()

    upload_conn =
      conn
      |> log_in_user(user)
      |> put_req_header("content-type", "image/jpeg")
      |> post(~p"/account/avatar", jpeg(512, 512))

    assert %{"avatar_url" => avatar_url, "version" => 1} = json_response(upload_conn, 200)
    assert avatar_url == "/avatars/#{user.username}?v=1"

    response_conn = get(recycle(upload_conn), avatar_url)
    assert response(response_conn, 200) == jpeg(512, 512)
    assert get_resp_header(response_conn, "content-type") == ["image/jpeg; charset=utf-8"]
    assert get_resp_header(response_conn, "content-disposition") == ["inline"]
    assert get_resp_header(response_conn, "access-control-allow-origin") == ["*"]
  end

  test "proxies a federated friend's avatar as a same-origin texture", %{conn: conn} do
    user = user_fixture()

    remote =
      %User{}
      |> Ecto.Changeset.change(%{
        email: "remote+carol@remote.example.invalid",
        username: "carol",
        host: "remote.example",
        public_key: Base.encode64(:binary.copy(<<7>>, 32)),
        has_avatar: true,
        avatar_version: 3
      })
      |> Repo.insert!()

    %Friendship{}
    |> Friendship.changeset(%{
      requester_id: user.id,
      addressee_id: remote.id,
      status: "accepted"
    })
    |> Repo.insert!()

    image = jpeg(512, 512)

    Req.Test.stub(Veejr.FederationStub, fn request ->
      assert request.request_path == "/avatars/carol"
      assert request.query_string == "v=3"

      request
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, image)
    end)

    response_conn =
      conn
      |> log_in_user(user)
      |> get(~p"/avatar-textures/#{remote.id}?v=3")

    assert response(response_conn, 200) == image
    assert get_resp_header(response_conn, "content-type") == ["image/jpeg; charset=utf-8"]

    assert get_resp_header(response_conn, "cache-control") ==
             ["private, max-age=31536000, immutable"]
  end

  test "does not proxy an unconnected federated user's avatar", %{conn: conn} do
    user = user_fixture()

    remote =
      %User{}
      |> Ecto.Changeset.change(%{
        email: "remote+stranger@remote.example.invalid",
        username: "stranger",
        host: "remote.example",
        has_avatar: true,
        avatar_version: 1
      })
      |> Repo.insert!()

    conn =
      conn
      |> log_in_user(user)
      |> get(~p"/avatar-textures/#{remote.id}?v=1")

    assert response(conn, 404) == "not found"
  end

  test "rejects images that were not normalized to 512 pixels", %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> log_in_user(user)
      |> put_req_header("content-type", "image/jpeg")
      |> post(~p"/account/avatar", jpeg(640, 480))

    assert %{"error" => "Please choose a valid image."} = json_response(conn, 422)
    refute Accounts.get_user!(user.id).has_avatar
  end

  test "requires authentication to replace an avatar", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "image/jpeg")
      |> post(~p"/account/avatar", jpeg(512, 512))

    assert redirected_to(conn) == ~p"/users/log-in"
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
