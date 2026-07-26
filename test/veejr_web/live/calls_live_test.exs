defmodule VeejrWeb.CallsLiveTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Calls, Social}

  setup %{conn: conn} do
    user = keyed_user()
    friend = keyed_user()
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
    assert has_element?(view, "details#scheduled-call-#{schedule.id}")
    refute has_element?(view, "details#scheduled-call-#{schedule.id}[open]")

    assert has_element?(
             view,
             "#scheduled-call-summary-#{schedule.id}",
             Social.Address.handle(friend)
           )

    assert has_element?(view, "#scheduled-call-#{schedule.id}", "Project catch-up")
    assert has_element?(view, "#scheduled-call-time-#{schedule.id}[phx-hook='LocalTime']")
    assert has_element?(view, "#scheduled-call-note-form-#{schedule.id}")

    assert has_element?(
             view,
             "#scheduled-call-note-form-#{schedule.id} textarea",
             "Project catch-up"
           )

    assert has_element?(view, "#save-scheduled-call-note-#{schedule.id}")
    assert has_element?(view, "#start-scheduled-call-#{schedule.id}")
    assert has_element?(view, "#cancel-scheduled-call-#{schedule.id}")
    assert has_element?(view, "#scheduled-call-cancellation-form-#{schedule.id}")

    view
    |> form("#scheduled-call-note-form-#{schedule.id}",
      schedule_note: %{note: "Updated agenda"}
    )
    |> render_submit()

    assert {:ok, updated} = Calls.get_scheduled_call(user, schedule.id)
    assert updated.note == "Updated agenda"

    assert has_element?(
             view,
             "#scheduled-call-note-form-#{schedule.id} textarea",
             "Updated agenda"
           )
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
    |> form("#scheduled-call-cancellation-form-#{schedule.id}", %{
      "cancellation" => %{"cancellation_reason" => "Calendar conflict"}
    })
    |> render_submit()

    assert has_element?(view, "#scheduled-call-#{schedule.id}", "Cancelled")

    assert has_element?(
             view,
             "#scheduled-call-cancellation-reason-#{schedule.id}",
             "Calendar conflict"
           )

    refute has_element?(view, "#start-scheduled-call-#{schedule.id}")
    refute has_element?(view, "#scheduled-call-cancellation-form-#{schedule.id}")
  end

  test "the invitee sees call notes on every schedule but cannot change them", %{
    user: user,
    friend: friend
  } do
    {:ok, schedule} =
      Calls.schedule_call(user, friend.id, %{
        "scheduled_for" =>
          DateTime.utc_now(:second) |> DateTime.add(1, :hour) |> DateTime.to_iso8601(),
        "reminder_minutes" => "15",
        "note" => ""
      })

    invitee_conn = build_conn() |> log_in_user(friend)
    {:ok, view, _html} = live(invitee_conn, "/calls")

    assert has_element?(
             view,
             "#scheduled-call-note-form-#{schedule.id} textarea[disabled]"
           )

    refute has_element?(view, "#save-scheduled-call-note-#{schedule.id}")
    assert has_element?(view, "#scheduled-call-cancellation-form-#{schedule.id}")

    view
    |> form("#scheduled-call-cancellation-form-#{schedule.id}", %{
      "cancellation" => %{"cancellation_reason" => "Can we reschedule?"}
    })
    |> render_submit()

    assert {:ok, cancelled} = Calls.get_scheduled_call(friend, schedule.id)
    assert cancelled.status == "cancelled"
    assert cancelled.cancelled_by_id == friend.id
    assert cancelled.cancellation_reason == "Can we reschedule?"
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
