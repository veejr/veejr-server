defmodule VeejrWeb.Api.V1.MessageBatchControllerTest do
  use VeejrWeb.ConnCase

  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Messaging, Repo, Social}
  alias Veejr.Messaging.BlobReference

  setup %{conn: conn} do
    alice = keyed_user("alice") |> set_password()
    bob = keyed_user("bob")
    {:ok, request} = Social.send_friend_request(alice, bob.username)
    {:ok, _friendship} = Social.accept_friend_request(bob, request.id)

    {:ok, _policy} =
      Messaging.put_delivery_policy(bob, "contact", alice.id, %{"acceptance" => "ask"})

    tokens = login(conn, alice)
    %{alice: alice, bob: bob, tokens: tokens}
  end

  test "lists and resolves accepted recipients", %{conn: conn, bob: bob, tokens: tokens} do
    contacts =
      conn
      |> authorize(tokens["access_token"])
      |> get("/api/v1/contacts")
      |> json_response(200)
      |> Map.fetch!("contacts")

    assert [%{"id" => id, "handle" => "@bob", "public_key" => public_key}] = contacts
    assert id == to_string(bob.id)
    assert public_key == bob.public_key

    response =
      build_conn()
      |> authorize(tokens["access_token"])
      |> post("/api/v1/recipients/resolve", %{
        "friend_ids" => [to_string(bob.id)],
        "group_ids" => [],
        "include_self" => true
      })
      |> json_response(200)

    assert Enum.sort(Enum.map(response["recipients"], & &1["id"])) ==
             Enum.sort([to_string(bob.id), to_string(response_id(response, "alice"))])

    assert response["missing_keys"] == []
  end

  test "creates one encrypted friend copy and one self-copy idempotently", %{
    conn: conn,
    alice: alice,
    bob: bob,
    tokens: tokens
  } do
    :ok = Messaging.subscribe(bob)
    params = batch_params(alice, bob)

    first =
      conn
      |> authorize(tokens["access_token"])
      |> put_req_header("idempotency-key", String.duplicate("a", 22))
      |> post("/api/v1/message-batches", params)
      |> json_response(201)

    second =
      build_conn()
      |> authorize(tokens["access_token"])
      |> put_req_header("idempotency-key", String.duplicate("a", 22))
      |> post("/api/v1/message-batches", params)
      |> json_response(200)

    assert second["batch_id"] == first["batch_id"]
    assert length(first["copies"]) == 2
    assert length(Messaging.list_pending_notifications(bob)) == 1
    assert_receive {:veejr_notification, notification}
    assert notification.user_id == bob.id
    refute_receive {:veejr_notification, _notification}
  end

  test "creates a single encrypted notes-to-self copy", %{
    conn: conn,
    alice: alice,
    tokens: tokens
  } do
    response =
      conn
      |> authorize(tokens["access_token"])
      |> put_req_header("idempotency-key", String.duplicate("s", 22))
      |> post("/api/v1/message-batches", %{
        "kind" => "message",
        "envelopes" => [
          %{
            "recipient_id" => to_string(alice.id),
            "ciphertext" => "for-alice",
            "nonce" => "nonce"
          }
        ]
      })
      |> json_response(201)

    assert [%{"recipient_id" => recipient_id}] = response["copies"]
    assert recipient_id == to_string(alice.id)
    assert [%{batch_id: batch_id}] = Messaging.list_history(alice, limit: 1)
    assert batch_id == response["batch_id"]
  end

  test "links uploaded attachment IDs through the API batch", %{
    conn: conn,
    alice: alice,
    bob: bob,
    tokens: tokens
  } do
    {:ok, blob} = Messaging.create_blob(alice, "encrypted-video")
    params = Map.put(batch_params(alice, bob), "attachment_ids", [blob.public_id])

    response =
      conn
      |> authorize(tokens["access_token"])
      |> put_req_header("idempotency-key", String.duplicate("v", 22))
      |> post("/api/v1/message-batches", params)
      |> json_response(201)

    assert Repo.get_by!(BlobReference, blob_id: blob.id, batch_id: response["batch_id"])
  end

  test "rejects reuse with another request and batches without a self-copy", %{
    conn: conn,
    alice: alice,
    bob: bob,
    tokens: tokens
  } do
    key = String.duplicate("b", 22)

    conn
    |> authorize(tokens["access_token"])
    |> put_req_header("idempotency-key", key)
    |> post("/api/v1/message-batches", batch_params(alice, bob))
    |> json_response(201)

    changed =
      put_in(batch_params(alice, bob), ["envelopes", Access.at(0), "ciphertext"], "changed")

    conflict =
      build_conn()
      |> authorize(tokens["access_token"])
      |> put_req_header("idempotency-key", key)
      |> post("/api/v1/message-batches", changed)
      |> json_response(409)

    assert conflict["error"]["code"] == "idempotency_conflict"

    invalid =
      put_in(batch_params(alice, bob), ["envelopes"], [hd(batch_params(alice, bob)["envelopes"])])

    response =
      build_conn()
      |> authorize(tokens["access_token"])
      |> put_req_header("idempotency-key", String.duplicate("c", 22))
      |> post("/api/v1/message-batches", invalid)
      |> json_response(422)

    assert response["error"]["code"] == "validation_failed"
  end

  defp response_id(response, username) do
    response["recipients"] |> Enum.find(&(&1["username"] == username)) |> Map.fetch!("id")
  end

  defp batch_params(alice, bob) do
    %{
      "kind" => "message",
      "expires_at" => nil,
      "max_displays" => nil,
      "envelopes" => [
        %{"recipient_id" => to_string(bob.id), "ciphertext" => "for-bob", "nonce" => "nonce"},
        %{"recipient_id" => to_string(alice.id), "ciphertext" => "for-alice", "nonce" => "nonce"}
      ]
    }
  end

  defp keyed_user(username) do
    user = user_fixture(%{username: username})

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        public_key: Base.encode64(binary_part(String.pad_trailing(username, 32, "x"), 0, 32)),
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
