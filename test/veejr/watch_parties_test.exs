defmodule Veejr.WatchPartiesTest do
  use Veejr.DataCase

  alias Veejr.WatchParties

  test "extracts ids only from supported YouTube URLs" do
    assert {:ok, "dQw4w9WgXcQ"} =
             WatchParties.extract_video_id("https://www.youtube.com/watch?v=dQw4w9WgXcQ")

    assert {:ok, "dQw4w9WgXcQ"} =
             WatchParties.extract_video_id("https://youtu.be/dQw4w9WgXcQ?t=12")

    assert {:ok, "dQw4w9WgXcQ"} = WatchParties.extract_video_id("dQw4w9WgXcQ")

    assert {:error, :invalid_youtube_url} =
             WatchParties.extract_video_id("https://example.com/watch?v=dQw4w9WgXcQ")
  end

  test "only the initiating user can control or end a party" do
    server = start_supervised!({WatchParties, name: unique_server_name()})
    host = %{id: 10, username: "host_user", display_name: "Host"}
    :ok = WatchParties.subscribe()

    assert {:ok, party} = WatchParties.start_party(host, "dQw4w9WgXcQ", server)
    assert_receive {:watch_party_started, ^party}
    assert {:error, :party_active} = WatchParties.start_party(host, "M7lc1UVf-VE", server)
    assert {:error, :not_host} = WatchParties.control(party.public_id, 11, "playing", 2.0, server)
    assert :ok = WatchParties.control(party.public_id, host.id, "playing", 2.0, server)
    assert %{playback: "playing", position: 2.0} = WatchParties.active_party(server)
    assert {:error, :not_host} = WatchParties.end_party(party.public_id, 11, server)
    assert :ok = WatchParties.end_party(party.public_id, host.id, server)
    assert is_nil(WatchParties.active_party(server))
  end

  test "voice participants exchange only targeted opaque signaling" do
    server = start_supervised!({WatchParties, name: unique_server_name()})
    host = %{id: 10, username: "host_user", display_name: "Host", public_key: "host-key"}
    guest = %{id: 11, username: "guest_user", display_name: "Guest", public_key: "guest-key"}

    assert {:ok, party} = WatchParties.start_party(host, "dQw4w9WgXcQ", server)
    :ok = WatchParties.subscribe(party.public_id)

    assert {:ok, host_participant, []} =
             WatchParties.join_voice(party.public_id, host, self(), server)

    assert {:ok, guest_participant, [peer]} =
             WatchParties.join_voice(party.public_id, guest, self(), server)

    assert peer.id == host_participant.id
    assert peer.public_key == "host-key"

    assert :ok =
             WatchParties.signal_voice(
               party.public_id,
               host_participant.id,
               guest_participant.id,
               "opaque-ciphertext",
               "nonce",
               server
             )

    assert_receive {:watch_voice_signal, target_id, sender, "opaque-ciphertext", "nonce"}
    assert target_id == guest_participant.id
    assert sender.id == host_participant.id

    assert {:error, :invalid_signal} =
             WatchParties.signal_voice(
               party.public_id,
               "not-a-participant",
               guest_participant.id,
               "opaque-ciphertext",
               "nonce",
               server
             )
  end

  test "guest email capabilities are private, normalized, and expire with the party" do
    server = start_supervised!({WatchParties, name: unique_server_name()})
    host = %{id: 10, username: "host_user", display_name: "Host"}

    assert {:ok, party} = WatchParties.start_party(host, "dQw4w9WgXcQ", server)

    assert {:ok, invitations} =
             WatchParties.create_guest_invites(
               party.public_id,
               host.id,
               " FIRST@example.com, second@example.org, first@example.com ",
               server
             )

    assert Enum.map(invitations, & &1.email) == ["first@example.com", "second@example.org"]
    assert Enum.all?(invitations, &(WatchParties.guest_party(&1.token, server) == party))
    assert is_nil(WatchParties.guest_party("not-a-capability", server))

    [first | _rest] = invitations
    assert :ok = WatchParties.revoke_guest_invite(party.public_id, host.id, first.token, server)
    assert is_nil(WatchParties.guest_party(first.token, server))

    assert :ok = WatchParties.end_party(party.public_id, host.id, server)
    assert Enum.all?(invitations, &is_nil(WatchParties.guest_party(&1.token, server)))
  end

  test "guest email parsing rejects invalid and excessive lists" do
    assert {:error, :no_guest_emails} = WatchParties.parse_guest_emails("  ")

    assert {:error, {:invalid_guest_email, "not-an-email"}} =
             WatchParties.parse_guest_emails("valid@example.com, not-an-email")

    too_many =
      1..26
      |> Enum.map_join(",", &"guest#{&1}@example.com")

    assert {:error, :too_many_guest_emails} = WatchParties.parse_guest_emails(too_many)
  end

  defp unique_server_name do
    String.to_atom("watch_parties_test_#{System.unique_integer([:positive])}")
  end
end
