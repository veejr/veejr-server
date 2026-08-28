defmodule VeejrWeb.BlobControllerTest do
  use VeejrWeb.ConnCase

  import Veejr.AccountsFixtures

  alias Veejr.Accounts.User
  alias Veejr.Messaging.Envelope
  alias Veejr.{Messaging, Repo}

  describe "GET /api/blobs/:id (public capability)" do
    setup do
      owner = user_fixture()
      {:ok, blob} = Messaging.create_blob(owner, "encrypted-bytes-here")
      %{blob: blob}
    end

    test "serves the encrypted bytes with permissive CORS, no session", %{conn: conn, blob: blob} do
      conn = get(conn, ~p"/api/blobs/#{blob.public_id}")

      assert conn.status == 200
      assert response(conn, 200) == "encrypted-bytes-here"
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert ["application/octet-stream" <> _] = get_resp_header(conn, "content-type")
    end

    test "404s on an unknown id", %{conn: conn} do
      conn = get(conn, ~p"/api/blobs/does-not-exist")
      assert conn.status == 404
    end
  end

  describe "GET /blobs/:id (authenticated relay)" do
    test "relays a federated sender's encrypted attachment over the viewer's origin", %{
      conn: conn
    } do
      recipient = user_fixture()

      sender =
        %User{}
        |> Ecto.Changeset.change(%{
          email: "remote+carol@remote.example.invalid",
          username: "carol",
          host: "remote.example",
          public_key: Base.encode64(:binary.copy(<<7>>, 32))
        })
        |> Repo.insert!()

      %Envelope{sender_id: sender.id, public_id: "remote-envelope", batch_id: "remote-envelope"}
      |> Envelope.changeset(%{
        recipient_id: recipient.id,
        kind: "message",
        ciphertext: "encrypted-envelope",
        nonce: "nonce"
      })
      |> Repo.insert!()

      Req.Test.stub(Veejr.FederationStub, fn request ->
        assert request.request_path == "/api/blobs/encrypted-video-id"
        Plug.Conn.send_resp(request, 200, "encrypted-video-bytes")
      end)

      response_conn =
        conn
        |> log_in_user(recipient)
        |> get(~p"/blobs/encrypted-video-id?origin=https://remote.example")

      assert response(response_conn, 200) == "encrypted-video-bytes"

      assert get_resp_header(response_conn, "cache-control") ==
               ["private, max-age=31536000, immutable"]
    end

    test "does not relay an origin that has not sent the viewer a message", %{conn: conn} do
      recipient = user_fixture()

      conn =
        conn
        |> log_in_user(recipient)
        |> get(~p"/blobs/encrypted-video-id?origin=https://untrusted.example")

      assert response(conn, 404) == "not found"
    end
  end
end
