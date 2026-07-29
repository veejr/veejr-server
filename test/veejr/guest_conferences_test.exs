defmodule Veejr.GuestConferencesTest do
  use Veejr.DataCase, async: false

  import Veejr.AccountsFixtures

  alias Veejr.{Calls, GuestConferences, Repo}
  alias Veejr.GuestConferences.GuestConference

  @guest_key Base.encode64(:binary.copy(<<7>>, 32))

  test "creates a normalized, expiring capability without a user account" do
    host = user_fixture()

    assert {:ok, conference, token} =
             GuestConferences.create_invitation(host, %{
               "invited_email" => " Guest@Example.COM "
             })

    assert conference.invited_email == "guest@example.com"
    assert conference.state == "sent"
    assert is_binary(token)
    assert GuestConferences.get_by_token(token).id == conference.id
    assert GuestConferences.get_by_token("not-the-token") == nil
  end

  test "the guest waits, the host admits, and both sides exchange sealed signaling" do
    host = user_fixture()

    {:ok, conference, token} =
      GuestConferences.create_invitation(host, %{invited_email: "g@x.io"})

    GuestConferences.subscribe(conference)

    assert {:error, :unavailable} = Calls.start_guest_call(host, conference)

    assert {:ok, waiting} =
             GuestConferences.put_waiting(conference, %{
               display_name: "Guest Person",
               public_key: @guest_key
             })

    assert_receive {:guest_conference_waiting, %GuestConference{state: "waiting"}}
    assert {:ok, call} = Calls.start_guest_call(host, waiting)
    assert_receive {:guest_conference_admitted, call_id}
    assert call_id == call.public_id

    Calls.subscribe(call)
    assert {:ok, accepted} = Calls.join_guest_call(waiting)
    assert accepted.state == "accepted"
    assert_receive {:call_peer_joined, ^call_id, _participant}

    assert :ok = Calls.signal_guest(waiting, "guest-ciphertext", "guest-nonce")

    assert_receive {:call_signal, ^call_id, {:guest, _}, _target, "guest-ciphertext",
                    "guest-nonce"}

    assert :ok =
             Calls.signal_guest_host(
               host,
               call,
               "host-ciphertext",
               "host-nonce"
             )

    assert_receive {:call_signal, ^call_id, host_id, _target, "host-ciphertext", "host-nonce"}
    assert host_id == host.id

    assert :ok = Calls.end_guest_call(waiting)
    assert_receive {:call_ended, ^call_id, "ended"}
    assert_receive {:guest_conference_ended, %GuestConference{state: "ended"}}

    ended = Repo.get!(GuestConference, conference.id)
    assert ended.state == "ended"
    assert is_nil(ended.public_key)
    assert GuestConferences.get_by_token(token).id == conference.id
  end

  test "a different member cannot operate a host's guest call" do
    host = user_fixture()
    stranger = user_fixture()

    {:ok, conference, _token} =
      GuestConferences.create_invitation(host, %{invited_email: "g@x.io"})

    {:ok, waiting} =
      GuestConferences.put_waiting(conference, %{
        display_name: "Guest",
        public_key: @guest_key
      })

    {:ok, call} = Calls.start_guest_call(host, waiting)

    assert {:error, :not_found} = Calls.get_guest_call_for_host(stranger, call.public_id)
    assert {:error, :not_found} = Calls.end_guest_host_call(stranger, call)
  end
end
