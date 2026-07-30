defmodule VeejrWeb.Api.V1.AuthControllerTest do
  use VeejrWeb.ConnCase

  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Admin}

  describe "GET /api/v1/capabilities" do
    test "advertises the stable client contract without authentication", %{conn: conn} do
      response = conn |> get("/api/v1/capabilities") |> json_response(200)

      assert response["api_versions"] == [1]
      assert response["payload_versions"] == [1]
      assert response["message_kinds"] == ["message", "location", "note", "self_note", "self_doc"]
      assert response["max_blob_bytes"] == 25 * 1024 * 1024
      assert response["android_push"] == false
    end
  end

  describe "POST /api/v1/auth/login" do
    test "creates a revocable Android device session", %{conn: conn} do
      user = user_fixture() |> set_password()

      response =
        conn
        |> post("/api/v1/auth/login", login_params(user))
        |> json_response(200)

      assert response["account"]["id"] == to_string(user.id)
      assert response["account"]["email"] == user.email
      assert response["account"]["keys_configured"] == false
      assert response["account"]["wrapped_key"] == nil
      assert is_binary(response["tokens"]["access_token"])
      assert is_binary(response["tokens"]["refresh_token"])
      assert is_binary(response["tokens"]["device_session_id"])
    end

    test "returns one generic error for invalid credentials", %{conn: conn} do
      user = user_fixture() |> set_password()

      response =
        conn
        |> post("/api/v1/auth/login", %{login_params(user) | "password" => "wrong password"})
        |> json_response(401)

      assert response["error"]["code"] == "invalid_credentials"
      refute response["error"]["message"] =~ user.email
    end

    test "validates device metadata", %{conn: conn} do
      user = user_fixture() |> set_password()
      params = put_in(login_params(user), ["device", "platform"], "ios")

      response = conn |> post("/api/v1/auth/login", params) |> json_response(422)

      assert response["error"]["code"] == "validation_failed"
      assert response["error"]["details"]["fields"]["platform"]
    end

    test "accepts a username as the login identifier", %{conn: conn} do
      user = user_fixture() |> set_password()

      response =
        conn
        |> post("/api/v1/auth/login", %{login_params(user) | "identifier" => user.username})
        |> json_response(200)

      assert response["account"]["id"] == to_string(user.id)
    end

    test "returns the generic credentials error for a suspended account", %{conn: conn} do
      admin = user_fixture()
      user = user_fixture() |> set_password()
      assert {:ok, _result} = Admin.suspend_user(admin, user.id)

      response = conn |> post("/api/v1/auth/login", login_params(user)) |> json_response(401)

      assert response["error"]["code"] == "invalid_credentials"
    end
  end

  describe "one-time Android login" do
    test "sends a non-enumerating magic link and exchanges its one-time token", %{conn: conn} do
      user = user_fixture()

      assert conn
             |> post("/api/v1/auth/magic-link", %{"identifier" => user.username})
             |> response(202) == "{}"

      {one_time_token, _hashed_token} = generate_user_magic_link_token(user)

      response =
        build_conn()
        |> post("/api/v1/auth/magic-link/exchange", %{
          "token" => one_time_token,
          "device" => login_params(user)["device"]
        })
        |> json_response(200)

      assert response["account"]["id"] == to_string(user.id)
      assert is_binary(response["tokens"]["access_token"])

      assert build_conn()
             |> post("/api/v1/auth/magic-link/exchange", %{
               "token" => one_time_token,
               "device" => login_params(user)["device"]
             })
             |> json_response(401)
             |> get_in(["error", "code"]) == "invalid_one_time_token"
    end

    test "does not disclose whether an identifier exists", %{conn: conn} do
      assert conn
             |> post("/api/v1/auth/magic-link", %{"identifier" => "nobody"})
             |> response(202) == "{}"
    end
  end

  describe "authenticated device session" do
    setup %{conn: conn} do
      admin = user_fixture()
      user = user_fixture() |> set_password()
      login = conn |> post("/api/v1/auth/login", login_params(user)) |> json_response(200)
      %{admin: admin, user: user, tokens: login["tokens"]}
    end

    test "GET /api/v1/me returns wrapped roaming key material", %{
      conn: conn,
      user: user,
      tokens: tokens
    } do
      {:ok, _user} =
        Accounts.setup_user_keys(user, %{
          public_key: Base.encode64(:crypto.strong_rand_bytes(32)),
          enc_secret_key: Base.encode64(:crypto.strong_rand_bytes(48)),
          key_salt: Base.encode64(:crypto.strong_rand_bytes(16)),
          key_nonce: Base.encode64(:crypto.strong_rand_bytes(24))
        })

      response =
        conn
        |> authorize(tokens["access_token"])
        |> get("/api/v1/me")
        |> json_response(200)

      assert response["account"]["keys_configured"]
      assert response["account"]["wrapped_key"]["kdf"]["iterations"] == 310_000
      assert response["account"]["wrapped_key"]["wrap"] == "XSalsa20-Poly1305"
    end

    test "rejects missing and malformed bearer credentials", %{conn: conn} do
      assert conn |> get("/api/v1/me") |> json_response(401) |> get_in(["error", "code"]) ==
               "authentication_required"

      assert conn
             |> authorize("not-a-token")
             |> get("/api/v1/me")
             |> json_response(401)
             |> get_in(["error", "code"]) == "authentication_required"
    end

    test "refresh rotates both tokens and rejects the old access token", %{
      conn: conn,
      tokens: tokens
    } do
      refreshed =
        conn
        |> post("/api/v1/auth/refresh", %{"refresh_token" => tokens["refresh_token"]})
        |> json_response(200)
        |> Map.fetch!("tokens")

      refute refreshed["access_token"] == tokens["access_token"]
      refute refreshed["refresh_token"] == tokens["refresh_token"]

      assert conn
             |> authorize(tokens["access_token"])
             |> get("/api/v1/me")
             |> json_response(401)

      assert conn
             |> authorize(refreshed["access_token"])
             |> get("/api/v1/me")
             |> json_response(200)
    end

    test "refresh token reuse revokes the device session", %{conn: conn, tokens: tokens} do
      first_refresh =
        conn
        |> post("/api/v1/auth/refresh", %{"refresh_token" => tokens["refresh_token"]})
        |> json_response(200)
        |> Map.fetch!("tokens")

      second_refresh =
        conn
        |> post("/api/v1/auth/refresh", %{"refresh_token" => first_refresh["refresh_token"]})
        |> json_response(200)
        |> Map.fetch!("tokens")

      assert conn
             |> post("/api/v1/auth/refresh", %{"refresh_token" => tokens["refresh_token"]})
             |> json_response(401)

      assert conn
             |> authorize(second_refresh["access_token"])
             |> get("/api/v1/me")
             |> json_response(401)
    end

    test "suspension rejects current access and refresh tokens", %{
      admin: admin,
      conn: conn,
      user: user,
      tokens: tokens
    } do
      assert {:ok, _result} = Admin.suspend_user(admin, user.id)

      assert conn
             |> authorize(tokens["access_token"])
             |> get("/api/v1/me")
             |> json_response(401)

      assert build_conn()
             |> post("/api/v1/auth/refresh", %{"refresh_token" => tokens["refresh_token"]})
             |> json_response(401)
    end

    test "DELETE /api/v1/auth/session logs out only the current device", %{
      conn: conn,
      tokens: tokens
    } do
      conn =
        conn
        |> authorize(tokens["access_token"])
        |> delete("/api/v1/auth/session")

      assert response(conn, 204) == ""

      assert build_conn()
             |> authorize(tokens["access_token"])
             |> get("/api/v1/me")
             |> json_response(401)
    end

    test "registers and removes an Android push token for the current device", %{
      conn: conn,
      tokens: tokens
    } do
      assert conn
             |> authorize(tokens["access_token"])
             |> put("/api/v1/devices/current/push-token", %{"token" => "fcm-token"})
             |> response(204) == ""

      assert conn
             |> authorize(tokens["access_token"])
             |> delete("/api/v1/devices/current/push-token")
             |> response(204) == ""
    end
  end

  defp login_params(user) do
    %{
      "identifier" => user.email,
      "password" => valid_user_password(),
      "device" => %{
        "name" => "Test Pixel",
        "platform" => "android",
        "app_version" => "0.1.0-alpha01"
      }
    }
  end

  defp authorize(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")
end
