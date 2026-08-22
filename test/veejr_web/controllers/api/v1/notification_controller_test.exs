defmodule VeejrWeb.Api.V1.NotificationControllerTest do
  use VeejrWeb.ConnCase

  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Messaging, Social}

  describe "native notification consent API" do
    setup %{conn: conn} do
      alice = keyed_user("alice")
      bob = keyed_user("bob") |> set_password()
      {:ok, request} = Social.send_friend_request(alice, bob.username)
      {:ok, _friendship} = Social.accept_friend_request(bob, request.id)

      {:ok, _policy} =
        Messaging.put_delivery_policy(bob, "contact", alice.id, %{
          "acceptance" => "ask",
          "notification" => "normal"
        })

      {:ok, _batch_id, _deliveries} =
        Messaging.send_batch(alice, "message", [
          %{"recipient_id" => bob.id, "ciphertext" => "bob-ciphertext", "nonce" => "bob-nonce"},
          %{
            "recipient_id" => alice.id,
            "ciphertext" => "alice-ciphertext",
            "nonce" => "alice-nonce"
          }
        ])

      tokens = login(conn, bob)
      %{alice: alice, bob: bob, tokens: tokens}
    end

    test "lists metadata without releasing ciphertext", %{conn: conn, tokens: tokens} do
      response =
        conn
        |> authorize(tokens["access_token"])
        |> get("/api/v1/notifications?state=pending")
        |> json_response(200)

      assert [notification] = response["notifications"]
      assert notification["kind"] == "message"
      assert notification["sender"]["handle"] == "@alice"
      refute Map.has_key?(notification, "ciphertext")
      refute Jason.encode!(response) =~ "bob-ciphertext"
    end

    test "accept returns the authorized encrypted envelope", %{conn: conn, tokens: tokens} do
      [notification] = pending(conn, tokens)

      response =
        build_conn()
        |> authorize(tokens["access_token"])
        |> post("/api/v1/notifications/#{notification["id"]}/accept")
        |> json_response(200)

      assert response["envelope"]["ciphertext"] == "bob-ciphertext"
      assert response["envelope"]["nonce"] == "bob-nonce"
      assert response["envelope"]["peer_key"]
      assert pending(build_conn(), tokens) == []
    end

    test "decline removes metadata without returning content", %{conn: conn, tokens: tokens} do
      [notification] = pending(conn, tokens)

      response_conn =
        build_conn()
        |> authorize(tokens["access_token"])
        |> post("/api/v1/notifications/#{notification["id"]}/decline")

      assert response(response_conn, 204) == ""
      assert pending(build_conn(), tokens) == []
    end

    test "another user cannot accept the recipient's notification", %{
      conn: conn,
      alice: alice,
      tokens: bob_tokens
    } do
      [notification] = pending(conn, bob_tokens)
      alice = alice |> set_password()
      alice_tokens = login(build_conn(), alice)

      response =
        build_conn()
        |> authorize(alice_tokens["access_token"])
        |> post("/api/v1/notifications/#{notification["id"]}/accept")
        |> json_response(404)

      assert response["error"]["code"] == "not_found"
    end
  end

  defp keyed_user(username) do
    user = user_fixture(%{username: username})

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        public_key: Base.encode64(:binary.copy(<<1>>, 32)),
        enc_secret_key: Base.encode64(:binary.copy(<<2>>, 48)),
        key_salt: Base.encode64(:binary.copy(<<3>>, 16)),
        key_nonce: Base.encode64(:binary.copy(<<4>>, 24))
      })

    user
  end

  defp pending(conn, tokens) do
    conn
    |> authorize(tokens["access_token"])
    |> get("/api/v1/notifications?state=pending")
    |> json_response(200)
    |> Map.fetch!("notifications")
  end

  defp login(conn, user) do
    conn
    |> post("/api/v1/auth/login", %{
      "email" => user.email,
      "password" => valid_user_password(),
      "device" => %{
        "name" => "Test Pixel",
        "platform" => "android",
        "app_version" => "0.1.0-alpha01"
      }
    })
    |> json_response(200)
    |> Map.fetch!("tokens")
  end

  defp authorize(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")
end
