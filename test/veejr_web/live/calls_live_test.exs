defmodule VeejrWeb.CallsLiveTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Calls, Social}

  setup %{conn: conn} do
    user = keyed_user()
    friend = user_fixture()
    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _friendship} = Social.accept_friend_request(friend, request.id)

    %{conn: log_in_user(conn, user), user: user, friend: friend}
  end

  test "prefills a friend and schedules a call with a reminder", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, view, _html} = live(conn, "/calls?friend_id=#{friend.id}")

    assert has_element?(view, "#schedule-call-form[phx-hook='ScheduleTime']")

    assert has_element?(
             view,
             "#schedule-call-form select[name='schedule[friend_id]'] option[value='#{friend.id}'][selected]"
           )

    view
    |> form("#schedule-call-form", %{
      "schedule" => %{
        "friend_id" => to_string(friend.id),
        "reminder_minutes" => "30",
        "note" => "Project catch-up"
      }
    })
    |> render_submit()

    [schedule] = Calls.list_scheduled_calls(user)
    assert has_element?(view, "#scheduled-call-#{schedule.id}", "Project catch-up")
    assert has_element?(view, "#scheduled-call-time-#{schedule.id}[phx-hook='LocalTime']")
    assert has_element?(view, "#start-scheduled-call-#{schedule.id}")
    assert has_element?(view, "#cancel-scheduled-call-#{schedule.id}")
  end

  test "the organizer cancels a scheduled call from the Calls page", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, schedule} =
      Calls.schedule_call(user, friend.id, %{
        "scheduled_for" =>
          DateTime.utc_now(:second) |> DateTime.add(1, :hour) |> DateTime.to_iso8601(),
        "reminder_minutes" => "15"
      })

    {:ok, view, _html} = live(conn, "/calls")

    view
    |> element("#cancel-scheduled-call-#{schedule.id}")
    |> render_click()

    assert has_element?(view, "#scheduled-call-#{schedule.id}", "Cancelled")
    refute has_element?(view, "#start-scheduled-call-#{schedule.id}")
  end

  defp keyed_user do
    user = user_fixture()

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        "public_key" => Base.encode64(String.pad_trailing("public-key", 32, "x")),
        "enc_secret_key" => Base.encode64(String.pad_trailing("wrapped-key", 48, "x")),
        "key_salt" => Base.encode64(String.pad_trailing("salt", 16, "x")),
        "key_nonce" => Base.encode64(String.pad_trailing("nonce", 24, "x"))
      })

    user
  end
end
