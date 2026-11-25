defmodule Veejr.Messaging.ReminderSchedule do
  @moduledoc "Calendar recurrence in UTC, skipping occurrences missed while the instance was offline."

  def next(time, repeat, now, day \\ nil)
  def next(_time, "once", _now, _day), do: nil

  def next(time, repeat, now, _day) when repeat in ["daily", "weekly"] do
    seconds = if repeat == "daily", do: 86_400, else: 604_800
    steps = div(max(DateTime.diff(now, time), 0), seconds) + 1
    DateTime.add(time, steps * seconds)
  end

  def next(time, "monthly", now, day) do
    time = %{time | day: day || time.day}
    months = (now.year - time.year) * 12 + now.month - time.month
    candidate = shift_month(time, max(months, 1))
    if DateTime.compare(candidate, now) == :gt, do: candidate, else: shift_month(time, months + 1)
  end

  def next(_time, _repeat, _now, _day), do: nil

  defp shift_month(time, months) do
    index = time.year * 12 + time.month - 1 + months
    year = div(index, 12)
    month = rem(index, 12) + 1
    day = min(time.day, Calendar.ISO.days_in_month(year, month))
    %{time | year: year, month: month, day: day}
  end
end
