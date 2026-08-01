// Which top-level Contacts sections stand open, per appearance.
//
// Classic is an accordion: the server renders exactly one section open and
// the reader opens the rest. Every flat appearance shows all of them at once,
// with no arrow and no pointer cursor, so the hook forces them open natively
// rather than fighting daisyUI's collapse styles from CSS.
//
// The asymmetry this exists to capture: going to a flat theme sets `open` on
// sections the server never marked, so coming back to Classic has to put them
// back. Without that the accordion stays stuck open until a full page reload,
// because LiveView does not re-send the unchanged `<details>` markup.
//
// The invariant these two functions are here to hold: arriving at Contacts
// always leaves Friends and Groups closed under Classic, whatever state the
// DOM was in beforehand.

export const CLASSIC = "classic"

/**
 * Whether a section should be open under `theme`.
 *
 * `defaultOpen` is the server's own choice for that section, marked in the
 * template, so the two cannot drift apart by counting positions.
 */
export function sectionOpen(theme, defaultOpen) {
  return theme !== CLASSIC || defaultOpen
}

/**
 * Whether a move from `previous` to `next` should reassert open state.
 *
 * `previous` is `undefined` only on mount — arriving at Contacts. Arriving
 * always reasserts, so Friends and Groups are closed however the DOM got
 * here: a fresh render, a live navigation, a back-button restore from the
 * browser's cache. Relying on the server markup alone would leave whichever
 * of those paths hands back a `<details>` that is already open.
 *
 * Flat themes reassert on every render too, since LiveView may have patched
 * a section back to the server's markup.
 *
 * The one case that does not reassert is an ordinary update while already in
 * Classic. Reapplying there would slam shut a section the reader had just
 * expanded themselves, which is a worse bug than the one being fixed.
 */
export function shouldReapply(previous, next) {
  if (next !== CLASSIC) return true

  return previous !== CLASSIC
}
