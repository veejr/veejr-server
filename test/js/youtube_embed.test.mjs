import {test} from "node:test"
import assert from "node:assert/strict"

import {
  PRIVATE_EMBED_HOST,
  SIGNED_IN_EMBED_HOST,
  playbackStalled,
  youtubeEmbedUrl,
  youtubeWatchUrl,
} from "../../assets/js/veejr/youtube_embed.js"

test("the privacy-preserving host is the default embed", () => {
  const url = new URL(youtubeEmbedUrl("dQw4w9WgXcQ"))

  assert.equal(url.origin, PRIVATE_EMBED_HOST)
  assert.equal(url.pathname, "/embed/dQw4w9WgXcQ")
  assert.equal(url.searchParams.get("enablejsapi"), "1")
})

test("only the signed-in escape hatch leaves the privacy host", () => {
  const url = new URL(youtubeEmbedUrl("dQw4w9WgXcQ", {signedIn: true}))

  assert.equal(url.origin, SIGNED_IN_EMBED_HOST)
  assert.equal(url.pathname, "/embed/dQw4w9WgXcQ")
})

test("whoever gets the controls keeps the keyboard", () => {
  const viewer = new URL(youtubeEmbedUrl("dQw4w9WgXcQ"))
  assert.equal(viewer.searchParams.get("controls"), "0")
  assert.equal(viewer.searchParams.get("disablekb"), "1")

  const controller = new URL(youtubeEmbedUrl("dQw4w9WgXcQ", {controls: true}))
  assert.equal(controller.searchParams.get("controls"), "1")
  assert.equal(controller.searchParams.get("disablekb"), "0")
})

test("the origin parameter is sent only when the page knows its own", () => {
  const anonymous = new URL(youtubeEmbedUrl("dQw4w9WgXcQ"))
  assert.equal(anonymous.searchParams.get("origin"), null)

  const known = new URL(youtubeEmbedUrl("dQw4w9WgXcQ", {origin: "https://veejr.example"}))
  assert.equal(known.searchParams.get("origin"), "https://veejr.example")
})

test("a stuck viewer is sent to first-party YouTube at the shared position", () => {
  const url = new URL(youtubeWatchUrl("dQw4w9WgXcQ", 92.7))

  assert.equal(url.origin, SIGNED_IN_EMBED_HOST)
  assert.equal(url.pathname, "/watch")
  assert.equal(url.searchParams.get("v"), "dQw4w9WgXcQ")
  assert.equal(url.searchParams.get("t"), "92s")
})

test("the start of a video carries no timestamp", () => {
  assert.equal(new URL(youtubeWatchUrl("dQw4w9WgXcQ")).searchParams.get("t"), null)
  assert.equal(new URL(youtubeWatchUrl("dQw4w9WgXcQ", -5)).searchParams.get("t"), null)
})

test("silence is not a stall until playback has been asked for", () => {
  assert.equal(
    playbackStalled({requestedAt: null, now: 500_000, state: -1}),
    false,
  )
})

test("playback that never starts is a stall", () => {
  const asked = {requestedAt: 1_000, state: -1}

  assert.equal(playbackStalled({...asked, now: 4_000}), false)
  assert.equal(playbackStalled({...asked, now: 7_000}), true)
})

test("a player that is playing or buffering is never stalled", () => {
  const late = {requestedAt: 1_000, now: 60_000}

  assert.equal(playbackStalled({...late, state: 1}), false)
  assert.equal(playbackStalled({...late, state: 3}), false)
  assert.equal(playbackStalled({...late, state: 2}), true)
})

test("an error the viewer could act on stalls immediately", () => {
  const fresh = {requestedAt: null, now: 0, state: -1}

  assert.equal(playbackStalled({...fresh, errorCode: 150}), true)
  assert.equal(playbackStalled({...fresh, errorCode: 100}), true)
  // Our own malformed request; nothing the viewer can do about it.
  assert.equal(playbackStalled({...fresh, errorCode: 2}), false)
})
