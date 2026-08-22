defmodule Veejr.FederationTest do
  use Veejr.DataCase, async: false

  import Veejr.AccountsFixtures

  alias Veejr.Accounts.User
  alias Veejr.{Accounts, Federation, Messaging, Repo, Social}
  alias Veejr.Social.Address

  @remote_host "remote.example"
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

  # Stub the remote instance: a directory that knows carol, plus accepting
  # federation endpoints. Tests that expect no HTTP simply don't call this.
  defp stub_remote_instance(opts \\ []) do
    envelope_body =
      Keyword.get(opts, :envelope, %{ciphertext: "remote-ct", nonce: "remote-nonce"})

    Req.Test.stub(Veejr.FederationStub, fn conn ->
      case conn.request_path do
        "/api/directory/carol" ->
          Req.Test.json(conn, %{
            username: "carol",
            display_name: "Carol",
            has_avatar: true,
            avatar_version: 3,
            avatar_url: "https://remote.example/avatars/carol?v=3",
            public_key: @carol_key,
            host: @remote_host
          })

        "/api/directory/" <> _ ->
          Plug.Conn.send_resp(conn, 404, "{}")

        "/api/federation/" <> _ ->
          Req.Test.json(conn, %{ok: true})

        "/api/envelopes/" <> _ ->
          Req.Test.json(conn, envelope_body)
      end
    end)
  end

  describe "address parsing" do
    test "authorities route local vs remote" do
      ours = Veejr.instance_authority()

      assert {:local, "bob"} = Address.parse("bob")
      assert {:local, "bob"} = Address.parse("@Bob@#{ours}")
      assert {:remote, "carol", "remote.example"} = Address.parse("carol@remote.example")
      assert {:remote, "carol", "localhost:4001"} = Address.parse("carol@localhost:4001")
      assert {:error, :invalid} = Address.parse("no spaces allowed@x")
      assert {:error, :invalid} = Address.parse("carol@")
    end
  end

  describe "outgoing friend requests" do
    test "pins the remote key and mirrors a pending friendship" do
      alice = local_user("alice")
      stub_remote_instance()

      assert {:ok, fr} = Social.send_remote_friend_request(alice, "carol", @remote_host)
      assert fr.status == "pending"
      assert fr.addressee.host == @remote_host
      assert fr.addressee.public_key == @carol_key
      assert fr.addressee.has_avatar

      assert Accounts.avatar_url(fr.addressee) ==
               "https://remote.example/avatars/carol?v=3"

      # repeat is rejected
      assert {:error, :already_requested} =
               Social.send_remote_friend_request(alice, "carol", @remote_host)
    end

    test "accepts an incoming remote request that mirrors our outgoing pending request" do
      alice = local_user("alice")
      stub_remote_instance()

      assert {:ok, outgoing} = Social.send_remote_friend_request(alice, "carol", @remote_host)
      assert outgoing.status == "pending"

      assert {:ok, accepted} =
               Federation.handle_friend_request(
                 %{
                   "from" => %{"username" => "carol", "authority" => @remote_host},
                   "to" => "alice"
                 },
                 @remote_host
               )

      assert accepted.id == outgoing.id
      assert accepted.status == "accepted"
      assert Social.list_incoming_requests(alice) == []
      assert Social.friends?(accepted.requester_id, accepted.addressee_id)
    end

    test "leaves nothing behind when the remote instance is down" do
      alice = local_user("alice")

      Req.Test.stub(Veejr.FederationStub, fn conn ->
        case conn.request_path do
          "/api/directory/carol" ->
            Req.Test.json(conn, %{username: "carol", public_key: @carol_key, host: @remote_host})

          _ ->
            Plug.Conn.send_resp(conn, 500, "boom")
        end
      end)

      assert {:error, {:http, 500}} =
               Social.send_remote_friend_request(alice, "carol", @remote_host)

      assert Social.list_outgoing_requests(alice) == []
    end
  end

  describe "account moves" do
    test "a signed move notice preserves an existing local friendship and address book data" do
      alice = local_user("alice")

      old_contact =
        %User{}
        |> Ecto.Changeset.change(
          email: "remote+carol@old.example.invalid",
          username: "carol",
          host: "old.example",
          public_key: @carol_key
        )
        |> Repo.insert!()

      Req.Test.stub(Veejr.FederationStub, fn conn ->
        case conn.request_path do
          "/api/directory/carol" ->
            Req.Test.json(conn, %{
              username: "carol",
              public_key: @carol_key,
              host: "new.example"
            })

          "/api/federation/" <> _ ->
            Req.Test.json(conn, %{ok: true})
        end
      end)

      {:ok, request} = Social.receive_remote_friend_request(old_contact, alice)
      {:ok, _} = Social.accept_friend_request(alice, request.id)
      {:ok, group} = Social.create_group(alice, %{name: "Travel"})
      {:ok, _} = Social.add_group_member(alice, group.id, old_contact.id)
      {:ok, _} = Social.upsert_contact_note(alice, old_contact.id, "Carol moved")

      assert {:ok, %{friendships: 1}} =
               Federation.handle_account_move(
                 %{
                   "from" => %{"username" => "carol", "authority" => "old.example"},
                   "new_authority" => "new.example"
                 },
                 "old.example"
               )

      replacement = Repo.get_by!(User, username: "carol", host: "new.example")
      assert Social.friends?(alice.id, replacement.id)
      assert Enum.map(Social.group_members(alice, group.id), & &1.id) == [replacement.id]
      assert Social.list_contact_notes(alice)[replacement.id] == "Carol moved"
    end
  end

  describe "incoming federation requests" do
    test "friend request verifies by callback, then accept notifies origin" do
      alice = local_user("alice")
      stub_remote_instance()

      params = %{
        "from" => %{"username" => "carol", "authority" => @remote_host},
        "to" => "alice"
      }

      assert {:ok, _} = Federation.handle_friend_request(params, @remote_host)
      # idempotent
      assert {:ok, _} = Federation.handle_friend_request(params, @remote_host)

      assert [request] = Social.list_incoming_requests(alice)
      assert request.requester.host == @remote_host
      assert request.requester.public_key == @carol_key

      assert {:ok, fr} = Social.accept_friend_request(alice, request.id)
      assert fr.status == "accepted"
      assert Social.friends?(alice.id, fr.requester.id)
    end

    test "claims of being local are refused before any callback" do
      assert {:error, :bad_request} =
               Federation.handle_friend_request(
                 %{
                   "from" => %{"username" => "mallory", "authority" => Veejr.instance_authority()},
                   "to" => "alice"
                 },
                 Veejr.instance_authority()
               )
    end

    test "notify from a non-friend is rejected" do
      _alice = local_user("alice")
      stub_remote_instance()

      assert {:error, :not_friends} =
               Federation.handle_notify(
                 %{
                   "from" => %{"username" => "carol", "authority" => @remote_host},
                   "to" => "alice",
                   "kind" => "message",
                   "public_id" => "spam123"
                 },
                 @remote_host
               )

      assert Repo.aggregate(Veejr.Messaging.Envelope, :count) == 0
    end
  end

  describe "cross-instance message delivery" do
    setup do
      alice = local_user("alice")
      stub_remote_instance()

      {:ok, _} =
        Federation.handle_friend_request(
          %{
            "from" => %{"username" => "carol", "authority" => @remote_host},
            "to" => "alice"
          },
          @remote_host
        )

      [request] = Social.list_incoming_requests(alice)
      {:ok, fr} = Social.accept_friend_request(alice, request.id)
      # deliver the queued friend_response so tests start with an empty outbox
      {1, 0} = Veejr.Federation.Outbox.process_due()
      %{alice: alice, carol: fr.requester}
    end

    test "incoming notify stores a content-free stub until accepted", %{
      alice: alice,
      carol: carol
    } do
      {:ok, _policy} =
        Messaging.put_delivery_policy(alice, "contact", carol.id, %{
          "acceptance" => "ask",
          "notification" => "normal"
        })

      assert {:ok, :created} =
               Federation.handle_notify(
                 %{
                   "from" => %{"username" => "carol", "authority" => @remote_host},
                   "to" => "alice",
                   "kind" => "message",
                   "public_id" => "remote-env-1"
                 },
                 @remote_host
               )

      # duplicate deliveries are absorbed
      assert {:ok, :duplicate} =
               Federation.handle_notify(
                 %{
                   "from" => %{"username" => "carol", "authority" => @remote_host},
                   "to" => "alice",
                   "kind" => "message",
                   "public_id" => "remote-env-1"
                 },
                 @remote_host
               )

      assert [notification] = Messaging.list_pending_notifications(alice)
      assert notification.envelope.ciphertext == ""
      # nothing decryptable is on this instance yet
      assert Messaging.list_history(alice) == []

      # accepting fetches the ciphertext from the origin
      assert {:ok, _} = Messaging.accept_notification(alice, notification.id)
      assert [envelope] = Messaging.list_history(alice)
      assert envelope.ciphertext == "remote-ct"
      assert envelope.nonce == "remote-nonce"
      assert Address.handle(envelope.sender) == "@carol@#{@remote_host}"
    end

    test "sending to a remote friend keeps the envelope here and notifies them",
         %{alice: alice, carol: carol} do
      assert {:ok, batch_id, ["@carol@" <> _]} =
               Messaging.send_batch(alice, "message", [
                 %{"recipient_id" => carol.id, "ciphertext" => "ct-carol", "nonce" => "n"},
                 %{"recipient_id" => alice.id, "ciphertext" => "ct-self", "nonce" => "n"}
               ])

      # the notify was enqueued transactionally; the outbox delivers it
      assert Veejr.Federation.Outbox.pending_count() == 1
      assert {1, 0} = Veejr.Federation.Outbox.process_due()
      assert Veejr.Federation.Outbox.pending_count() == 0

      # no local notification rows for remote recipients
      assert Repo.aggregate(Veejr.Messaging.Notification, :count) == 0

      # carol's copy is served over the capability endpoint...
      envelope =
        Repo.get_by(Veejr.Messaging.Envelope, batch_id: batch_id, recipient_id: carol.id)

      assert {:ok, served} = Messaging.get_public_envelope(envelope.public_id)
      assert served.ciphertext == "ct-carol"
      assert served.delivered_at

      # ...but alice's local self-copy is not
      self_copy =
        Repo.get_by(Veejr.Messaging.Envelope, batch_id: batch_id, recipient_id: alice.id)

      assert {:error, :not_found} = Messaging.get_public_envelope(self_copy.public_id)

      assert Messaging.batch_recipients(alice, batch_id) == ["@carol@#{@remote_host}"]
    end

    test "sends to unreachable instances stay parked for retry",
         %{alice: alice, carol: carol} do
      Req.Test.stub(Veejr.FederationStub, fn conn ->
        Plug.Conn.send_resp(conn, 503, "down")
      end)

      assert {:ok, _batch_id, ["@carol@" <> _]} =
               Messaging.send_batch(alice, "message", [
                 %{"recipient_id" => carol.id, "ciphertext" => "ct", "nonce" => "n"}
               ])

      # the failed attempt backs off instead of dropping the notify
      assert Veejr.Federation.Outbox.pending_count() == 1
      assert {0, 1} = Veejr.Federation.Outbox.process_due()
      assert Veejr.Federation.Outbox.pending_count() == 1
    end
  end

  describe "invites" do
    test "closed registration accepts a valid invite" do
      owner = local_user("owner")
      token = Accounts.generate_invite(owner)

      # personal mode with an existing user → closed without an invite
      Application.put_env(:veejr, :instance_mode, :personal)
      on_exit(fn -> Application.put_env(:veejr, :instance_mode, :community) end)

      assert {:error, :registration_closed} =
               Accounts.register_user(%{email: "kid@example.com", username: "kid"})

      assert {:ok, %User{username: "kid"}} =
               Accounts.register_user(%{email: "kid@example.com", username: "kid"}, token)

      assert {:error, :registration_closed} =
               Accounts.register_user(
                 %{email: "other@example.com", username: "other"},
                 "not-a-real-token"
               )
    end
  end
end
