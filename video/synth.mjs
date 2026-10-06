// A synthetic drafting track for previewing the edit before the real song
// exists. It matches video/tracks/draft-110.json: 110 BPM, 27 bars of 4/4,
// D minor (i–VI–III–VII: Dm Bb F C), synthesized in code with no samples.
// It is never the film's soundtrack.
//
//   node video/synth.mjs [video/cache/music/draft-110.wav]
//
// Bars (zero-based) follow the draft landmarks:
//   0–3   intro: warm pad swell and a filtered bass pulse, no drums
//   4–13  groove: kick, gated snare on 2 and 4, eighth hats, driving bass
//   14–19 build: sixteenth arpeggio, opening filter, low toms, riser in bar 19
//   20–23 drop: full groove, brassy lead, wide pad
//   24    outro groove; 25 final hit on the downbeat, then a dark tail to bar 27
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname } from 'node:path'

const SR = 48000, BPM = 110, BEAT = 60 / BPM, BAR = 4 * BEAT, BARS = 27
const LEN = Math.round(BARS * BAR * SR)
const L = new Float32Array(LEN), R = new Float32Array(LEN), SEND = new Float32Array(LEN)
const at = (t) => Math.round(t * SR)
const bar = (b) => b * BAR
const hz = (m) => 440 * Math.pow(2, (m - 69) / 12)
let seed = 0x6d61676d
const rnd = () => { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; return (seed >>> 0) / 4294967296 * 2 - 1 }
const add = (i, l, r = l, send = 0) => { if (i >= 0 && i < LEN) { L[i] += l; R[i] += r; SEND[i] += send * (l + r) * .5 } }

const CHORDS = [[62, 65, 69], [58, 62, 65], [65, 69, 72], [60, 64, 67]] // Dm Bb F C
const ROOTS = [38, 34, 41, 36]
const chord = (b) => CHORDS[((b % 4) + 4) % 4], root = (b) => ROOTS[((b % 4) + 4) % 4]
const section = (b) => b < 4 ? 'intro' : b < 14 ? 'groove' : b < 20 ? 'build' : b < 24 ? 'drop' : b < 25 ? 'outro' : 'tail'

function lowpass() { let a = 0, b = 0; return (x, c) => { const k = 1 - Math.exp(-2 * Math.PI * Math.min(c, SR * .45) / SR); a += k * (x - a); b += k * (a - b); return b } }
const saw = (p) => 2 * (p - Math.floor(p + .5))
const sq = (p) => (p - Math.floor(p)) < .5 ? 1 : -1

