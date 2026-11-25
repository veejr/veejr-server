defmodule VeejrWeb.UnlockControllerTest do
  use VeejrWeb.ConnCase
  import Veejr.AccountsFixtures
  alias Veejr.{Accounts, Repo, Unlock}

  test "management requires login and recent authentication", %{conn: conn} do
    assert redirected_to(get(conn, "/unlock/methods")) == "/users/log-in"
    user = keyed_user()
    stale = %{user | authenticated_at: DateTime.add(DateTime.utc_now(:second), -3600)}
    conn = log_in_user(conn, stale) |> post("/unlock/registration/options", %{})
    assert json_response(conn, 403)["error"] =~ "Sign in again"
  end

  test "stores a recovery slot, replaces it atomically and hides stale identity slots", %{
    conn: conn
  } do
    user = keyed_user()

    wrapped = %{
      "salt" => Base.encode64(:crypto.strong_rand_bytes(16)),
      "nonce" => Base.encode64(:crypto.strong_rand_bytes(24)),
      "ciphertext" => Base.encode64(:crypto.strong_rand_bytes(48)),
      "info" => "veejr key-slot v1 recovery-code"
    }

    params = %{"kind" => "recovery_code", "public_key" => user.public_key, "wrapped" => wrapped}
    assert json_response(post(log_in_user(conn, user), "/unlock/slots", params), 200)["ok"]

    assert json_response(post(log_in_user(build_conn(), user), "/unlock/slots", params), 200)[
             "ok"
           ]

    assert [_] = Unlock.slots(Accounts.Scope.for_user(user))
    result = get(log_in_user(build_conn(), user), "/unlock/methods")
    assert get_resp_header(result, "cache-control") == ["no-store"]
    assert [%{"kind" => "recovery_code"}] = json_response(result, 200)["slots"]

    {:ok, changed} =
      user
      |> Ecto.Changeset.change(public_key: Base.encode64(:crypto.strong_rand_bytes(32)))
      |> Repo.update()

    assert [] = Unlock.slots(Accounts.Scope.for_user(changed))
  end

  test "registration options use a random stable account handle and a fixed origin", %{conn: conn} do
    user = keyed_user()

    response =
      post(log_in_user(conn, user), "/unlock/registration/options", %{}) |> json_response(200)

    options = response["options"]
    assert options["authenticatorSelection"]["userVerification"] == "required"
    assert {:ok, handle} = Unlock.decode(options["user"]["id"])
    assert byte_size(handle) == 32
    assert handle == Unlock.user_handle(Accounts.Scope.for_user(user))
    assert options["rp"]["id"] == URI.parse(VeejrWeb.Endpoint.url()).host
  end

  defp keyed_user do
    user = user_fixture()

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        public_key: Base.encode64(:crypto.strong_rand_bytes(32)),
        enc_secret_key: Base.encode64(:crypto.strong_rand_bytes(48)),
        key_salt: Base.encode64(:crypto.strong_rand_bytes(16)),
        key_nonce: Base.encode64(:crypto.strong_rand_bytes(24))
      })

    user
  end
end
