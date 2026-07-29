defmodule Veejr.CallsTest do
  use Veejr.DataCase, async: false

  import Swoosh.TestAssertions

  alias Veejr.{Calls, Social}
  alias Veejr.Calls.{Call, ScheduledCall}
  import Veejr.AccountsFixtures

  defp befriend(a, b) do
    {:ok, request} = Social.send_friend_request(a, b.username)
    {:ok, _} = Social.accept_friend_request(b, request.id)
  end

  defp subscribe_user(user) do
    Phoenix.PubSub.subscribe(Veejr.PubSub, "user:#{user.id}")
  end

  describe "local calls" do
    test "ringing an accepted friend broadcasts to their tabs" do
      alice = user_fixture()
      bob = user_fixture()
      befriend(alice, bob)
      subscribe_user(bob)

      assert {:ok, call} = Calls.start_call(alice, bob.id)
      assert call.state == "ringing"
      assert_receive {:veejr_call_ring, %Call{public_id: public_id}}
      assert public_id == call.public_id
      assert %Call{public_id: ^public_id} = Calls.pending_ring(bob)
    end

    test "repeated starts reuse the active call and ring only once" do
      alice = user_fixture()
      bob = user_fixture()
      befriend(alice, bob)
      subscribe_user(bob)

      assert {:ok, first} = Calls.start_call(alice, bob.id)
      assert_receive {:veejr_call_ring, %Call{public_id: public_id}}
      assert public_id == first.public_id

      assert {:ok, second} = Calls.start_call(alice, bob.id)
      assert second.public_id == first.public_id
      refute_receive {:veejr_call_ring, _call}
    end

    test "only accepted friends can ring" do
      alice = user_fixture()
      stranger = user_fixture()

      assert {:error, :not_a_friend} = Calls.start_call(alice, stranger.id)
      assert {:error, :self} = Calls.start_call(alice, alice.id)
    end

    test "only participants can see a call" do
      alice = user_fixture()
      bob = user_fixture()
      eve = user_fixture()
      befriend(alice, bob)

      {:ok, call} = Calls.start_call(alice, bob.id)

      assert {:ok, _} = Calls.get_call(alice, call.public_id)
      assert {:ok, _} = Calls.get_call(bob, call.public_id)
      assert {:error, :not_found} = Calls.get_call(eve, call.public_id)
    end

    test "joining answers the ring and unlocks signaling" do
      alice = user_fixture()
      bob = user_fixture()
      befriend(alice, bob)

      {:ok, call} = Calls.start_call(alice, bob.id)
      Calls.subscribe(call)

      # signaling is refused while still ringing
      assert {:error, {:bad_state, "ringing"}} = Calls.signal(alice, call.public_id, "ct", "n")

      assert {:ok, joined} = Calls.join_call(bob, call.public_id)
      assert joined.state == "accepted"
      assert_receive {:call_peer_joined, _id, _participant}

      assert :ok = Calls.signal(alice, call.public_id, "sealed-offer", "nonce")
      assert_receive {:call_signal, _id, from_id, _target, "sealed-offer", "nonce"}
      assert from_id == alice.id

      # the caller cannot join as callee
      assert {:error, _} = Calls.join_call(alice, call.public_id)
    end

    test "an accepted callee can re-announce after reconnecting" do
      alice = user_fixture()
      bob = user_fixture()
      befriend(alice, bob)

      {:ok, call} = Calls.start_call(alice, bob.id)
      {:ok, _joined} = Calls.join_call(bob, call.public_id)
      Calls.subscribe(call)

      assert {:ok, %Call{state: "accepted"}} = Calls.rejoin_call(bob, call.public_id)
      assert_receive {:call_peer_joined, public_id, _participant}
      assert public_id == call.public_id
    end

    test "decline and hang-up settle the call state" do
      alice = user_fixture()
      bob = user_fixture()
      befriend(alice, bob)

      {:ok, ringing} = Calls.start_call(alice, bob.id)
      Calls.subscribe(ringing)
      assert {:ok, declined} = Calls.decline_call(bob, ringing.public_id)
      assert declined.state == "declined"
      assert_receive {:call_ended, _id, "declined"}

      {:ok, second} = Calls.start_call(alice, bob.id)
      {:ok, _} = Calls.join_call(bob, second.public_id)
      Calls.subscribe(second)
      assert :ok = Calls.end_call(alice, second.public_id)
      assert_receive {:call_ended, _id, "ended"}
      assert {:ok, %Call{state: "ended"}} = Calls.get_call(alice, second.public_id)

      # cancelling an unanswered ring records a missed call
      {:ok, third} = Calls.start_call(alice, bob.id)
      assert :ok = Calls.end_call(alice, third.public_id)
      assert {:ok, %Call{state: "missed"}} = Calls.get_call(bob, third.public_id)
    end

    test "busy declines the call and sends a distinct outcome to the caller" do
      alice = user_fixture()
      bob = user_fixture()
      befriend(alice, bob)
      subscribe_user(bob)

      {:ok, call} = Calls.start_call(alice, bob.id)
      Calls.subscribe(call)

      assert {:ok, %Call{state: "declined"}} =
               Calls.decline_call(bob, call.public_id, "busy")

      assert_receive {:call_ended, public_id, "busy"}
      assert public_id == call.public_id
      assert_receive {:veejr_call_cancelled, ^public_id}
    end

    test "the caller explicitly cancels an unanswered invitation" do
      alice = user_fixture()
      bob = user_fixture()
      befriend(alice, bob)
      subscribe_user(bob)

      {:ok, call} = Calls.start_call(alice, bob.id)
      Calls.subscribe(call)

      assert {:ok, %Call{state: "cancelled"}} = Calls.cancel_call(alice, call.public_id)
      assert_receive {:call_ended, public_id, "cancelled"}
      assert public_id == call.public_id
      assert_receive {:veejr_call_cancelled, ^public_id}
      assert {:error, :not_ringing} = Calls.cancel_call(bob, call.public_id)
    end

    test "an accepted participant disconnect is distinguishable from a hang-up" do
      alice = user_fixture()
      bob = user_fixture()
      befriend(alice, bob)

      {:ok, call} = Calls.start_call(alice, bob.id)
      {:ok, _} = Calls.join_call(bob, call.public_id)
      Calls.subscribe(call)

      assert :ok = Calls.disconnect_call(bob, call.public_id)
      assert_receive {:call_disconnected, public_id, departed_id}
      assert public_id == call.public_id
      assert departed_id == bob.id
      assert {:ok, %Call{state: "ended"}} = Calls.get_call(alice, call.public_id)
    end
  end

  describe "scheduled calls" do
    test "either participant can cancel a local schedule with a reason and email" do
      alice = user_fixture()
      bob = user_fixture()
      befriend(alice, bob)
      assert_email_sent()
      assert_email_sent()

      scheduled_for = DateTime.add(DateTime.utc_now(:second), 2, :hour)
      browser_time = scheduled_for |> DateTime.to_iso8601() |> String.replace("Z", ".000Z")

      assert {:ok, schedule} =
               Calls.schedule_call(alice, bob.id, %{
                 "scheduled_for" => browser_time,
                 "reminder_minutes" => "30",
                 "note" => "Plan the weekend"
               })

      assert schedule.status == "scheduled"
      assert schedule.note == "Plan the weekend"
      assert [%ScheduledCall{id: id}] = Calls.list_scheduled_calls(bob)

      assert_email_sent(
        to: bob.email,
        subject: "#{alice.display_name || "@#{alice.username}"} scheduled a call with you"
      )

      subscribe_user(alice)

      assert {:ok,
              %ScheduledCall{
                status: "cancelled",
                cancelled_by_id: cancelled_by_id,
                cancellation_reason: "Something came up"
              }} =
               Calls.cancel_scheduled_call(bob, id, %{
                 "cancellation_reason" => "  Something came up  "
               })

      assert cancelled_by_id == bob.id
      assert_receive {:veejr_call_schedule, :cancelled, %ScheduledCall{id: ^id}, _peer}

      assert_email_sent(fn email ->
        assert email.to == [{"", alice.email}]

        assert email.subject ==
                 "#{bob.display_name || "@#{bob.username}"} canceled your scheduled call"

        assert email.text_body =~ "Reason: Something came up"
      end)
    end

    test "due reminders are persisted and broadcast once to both local participants" do
      alice = user_fixture()
      bob = user_fixture()
      befriend(alice, bob)
      now = DateTime.utc_now(:second)

      {:ok, schedule} =
        Calls.schedule_call(alice, bob.id, %{
          "scheduled_for" => DateTime.to_iso8601(DateTime.add(now, 10, :minute)),
          "reminder_minutes" => "15"
        })

      subscribe_user(alice)
      subscribe_user(bob)

      assert %{reminded: 1} = Calls.dispatch_due_reminders(now)
      assert_receive {:veejr_call_schedule, :reminder, %ScheduledCall{id: id}, _peer}
      assert id == schedule.id
      assert_receive {:veejr_call_schedule, :reminder, %ScheduledCall{id: ^id}, _peer}
      assert %{reminded: 0} = Calls.dispatch_due_reminders(now)
      assert Repo.get!(ScheduledCall, schedule.id).reminded_at
    end

    test "both local participants receive the persisted two-minute email reminder once" do
      alice = user_fixture(%{display_name: "Alice"})
      bob = user_fixture(%{display_name: "Bob"})
      befriend(alice, bob)
      assert_email_sent()
      assert_email_sent()
      now = DateTime.utc_now(:second)

      {:ok, schedule} =
        Calls.schedule_call(alice, bob.id, %{
          "scheduled_for" => DateTime.to_iso8601(DateTime.add(now, 90, :second)),
          "reminder_minutes" => "5"
        })

      assert_email_sent(
        to: bob.email,
        subject: "Alice scheduled a call with you"
      )

      assert %{emailed: 2} = Calls.dispatch_due_reminders(now)

      assert_email_sent(
        to: alice.email,
        subject: "Your call with Bob starts in two minutes"
      )

      assert_email_sent(
        to: bob.email,
        subject: "Your call with Alice starts in two minutes"
      )

      assert %{emailed: 0} = Calls.dispatch_due_reminders(now)
      persisted = Repo.get!(ScheduledCall, schedule.id)
      assert persisted.organizer_email_reminded_at
      assert persisted.invitee_email_reminded_at
    end

    test "only the organizer can update shared call notes" do
      alice = user_fixture()
      bob = user_fixture()
      befriend(alice, bob)

      {:ok, schedule} =
        Calls.schedule_call(alice, bob.id, %{
          "scheduled_for" =>
            DateTime.utc_now(:second) |> DateTime.add(1, :hour) |> DateTime.to_iso8601(),
          "reminder_minutes" => "15"
        })

      assert {:error, :not_organizer} =
               Calls.update_scheduled_call_note(bob, schedule.id, %{"note" => "Nope"})

      assert {:ok, %ScheduledCall{note: "Agenda and links"}} =
               Calls.update_scheduled_call_note(alice, schedule.id, %{
                 "note" => "Agenda and links"
               })

      assert Repo.get!(ScheduledCall, schedule.id).note == "Agenda and links"
    end

    test "the organizer starts a scheduled call" do
      alice = user_fixture()
      bob = user_fixture()
      befriend(alice, bob)

      {:ok, schedule} =
        Calls.schedule_call(alice, bob.id, %{
          "scheduled_for" =>
            DateTime.utc_now(:second) |> DateTime.add(1, :hour) |> DateTime.to_iso8601(),
          "reminder_minutes" => "15"
        })

      assert {:error, :not_scheduled} = Calls.start_scheduled_call(bob, schedule.id)
      assert {:ok, %Call{state: "ringing"}} = Calls.start_scheduled_call(alice, schedule.id)
      assert Repo.get!(ScheduledCall, schedule.id).status == "started"
    end
  end

  describe "federated calls" do
    @remote_host "remote.example"

    setup do
      alice = user_fixture(%{username: "alice"})

      Req.Test.stub(Veejr.FederationStub, fn conn ->
        case conn.request_path do
          "/api/directory/carol" ->
            Req.Test.json(conn, %{
              username: "carol",
              public_key: Base.encode64("carol-key"),
              host: @remote_host
            })

          _ ->
            Req.Test.json(conn, %{ok: true})
        end
      end)

      {:ok, _} =
        Veejr.Federation.handle_friend_request(
          %{"from" => %{"username" => "carol", "authority" => @remote_host}, "to" => "alice"},
          @remote_host
        )

      [request] = Social.list_incoming_requests(alice)
      {:ok, fr} = Social.accept_friend_request(alice, request.id)
      {1, 0} = Veejr.Federation.Outbox.process_due()
      %{alice: alice, carol: fr.requester}
    end

    test "an inbound invite from a verified peer rings the local callee", %{
      alice: alice,
      carol: carol
    } do
      subscribe_user(alice)

      assert {:ok, :created} =
               Veejr.Federation.handle_call_invite(
                 %{
                   "from" => %{"username" => "carol", "authority" => @remote_host},
                   "to" => "alice",
                   "call_id" => "remote-call-1"
                 },
                 @remote_host
               )

      assert_receive {:veejr_call_ring, %Call{public_id: "remote-call-1"}}
      assert {:ok, %Call{caller_id: caller_id}} = Calls.get_call(alice, "remote-call-1")
      assert caller_id == carol.id

      # duplicate deliveries are absorbed
      assert {:ok, :duplicate} =
               Veejr.Federation.handle_call_invite(
                 %{
                   "from" => %{"username" => "carol", "authority" => @remote_host},
                   "to" => "alice",
                   "call_id" => "remote-call-1"
                 },
                 @remote_host
               )

      assert {:ok, :applied} =
               Veejr.Federation.handle_call_update(
                 %{"call_id" => "remote-call-1", "event" => "cancelled"},
                 @remote_host
               )

      assert_receive {:veejr_call_cancelled, "remote-call-1"}
      assert {:ok, %Call{state: "cancelled"}} = Calls.get_call(alice, "remote-call-1")
    end

    test "remote updates and signals only land from the call's own peer", %{alice: alice} do
      {:ok, :created} =
        Veejr.Federation.handle_call_invite(
          %{
            "from" => %{"username" => "carol", "authority" => @remote_host},
            "to" => "alice",
            "call_id" => "remote-call-2"
          },
          @remote_host
        )

      # a different (even verified) authority cannot touch this call
      assert {:error, :origin_mismatch} =
               Calls.receive_remote_update("remote-call-2", "other.example", "ended")

      {:ok, call} = Calls.get_call(alice, "remote-call-2")
      Calls.subscribe(call)

      {:ok, _} = Calls.join_call(alice, "remote-call-2")

      # A callee reconnect re-announces "joined" so negotiation can restart.
      assert {:ok, :applied} =
               Calls.receive_remote_update("remote-call-2", @remote_host, "joined")

      assert_receive {:call_peer_joined, "remote-call-2", _participant}

      assert {:ok, :relayed} =
               Calls.receive_remote_signal("remote-call-2", @remote_host, "sealed", "nonce")

      assert_receive {:call_signal, "remote-call-2", _from, _target, "sealed", "nonce"}

      assert {:ok, :applied} = Calls.receive_remote_update("remote-call-2", @remote_host, "ended")
      assert {:ok, %Call{state: "ended"}} = Calls.get_call(alice, "remote-call-2")
    end

    test "a federated busy response remains distinct for the caller", %{alice: alice} do
      {:ok, :created} =
        Veejr.Federation.handle_call_invite(
          %{
            "from" => %{"username" => "carol", "authority" => @remote_host},
            "to" => "alice",
            "call_id" => "remote-busy"
          },
          @remote_host
        )

      {:ok, call} = Calls.get_call(alice, "remote-busy")
      Calls.subscribe(call)

      assert {:ok, :applied} =
               Calls.receive_remote_update(call.public_id, @remote_host, "busy")

      assert_receive {:call_ended, "remote-busy", "busy"}
      assert {:ok, %Call{state: "declined"}} = Calls.get_call(alice, call.public_id)
    end

    test "a remote participant disconnect identifies who left", %{alice: alice} do
      {:ok, :created} =
        Veejr.Federation.handle_call_invite(
          %{
            "from" => %{"username" => "carol", "authority" => @remote_host},
            "to" => "alice",
            "call_id" => "remote-disconnect"
          },
          @remote_host
        )

      {:ok, call} = Calls.get_call(alice, "remote-disconnect")
      Calls.subscribe(call)
      {:ok, _accepted} = Calls.join_call(alice, call.public_id)

      assert {:ok, :applied} =
               Calls.receive_remote_update(call.public_id, @remote_host, "disconnected")

      assert_receive {:call_disconnected, "remote-disconnect", departed_id}
      assert departed_id == call.caller_id
      assert {:ok, %Call{state: "ended"}} = Calls.get_call(alice, call.public_id)
    end

    test "calling a remote friend delivers a signed invite", %{alice: alice, carol: carol} do
      assert {:ok, call} = Calls.start_call(alice, carol.id)
      assert call.state == "ringing"
    end

    test "a verified peer can mirror and cancel a scheduled call", %{
      alice: alice,
      carol: carol
    } do
      assert_email_sent()

      scheduled_for =
        DateTime.utc_now(:second) |> DateTime.add(2, :hour) |> DateTime.to_iso8601()

      assert {:ok, schedule} =
               Veejr.Federation.handle_call_schedule(
                 %{
                   "from" => %{"username" => "carol", "authority" => @remote_host},
                   "to" => "alice",
                   "schedule_id" => "remote-schedule-1",
                   "event" => "scheduled",
                   "scheduled_for" => scheduled_for,
                   "reminder_minutes" => 15,
                   "note" => "Catch up"
                 },
                 @remote_host
               )

      assert schedule.organizer_id == carol.id
      assert schedule.invitee_id == alice.id

      assert_email_sent(
        to: alice.email,
        subject: "@carol scheduled a call with you"
      )

      assert {:ok, :applied} =
               Veejr.Federation.handle_call_schedule(
                 %{
                   "schedule_id" => schedule.public_id,
                   "event" => "updated",
                   "note" => "Updated shared agenda"
                 },
                 @remote_host
               )

      assert Repo.get!(ScheduledCall, schedule.id).note == "Updated shared agenda"

      assert {:ok, :applied} =
               Veejr.Federation.handle_call_schedule(
                 %{
                   "from" => %{"username" => "carol", "authority" => @remote_host},
                   "to" => "alice",
                   "schedule_id" => schedule.public_id,
                   "event" => "cancelled",
                   "cancellation_reason" => "Travel delay"
                 },
                 @remote_host
               )

      persisted = Repo.get!(ScheduledCall, schedule.id)
      assert persisted.status == "cancelled"
      assert persisted.cancelled_by_id == carol.id
      assert persisted.cancellation_reason == "Travel delay"

      assert_email_sent(fn email ->
        assert email.to == [{"", alice.email}]
        assert email.subject == "@carol canceled your scheduled call"
        assert email.text_body =~ "Reason: Travel delay"
      end)
    end

    test "an unreachable callee instance fails the call cleanly", %{alice: alice, carol: carol} do
      Req.Test.stub(Veejr.FederationStub, fn conn ->
        Plug.Conn.send_resp(conn, 503, "down")
      end)

      assert {:error, :callee_unreachable} = Calls.start_call(alice, carol.id)
    end
  end

  test "participant presence tracks live call pages per process" do
    refute Calls.present?("some-call", 1)

    task =
      Task.async(fn ->
        Calls.register_presence("some-call", 1)
        Process.sleep(:infinity)
      end)

    # registration is visible while the page process lives…
    Process.sleep(50)
    assert Calls.present?("some-call", 1)
    refute Calls.present?("some-call", 2)
    refute Calls.present?("other-call", 1)

    # …and disappears with it, which is what the hang-up grace checks
    Task.shutdown(task, :brutal_kill)
    Process.sleep(50)
    refute Calls.present?("some-call", 1)
  end

  test "the janitor sweep marks stale rings missed" do
    alice = user_fixture()
    bob = user_fixture()
    befriend(alice, bob)

    {:ok, call} = Calls.start_call(alice, bob.id)

    Repo.get_by!(Call, public_id: call.public_id)
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(:second), -120, :second))
    |> Repo.update!()

    assert %{missed: 1} = Calls.sweep_stale_calls()
    assert {:ok, %Call{state: "missed"}} = Calls.get_call(alice, call.public_id)
  end
end
