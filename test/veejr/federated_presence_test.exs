defmodule Veejr.FederatedPresenceTest do
  use Veejr.DataCase, async: false

  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Federation, Presence, Social}

  @remote_host "remote.example"
  @other_host "other.example"
  @carol_key Base.encode64("carol-public-key")

  defp local_user(username) do
    user = user_fixture(%{username: username})

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        "public_key" => Base.encode64("pub-" <> username),
        "enc_secret_key" => Base.encode64("wrapped-" <> username),
        "key_salt" => Base.encode64("salt"),
        "key_nonce" => Base.encode64("nonce")
      })

    user
  end

  defp stub_remote(handler) when is_function(handler, 1) do
    Req.Test.stub(Veejr.FederationStub, handler)
  end

  defp directory_stub(username, host) do
    fn conn ->
      case conn.request_path do
        "/api/directory/" <> ^username ->
          Req.Test.json(conn, %{username: username, public_key: @carol_key, host: host})

        "/api/federation/" <> _ ->
          Req.Test.json(conn, %{ok: true})

        _ ->
          Plug.Conn.send_resp(conn, 404, "{}")
      end
    end
  end

  # A remote contact who is an accepted friend of `user`.
  defp remote_friend(user, username, host) do
    stub_remote(directory_stub(username, host))
    {:ok, remote} = Federation.ensure_remote_user(username, host)

    {:ok, _} =
      %Social.Friendship{}
      |> Ecto.Changeset.change(
        requester_id: user.id,
        addressee_id: remote.id,
        status: "accepted"
      )
      |> Repo.insert()

    remote
  end

  describe "addressing" do
    test "groups changes into one payload per peer" do
      alice = local_user("alice")
      remote_friend(alice, "carol", @remote_host)
      remote_friend(alice, "dave", @other_host)

      deliveries = Presence.peer_deliveries([{alice.id, :online}])

      assert Enum.sort_by(deliveries, &elem(&1, 0)) == [
               {@other_host, [%{username: "alice", state: "online"}]},
               {@remote_host, [%{username: "alice", state: "online"}]}
             ]
    end

    test "one request carries every affected user on that peer" do
      alice = local_user("alice")
      bob = local_user("bob")
      remote_friend(alice, "carol", @remote_host)
      remote_friend(bob, "carol", @remote_host)

      assert [{@remote_host, entries}] =
               Presence.peer_deliveries([{alice.id, :online}, {bob.id, :recently}])

      assert Enum.sort_by(entries, & &1.username) == [
               %{username: "alice", state: "online"},
               %{username: "bob", state: "recently"}
             ]
    end

    test "a user with only local friends addresses nobody" do
      alice = local_user("alice")
      bob = local_user("bob")
      {:ok, request} = Social.send_friend_request(alice, bob.username)
      {:ok, _} = Social.accept_friend_request(bob, request.id)

      assert Presence.peer_deliveries([{alice.id, :online}]) == []
    end

    test "a pending remote friendship is not somebody to tell" do
      alice = local_user("alice")
      stub_remote(directory_stub("carol", @remote_host))
      {:ok, _} = Social.send_remote_friend_request(alice, "carol", @remote_host)

      assert Presence.peer_deliveries([{alice.id, :online}]) == []
    end
  end

  describe "delivering to a peer" do
    setup do
      parent = self()

      stub_remote(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:presence_post, conn.request_path, Jason.decode!(body)})
        Req.Test.json(conn, %{ok: true})
      end)

      :ok
    end

    test "posts the origin, a ttl, and the users" do
      assert :ok =
               Federation.deliver_presence(@remote_host, [
                 %{username: "alice", state: "online"}
               ])

      assert_receive {:presence_post, "/api/federation/presence", payload}
      assert payload["from"]["authority"] == Veejr.instance_authority()
      assert payload["users"] == [%{"username" => "alice", "state" => "online"}]
      assert is_integer(payload["ttl"]) and payload["ttl"] > 0
    end

    test "an empty change set is not a request" do
      assert :ok = Federation.deliver_presence(@remote_host, [])
      refute_receive {:presence_post, _, _}, 50
    end
  end

  describe "peers that do not speak presence" do
    test "a 404 parks the peer instead of posting on every transition" do
      parent = self()

      stub_remote(fn conn ->
        send(parent, :attempted)
        Plug.Conn.send_resp(conn, 404, "{}")
      end)

      entries = [%{username: "alice", state: "online"}]

      assert {:error, :unsupported} = Federation.deliver_presence(@remote_host, entries)
      assert_receive :attempted

      # Parked: the next transition does not go near the network.
      assert :ok = Federation.deliver_presence(@remote_host, entries)
      refute_receive :attempted, 50
    end

    test "the peer is retried once the backoff lapses" do
      previous = Application.get_env(:veejr, :presence_unsupported_backoff_ms)
      Application.put_env(:veejr, :presence_unsupported_backoff_ms, 0)
      on_exit(fn -> restore(:presence_unsupported_backoff_ms, previous) end)

      parent = self()
      stub_remote(fn conn -> send(parent, :attempted) && Plug.Conn.send_resp(conn, 404, "{}") end)

      entries = [%{username: "alice", state: "online"}]
      assert {:error, :unsupported} = Federation.deliver_presence(@remote_host, entries)
      assert_receive :attempted

      assert {:error, :unsupported} = Federation.deliver_presence(@remote_host, entries)
      assert_receive :attempted
    end

    test "a peer that starts answering is un-parked" do
      Presence.mark_peer_unsupported(@remote_host)
      refute Presence.peer_supported?(@remote_host)

      Presence.mark_peer_supported(@remote_host)
      assert Presence.peer_supported?(@remote_host)
    end
  end

  describe "receiving from a peer" do
    setup do
      alice = local_user("alice")
      carol = remote_friend(alice, "carol", @remote_host)
      Phoenix.PubSub.subscribe(Veejr.PubSub, "user:#{alice.id}")

      %{alice: alice, carol: carol}
    end

    defp presence_payload(users, authority \\ @remote_host, extra \\ %{}) do
      Map.merge(%{"from" => %{"authority" => authority}, "users" => users}, extra)
    end

    test "records the state and tells the local friend", %{carol: carol} do
      assert {:ok, :accepted} =
               Federation.handle_presence(
                 presence_payload([%{"username" => "carol", "state" => "online"}]),
                 @remote_host
               )

      assert_receive {:veejr_presence, carol_id, :online}
      assert carol_id == carol.id
      assert Presence.state(carol) == :online
    end

    test "a remote contact starts out unknown, not offline", %{carol: carol} do
      assert Presence.state(carol) == :unknown
    end

    test "an instance cannot speak for another instance's users" do
      assert {:error, :origin_mismatch} =
               Federation.handle_presence(
                 presence_payload([%{"username" => "carol", "state" => "online"}], @remote_host),
                 @other_host
               )
    end

    test "withdrawing the claim clears the dot", %{carol: carol} do
      {:ok, :accepted} =
        Federation.handle_presence(
          presence_payload([%{"username" => "carol", "state" => "online"}]),
          @remote_host
        )

      assert_receive {:veejr_presence, _, :online}

      assert {:ok, :accepted} =
               Federation.handle_presence(
                 presence_payload([%{"username" => "carol", "state" => "unknown"}]),
                 @remote_host
               )

      assert_receive {:veejr_presence, _, :unknown}
      assert Presence.state(carol) == :unknown
      refute :ets.member(Veejr.Presence.Remote, carol.id)
    end

    test "a contact nobody here is friends with is nobody's business" do
      stub_remote(directory_stub("dave", @remote_host))
      {:ok, dave} = Federation.ensure_remote_user("dave", @remote_host)

      assert {:ok, :accepted} =
               Federation.handle_presence(
                 presence_payload([%{"username" => "dave", "state" => "online"}]),
                 @remote_host
               )

      assert Presence.state(dave) == :unknown
      refute_receive {:veejr_presence, _, _}, 50
    end

    test "a user we have never heard of is ignored, not created" do
      before = Repo.aggregate(Veejr.Accounts.User, :count)

      assert {:ok, :accepted} =
               Federation.handle_presence(
                 presence_payload([%{"username" => "nobody", "state" => "online"}]),
                 @remote_host
               )

      assert Repo.aggregate(Veejr.Accounts.User, :count) == before
    end

    test "a state we do not recognise is dropped, and the rest still land", %{carol: carol} do
      assert {:ok, :accepted} =
               Federation.handle_presence(
                 presence_payload([
                   %{"username" => "carol", "state" => "busy-doing-science"},
                   %{"username" => "carol", "state" => "recently"}
                 ]),
                 @remote_host
               )

      assert Presence.state(carol) == :recently
    end

    test "malformed payloads are rejected" do
      assert {:error, :bad_request} = Federation.handle_presence(%{"users" => []}, @remote_host)
      assert {:error, :bad_request} = Federation.handle_presence(%{}, @remote_host)
    end
  end

  describe "assertions going stale" do
    setup do
      alice = local_user("alice")
      carol = remote_friend(alice, "carol", @remote_host)
      Phoenix.PubSub.subscribe(Veejr.PubSub, "user:#{alice.id}")

      %{alice: alice, carol: carol}
    end

    test "a lapsed ttl reads as unknown rather than offline", %{carol: carol} do
      {:ok, :accepted} =
        Federation.handle_presence(
          presence_payload([%{"username" => "carol", "state" => "online"}], @remote_host, %{
            "ttl" => 1
          }),
          @remote_host
        )

      assert Presence.state(carol) == :online

      Process.sleep(1_100)

      # Silence means we lost the peer, not that carol went away.
      assert Presence.state(carol) == :unknown
    end

    test "the heartbeat sweeps stale rows and tells the local friend", %{carol: carol} do
      {:ok, :accepted} =
        Federation.handle_presence(
          presence_payload([%{"username" => "carol", "state" => "online"}], @remote_host, %{
            "ttl" => 1
          }),
          @remote_host
        )

      assert_receive {:veejr_presence, _, :online}
      Process.sleep(1_100)

      Presence.tick()

      assert_receive {:veejr_presence, carol_id, :unknown}
      assert carol_id == carol.id
      refute :ets.member(Veejr.Presence.Remote, carol.id)
    end

    test "a peer cannot make us hold a claim indefinitely", %{carol: carol} do
      {:ok, :accepted} =
        Federation.handle_presence(
          presence_payload([%{"username" => "carol", "state" => "online"}], @remote_host, %{
            "ttl" => 999_999_999
          }),
          @remote_host
        )

      [{_id, _state, expires_at}] = :ets.lookup(Veejr.Presence.Remote, carol.id)
      held_ms = expires_at - System.monotonic_time(:millisecond)

      assert held_ms <= 900 * 1_000
    end
  end

  defp restore(key, nil), do: Application.delete_env(:veejr, key)
  defp restore(key, value), do: Application.put_env(:veejr, key, value)
end
