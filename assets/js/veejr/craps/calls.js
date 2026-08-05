// What gets said at the table: the croupier's call, and the gallery's
// reaction to it.
//
// Pure so it can be tested without a speech engine. `audio.js` decides when
// to say these and in whose voice; nothing here touches the browser.

const NAMES = {
  2: "Two",
  3: "Three",
  4: "Four",
  5: "Five",
  6: "Six",
  7: "Seven",
  8: "Eight",
  9: "Nine",
  10: "Ten",
  11: "Eleven",
  12: "Twelve",
}

// The croupier calls every roll.
export function croupierCall(event, total) {
  const name = NAMES[total] || String(total)

  switch (event) {
    case "natural":
      return total === 7 ? "Seven! Natural! Winner!" : "Eleven! Natural! Winner!"
    case "craps":
      if (total === 2) return "Two — snake eyes! Craps!"
      if (total === 12) return "Twelve — boxcars! Craps!"
      return `${name}! Craps!`
    case "point_set":
      return `${name}. The point is ${name.toLowerCase()}.`
    case "point_made":
      return `${name}! Winner! Point made!`
    case "seven_out":
      return "Seven out! Line away!"
    case "roll":
      return `${name}.`
    default:
      return null
  }
}

export const CHEERS = ["You da man!", "Sweet!", "Yessir!", "Get in!", "Beautiful!"]

// Held back for an actual run, so it means something when it lands.
export const STREAK_CHEERS = [
  "You're on a roll!",
  "He's on a roll!",
  "Again! You da man!",
]

// Only the shooter coming good gets a cheer. A craps or a seven-out kills the
// run; an ordinary point-phase roll leaves it where it was.
export function isWin(event) {
  return event === "natural" || event === "point_made"
}

export function nextStreak(streak, event) {
  if (isWin(event)) return streak + 1
  if (event === "craps" || event === "seven_out") return 0
  return streak
}

export function cheerPool(streak) {
  return streak >= 2 ? STREAK_CHEERS.concat(CHEERS) : CHEERS
}

/**
 * The gallery's reaction, or null for a roll that does not deserve one.
 * `pick` is injected so a test can be deterministic.
 */
export function galleryCheer(event, streak, pick = Math.random) {
  if (!isWin(event)) return null

  const pool = cheerPool(streak)
  return pool[Math.floor(pick() * pool.length)] || pool[0]
}
