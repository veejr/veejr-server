defmodule Veejr.PresenceTest do
  use Veejr.DataCase, async: false

  import Veejr.AccountsFixtures

  alias Veejr.{Presence, Social}

  # Short enough to assert on, long enough that a slow CI box does not read a
  # live socket as a departure.
  @grace_ms 60
  @recent_ms 120

  setup do
    grace = Application.get_env(:veejr, :presence_grace_ms)
    recent = Application.get_env(:veejr, :presence_recent_ms)
    Application.put_env(:veejr, :presence_grace_ms, @grace_ms)
    Application.put_env(:veejr, :presence_recent_ms, @recent_ms)

    on_exit(fn ->
      restore(:presence_grace_ms, grace)
      restore(:presence_recent_ms, recent)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:veejr, key)
  defp restore(key, value), do: Application.put_env(:veejr, key, value)

  defp befriend(a, b) do
    {:ok, request} = Social.send_friend_request(a, b.username)
    {:ok, _} = Social.accept_friend_request(b, request.id)
    :ok
  end

  # A stand-in for a mounted LiveView: it tracks, then stays up until told to
  # stop, so a test can end a "session" deliberately.
  defp open_page(user) do
    test = self()

    pid =
      spawn(fn ->
        Presence.track(user)
        send(test, :tracked)

        receive do
          :close -> :ok
        end
      end)

    assert_receive :tracked
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp close_page(pid) do
    ref = Process.monitor(pid)
    send(pid, :close)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    # The presence server handles the DOWN separately from ours, so wait for
    # it to have processed its own mailbox before asserting on state.
    _ = :sys.get_state(Presence)
    :ok
  end

  describe "state/1" do
    test "an open page reads as online" do
      user = user_fixture()
      assert Presence.state(user) == :offline

      open_page(user)

      assert Presence.state(user) == :online
    end

    test "a remote contact is unknown, never offline" do
      remote = %Veejr.Accounts.User{id: -1, host: "other.example", presence_sharing: true}

      assert Presence.state(remote) == :unknown
    end

    test "a user who turned sharing off is unknown and is never tracked" do
      user = user_fixture()
      {:ok, hidden} = Veejr.Accounts.set_presence_sharing(user, false)

      open_page(hidden)

      assert Presence.state(hidden) == :unknown
      # Not merely hidden at render time — nothing was recorded.
      refute :ets.member(Veejr.Presence, hidden.id)
    end

    test "a second page does not double-count, and closing one keeps the user online" do
      user = user_fixture()

      first = open_page(user)
      open_page(user)

      close_page(first)

      assert Presence.state(user) == :online
    end
  end

  describe "leaving" do
    test "a dropped socket stays online through the grace period, then goes recently" do
      user = user_fixture()
      page = open_page(user)

      close_page(page)
      # A reconnecting mobile browser must not read as a departure.
      assert Presence.state(user) == :online

      Process.sleep(@grace_ms + 40)
      assert Presence.state(user) == :recently

      Process.sleep(@recent_ms + 40)
      assert Presence.state(user) == :offline
    end

    test "coming back during the grace period is not a departure" do
      alice = user_fixture(%{username: "alice"})
      bob = user_fixture(%{username: "bob"})
      befriend(alice, bob)
      Phoenix.PubSub.subscribe(Veejr.PubSub, "user:#{bob.id}")

      page = open_page(alice)
      assert_receive {:veejr_presence, _, :online}

      close_page(page)
      open_page(alice)

      Process.sleep(@grace_ms + 40)

      assert Presence.state(alice) == :online
      refute_received {:veejr_presence, _, :recently}
    end
  end

  describe "broadcasts" do
    setup do
      alice = user_fixture(%{username: "alice"})
      bob = user_fixture(%{username: "bob"})
      befriend(alice, bob)

      %{alice: alice, bob: bob}
    end

    test "friends are told when someone arrives and leaves", %{alice: alice, bob: bob} do
      Phoenix.PubSub.subscribe(Veejr.PubSub, "user:#{bob.id}")

      page = open_page(alice)
      assert_receive {:veejr_presence, alice_id, :online}
      assert alice_id == alice.id

      close_page(page)
      assert_receive {:veejr_presence, ^alice_id, :recently}, @grace_ms + 500
      assert_receive {:veejr_presence, ^alice_id, :offline}, @recent_ms + 500
    end

    test "strangers are not told anything", %{alice: alice} do
      stranger = user_fixture(%{username: "stranger"})
      Phoenix.PubSub.subscribe(Veejr.PubSub, "user:#{stranger.id}")

      open_page(alice)

      refute_receive {:veejr_presence, _, _}, 50
    end

    test "turning sharing off tells friends to stop showing a dot", %{alice: alice, bob: bob} do
      open_page(alice)
      Phoenix.PubSub.subscribe(Veejr.PubSub, "user:#{bob.id}")

      {:ok, _hidden} = Veejr.Accounts.set_presence_sharing(alice, false)

      assert_receive {:veejr_presence, alice_id, :unknown}
      assert alice_id == alice.id
      refute :ets.member(Veejr.Presence, alice.id)
    end
  end

  describe "states/1" do
    test "reports a whole contact list in one pass" do
      online = user_fixture()
      offline = user_fixture()
      remote = %Veejr.Accounts.User{id: -2, host: "other.example", presence_sharing: true}

      open_page(online)

      assert Presence.states([online, offline, remote]) == %{
               online.id => :online,
               offline.id => :offline,
               remote.id => :unknown
             }
    end
  end
end
