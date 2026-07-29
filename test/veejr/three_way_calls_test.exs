defmodule Veejr.ThreeWayCallsTest do
  @moduledoc """
  Multi-party call membership and routing.

  Calls used to be a `caller_id`/`callee_id` pair; membership now lives in
  `call_participants`, and signalling is addressed rather than broadcast.
  These are the properties that only matter once a third person is present.
  """
  use Veejr.DataCase, async: false

  alias Veejr.{Calls, Social}
  alias Veejr.Calls.Call
  import Veejr.AccountsFixtures

  defp befriend(a, b) do
    {:ok, request} = Social.send_friend_request(a, b.username)
    {:ok, _} = Social.accept_friend_request(b, request.id)
  end

  defp trio do
    alice = user_fixture()
    bob = user_fixture()
    carol = user_fixture()
    befriend(alice, bob)
    befriend(alice, carol)
    %{alice: alice, bob: bob, carol: carol}
  end

  defp accepted_call(alice, bob) do
    {:ok, call} = Calls.start_call(alice, bob.id)
    {:ok, call} = Calls.join_call(bob, call.public_id)
    call
  end

  describe "participants" do
    test "a new call records both people" do
      %{alice: alice, bob: bob} = trio()
      {:ok, call} = Calls.start_call(alice, bob.id)

      participants = Calls.participants(call)
      assert length(participants) == 2

      caller = Enum.find(participants, &(&1.user_id == alice.id))
      invitee = Enum.find(participants, &(&1.user_id == bob.id))

      # The caller is in from the moment they dial; the invitee is ringing.
      assert caller.role == "caller"
      assert caller.state == "joined"
      assert invitee.role == "invitee"
      assert invitee.state == "ringing"
    end

    test "joining moves the participant, not just the call" do
      %{alice: alice, bob: bob} = trio()
      call = accepted_call(alice, bob)

      assert call.state == "accepted"
      assert Calls.participant(call, bob.id).state == "joined"
      refute is_nil(Calls.participant(call, bob.id).joined_at)
    end

    test "peer_participants excludes the viewer and anyone who left" do
      %{alice: alice, bob: bob, carol: carol} = trio()
      call = accepted_call(alice, bob)
      {:ok, _} = Calls.add_participant(alice, call.public_id, carol.id)
      {:ok, _} = Calls.join_call(carol, call.public_id)

      assert Calls.peer_participants(call, alice.id) |> Enum.map(& &1.user_id) |> Enum.sort() ==
               Enum.sort([bob.id, carol.id])

      :ok = Calls.end_call(bob, call.public_id)
      assert Calls.peer_participants(call, alice.id) |> Enum.map(& &1.user_id) == [carol.id]
    end
  end

  describe "add_participant/3" do
    test "the caller can add a friend to an accepted call" do
      %{alice: alice, bob: bob, carol: carol} = trio()
      call = accepted_call(alice, bob)
      Phoenix.PubSub.subscribe(Veejr.PubSub, "user:#{carol.id}")

      assert {:ok, _call} = Calls.add_participant(alice, call.public_id, carol.id)
      assert Calls.participant(call, carol.id).state == "ringing"
      # Carol is rung exactly as a first invitee would be.
      assert_receive {:veejr_call_ring, %Call{}}
      assert %Call{} = Calls.pending_ring(carol)
    end

    test "someone who is not the caller cannot add" do
      %{alice: alice, bob: bob, carol: carol} = trio()
      befriend(bob, carol)
      call = accepted_call(alice, bob)

      assert {:error, :not_caller} = Calls.add_participant(bob, call.public_id, carol.id)
      assert is_nil(Calls.participant(call, carol.id))
    end

    test "only accepted friends of the caller can be added" do
      %{alice: alice, bob: bob} = trio()
      stranger = user_fixture()
      call = accepted_call(alice, bob)

      assert {:error, :not_a_friend} = Calls.add_participant(alice, call.public_id, stranger.id)
    end

    test "remote users are refused because federated calls are 1:1" do
      %{alice: alice, bob: bob} = trio()
      call = accepted_call(alice, bob)

      remote =
        %Veejr.Accounts.User{
          username: "carol",
          email: "carol@remote.example",
          host: "remote.example",
          public_key: Base.encode64(String.pad_trailing("k", 32, "x"))
        }
        |> Repo.insert!()

      # Refused for being remote, checked before friendship — a remote friend
      # would be rejected on the same grounds.
      assert {:error, :remote_participant} =
               Calls.add_participant(alice, call.public_id, remote.id)
    end

    test "adding the same person twice is refused" do
      %{alice: alice, bob: bob, carol: carol} = trio()
      call = accepted_call(alice, bob)

      assert {:ok, _} = Calls.add_participant(alice, call.public_id, carol.id)

      assert {:error, :already_participating} =
               Calls.add_participant(alice, call.public_id, carol.id)
    end

    test "the call cannot exceed max_participants" do
      %{alice: alice, bob: bob, carol: carol} = trio()
      dave = user_fixture()
      befriend(alice, dave)
      call = accepted_call(alice, bob)

      assert {:ok, _} = Calls.add_participant(alice, call.public_id, carol.id)
      # Mesh upload is quadratic, so the cap is a real limit, not advice.
      assert Calls.max_participants() == 3
      assert {:error, :call_full} = Calls.add_participant(alice, call.public_id, dave.id)
    end

    test "an ended call cannot take new participants" do
      %{alice: alice, bob: bob, carol: carol} = trio()
      call = accepted_call(alice, bob)
      :ok = Calls.end_call(alice, call.public_id)

      assert {:error, {:bad_state, _}} = Calls.add_participant(alice, call.public_id, carol.id)
    end
  end

  describe "addressed signalling" do
    setup do
      %{alice: alice, bob: bob, carol: carol} = trio()
      call = accepted_call(alice, bob)
      {:ok, _} = Calls.add_participant(alice, call.public_id, carol.id)
      {:ok, _} = Calls.join_call(carol, call.public_id)
      Calls.subscribe(call)
      %{alice: alice, bob: bob, carol: carol, call: call}
    end

    test "a signal carries its target", %{alice: alice, carol: carol, call: call} do
      :ok = Calls.signal(alice, call.public_id, "ct", "n", carol.id)

      assert_receive {:call_signal, _id, from, target, "ct", "n"}
      assert from == alice.id
      # Without this the other participant cannot tell which pairing the SDP
      # belongs to and would try to apply someone else's offer.
      assert target == carol.id
    end

    test "a 1:1 call still routes with no explicit target" do
      alice = user_fixture()
      bob = user_fixture()
      befriend(alice, bob)
      call = accepted_call(alice, bob)
      Calls.subscribe(call)

      :ok = Calls.signal(alice, call.public_id, "ct", "n")

      # One possible recipient, so the target is inferred rather than required.
      assert_receive {:call_signal, _id, _from, target, "ct", "n"}
      assert target == bob.id
    end
  end

  describe "leaving" do
    setup do
      %{alice: alice, bob: bob, carol: carol} = trio()
      call = accepted_call(alice, bob)
      {:ok, _} = Calls.add_participant(alice, call.public_id, carol.id)
      {:ok, _} = Calls.join_call(carol, call.public_id)
      %{alice: alice, bob: bob, carol: carol, call: call}
    end

    test "one of three leaving keeps the call alive", %{bob: bob, call: call} do
      Calls.subscribe(call)
      :ok = Calls.end_call(bob, call.public_id)

      assert {:ok, %Call{state: "accepted"}} = Calls.get_call(call.caller, call.public_id)
      assert Calls.participant(call, bob.id).state == "left"
      # The remaining meshes need to drop that peer connection.
      assert_receive {:call_participant_left, _id, departed}
      assert departed == bob.id
    end

    test "the call ends once fewer than two remain", %{alice: alice, bob: bob, call: call} do
      :ok = Calls.end_call(bob, call.public_id)
      :ok = Calls.end_call(alice, call.public_id)

      assert {:ok, %Call{state: "ended"}} = Calls.get_call(call.caller, call.public_id)
    end

    test "one invitee declining leaves the others talking", %{carol: carol, call: call} do
      # Re-ring carol so she has something to decline.
      :ok = Calls.end_call(carol, call.public_id)
      {:ok, _} = Calls.add_participant(call.caller, call.public_id, carol.id)

      assert {:ok, %Call{state: "accepted"}} =
               Calls.decline_call(carol, call.public_id, "declined")

      assert Calls.participant(call, carol.id).state == "declined"
    end

    test "a third participant is authorised by their membership alone", %{
      carol: carol,
      call: call
    } do
      # Carol is neither caller_id nor callee_id on the legacy columns.
      refute call.caller_id == carol.id
      refute call.callee_id == carol.id
      assert {:ok, %Call{}} = Calls.get_call(carol, call.public_id)
    end
  end
end
