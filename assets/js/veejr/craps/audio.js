// Dice sounds and the croupier.
//
// Everything is synthesised: filtered noise bursts through the Web Audio API
// for the clatter, and SpeechSynthesis for the calls. Nothing is downloaded,
// which is the same bargain the rest of veejr makes.
//
// Sound is off until a player asks for it. Browsers will not start an
// AudioContext without a gesture anyway, and a table that starts talking on
// its own is hostile.

import {croupierCall, galleryCheer, nextStreak} from "./calls.js"

const STORAGE_KEY = "veejr:craps-sound"

let ctx = null
let noiseBuffer = null
let enabled = readPreference()

function readPreference() {
  try {
    return window.localStorage.getItem(STORAGE_KEY) === "on"
  } catch (_error) {
    return false
  }
}

export function setEnabled(on) {
  enabled = on
  if (!on) stopSpeaking()
}

export function isEnabled() {
  return enabled
}

// The toggle lives outside this module — it is a button in the page — so the
// preference is announced rather than pushed.
window.addEventListener("veejr:craps-sound", (event) => setEnabled(!!event.detail))

function audio() {
  if (!ctx) {
    const Ctor = window.AudioContext || window.webkitAudioContext
    if (!Ctor) return null
    ctx = new Ctor()
  }
  if (ctx.state === "suspended") ctx.resume()
  return ctx
}

// Two seconds of white noise, reused by every sound.
function noise() {
  if (noiseBuffer) return noiseBuffer
  const c = audio()
  if (!c) return null
  const len = c.sampleRate * 2
  noiseBuffer = c.createBuffer(1, len, c.sampleRate)
  const data = noiseBuffer.getChannelData(0)
  for (let i = 0; i < len; i++) data[i] = Math.random() * 2 - 1
  return noiseBuffer
}

function burst({when = 0, dur = 0.08, freq = 1200, q = 3, vol = 0.25, filter = "bandpass"}) {
  const c = audio()
  const buffer = noise()
  if (!c || !buffer) return

  const at = c.currentTime + when

  const source = c.createBufferSource()
  source.buffer = buffer
  source.loop = true

  const biquad = c.createBiquadFilter()
  biquad.type = filter
  biquad.frequency.value = freq
  biquad.Q.value = q

  const gain = c.createGain()
  gain.gain.setValueAtTime(0.001, at)
  gain.gain.linearRampToValueAtTime(vol, at + 0.004)
  gain.gain.exponentialRampToValueAtTime(0.001, at + dur)

  source.connect(biquad)
  biquad.connect(gain)
  gain.connect(c.destination)
  source.start(at)
  source.stop(at + dur + 0.02)
}

// A die on the felt: soft and low.
function feltBounce(speed) {
  if (speed < 1.2) return
  burst({
    dur: Math.min(0.13, 0.035 + speed * 0.006),
    freq: 600 + speed * 25,
    q: 2.0,
    vol: Math.min(0.3, 0.06 + speed * 0.022),
    filter: "lowpass",
  })
}

// A die off the pyramid bumpers: a hard crack over a low body.
function wallBounce(speed) {
  if (speed < 1.2) return
  const vol = Math.min(0.4, 0.08 + speed * 0.028)
  burst({
    dur: Math.min(0.09, 0.025 + speed * 0.004),
    freq: 2400 + speed * 60,
    q: 4.5,
    vol,
    filter: "bandpass",
  })
  burst({dur: 0.07, freq: 180, q: 1.2, vol: vol * 0.55, filter: "lowpass"})
}

export function playBounce(type, speed) {
  if (!enabled) return
  if (type === "floor") feltBounce(speed)
  else if (type === "wall") wallBounce(speed)
}

// The rattle of the cup before the dice leave the hand.
export function playThrow() {
  if (!enabled) return
  for (let i = 0; i < 7; i++) {
    burst({
      when: i * 0.055 + Math.random() * 0.025,
      dur: 0.055 + Math.random() * 0.03,
      freq: 1400 + Math.random() * 600,
      q: 3.5,
      vol: Math.max(0.02, 0.18 - i * 0.02),
      filter: "bandpass",
    })
  }
}

// ── The croupier and the gallery ────────────────────────────────────────────
//
// The call is an outcome, not a sound effect. It must only ever be spoken
// where the rest of the result is revealed — naming the total while the dice
// are still rolling would give the game away through the one channel nobody
// thinks to check. The cheer rides along with it.

const CROUPIER_VOICES = ["Daniel", "Alex", "Fred", "Tom", "David", "James"]

// Somebody else at the rail, so the cheer does not sound like the croupier
// congratulating his own call.
const GALLERY_VOICES = ["Samantha", "Karen", "Moira", "Rishi", "Victoria", "Serena"]

function englishVoices() {
  return (window.speechSynthesis.getVoices() || []).filter((v) => v.lang.startsWith("en"))
}

function pickVoice(prefs, avoid) {
  const english = englishVoices()
  const wanted = english.filter((v) => prefs.some((p) => v.name.includes(p)))
  const distinct = wanted.filter((v) => v.name !== (avoid && avoid.name))
  return distinct[0] || wanted[0] || english.find((v) => v !== avoid) || english[0] || null
}

let winStreak = 0

export function announce(event, total) {
  if (!enabled || !window.speechSynthesis) return

  const call = croupierCall(event, total)
  winStreak = nextStreak(winStreak, event)
  const cheer = galleryCheer(event, winStreak)
  if (!call && !cheer) return

  window.speechSynthesis.cancel()

  const speak = () => {
    const croupier = pickVoice(CROUPIER_VOICES, null)

    if (call) {
      const utterance = new SpeechSynthesisUtterance(call)
      utterance.rate = 0.88
      utterance.pitch = 0.82
      utterance.volume = 0.95
      if (croupier) utterance.voice = croupier
      window.speechSynthesis.speak(utterance)
    }

    if (cheer) {
      // Queued behind the call rather than cancelling it, so the table hears
      // the result and then the room reacting to it.
      const utterance = new SpeechSynthesisUtterance(cheer)
      utterance.rate = 1.02
      utterance.pitch = 1.15
      utterance.volume = 0.85
      const voice = pickVoice(GALLERY_VOICES, croupier)
      if (voice) utterance.voice = voice
      window.speechSynthesis.speak(utterance)
    }
  }

  // Voices load asynchronously on some browsers and the list is empty until
  // they do.
  if (window.speechSynthesis.getVoices().length > 0) {
    speak()
  } else {
    window.speechSynthesis.addEventListener("voiceschanged", speak, {once: true})
  }
}

export function stopSpeaking() {
  if (window.speechSynthesis) window.speechSynthesis.cancel()
}
