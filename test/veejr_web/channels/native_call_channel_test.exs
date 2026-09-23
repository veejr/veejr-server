defmodule VeejrWeb.NativeCallChannelTest do
  use VeejrWeb.ChannelCase, async: false

  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Calls, Social}
  alias VeejrWeb.NativeSocket

  setup do
    alice = keyed_user()
    bob = keyed_user()
    {:ok, request} = Social.send_friend_request(alice, bob.username)
    {:ok, _} = Social.accept_friend_request(bob, request.id)

    %{alice: alice, bob: bob}
  end

  describe "socket authentication" do
    test "connects with a device-session access token", %{alice: alice} do
      assert {:ok, socket} = connect(NativeSocket, %{"access_token" => access_token(alice)})
      assert socket.assigns.user.id == alice.id
    end

    test "refuses a missing or unknown token" do
      assert :error = connect(NativeSocket, %{})
      assert :error = connect(NativeSocket, %{"access_token" => "not-a-token"})
    end
  end

  describe "calls:v1" do
    test "join replies with the user id and ICE servers", %{alice: alice} do
      assert {:ok, reply, _socket} = join_calls(alice)
      assert reply.user_id == to_string(alice.id)
      assert [_ | _] = reply.ice_servers
    end

    test "starting a call rings the callee's channel", %{alice: alice, bob: bob} do
      {:ok, _reply, alice_socket} = join_calls(alice)
      {:ok, _reply, _bob_socket} = join_calls(bob)

      ref = push(alice_socket, "start", %{"callee_id" => to_string(bob.id)})
      assert_reply ref, :ok, %{call_id: call_id, role: "caller", state: "ringing", peers: [peer]}
      assert peer.id == to_string(bob.id)
      assert peer.public_key == bob.public_key

      assert_push "ring", %{call_id: ^call_id, caller: caller, expires_at: expires_at}
      assert caller.id == to_string(alice.id)
      assert expires_at > System.system_time(:second)
    end

    test "a ring waiting before the channel joined is replayed", %{alice: alice, bob: bob} do
      {:ok, call} = Calls.start_call(alice, bob.id)
      call_id = call.public_id

      {:ok, _reply, _bob_socket} = join_calls(bob)
      assert_push "ring", %{call_id: ^call_id}
    end

    test "only accepted friends can be called", %{alice: alice} do
      stranger = keyed_user()
      {:ok, _reply, socket} = join_calls(alice)

      ref = push(socket, "start", %{"callee_id" => to_string(stranger.id)})
      assert_reply ref, :error, %{reason: "not_a_friend"}
    end

    test "accepting tells the caller and relays sealed signals both ways", %{
      alice: alice,
      bob: bob
    } do
      {:ok, _reply, alice_socket} = join_calls(alice)
      {:ok, _reply, bob_socket} = join_calls(bob)

      ref = push(alice_socket, "start", %{"callee_id" => to_string(bob.id)})
      assert_reply ref, :ok, %{call_id: call_id}
      assert_push "ring", %{call_id: ^call_id}

      ref = push(bob_socket, "accept", %{"call_id" => call_id})
      assert_reply ref, :ok, %{state: "accepted", role: "callee"}

      bob_id = to_string(bob.id)
      alice_id = to_string(alice.id)
      assert_push "peer_joined", %{call_id: ^call_id, peer: %{id: ^bob_id}}

      ref =
        push(alice_socket, "signal", %{
          "call_id" => call_id,
          "ciphertext" => "sealed-offer",
          "nonce" => "n1",
          "target" => bob_id
        })

      assert_reply ref, :ok

      assert_push "signal", %{
        call_id: ^call_id,
        from: ^alice_id,
        ciphertext: "sealed-offer",
        nonce: "n1"
      }

      # Delivered exactly once, and nobody receives their own signal back.
      refute_push "signal", _payload
    end

    test "signals for a call this device is not in are refused", %{alice: alice, bob: bob} do
      {:ok, call} = Calls.start_call(alice, bob.id)
      {:ok, _} = Calls.join_call(bob, call.public_id)
      {:ok, _reply, socket} = join_calls(alice)

      ref =
        push(socket, "signal", %{"call_id" => call.public_id, "ciphertext" => "x", "nonce" => "y"})

      assert_reply ref, :error, %{reason: "not_active"}
    end

    test "declining ends the call for the caller", %{alice: alice, bob: bob} do
      {:ok, _reply, alice_socket} = join_calls(alice)
      {:ok, _reply, bob_socket} = join_calls(bob)

      ref = push(alice_socket, "start", %{"callee_id" => to_string(bob.id)})
      assert_reply ref, :ok, %{call_id: call_id}
      assert_push "ring", %{call_id: ^call_id}

      ref = push(bob_socket, "decline", %{"call_id" => call_id, "reason" => "busy"})
      assert_reply ref, :ok

      assert_push "ended", %{call_id: ^call_id, reason: "busy"}
    end

    test "the caller hanging up a ring cancels it on the callee", %{alice: alice, bob: bob} do
      {:ok, _reply, alice_socket} = join_calls(alice)
      {:ok, _reply, _bob_socket} = join_calls(bob)

      ref = push(alice_socket, "start", %{"callee_id" => to_string(bob.id)})
      assert_reply ref, :ok, %{call_id: call_id}
      assert_push "ring", %{call_id: ^call_id}

      ref = push(alice_socket, "hangup", %{"call_id" => call_id})
      assert_reply ref, :ok

      assert_push "ring_cancelled", %{call_id: ^call_id, reason: "cancelled"}
      assert {:ok, %{state: "cancelled"}} = Calls.get_call(alice, call_id)
    end

    test "hanging up an accepted call ends it for the other side", %{alice: alice, bob: bob} do
      {:ok, _reply, alice_socket} = join_calls(alice)
      {:ok, _reply, bob_socket} = join_calls(bob)

      ref = push(alice_socket, "start", %{"callee_id" => to_string(bob.id)})
      assert_reply ref, :ok, %{call_id: call_id}
      ref = push(bob_socket, "accept", %{"call_id" => call_id})
      assert_reply ref, :ok

      ref = push(bob_socket, "hangup", %{"call_id" => call_id})
      assert_reply ref, :ok

      assert_push "ended", %{call_id: ^call_id, reason: "ended"}
      assert {:ok, %{state: "ended"}} = Calls.get_call(alice, call_id)
    end

    test "answering in a browser stops the ring on this device", %{alice: alice, bob: bob} do
      {:ok, _reply, _bob_socket} = join_calls(bob)
      {:ok, call} = Calls.start_call(alice, bob.id)
      call_id = call.public_id
      assert_push "ring", %{call_id: ^call_id}

      {:ok, _} = Calls.join_call(bob, call_id)

      assert_push "ring_cancelled", %{call_id: ^call_id, reason: "answered_elsewhere"}
    end

    test "a callee whose socket reconnects mid-call reattaches with accept", %{
      alice: alice,
      bob: bob
    } do
      {:ok, _reply, alice_socket} = join_calls(alice)
      {:ok, _reply, bob_socket} = join_calls(bob)

      ref = push(alice_socket, "start", %{"callee_id" => to_string(bob.id)})
      assert_reply ref, :ok, %{call_id: call_id}
      ref = push(bob_socket, "accept", %{"call_id" => call_id})
      assert_reply ref, :ok
      bob_id = to_string(bob.id)
      assert_push "peer_joined", %{peer: %{id: ^bob_id}}

      # The phone switches networks: a fresh channel on a new socket.
      Process.unlink(bob_socket.channel_pid)
      close(bob_socket)
      {:ok, _reply, bob_again} = join_calls(bob)

      ref = push(bob_again, "accept", %{"call_id" => call_id})
      assert_reply ref, :ok, %{state: "accepted"}

      # The caller is told to renegotiate, and signals flow to the new channel.
      assert_push "peer_joined", %{peer: %{id: ^bob_id}}
      assert Calls.present?(call_id, bob.id)

      ref =
        push(alice_socket, "signal", %{"call_id" => call_id, "ciphertext" => "c", "nonce" => "n"})

      assert_reply ref, :ok
      assert_push "signal", %{ciphertext: "c"}
    end

    test "a caller whose socket reconnects while ringing still hears the answer", %{
      alice: alice,
      bob: bob
    } do
      {:ok, _reply, alice_socket} = join_calls(alice)

      ref = push(alice_socket, "start", %{"callee_id" => to_string(bob.id)})
      assert_reply ref, :ok, %{call_id: call_id}

      Process.unlink(alice_socket.channel_pid)
      close(alice_socket)
      {:ok, _reply, alice_again} = join_calls(alice)

      ref = push(alice_again, "accept", %{"call_id" => call_id})
      assert_reply ref, :ok, %{state: "ringing", role: "caller"}

      {:ok, _} = Calls.join_call(bob, call_id)
      bob_id = to_string(bob.id)
      assert_push "peer_joined", %{call_id: ^call_id, peer: %{id: ^bob_id}}
    end

    test "a native caller interoperates with a browser callee", %{alice: alice, bob: bob} do
      {:ok, _reply, alice_socket} = join_calls(alice)

      ref = push(alice_socket, "start", %{"callee_id" => to_string(bob.id)})
      assert_reply ref, :ok, %{call_id: call_id}

      # What CallLive does for a browser: join, then relay a sealed signal.
      {:ok, _} = Calls.join_call(bob, call_id)
      bob_id = to_string(bob.id)
      assert_push "peer_joined", %{call_id: ^call_id, peer: %{id: ^bob_id}}

      :ok = Calls.signal(bob, call_id, "sealed-answer", "n2")
      assert_push "signal", %{call_id: ^call_id, from: ^bob_id, ciphertext: "sealed-answer"}
    end
  end

  defp join_calls(user) do
    {:ok, socket} = connect(NativeSocket, %{"access_token" => access_token(user)})
    subscribe_and_join(socket, VeejrWeb.NativeCallChannel, "calls:v1")
  end

  defp access_token(user) do
    {:ok, _session, tokens} =
      Accounts.create_api_device_session(user, %{"name" => "Test phone", "platform" => "android"})

    tokens.access_token
  end

  defp keyed_user do
    user = user_fixture()

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        "public_key" => Base.encode64(:crypto.strong_rand_bytes(32)),
        "enc_secret_key" => Base.encode64(String.pad_trailing("wrapped-key", 48, "x")),
        "key_salt" => Base.encode64(String.pad_trailing("salt", 16, "x")),
        "key_nonce" => Base.encode64(String.pad_trailing("nonce", 24, "x"))
      })

    user
  end
end