// Pad: detuned saws per chord tone, slow attack, filtered warm.
function pad(b0, b1, gain, cutoff) {
  for (let b = b0; b < b1; b++) {
    const notes = chord(b).flatMap((n) => [n - 12, n]), i0 = at(bar(b)), n = at(BAR)
    const filters = notes.map(() => [lowpass(), lowpass()])
    notes.forEach((note, v) => {
      const f = hz(note), ph = [0, .33, .71]
      for (let i = 0; i < n + at(.4); i++) {
        const t = i / SR, env = Math.min(1, t / .6) * (i > n ? Math.max(0, 1 - (i - n) / at(.4)) : 1)
        let s = 0
        for (let d = 0; d < 3; d++) s += saw(f * (1 + (d - 1) * .0035) * t + ph[d])
        const c = typeof cutoff === 'function' ? cutoff(b + t / BAR) : cutoff
        const y = filters[v][0](s / 3, c) * env * gain / notes.length
        add(i0 + i, y * (v % 2 ? .8 : 1.1), y * (v % 2 ? 1.1 : .8), .5)
      }
    })
  }
}
function kick(t, gain = 1) {
  const i0 = at(t)
  let ph = 0
  for (let i = 0; i < at(.42); i++) {
    const s = i / SR, f = 45 + 95 * Math.exp(-s * 28)
    ph += f / SR
    const y = Math.sin(2 * Math.PI * ph) * Math.exp(-s * 7.5) * gain + (i < 90 ? rnd() * .25 * (1 - i / 90) : 0)
    add(i0 + i, y * .9, y * .9)
  }
}
function snare(t, gain = 1) {
  const i0 = at(t), lp = lowpass()
  for (let i = 0; i < at(.32); i++) {
    const s = i / SR, gate = s < .2 ? 1 : Math.max(0, 1 - (s - .2) / .12)
    const n = rnd()
    const body = Math.sin(2 * Math.PI * 190 * s) * Math.exp(-s * 30) * .5
    const y = (lp(n, 5200) * Math.exp(-s * 9) * .7 + body) * gate * gain * .55
    add(i0 + i, y, y, .9)
  }
}
function hat(t, gain = .12) {
  const i0 = at(t)
  let prev = 0
  for (let i = 0; i < at(.05); i++) {
    const n = rnd(), y = (n - prev) * Math.exp(-i / SR * 70) * gain
    prev = n
    add(i0 + i, y * .8, y)
  }
}
function tom(t, note, gain = .6) {
  const i0 = at(t)
  let ph = 0
  for (let i = 0; i < at(.5); i++) {
    const s = i / SR, f = hz(note) * (1 + .5 * Math.exp(-s * 18))
    ph += f / SR
    const y = Math.sin(2 * Math.PI * ph) * Math.exp(-s * 6) * gain
    add(i0 + i, y, y * .9, .4)
  }
}
function crash(t, gain = .35) {
  const i0 = at(t), lp = lowpass()
  for (let i = 0; i < at(2.4); i++) { const s = i / SR, y = (rnd() - lp(rnd(), 3000)) * Math.exp(-s * 1.6) * gain; add(i0 + i, y, y * .95, .3) }
}
function note(t, dur, midi, { gain = .2, cutoff = 2400, wave = 'saw', attack = .01, send = .2, pan = 0 } = {}) {
  const i0 = at(t), n = at(dur), f = hz(midi), lp = lowpass()
  for (let i = 0; i < n + at(.12); i++) {
    const s = i / SR, env = Math.min(1, s / attack) * (i > n ? Math.max(0, 1 - (i - n) / at(.12)) : 1)
    const raw = wave === 'saw' ? (saw(f * s) + saw(f * 1.004 * s)) / 2 : (sq(f * s) * .6 + saw(f * .998 * s) * .4)
    const y = lp(raw, cutoff) * env * gain
    add(i0 + i, y * (1 - pan), y * (1 + pan), send)
  }
}
function riser(t0, t1, gain = .25) {
  const i0 = at(t0), n = at(t1 - t0), lp = lowpass()
  for (let i = 0; i < n; i++) { const k = i / n, y = lp(rnd(), 400 + 9000 * k * k) * k * k * gain; add(i0 + i, y, y, .6) }
}

