defmodule Veejr.ReminderScheduleTest do
  use ExUnit.Case, async: true
  alias Veejr.Messaging.ReminderSchedule

  test "skips missed daily occurrences and schedules strictly after now" do
    assert ReminderSchedule.next(~U[2026-01-01 09:00:00Z], "daily", ~U[2026-01-05 10:00:00Z]) ==
             ~U[2026-01-06 09:00:00Z]

    assert ReminderSchedule.next(~U[2026-01-01 09:00:00Z], "weekly", ~U[2026-01-08 09:00:00Z]) ==
             ~U[2026-01-15 09:00:00Z]
  end

  test "monthly recurrence clamps short months and keeps the original day" do
    assert ReminderSchedule.next(
             ~U[2026-01-31 09:00:00Z],
             "monthly",
             ~U[2026-01-31 09:00:00Z],
             31
           ) == ~U[2026-02-28 09:00:00Z]

    assert ReminderSchedule.next(
             ~U[2026-02-28 09:00:00Z],
             "monthly",
             ~U[2026-02-28 09:00:00Z],
             31
           ) == ~U[2026-03-31 09:00:00Z]

    assert ReminderSchedule.next(
             ~U[2026-01-31 09:00:00Z],
             "monthly",
             ~U[2027-05-01 00:00:00Z],
             31
           ) == ~U[2027-05-31 09:00:00Z]
  end
end
