defmodule VeejrWeb.InstanceControllerTest do
  use VeejrWeb.ConnCase

  import Veejr.AccountsFixtures

  alias Veejr.Accounts

  describe "GET /api/instance" do
    test "describes the instance without authentication", %{conn: conn} do
      body = conn |> get("/api/instance") |> json_response(200)

      assert body["software"] == "veejr"
      assert body["version"] == Veejr.version()
      assert body["mode"] == to_string(Veejr.instance_mode())
      assert is_boolean(body["registration_open"])
      assert is_binary(body["public_key"])
    end
  end

  describe "GET /api/directory/:username" do
    test "publishes the public key of a user who has set up keys", %{conn: conn} do
      user = user_fixture()
      key = Base.encode64(:binary.copy(<<1>>, 32))

      {:ok, _} =
        Accounts.setup_user_keys(user, %{
          "public_key" => key,
          "enc_secret_key" => Base.encode64(:binary.copy(<<2>>, 48)),
          "key_salt" => Base.encode64(:binary.copy(<<3>>, 16)),
          "key_nonce" => Base.encode64(:binary.copy(<<4>>, 24))
        })

      body = conn |> get("/api/directory/#{user.username}") |> json_response(200)

      assert body["username"] == user.username
      assert body["public_key"] == key
      refute Map.has_key?(body, "enc_secret_key")
    end

    test "404s for a user with no published key", %{conn: conn} do
      user = user_fixture()

      assert conn |> get("/api/directory/#{user.username}") |> json_response(404)
    end

    test "404s for an unknown user", %{conn: conn} do
      assert conn |> get("/api/directory/nobody_here") |> json_response(404)
    end
  end

  describe "GET /api/v1/capabilities" do
    test "advertises the API contract without authentication", %{conn: conn} do
      body = conn |> get("/api/v1/capabilities") |> json_response(200)

      assert body["api_versions"] == [1]
      assert body["payload_versions"] == [1]
      assert body["extensions"] == %{"calls" => 1}
      assert is_integer(body["max_blob_bytes"])
      assert is_list(body["message_kinds"])
      assert is_list(body["add_ons"])
    end
  end
end
