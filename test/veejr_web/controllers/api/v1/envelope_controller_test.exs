defmodule VeejrWeb.Api.V1.EnvelopeControllerTest do
  use VeejrWeb.ConnCase

  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Messaging, Social}

  setup %{conn: conn} do
    alice = keyed_user("history_alice") |> set_password()
    bob = keyed_user("history_bob") |> set_password()
    eve = keyed_user("history_eve") |> set_password()
    {:ok, request} = Social.send_friend_request(alice, bob.username)
    {:ok, _friendship} = Social.accept_friend_request(bob, request.id)

    {:ok, _policy} =
      Messaging.put_delivery_policy(bob, "contact", alice.id, %{
        "acceptance" => "ask",
        "notification" => "normal"
      })

    {:ok, _batch_id, _deliveries} =
      Messaging.send_batch(alice, "message", [
        %{"recipient_id" => bob.id, "ciphertext" => "bob-secret", "nonce" => "bob-nonce"},
        %{"recipient_id" => alice.id, "ciphertext" => "alice-copy", "nonce" => "alice-nonce"}
      ])

    %{conn: conn, alice: alice, bob: bob, eve: eve}
  end

  test "history releases self-copies but not pending recipient ciphertext", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
    alice_response = history(conn, alice)
    assert [copy] = alice_response["envelopes"]
    assert copy["ciphertext"] == "alice-copy"
    assert copy["sent_by_me"]

    bob_response = history(build_conn(), bob)
    assert bob_response["envelopes"] == []

    [notification] = Messaging.list_pending_notifications(bob)
    {:ok, _accepted} = Messaging.accept_notification(bob, notification.id)

    accepted_response = history(build_conn(), bob)
    assert [received] = accepted_response["envelopes"]
    assert received["ciphertext"] == "bob-secret"
    refute received["sent_by_me"]
  end

  test "a cursor from another account is rejected without leaking history", %{
    conn: conn,
    alice: alice,
    eve: eve
  } do
    [copy] = history(conn, alice)["envelopes"]
    tokens = login(build_conn(), eve)

    response =
      build_conn()
      |> authorize(tokens["access_token"])
      |> get("/api/v1/envelopes?kind=message&cursor=#{copy["public_id"]}")
      |> json_response(400)

    assert response["error"]["code"] == "invalid_cursor"
    refute Jason.encode!(response) =~ "alice-copy"
  end

  test "a cursor returns the next older encrypted copies", %{conn: conn, alice: alice, bob: bob} do
    {:ok, _batch_id, _deliveries} =
      Messaging.send_batch(alice, "message", [
        %{"recipient_id" => bob.id, "ciphertext" => "new-bob", "nonce" => "new-bob-nonce"},
        %{"recipient_id" => alice.id, "ciphertext" => "new-copy", "nonce" => "new-copy-nonce"}
      ])

    tokens = login(conn, alice)
    [newest, _older] = history_with_tokens(build_conn(), tokens)["envelopes"]

    response =
      build_conn()
      |> authorize(tokens["access_token"])
      |> get("/api/v1/envelopes?kind=message&cursor=#{newest["public_id"]}")
      |> json_response(200)

    assert [older] = response["envelopes"]
    assert older["ciphertext"] == "alice-copy"
  end

  test "an unsupported kind is rejected", %{conn: conn, alice: alice} do
    tokens = login(conn, alice)

    response =
      build_conn()
      |> authorize(tokens["access_token"])
      |> get("/api/v1/envelopes?kind=video")
      |> json_response(400)

    assert response["error"]["code"] == "invalid_kind"
  end

  defp history(conn, user) do
    tokens = login(conn, user)

    history_with_tokens(build_conn(), tokens)
  end

  defp history_with_tokens(conn, tokens) do
    conn
    |> authorize(tokens["access_token"])
    |> get("/api/v1/envelopes?kind=message")
    |> json_response(200)
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
