// Converting between an <input type="datetime-local"> value and the UTC
// instant the server stores.
//
// Its own module because it is pure, and because getting it wrong is quiet: a
// message scheduled for "9am" that goes out at 9am UTC is off by hours for
// most of the world and only noticed after it has already been sent. Tested in
// test/js/schedule_time.test.mjs.

/**
 * "2026-07-30T09:00" (the user's wall clock) to an ISO-8601 UTC instant.
 *
 * `new Date("2026-07-30T09:00")` already interprets a date-time without a zone
 * as local time, but relying on that leaves the intent invisible, so the parts
 * are read out and handed to the Date constructor explicitly.
 */
export function localDateTimeToIso(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(
    String(value ?? "").trim()
  )
  if (!match) return null

  const [, year, month, day, hour, minute, second] = match
  const date = new Date(
    Number(year),
    Number(month) - 1,
    Number(day),
    Number(hour),
    Number(minute),
    Number(second || 0),
    0
  )

  if (Number.isNaN(date.getTime())) return null

  // Two-digit years and month 13 silently roll over in the Date constructor;
  // comparing back catches that instead of scheduling for the wrong month.
  if (date.getFullYear() !== Number(year) || date.getMonth() !== Number(month) - 1) return null

  return date.toISOString()
}

/** The inverse: a UTC instant to the local value a datetime-local input wants. */
export function isoToLocalDateTime(iso) {
  if (!iso) return ""
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return ""

  const pad = (value) => String(value).padStart(2, "0")
  return (
    `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
    `T${pad(date.getHours())}:${pad(date.getMinutes())}`
  )
}

/** Now plus `minutes`, as a datetime-local value — for "in an hour" presets. */
export function localDateTimeIn(minutes, now = new Date()) {
  return isoToLocalDateTime(new Date(now.getTime() + minutes * 60_000).toISOString())
}

/**
 * A short, unambiguous label for a scheduled time. Always names the absolute
 * time: "in 2 hours" alone is not something you want to trust a message to.
 */
export function describeScheduledTime(iso, now = new Date()) {
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return ""

  const minutes = Math.round((date.getTime() - now.getTime()) / 60_000)
  const absolute = date.toLocaleString()

  if (minutes <= 0) return `${absolute} (due)`
  if (minutes < 60) return `${absolute} (in ${minutes} minute${minutes === 1 ? "" : "s"})`

  const hours = Math.round(minutes / 60)
  if (hours < 24) return `${absolute} (in ${hours} hour${hours === 1 ? "" : "s"})`

  const days = Math.round(hours / 24)
  return `${absolute} (in ${days} day${days === 1 ? "" : "s"})`
}