// Arrangement
pad(0, 4, .42, (b) => 380 + 260 * b)
pad(4, 14, .32, 1400)
pad(14, 20, .32, (b) => 1400 + 500 * (b - 14))
pad(20, 25, .38, 4200)
pad(25, 26, .5, 3200)
for (let b = 0; b < 25; b++) {
  const sec = section(b)
  for (let e = 0; e < 8; e++) {
    const t = bar(b) + e * BEAT / 2
    const cutoff = sec === 'intro' ? 180 + 90 * b : sec === 'groove' ? 520 : sec === 'build' ? 520 + 220 * (b - 14) + 30 * e : 1800
    note(t, BEAT / 2 * .9, root(b) + (e % 4 === 3 ? 12 : 0), { gain: sec === 'intro' ? .16 + .04 * b : .3, cutoff, wave: 'square', send: .05 })
  }
  if (sec !== 'intro') {
    for (let q = 0; q < 4; q++) {
      const t = bar(b) + q * BEAT
      kick(t, sec === 'drop' ? 1.05 : .95)
      if (q % 2 === 1) snare(t, sec === 'drop' ? 1.1 : 1)
      hat(t + BEAT / 2, sec === 'drop' ? .16 : .11)
      if (sec !== 'groove') hat(t, .07)
    }
  }
  if (sec === 'build') {
    const tones = chord(b)
    for (let s = 0; s < 16; s++) note(bar(b) + s * BEAT / 4, BEAT / 4 * .8, tones[s % 3] + (s % 6 < 3 ? 0 : 12), { gain: .07 + .012 * (b - 14), cutoff: 1200 + 700 * (b - 14), wave: 'square', send: .35, pan: s % 2 ? .3 : -.3 })
    if (b >= 18) for (let s = 0; s < 4; s++) tom(bar(b) + (3 + s * .25) * BEAT, 45 - s * 3)
  }
  if (sec === 'drop') {
    const motif = [[0, 74, 1.5], [1.5, 72, .5], [2, 69, 2], [0, 77, 1.5], [1.5, 76, .5], [2, 74, 2]]
    for (const [beat, midi, len] of motif.slice((b % 2) * 3, (b % 2) * 3 + 3)) note(bar(b) + beat * BEAT, len * BEAT * .95, midi - (b % 4 === 1 ? 2 : 0), { gain: .16, cutoff: 3000, attack: .06, send: .45 })
  }
}
riser(bar(19), bar(20), .3)
for (let s = 0; s < 8; s++) snare(bar(19) + 2 * BEAT + s * BEAT / 4, .35 + .08 * s)
crash(bar(20)); crash(bar(25), .45)
kick(bar(25), 1.25)
for (const n of [50, 62, 65, 69, 74]) note(bar(25), BAR * 1.6, n, { gain: .13, cutoff: 2600, attack: .005, send: .7 })

// Reverb send: four combs and two allpasses per side.
function reverb(input, delays, feedback = .78) {
  const out = new Float32Array(LEN)
  for (const d of delays) {
    const buf = new Float32Array(d), damp = lowpass()
    let j = 0
    for (let i = 0; i < LEN; i++) { const y = buf[j]; buf[j] = input[i] + damp(y, 5000) * feedback; out[i] += y * .25; j = (j + 1) % d }
  }
  for (const d of [556, 441]) {
    const buf = new Float32Array(d)
    let j = 0
    for (let i = 0; i < LEN; i++) { const b = buf[j], y = -out[i] + b; buf[j] = out[i] + b * .5; out[i] = y; j = (j + 1) % d }
  }
  return out
}
const wetL = reverb(SEND, [1557, 1617, 1491, 1422]), wetR = reverb(SEND, [1580, 1640, 1514, 1445])

// Master: gentle tape saturation, peak at -1 dBFS.
let peak = 0
for (let i = 0; i < LEN; i++) {
  L[i] = Math.tanh((L[i] + wetL[i] * .35) * 1.1); R[i] = Math.tanh((R[i] + wetR[i] * .35) * 1.1)
  peak = Math.max(peak, Math.abs(L[i]), Math.abs(R[i]))
}
const scale = Math.pow(10, -1 / 20) / peak
const pcm = Buffer.alloc(44 + LEN * 4)
pcm.write('RIFF', 0); pcm.writeUInt32LE(36 + LEN * 4, 4); pcm.write('WAVEfmt ', 8)
pcm.writeUInt32LE(16, 16); pcm.writeUInt16LE(1, 20); pcm.writeUInt16LE(2, 22); pcm.writeUInt32LE(SR, 24)
pcm.writeUInt32LE(SR * 4, 28); pcm.writeUInt16LE(4, 32); pcm.writeUInt16LE(16, 34); pcm.write('data', 36); pcm.writeUInt32LE(LEN * 4, 40)
for (let i = 0; i < LEN; i++) {
  pcm.writeInt16LE(Math.round(Math.max(-1, Math.min(1, L[i] * scale)) * 32767), 44 + i * 4)
  pcm.writeInt16LE(Math.round(Math.max(-1, Math.min(1, R[i] * scale)) * 32767), 46 + i * 4)
}
const out = process.argv[2] || new URL('cache/music/draft-110.wav', import.meta.url).pathname
mkdirSync(dirname(out), { recursive: true })
writeFileSync(out, pcm)
console.log(`synth: ${(LEN / SR).toFixed(3)} s, ${BPM} BPM, ${BARS} bars -> ${out}`)
