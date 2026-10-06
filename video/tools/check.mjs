// Validate cue bounds, scene durations and real capture references without a browser.
// Missing captures are allowed while planning; --final requires them for measured cuts.
// node video/tools/check.mjs CUT [--capture DIR] [--final]
import { readFileSync, existsSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { parseArgs } from 'node:util'
import { Music } from '../web/music.js'

const { values: opt, positionals } = parseArgs({ allowPositionals: true, options: {
  capture: { type: 'string' }, final: { type: 'boolean', default: false },
} })
const here = new URL('..', import.meta.url).pathname
const cut = JSON.parse(readFileSync(resolve(positionals[0] || join(here, 'tracks/draft-110.json')), 'utf8'))
if (!Number.isFinite(cut.duration) || cut.duration <= 0) throw new Error('cut duration must be finite and positive')
if (!Array.isArray(cut.scenes) || !cut.scenes.length) throw new Error('cut needs scenes')
const M = new Music(cut)
if (!Number.isFinite(M.beat) || M.beat <= 0) throw new Error('cut needs a positive beat interval')
const capture = resolve(opt.capture || join(here, 'cache/capture'))
const requireCaptures = opt.final && cut.kind === 'measured'
const skipped = cut.scenes.filter((s) => s.skip).map((s) => s.id)
cut.scenes = cut.scenes.filter((s) => !s.skip)
const problems = []
const fail = (message) => problems.push(message)
if (!cut.scenes.length) fail('cut has no enabled scenes')
const T = (expr, where) => {
  try {
    const t = M.T(expr)
    if (!Number.isFinite(t)) throw new Error('cue must resolve to a finite time')
    return t
  } catch (error) { fail(`${where}: ${error.message}`); return NaN }
}
const bounds = (t, where, start = 0, end = M.duration) => {
  if (Number.isFinite(t) && (t < start - .01 || t > end + .01)) fail(`${where} is outside ${start.toFixed(2)}–${end.toFixed(2)} s (${t.toFixed(2)} s)`)
}
const duration = (expr, where) => {
  try {
    const d = M.dur(expr, 0)
    if (!Number.isFinite(d) || d < 0) throw new Error('duration must be finite and non-negative')
    return d
  } catch (error) { fail(`${where}: ${error.message}`); return NaN }
}

const tapes = {}
for (const name of new Set(cut.scenes.map((s) => s.tape).filter(Boolean))) {
  const path = join(capture, 'tapes', `${name}.json`)
  if (existsSync(path)) {
    const tape = JSON.parse(readFileSync(path, 'utf8'))
    tapes[name] = new Map(tape.marks.map((m) => [m.name, m.t]).reverse())
    if (requireCaptures && !tape.frames?.length) fail(`tape ${name} contains no captured frames`)
  } else if (requireCaptures) fail(`tape ${name} was not captured`)
}
const bar = existsSync(join(capture, 'bar/bar.json')) ? JSON.parse(readFileSync(join(capture, 'bar/bar.json'), 'utf8')) : null
if (requireCaptures && cut.scenes.some((s) => s.kind === 'bar') && !bar) fail('bar states were not captured')
if (requireCaptures && cut.scenes.some((s) => s.kind === 'cli') && !existsSync(join(capture, 'cli.json'))) fail('CLI cameo was not captured')

let previous = -Infinity
const rows = []
cut.scenes.forEach((s, i) => {
  const t0 = T(s.start, `${s.id}.start`)
  if (!(t0 >= previous)) fail(`${s.id} starts before the previous scene`)
  previous = t0
  const t1 = s.end !== undefined ? T(s.end, `${s.id}.end`) : i + 1 < cut.scenes.length ? T(cut.scenes[i + 1].start, 'next') : M.duration
  bounds(t0, `${s.id}.start`); bounds(t1, `${s.id}.end`)
  if (!(t1 > t0)) fail(`${s.id} must have a positive scene duration`)
  const sceneBounds = (t, where) => { bounds(t, where); bounds(t, where, t0, t1) }
  for (const [k, v] of Object.entries(s.cues || {})) sceneBounds(T(v, `${s.id}.cues.${k}`), `${s.id}.cues.${k}`)
  for (const c of s.captions || []) {
    const a = T(c.at, `${s.id}.caption`), b = c.until !== undefined ? T(c.until, `${s.id}.caption.until`) : t1
    sceneBounds(a, `${s.id}.caption`); sceneBounds(b, `${s.id}.caption.until`)
    if (b - a < 1.2) fail(`${s.id}: caption "${c.big}" is on screen only ${(b - a).toFixed(2)} s`)
  }
  for (const k of s.camera || []) {
    if (k.to && !['full', 'right', 'left', 'top', 'center', 'bottom'].includes(k.to)) fail(`${s.id}: unknown camera box ${k.to}`)
    const at = T(k.at, `${s.id}.camera`), d = duration(k.dur, `${s.id}.camera.dur`)
    sceneBounds(at, `${s.id}.camera`); sceneBounds(at + d, `${s.id}.camera.end`)
  }
  for (const [stem, at] of s.states || []) {
    sceneBounds(T(at, `${s.id}.states`), `${s.id}.states`)
    if (bar && !bar.frames.some((f) => f.file === `${stem}.png`)) fail(`${s.id}: bar state ${stem} was not captured`)
    if (requireCaptures && bar && !existsSync(join(capture, 'bar', `${stem}.png`))) fail(`${s.id}: bar image ${stem} is missing`)
  }
  if (s.kind === 'term' && !s.sync?.length) fail(`${s.id}: terminal scene needs sync anchors`)
  if (s.sync) {
    let lastFilm = -Infinity, lastTape = -Infinity
    for (const [mark, at] of s.sync) {
      const f = T(at, `${s.id}.sync.${mark}`)
      sceneBounds(f, `${s.id}.sync.${mark}`)
      if (f <= lastFilm) fail(`${s.id}: sync anchors must advance in film time at ${mark}`)
      const tape = tapes[s.tape]
      if (tape) {
        if (!tape.has(mark)) fail(`${s.id}: tape ${s.tape} has no mark ${mark}`)
        else {
          const p = tape.get(mark)
          if (!Number.isFinite(p) || p < 0) fail(`${s.id}: ${mark} has an invalid tape time`)
          if (p < lastTape) fail(`${s.id}: ${mark} runs the tape backwards`)
          if (f > lastFilm && p > lastTape && lastFilm > -Infinity && (p - lastTape) / (f - lastFilm) > 12) fail(`${s.id}: ${mark} plays the tape faster than 12x`)
          lastTape = p
        }
      }
      lastFilm = f
    }
  }
  rows.push(`${s.id.padEnd(10)} ${t0.toFixed(2).padStart(6)} → ${t1.toFixed(2).padStart(6)}  ${(t1 - t0).toFixed(2).padStart(5)} s  ${s.kind}${s.tape ? `:${s.tape}${tapes[s.tape] ? '' : ' (not captured)'}` : ''}`)
})
// The poster is either a film time or a real tape state ({tape, mark}) composed by the page.
if (cut.poster && typeof cut.poster === 'object') {
  const tape = tapes[cut.poster.tape] ?? (existsSync(join(capture, 'tapes', `${cut.poster.tape}.json`))
    ? new Map(JSON.parse(readFileSync(join(capture, 'tapes', `${cut.poster.tape}.json`), 'utf8')).marks.map((m) => [m.name, m.t])) : null)
  if (tape && !tape.has(cut.poster.mark)) fail(`poster: tape ${cut.poster.tape} has no mark ${cut.poster.mark}`)
  if (!tape && requireCaptures) fail(`poster: tape ${cut.poster.tape} was not captured`)
} else {
  const poster = cut.poster !== undefined ? cut.poster : 'drop' in M.landmarks ? '@drop+3b' : M.duration * .7
  bounds(T(poster, 'poster'), 'poster')
}
const landmarks = Object.entries(M.landmarks).map(([k, v]) => `${k}=${T(v, `landmark ${k}`).toFixed(2)}`)
console.log(`${cut.kind || 'cut'} map: ${M.duration.toFixed(3)} s, ${M.beats.length} beats, beat ${M.beat.toFixed(4)} s (${(60 / M.beat).toFixed(2)} BPM)`)
console.log(`landmarks: ${landmarks.join(' ')}`)
console.log(rows.join('\n'))
if (skipped.length) console.log(`skipped (optional): ${skipped.join(', ')}`)
if (problems.length) {
  console.error(`\n${problems.length} problem(s):\n- ${problems.join('\n- ')}`)
  process.exit(1)
}
console.log('check: ok')
