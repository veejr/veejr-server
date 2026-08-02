defmodule VeejrWeb.WatchLiveTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, WatchParties}

  setup %{conn: conn} do
    user = keyed_user()

    if party = WatchParties.active_party() do
      WatchParties.end_party(party.public_id, party.host_id)
    end

    %{conn: log_in_user(conn, user), user: user}
  end

  # A watch party is behind the same key gate as the rest of the account, so a
  # second participant needs keys before they can be let in.
  defp keyed_user do
    {:ok, user} =
      Accounts.setup_user_keys(user_fixture(), %{
        "public_key" => Base.encode64(String.pad_trailing("public-key", 32, "x")),
        "enc_secret_key" => Base.encode64(String.pad_trailing("wrapped-key", 48, "x")),
        "key_salt" => Base.encode64(String.pad_trailing("salt", 16, "x")),
        "key_nonce" => Base.encode64(String.pad_trailing("nonce", 24, "x"))
      })

    user
  end

  test "renders the watch lobby and validates YouTube input", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/watch")

    assert has_element?(view, "#watch-lobby")
    assert has_element?(view, "#watch-start-form")

    view
    |> form("#watch-start-form", watch: %{url: "https://example.com/not-youtube"})
    |> render_submit()

    assert has_element?(view, "#watch-start-form")
  end

  test "the initiator starts a host-controlled player", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, "/watch")

    view
    |> form("#watch-start-form", watch: %{url: "https://youtu.be/dQw4w9WgXcQ"})
    |> render_submit()

    party = WatchParties.active_party()
    assert_redirect(view, "/watch/#{party.public_id}")

    {:ok, host_view, _html} = live(conn, "/watch/#{party.public_id}")
    assert has_element?(host_view, "#youtube-watch-player[data-host='true']")
    assert has_element?(host_view, "#youtube-watch-iframe[src*='youtube-nocookie.com']")
    assert has_element?(host_view, "#watch-end")
    assert has_element?(host_view, "#watch-voice[phx-hook='WatchVoice']")
    assert has_element?(host_view, "#watch-microphone[aria-pressed='false']")

    host_view |> element("#watch-end") |> render_click()
    assert_redirect(host_view, "/watch")
    assert is_nil(WatchParties.active_party())
    assert user.id == party.host_id
  end

  test "the host emails distinct outsider invitations", %{conn: conn, user: user} do
    assert {:ok, party} = WatchParties.start_party(user, "dQw4w9WgXcQ")
    {:ok, view, _html} = live(conn, "/watch/#{party.public_id}")

    assert has_element?(view, "#watch-outsider-invites")
    assert has_element?(view, "#watch-outsider-invite-form")

    view
    |> form("#watch-outsider-invite-form",
      outsider_invites: %{emails: "first@example.com, second@example.org"}
    )
    |> render_submit()

    assert render(view) =~ "2 outsider invitations sent."
  end

  test "an outsider joins synchronized playback without an account", %{
    user: user
  } do
    assert {:ok, party} = WatchParties.start_party(user, "dQw4w9WgXcQ")

    assert {:ok, [%{token: token}]} =
             WatchParties.create_guest_invites(
               party.public_id,
               user.id,
               "guest@example.com"
             )

    guest_conn = build_conn()
    {:ok, guest_view, _html} = live(guest_conn, "/watch/guest/#{token}")

    assert has_element?(guest_view, "#guest-watch-party")
    assert has_element?(guest_view, "#guest-youtube-watch-player[data-host='false']")
    refute has_element?(guest_view, "#watch-voice")

    assert :ok = WatchParties.control(party.public_id, user.id, "playing", 42.0)

    assert_push_event guest_view, "watch:control", %{
      playback: "playing",
      position: 42.0
    }

    assert :ok = WatchParties.end_party(party.public_id, user.id)
    assert has_element?(guest_view, "#guest-watch-unavailable")
  end

  test "a viewer is never sealed away from the player", %{user: user} do
    assert {:ok, party} = WatchParties.start_party(user, "dQw4w9WgXcQ")

    viewer_conn = log_in_user(build_conn(), keyed_user())
    {:ok, view, _html} = live(viewer_conn, "/watch/#{party.public_id}")

    # YouTube can stop a viewer to ask them to confirm they are not a bot, and
    # that prompt is painted inside the frame. A guard the hook can drop keeps
    # stray clicks off the video; sealing the frame itself would leave the
    # challenged viewer with nothing to answer.
    assert has_element?(view, "#watch-youtube-guard[data-role='guard']")
    refute has_element?(view, "#youtube-watch-iframe.pointer-events-none")

    assert has_element?(view, "#watch-youtube-help[data-role='youtube-help']")
    assert has_element?(view, "#watch-youtube-assist-signed-in[data-role='youtube-signed-in']")

    assert has_element?(
             view,
             "#watch-youtube-assist-open[data-role='youtube-open'][target='_blank']"
           )
  end

  test "the host keeps the player and the same way out", %{conn: conn, user: user} do
    assert {:ok, party} = WatchParties.start_party(user, "dQw4w9WgXcQ")
    {:ok, view, _html} = live(conn, "/watch/#{party.public_id}")

    # Nothing stands between the host and the video, but the bot check does not
    # spare them, so the escape hatch is theirs too.
    refute has_element?(view, "#watch-youtube-guard")
    refute has_element?(view, "[data-role='unlock']")
    assert has_element?(view, "#watch-youtube-help[data-role='youtube-help']")
    assert has_element?(view, "#watch-youtube-assist[data-role='youtube-assist']")
  end

  test "a guest is never sealed away from the player", %{user: user} do
    assert {:ok, party} = WatchParties.start_party(user, "dQw4w9WgXcQ")

    assert {:ok, [%{token: token}]} =
             WatchParties.create_guest_invites(
               party.public_id,
               user.id,
               "guest@example.com"
             )

    {:ok, view, _html} = live(build_conn(), "/watch/guest/#{token}")

    assert has_element?(view, "#guest-watch-youtube-guard[data-role='guard']")
    refute has_element?(view, "#guest-youtube-watch-iframe.pointer-events-none")
    assert has_element?(view, "#guest-watch-youtube-help[data-role='youtube-help']")

    assert has_element?(
             view,
             "#guest-watch-youtube-assist-signed-in[data-role='youtube-signed-in']"
           )
  end

  test "an invalid outsider capability exposes no party", %{user: user} do
    assert {:ok, _party} = WatchParties.start_party(user, "dQw4w9WgXcQ")
    {:ok, view, _html} = live(build_conn(), "/watch/guest/not-a-real-token")

    assert has_element?(view, "#guest-watch-unavailable")
    refute has_element?(view, "#guest-youtube-watch-player")
  end
end
