// Local wall-clock <-> UTC conversion for scheduled sends and reminders.
//
// The failure this guards against is silent: a message scheduled for 9am that
// leaves at 9am UTC looks fine in the database and arrives at the wrong time.

import {test} from "node:test"
import assert from "node:assert/strict"

import {
  describeScheduledTime,
  isoToLocalDateTime,
  localDateTimeIn,
  localDateTimeToIso,
} from "../../assets/js/veejr/schedule_time.js"

test("a datetime-local value is read as local time, not as UTC", () => {
  const iso = localDateTimeToIso("2026-07-30T09:00")
  assert.ok(iso)

  // Whatever zone this runs in, the instant must map back to 09:00 locally.
  const back = new Date(iso)
  assert.equal(back.getHours(), 9)
  assert.equal(back.getMinutes(), 0)
  assert.equal(back.getFullYear(), 2026)
  assert.equal(back.getMonth(), 6)
  assert.equal(back.getDate(), 30)
})

test("the conversion round-trips", () => {
  for (const value of ["2026-01-01T00:00", "2026-07-30T09:00", "2026-12-31T23:59"]) {
    assert.equal(isoToLocalDateTime(localDateTimeToIso(value)), value)
  }
})

test("seconds are accepted and junk is refused", () => {
  assert.ok(localDateTimeToIso("2026-07-30T09:00:30"))
  assert.equal(localDateTimeToIso(""), null)
  assert.equal(localDateTimeToIso(null), null)
  assert.equal(localDateTimeToIso("tomorrow"), null)
  assert.equal(localDateTimeToIso("2026-07-30"), null)
  assert.equal(localDateTimeToIso("2026-07-30T09"), null)
})

test("an impossible date is refused rather than silently rolled over", () => {
  // The Date constructor would happily turn month 13 into January of 2027.
  assert.equal(localDateTimeToIso("2026-13-01T09:00"), null)
  assert.equal(localDateTimeToIso("2026-02-30T09:00"), null)
})

test("relative presets land in the future", () => {
  const now = new Date("2026-07-30T09:00:00Z")
  const iso = localDateTimeToIso(localDateTimeIn(60, now))
  assert.ok(new Date(iso).getTime() > now.getTime())
  assert.equal(Math.round((new Date(iso) - now) / 60_000), 60)
})

test("a scheduled time is always described absolutely, with a relative hint", () => {
  const now = new Date("2026-07-30T09:00:00Z")

  const soon = describeScheduledTime(new Date("2026-07-30T09:30:00Z").toISOString(), now)
  assert.match(soon, /in 30 minutes/)

  const later = describeScheduledTime(new Date("2026-07-30T14:00:00Z").toISOString(), now)
  assert.match(later, /in 5 hours/)

  const days = describeScheduledTime(new Date("2026-08-02T09:00:00Z").toISOString(), now)
  assert.match(days, /in 3 days/)

  const past = describeScheduledTime(new Date("2026-07-30T08:00:00Z").toISOString(), now)
  assert.match(past, /due/)

  assert.equal(describeScheduledTime("not a date", now), "")
})
