defmodule VeejrWeb.FederationAuthTest do
  use VeejrWeb.ConnCase, async: false

  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Admin, Repo}
  alias Veejr.Federation.Peers.Peer

  @peer_authority "remote.example"

  # A pretend remote instance with its own signing identity.
  defp make_peer do
    {public, secret} = :crypto.generate_key(:eddsa, :ed25519)
    %{public: Base.encode64(public), secret: secret}
  end

  defp stub_peer_instance(peer) do
    Req.Test.stub(Veejr.FederationStub, fn conn ->
      case conn.request_path do
        "/api/instance" ->
          Req.Test.json(conn, %{host: @peer_authority, public_key: peer.public})

        "/api/directory/carol" ->
          Req.Test.json(conn, %{
            username: "carol",
            public_key: Base.encode64("carol-key"),
            host: @peer_authority
          })

        _ ->
          Plug.Conn.send_resp(conn, 404, "{}")
      end
    end)
  end

  defp sign(peer, path, timestamp, body) do
    body_hash = Base.encode64(:crypto.hash(:sha256, body))
    message = "veejr-v1|#{@peer_authority}|#{path}|#{timestamp}|#{body_hash}"
    Base.encode64(:crypto.sign(:eddsa, :none, message, [peer.secret, :ed25519]))
  end

  defp signed_post(conn, peer, path, payload, opts \\ []) do
    body = Jason.encode!(payload)
    timestamp = Keyword.get(opts, :timestamp, Integer.to_string(System.system_time(:second)))
    signature = Keyword.get(opts, :signature, sign(peer, path, timestamp, body))

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-veejr-authority", @peer_authority)
    |> put_req_header("x-veejr-timestamp", timestamp)
    |> put_req_header("x-veejr-signature", signature)
    |> post(path, body)
  end

  defp friend_request_payload do
    %{from: %{username: "carol", authority: @peer_authority}, to: "alice"}
  end

  setup do
    user_fixture(%{username: "alice"})
    :ok
  end

  test "a correctly signed request from a pinned peer is accepted", %{conn: conn} do
    peer = make_peer()
    stub_peer_instance(peer)

    conn = signed_post(conn, peer, "/api/federation/friend_request", friend_request_payload())
    assert json_response(conn, 200) == %{"ok" => true}

    alice = Accounts.get_user_by_username("alice")
    assert [_request] = Veejr.Social.list_incoming_requests(alice)
  end

  test "a signed presence assertion reaches the contact's local friends", %{conn: conn} do
    peer = make_peer()
    stub_peer_instance(peer)

    alice = Accounts.get_user_by_username("alice")
    {:ok, carol} = Veejr.Federation.ensure_remote_user("carol", @peer_authority)

    {:ok, _friendship} =
      %Veejr.Social.Friendship{}
      |> Ecto.Changeset.change(
        requester_id: alice.id,
        addressee_id: carol.id,
        status: "accepted"
      )
      |> Repo.insert()

    Phoenix.PubSub.subscribe(Veejr.PubSub, "user:#{alice.id}")

    conn =
      signed_post(conn, peer, "/api/federation/presence", %{
        from: %{authority: @peer_authority},
        ttl: 300,
        users: [%{username: "carol", state: "online"}]
      })

    assert json_response(conn, 200) == %{"ok" => true}
    assert_receive {:veejr_presence, carol_id, :online}
    assert carol_id == carol.id
  end

  test "unsigned requests are rejected", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/federation/friend_request", Jason.encode!(friend_request_payload()))

    assert json_response(conn, 401)["error"] =~ "signature"
  end

  test "a signature from the wrong key is rejected", %{conn: conn} do
    peer = make_peer()
    stub_peer_instance(peer)
    impostor = make_peer()

    body = Jason.encode!(friend_request_payload())
    timestamp = Integer.to_string(System.system_time(:second))

    conn =
      signed_post(conn, peer, "/api/federation/friend_request", friend_request_payload(),
        signature: sign(impostor, "/api/federation/friend_request", timestamp, body),
        timestamp: timestamp
      )

    assert json_response(conn, 401)
  end

  test "stale timestamps are rejected", %{conn: conn} do
    peer = make_peer()
    stub_peer_instance(peer)
    old = Integer.to_string(System.system_time(:second) - 3600)

    conn =
      signed_post(conn, peer, "/api/federation/friend_request", friend_request_payload(),
        timestamp: old
      )

    assert json_response(conn, 401)
  end

  test "a signed peer cannot speak for users of another instance", %{conn: conn} do
    peer = make_peer()
    stub_peer_instance(peer)

    payload = %{from: %{username: "mallory", authority: "other-instance.example"}, to: "alice"}
    conn = signed_post(conn, peer, "/api/federation/friend_request", payload)

    assert json_response(conn, 403)["error"] =~ "origin"
  end

  test "once pinned, a peer presenting a new key is rejected", %{conn: conn} do
    peer = make_peer()
    stub_peer_instance(peer)

    conn1 = signed_post(conn, peer, "/api/federation/friend_request", friend_request_payload())
    assert json_response(conn1, 200)

    # peer "rotates" its key — the pin must win
    rotated = make_peer()
    stub_peer_instance(rotated)

    conn2 =
      signed_post(
        build_conn(),
        rotated,
        "/api/federation/friend_request",
        friend_request_payload()
      )

    assert json_response(conn2, 401)
  end

  test "a blocked pinned peer is rejected before federation handlers run", %{conn: conn} do
    peer_key = make_peer()
    stub_peer_instance(peer_key)

    first =
      signed_post(conn, peer_key, "/api/federation/friend_request", friend_request_payload())

    assert json_response(first, 200)

    admin = Accounts.get_user_by_username("alice")
    pinned = Repo.get_by!(Peer, authority: @peer_authority)
    assert {:ok, _result} = Admin.block_peer(admin, pinned.id)

    blocked =
      signed_post(
        build_conn(),
        peer_key,
        "/api/federation/friend_request",
        friend_request_payload()
      )

    assert json_response(blocked, 401)["error"] =~ "signature"
  end
end
