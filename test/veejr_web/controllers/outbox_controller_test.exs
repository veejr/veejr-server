defmodule VeejrWeb.OutboxControllerTest do
  use VeejrWeb.ConnCase
  import Veejr.AccountsFixtures
  alias Veejr.Messaging

  test "an acknowledged retry creates one batch and refreshes the sender", %{conn: conn} do
    user = user_fixture()
    Messaging.subscribe(user)

    params = %{
      "kind" => "message",
      "client_batch_id" => "offline-browser-test-1234567890",
      "envelopes" => [
        %{"recipient_id" => user.id, "ciphertext" => "encrypted", "nonce" => "nonce"}
      ]
    }

    assert json_response(post(log_in_user(conn, user), "/outbox/messages", params), 200)["ok"]
    assert_receive {:veejr_outbox_sent}

    assert json_response(post(log_in_user(build_conn(), user), "/outbox/messages", params), 200)[
             "ok"
           ]

    assert [_] = Messaging.list_history(user)
  end

  test "queued messages cannot target another account without friendship", %{conn: conn} do
    user = user_fixture()
    other = user_fixture()

    params = %{
      "kind" => "message",
      "envelopes" => [%{"recipient_id" => other.id, "ciphertext" => "sealed", "nonce" => "nonce"}]
    }

    assert json_response(post(log_in_user(conn, user), "/outbox/messages", params), 422)["error"]
    assert Messaging.list_history(other) == []
  end
end
