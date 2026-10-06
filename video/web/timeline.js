// The Omagma film. render(t) is pure: the same t always gives the same frame.
// Times come from the cut map (video/tracks/*.json) and are written in musical
// terms that resolve against the measured beats:
//   D12        downbeat 12 (bar 12, zero-based)      B40   beat 40
//   @drop      a landmark from the cut map           @end  the film's end
//   D12+2b     two beats after bar 12                @drop-1   one bar before the drop
//   D12+0.25s  plain seconds                          7.5   seconds from the start
// Terminal scenes show real tapes (video/capture/takes.py); `sync` pins tape
// marks to film times, and frames between are re-timed linearly. Nothing here
// draws Omagma UI: overlays only emphasise events the tape actually contains.
import { PALETTE, clamp, mix, smooth, easeOut, easeIn, easeInOut, viscous, MagmaField, LogoFlow, seam, grainTile, frameHash, fbm } from './magma.js'
import { Tape, TermView, paneOutline } from './term.js'
import { Music } from './music.js'

const $ = (selector, root = document) => root.querySelector(selector)
const W = 1920, H = 1080, PAD = 22
const params = new URLSearchParams(location.search)
const pending = []
let M, CUT, SCENES, TAPES = {}, BAR = null, CLI = null, LOGO = null, FPS = 30

// --- loading ------------------------------------------------------------------------
async function json(url, optional = false) {
  const response = await fetch(url)
  if (!response.ok) { if (optional) return null; throw new Error(`${url}: ${response.status}`) }
  return response.json()
}
async function image(urls) {
  for (const url of [].concat(urls)) {
    const img = new Image()
    img.src = url
    try { await img.decode(); return img } catch { /* try the next source */ }
  }
  throw new Error(`no image: ${urls}`)
}

async function init() {
  const cutUrl = params.get('cut') || '../tracks/draft-110.json'
  const cut = CUT = await json(cutUrl)
  FPS = cut.fps || 30
  M = new Music(cut)
  const capture = params.get('capture') || '../cache/capture'
  const used = cut.scenes.filter((s) => s.tape && !s.skip).map((s) => s.tape)
  if (cut.poster?.tape) used.push(cut.poster.tape)
  for (const name of new Set(used)) {
    const data = await json(`${capture}/tapes/${name}.json`, true)
    if (data) TAPES[name] = new Tape(data)
  }
  BAR = await json(`${capture}/bar/bar.json`, true)
  if (BAR) {
    const host = $('#bar .frames')
    BAR.images = {}
    for (const frame of BAR.frames) {
      const img = await image(`${capture}/bar/${frame.file}`)
      img.dataset.stem = frame.file.replace(/\.png$/, '')
      host.append(img)
      BAR.images[img.dataset.stem] = img
    }
  }
  CLI = await json(`${capture}/cli.json`, true)
  const logo = await image([params.get('logo') || '../cache/logo-master.png', '../../assets/omagma-logo.png'])
  LOGO = { flow: new LogoFlow(logo, 520), small: logo }
  await Promise.all(['800 150px', '850 74px', '500 34px', '600 32px'].map((f) => document.fonts.load(`${f} "Adwaita Sans"`)))
  await Promise.all(['400', '700', 'italic 400', 'italic 700'].map((f) => document.fonts.load(`${f} 20px "JetBrainsMono Nerd Font"`)))
  await document.fonts.load('20px "Noto Color Emoji"', '🌋')
  await document.fonts.ready
  wrapForRise($('#ember .word')); wrapForRise($('#outro .word'))
  scrims()
  if (params.get('label')) {
    const label = document.createElement('div')
    label.id = 'label'; label.textContent = params.get('label')
    $('#stage').append(label)
  }
  $('#grain').style.backgroundImage = `url(${grainTile()})`
  TERM.view = new TermView($('#term .surface'))
  SCENES = resolve(cut)
  const gaps = missing()
  if (params.has('strict') && (gaps.tapes.length || gaps.bar || gaps.cli)) throw new Error(`strict render: missing captures ${JSON.stringify(gaps)}`)
  window.RESOLVED = resolved(cut)
  if (params.has('scrub')) scrubber()
  if (params.has('t')) await window.render(+params.get('t'))
  return { duration: M.duration, fps: FPS, frames: Math.round(M.duration * FPS), missing: missing() }
}

function missing() {
  const tapes = SCENES.filter((s) => s.tape && !TAPES[s.tape]).map((s) => s.tape)
  return { tapes: [...new Set(tapes)], bar: !BAR, cli: !CLI }
}

function wrapForRise(el) {
  const clip = document.createElement('div')
  clip.className = 'clip rise'
  Object.assign(clip.style, { position: 'absolute', left: 0, right: 0, top: el.style.top || getComputedStyle(el).top })
  el.style.position = 'relative'; el.style.top = '0'
  el.replaceWith(clip); clip.append(el)
}

// --- scene resolution ----------------------------------------------------------------
function resolve(cut) {
  const list = cut.scenes.filter((s) => !s.skip).map((s) => ({ ...s, t0: M.T(s.start) }))
  list.forEach((s, i) => {
    s.t1 = s.end !== undefined ? M.T(s.end) : list[i + 1]?.t0 ?? M.duration
    s.at = Object.fromEntries(Object.entries(s.cues || {}).map(([k, v]) => [k, M.T(v)]))
    s.captions = (s.captions || []).map((c, j) => ({ ...c, id: `${s.id}-${j}`, t0: M.T(c.at), t1: c.until !== undefined ? M.T(c.until) : s.t1 }))
    if (s.states) s.states = s.states.map(([stem, at]) => [stem, M.T(at)])
    if (s.kind === 'term') resolveTerm(s, list[i - 1])
  })
  // A caption makes way when the next one in the same place arrives: quick exit, short delayed entry.
  const family = (pos) => ({ 'left-low': 'left', stat: 'left', 'bottom-low': 'bottom' })[pos || 'left'] || pos || 'left'
  const all = list.flatMap((s) => s.captions).sort((a, b) => a.t0 - b.t0)
  all.forEach((c, i) => {
    const next = all.slice(i + 1).find((n) => family(n.pos) === family(c.pos))
    if (next && next.t0 < c.t1 + .35) { c.t1 = Math.min(c.t1, next.t0); c.quick = true; next.delay = .14 }
  })
  return list
}

function resolveTerm(s, previous) {
  const tape = TAPES[s.tape]
  s.previous = previous
  s.open = s.open ? { ...s.open, dur: M.dur(s.open.dur, .6) } : null
  s.camera = (s.camera || [{ at: s.start, view: 'all' }]).map((k) => ({ ...k, t: M.T(k.at), dur: M.dur(k.dur, 0) }))
  s.pulses = (s.pulses || []).map((p) => ({ ...p, t: M.T(p.at), dur: M.dur(p.dur, '2b') }))
  if (s.burst) s.burst = { ...s.burst, t: M.T(s.burst.at) }
  if (s.tag) s.tag = { ...s.tag, t0: M.T(s.tag.at), t1: M.T(s.tag.until) }
  if (!tape) { s.anchors = []; s.keys = []; s.clicks = []; return }
  s.anchors = s.sync.map(([mark, at]) => [M.T(at), tape.mark(mark).t]).sort((a, b) => a[0] - b[0])
  const inScene = (f) => f >= s.t0 - .3 && f < s.t1
  s.keys = tape.marks.filter((m) => m.keys !== undefined && m.show !== false)
    .map((m) => ({ f: filmTime(s, m.t), keys: m.keys, name: m.name })).filter((k) => inScene(k.f))
  if (s.hideKeys) s.keys = s.keys.filter((k) => !s.hideKeys.some((prefix) => k.name.startsWith(prefix)))
  s.clicks = tape.marks.filter((m) => m.click).map((m) => ({ f: filmTime(s, m.t), cell: m.click })).filter((c) => inScene(c.f))
}

function tapeTime(s, t) {
  const a = s.anchors
  if (!a.length) return 0
  if (t <= a[0][0]) return Math.max(0, a[0][1] - (a[0][0] - t))
  for (let i = 0; i + 1 < a.length; i++) {
    if (t < a[i + 1][0]) {
      const [f0, p0] = a[i], [f1, p1] = a[i + 1]
      return p0 + (p1 - p0) * (t - f0) / (f1 - f0)
    }
  }
  const [f, p] = a[a.length - 1]
  return p + (t - f)
}
function filmTime(s, p) {
  const a = s.anchors
  if (p < a[0][1]) return a[0][0] - (a[0][1] - p)
  for (let i = 0; i + 1 < a.length; i++) {
    const [f0, p0] = a[i], [f1, p1] = a[i + 1]
    if (p >= p0 && p < p1) return f0 + (f1 - f0) * (p - p0) / (p1 - p0)
  }
  const [f, q] = a[a.length - 1]
  return f + (p - q)
}

function resolved(cut) {
  const r = (x) => +x.toFixed(3)
  const poster = typeof cut.poster === 'object' ? cut.poster : r(cut.poster !== undefined ? M.T(cut.poster) : 'drop' in M.landmarks ? M.T('@drop+3b') : M.duration * .7)
  return {
    kind: cut.kind, track: cut.track, analysis: cut.analysis, audio_offset: cut.audio_offset ?? 0, audio: cut.audio, duration: M.duration, fps: FPS, poster,
    scenes: SCENES.map((s) => ({ id: s.id, kind: s.kind, start: r(s.t0), end: r(s.t1),
      cues: Object.fromEntries(Object.entries(s.at).map(([k, v]) => [k, r(v)])),
      captions: s.captions.map((c) => ({ text: [c.big, c.small].filter(Boolean).join(' / '), start: r(c.t0), end: r(c.t1) })),
      ...(s.kind === 'term' ? { tape: s.tape, sync: s.anchors.map(([f, p]) => [r(f), r(p)]),
        keys: (s.keys || []).map((k) => [r(k.f), k.keys]), clicks: (s.clicks || []).map((c) => [r(c.f), c.cell]) } : {}),
      ...(s.states ? { states: s.states.map(([stem, at]) => [stem, r(at)]) } : {}) })),
  }
}

// --- shared drawing -----------------------------------------------------------------
const fx = $('#fx').getContext('2d')
const show = (selector) => $(selector).classList.add('on')
const BOXES = {
  full: { x: 70, y: 66, w: 1780, h: 948 }, right: { x: 700, y: 70, w: 1160, h: 940 },
  left: { x: 60, y: 70, w: 1160, h: 940 }, top: { x: 70, y: 50, w: 1780, h: 700 }, center: { x: 240, y: 80, w: 1440, h: 920 },
  bottom: { x: 70, y: 280, w: 1780, h: 760 },
}

function background(t, scene) {
  const level = M.level(t)
  $('#bg .heat').style.opacity = (.08 + .16 * level * (scene?.heat ?? 1)).toFixed(3)
  const i = Math.round(t * FPS)
  $('#grain').style.backgroundPosition = `${Math.round(frameHash(i) * 256)}px ${Math.round(frameHash(i + 7919) * 256)}px`
}

// --- ember: the logo in the dark, then into the bar -----------------------------------
const ICON = { x: 1872, y: 29, size: 40 }
function ember(s, t) {
  show('#ember')
  const el = $('#ember'), a = s.at
  const logo = $('.logo', el), local = t - (a.logo ?? s.t0)
  const glow = .35 + .65 * smooth(0, 2.5, local) + .25 * M.level(t)
  const canvas = LOGO.flow.draw(t, { amount: 1, glow: clamp(glow * .6, 0, .8) })
  const ctx = logo.getContext('2d')
  ctx.clearRect(0, 0, 520, 520); ctx.drawImage(canvas, 0, 0)
  const appear = viscous(local / 1.6)
  let x = 960, y = 350, size = 360 * (.9 + .1 * appear), opacity = appear
  if (a.fly !== undefined && t >= a.fly) {
    const k = easeInOut((t - a.fly) / M.dur(s.flyDur, '2b'))
    x = mix(960, ICON.x, k); y = mix(350, ICON.y, k) - Math.sin(k * Math.PI) * 60
    size = mix(360, ICON.size, Math.pow(k, .8))
    if (k >= 1) opacity = 0
  }
  Object.assign(logo.style, { left: `${x - size / 2}px`, top: `${y - size / 2}px`, width: `${size}px`, height: `${size}px`, opacity,
    filter: `drop-shadow(0 0 ${30 + 40 * glow}px rgba(236, 122, 53, ${.25 + .3 * glow * appear}))` })
  const leave = a.fly !== undefined ? 1 - easeIn((t - a.fly) / .35) : 1
  rise($('#ember .word'), t, a.word, leave)
  if (a.word !== undefined) {
    const k = t - a.word
    seam(fx, 960 - 330, 742, 960 + 330, 742, { progress: easeOut(k / .45), heat: 1 - smooth(.3, 2.2, k), t, width: 3, alpha: leave, seed: 2 })
  }
  const tag = $('#ember .tagline')
  tag.style.opacity = a.tag === undefined ? 0 : easeOut((t - a.tag) / .6) * leave
  tag.style.transform = `translateY(${(1 - easeOut((t - (a.tag ?? 0)) / .6)) * 14}px)`
  if (a.strip !== undefined && t >= a.strip) {
    strip(t, a.strip, a.fly !== undefined && t >= a.fly + M.dur(s.flyDur, '2b'))
    $('#bar .popup').style.display = 'none'
  }
}

function rise(el, t, at, opacity = 1) {
  if (at === undefined || t < at) { el.style.transform = 'translateY(110%)'; el.style.opacity = 0; return }
  const k = viscous((t - at) / .7)
  el.style.transform = `translateY(${(1 - k) * 105}%)`
  el.style.opacity = opacity
  const heat = 1 - smooth(.1, 1.1, t - at)
  el.style.color = heat > .01 ? `rgb(${mix(244, 255, heat)}, ${mix(240, 200, heat)}, ${mix(247, 150, heat)})` : ''
  el.style.textShadow = heat > .01 ? `0 0 ${40 * heat}px rgba(255, 140, 60, ${.7 * heat})` : ''
}

function strip(t, from, iconOn, glow = 0) {
  show('#bar')
  const k = viscous((t - from) / .6)
  $('#bar .strip').style.transform = `translateY(${(1 - k) * -64}px)`
  const icon = $('#bar .icon')
  icon.style.opacity = iconOn ? 1 : 0
  if (iconOn && icon.dataset.drawn !== '1') {
    const ctx = icon.getContext('2d'); ctx.clearRect(0, 0, 520, 520); ctx.drawImage(LOGO.small, 0, 0, 520, 520); icon.dataset.drawn = '1'
  }
  icon.style.filter = `drop-shadow(0 0 ${6 + 16 * glow}px rgba(255, 140, 60, ${.35 + .6 * glow}))`
}

// --- bar: a tiny eruption into the real dropdown, then the crack ----------------------
const POPUP = { x: 1920 - 22 - 1240, y: 70, w: 1240, h: 737 }
let pourField = null
function bar(s, t) {
  const a = s.at
  // Pressure on the icon builds toward the eruption.
  const pressure = a.erupt !== undefined ? smooth(a.erupt - 2 * M.beat, a.erupt, t) * (1 - smooth(a.erupt, a.erupt + .6, t)) : 0
  strip(t, -10, true, pressure + .3 * M.level(t))
  const popup = $('#bar .popup')
  let state = s.states?.[0]?.[0]
  for (const [stem, at] of s.states || []) if (t >= at) state = stem
  if (BAR) for (const [stem, img] of Object.entries(BAR.images)) img.classList.toggle('on', stem === state)
  const k = a.erupt === undefined ? 1 : (t - a.erupt) / 1.1
  const spill = { x: POPUP.x + POPUP.w - 70, y: POPUP.y + 14 }, reach = Math.hypot(POPUP.w, POPUP.h) + 320
  // A molten band sweeps out from the icon; the real dropdown is already cooled behind it.
  const spread = easeInOut((k - .08) / .62) * reach, cool = Math.max(0, spread - 230)
  popup.style.display = k > .12 ? 'block' : 'none'
  popup.style.maskImage = k >= 1 ? '' : `radial-gradient(circle at ${spill.x - POPUP.x}px ${spill.y - POPUP.y}px, #000 ${spread}px, transparent ${spread + 1}px)`
  if (k > 0 && k < 1.05) pour(t, k, spill, spread, cool)
  // The crack: the dropdown recedes, a seam opens across the frame, the command is typed on it.
  let dim = 0
  if (a.crack !== undefined && t >= a.crack) {
    dim = easeInOut((t - a.crack) / .6)
    const c = t - a.crack, L = 860
    seam(fx, 960, 540, 960 - L * viscous(c / .5), 540, { progress: 1, heat: .55 + .45 * M.level(t), t, width: 3.2, seed: 5 })
    seam(fx, 960, 540, 960 + L * viscous(c / .5), 540, { progress: 1, heat: .55 + .45 * M.level(t), t, width: 3.2, seed: 9 })
  }
  popup.style.opacity = (1 - .82 * dim).toFixed(3)
  popup.style.transform = `scale(${1 - .05 * dim})`
  popup.style.transformOrigin = '100% 0'
  if (a.type !== undefined && t >= a.type) {
    show('#prompt')
    const command = s.command || 'omagma tui', end = (a.enter ?? s.t1) - M.beat * .5
    const n = Math.floor(clamp((t - a.type) / Math.max(.2, end - a.type)) * command.length + 1e-6)
    $('#prompt .cmd').textContent = command.slice(0, n)
    $('#prompt .caret').style.opacity = n < command.length || Math.floor((t - a.type) / (M.beat / 2)) % 2 === 0 ? 1 : 0
  }
}

function pour(t, k, spill, spread, cool) {
  if (!pourField) pourField = new MagmaField(370, 220)
  const heat = .66 - .22 * smooth(.3, 1, k)
  const field = pourField.draw(t, { scale: 3.4, speed: .35, heat, seed: 3, aspect: POPUP.w / POPUP.h })
  fx.save()
  roundRect(fx, POPUP.x, POPUP.y, POPUP.w, POPUP.h, 16); fx.clip()
  // The molten sheet with a wobbling front.
  fx.beginPath()
  for (let i = 0; i <= 64; i++) {
    const angle = Math.PI / 2 + (i / 64) * Math.PI, r = spread * (1 + .07 * (fbm(i * .3, t * .8, 1, 2) - .5) * 2)
    const x = spill.x + Math.cos(angle) * r, y = spill.y - Math.sin(angle) * r
    i ? fx.lineTo(x, y) : fx.moveTo(x, y)
  }
  fx.lineTo(spill.x + spread, spill.y); fx.lineTo(spill.x + spread, spill.y - 40); fx.closePath(); fx.clip()
  fx.globalAlpha = .88
  fx.drawImage(field, POPUP.x, POPUP.y, POPUP.w, POPUP.h)
  fx.globalAlpha = 1
  // Cooling from the source outward reveals the real dropdown underneath.
  if (cool > 0) {
    fx.globalCompositeOperation = 'destination-out'
    const g = fx.createRadialGradient(spill.x, spill.y, Math.max(0, cool - 90), spill.x, spill.y, cool)
    g.addColorStop(0, 'rgba(0,0,0,1)'); g.addColorStop(1, 'rgba(0,0,0,0)')
    fx.fillStyle = g; fx.fillRect(POPUP.x, POPUP.y, POPUP.w, POPUP.h)
    fx.globalCompositeOperation = 'source-over'
  }
  fx.restore()
  // The spill itself: a bright bead from the icon to the dropdown.
  if (k < .35) {
    const p = easeIn(k / .35), x = mix(ICON.x, spill.x, p), y = mix(ICON.y + 14, spill.y, p)
    const g = fx.createRadialGradient(x, y, 0, x, y, 26)
    g.addColorStop(0, 'rgba(255, 240, 210, 1)'); g.addColorStop(.4, 'rgba(255, 150, 70, .8)'); g.addColorStop(1, 'rgba(236, 122, 53, 0)')
    fx.fillStyle = g; fx.fillRect(x - 26, y - 26, 52, 52)
  }
}

function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath()
  ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r)
  ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath()
}

// --- terminal scenes: real tapes, re-timed, framed by the camera ----------------------
const TERM = { view: null }
function term(s, t) {
  show('#term')
  const tape = TAPES[s.tape], view = TERM.view, win = $('#term .window')
  const note = $('#term .missing')
  if (note) note.style.display = tape ? 'none' : 'block'
  $('#term .surface').style.visibility = ''
  if (!tape) { placeholder(s, t); return }
  const index = tape.frameAt(tapeTime(s, t))
  const blink = Math.floor(t / (M.beat / 2)) % 2 === 0
  view.show(tape, index, { blink })
  const ww = view.width + 2 * PAD, wh = view.height + 2 * PAD
  Object.assign(win.style, { width: `${ww}px`, height: `${wh}px` })
  Object.assign($('#term .surface').style, { left: `${PAD}px`, top: `${PAD}px` })
  const cam = camera(s, t, tape, index, ww, wh)
  win.style.transform = `translate(${(W / 2 - cam.cx * cam.s).toFixed(2)}px, ${(H / 2 - cam.cy * cam.s).toFixed(2)}px) scale(${cam.s.toFixed(5)})`
  win.style.clipPath = ''
  win.style.maskImage = ''
  if (s.open && t < s.t0 + s.open.dur) opening(s, t, cam, ww, wh)
  pulses(s, t, tape, index)
  pointer(s, t)
  if (s.burst) burst(s, t, cam, ww, wh)
  if (s.tag) tagline(s.tag, t)
  keys(s, t)
}

function region(spec, tape, index, ww, wh) {
  const all = { x: 0, y: 0, w: ww, h: wh }
  if (!spec || spec === 'all') return all
  if (typeof spec === 'object') {
    const [c0, c1] = spec.cols || [0, tape.columns - 1], [r0, r1] = spec.rows || [0, tape.rows - 1]
    return { x: PAD + c0 * TERM.view.cellW, y: PAD + r0 * TERM.view.cellH, w: (c1 - c0 + 1) * TERM.view.cellW, h: (r1 - r0 + 1) * TERM.view.cellH }
  }
  if (spec.startsWith('pane:')) {
    const pane = tape.pane(index, spec.slice(5))
    if (!pane) return all
    const r = TERM.view.rect(pane)
    return { x: r.x + PAD - 10, y: r.y + PAD - 10, w: r.w + 20, h: r.h + 20 }
  }
  return all
}

function cameraState(k, tape, t, ww, wh) {
  const index = tape.frameAt(Math.max(0, tapeTime(k.scene, k.t + k.dur)))
  const r = region(k.view, tape, index, ww, wh), box = BOXES[k.to || 'full']
  const s = Math.min(box.w / r.w, box.h / r.h) * (k.zoom || 1)
  return { cx: r.x + r.w / 2 - (box.x + box.w / 2 - W / 2) / s, cy: r.y + r.h / 2 - (box.y + box.h / 2 - H / 2) / s, s }
}
function lerpCam(a, b, k) { return { cx: mix(a.cx, b.cx, k), cy: mix(a.cy, b.cy, k), s: Math.exp(mix(Math.log(a.s), Math.log(b.s), k)) } }
function drifted(state, k, t) {
  const since = Math.max(0, t - (k.t + k.dur))
  return k.drift ? { ...state, s: state.s * (1 + k.drift * since) } : state
}

function camera(s, t, tape, index, ww, wh) {
  const keys = s.camera.map((k) => ({ ...k, scene: s }))
  let i = keys.findLastIndex((k) => t >= k.t)
  if (i < 0) i = 0
  const k = keys[i], target = cameraState(k, tape, t, ww, wh)
  let from = null
  if (i > 0) from = drifted(cameraState(keys[i - 1], tape, t, ww, wh), keys[i - 1], k.t)
  else if (k.dur > 0 && s.previous?.kind === 'term' && TAPES[s.previous.tape]) {
    const prev = s.previous, last = prev.camera.map((c) => ({ ...c, scene: prev })).at(-1)
    from = drifted(cameraState(last, TAPES[prev.tape], s.t0, ww, wh), last, s.t0)
  }
  let state = from && k.dur > 0 && t < k.t + k.dur ? lerpCam(from, target, easeInOut((t - k.t) / k.dur)) : drifted(target, k, t)
  if (s.burst && t >= s.burst.t) state = { ...state, s: state.s * (1 + .03 * Math.exp(-(t - s.burst.t) * 5)) }
  return state
}

// The first terminal scene opens out of the seam: two molten edges part to reveal it.
function opening(s, t, cam, ww, wh) {
  const k = viscous((t - s.t0) / s.open.dur), inset = (1 - k) * 50
  $('#term .window').style.clipPath = `inset(${inset}% -2% ${inset}% -2% round 16px)`
  const x0 = W / 2 - cam.cx * cam.s, y0 = H / 2 - cam.cy * cam.s, w = ww * cam.s, h = wh * cam.s
  const top = y0 + h * (1 - k) / 2, bottom = y0 + h - h * (1 - k) / 2, heat = 1 - smooth(.45, 1, k)
  seam(fx, x0, top, x0 + w, top, { heat, t, width: 3.2, seed: 5, alpha: 1 - smooth(.85, 1, k) })
  seam(fx, x0, bottom, x0 + w, bottom, { heat, t, width: 3.2, seed: 9, alpha: 1 - smooth(.85, 1, k) })
}

// A bead of light travelling once around a pane border the app actually drew.
function pulses(s, t, tape, index) {
  const svg = $('#term .pulses'), view = TERM.view, parts = []
  const active = [...s.pulses]
  if (s.burst && t >= s.burst.t && t < s.burst.t + 1.6) active.push({ t: s.burst.t, dur: 1.4, pane: 'all', strong: true })
  for (const p of active) {
    const k = (t - p.t) / p.dur
    if (k < 0 || k > 1) continue
    const panes = p.pane === 'all' ? tape.panes(index) : [tape.pane(index, p.pane || 'focused')].filter(Boolean)
    panes.forEach((pane, n) => {
      const { d, length } = paneOutline(view, pane)
      const bead = length * (p.strong ? .3 : .16), head = easeInOut(k) * (length + bead) + n * length * .17
      const alpha = Math.sin(Math.PI * clamp(k)) * (p.strong ? 1 : .85)
      parts.push(`<path d="${d}" transform="translate(${PAD} ${PAD})" fill="none" stroke="url(#lava)" stroke-width="${p.strong ? 5 : 3.5}"
        stroke-linecap="round" stroke-dasharray="${bead.toFixed(1)} ${length.toFixed(1)}" stroke-dashoffset="${(bead - head).toFixed(1)}"
        opacity="${alpha.toFixed(3)}" filter="url(#glow)"/>`)
    })
  }
  const width = view.width + 2 * PAD, height = view.height + 2 * PAD
  svg.setAttribute('width', width); svg.setAttribute('height', height)
  svg.innerHTML = parts.length ? `<defs><linearGradient id="lava" x1="0" x2="1"><stop offset="0" stop-color="#ffd9a8"/><stop offset=".5" stop-color="#ff9e61"/><stop offset="1" stop-color="#ec7a35"/></linearGradient>
    <filter id="glow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="4" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>${parts.join('')}` : ''
}

// The send: a restrained heat ring from the window centre, cooling within a second.
let burstField = null, burstLayer = null
function burst(s, t, cam, ww, wh) {
  const k = t - s.burst.t
  if (k < 0 || k > 1.3) return
  if (!burstField) burstField = new MagmaField(320, 180)
  const cx = W / 2 - cam.cx * cam.s + ww * cam.s / 2, cy = H / 2 - cam.cy * cam.s + wh * cam.s / 2
  const radius = viscous(k / .9) * 1250, band = 150 + 120 * k, alpha = (1 - smooth(.25, 1.3, k)) * .55
  const field = burstField.draw(t, { scale: 2.6, speed: .5, heat: .7, seed: 11, aspect: 16 / 9 })
  if (!burstLayer) { burstLayer = document.createElement('canvas'); burstLayer.width = W; burstLayer.height = H }
  const layer = burstLayer, ctx = layer.getContext('2d')
  ctx.globalCompositeOperation = 'source-over'
  ctx.clearRect(0, 0, W, H)
  ctx.drawImage(field, 0, 0, W, H)
  ctx.globalCompositeOperation = 'destination-in'
  const g = ctx.createRadialGradient(cx, cy, Math.max(0, radius - band), cx, cy, radius)
  g.addColorStop(0, 'rgba(0,0,0,0)'); g.addColorStop(.6, 'rgba(0,0,0,1)'); g.addColorStop(1, 'rgba(0,0,0,0)')
  ctx.fillStyle = g; ctx.fillRect(0, 0, W, H)
  fx.save(); fx.globalAlpha = alpha; fx.globalCompositeOperation = 'screen'; fx.drawImage(layer, 0, 0); fx.restore()
}

function pointer(s, t) {
  const el = $('#term .pointer'), click = s.clicks.find((c) => t >= c.f - .7 && t < c.f + .9)
  if (!click) { el.style.display = 'none'; return }
  const view = TERM.view, [col, row] = click.cell
  const tx = PAD + (col + .5) * view.cellW, ty = PAD + (row + .5) * view.cellH
  const k = easeInOut((t - (click.f - .6)) / .5)
  const x = mix(tx + 9 * view.cellW, tx, k), y = mix(ty + 4 * view.cellH, ty, k)
  el.style.display = 'block'
  el.style.opacity = 1 - smooth(click.f + .5, click.f + .9, t)
  el.style.transform = `translate(${x - 5.7}px, ${y - 2.8}px) scale(${t >= click.f && t < click.f + .12 ? .9 : 1})`
  const ring = $('.ring', el), r = t >= click.f ? easeOut((t - click.f) / .45) : 0
  Object.assign(ring.style, { width: `${r * 70}px`, height: `${r * 70}px`, opacity: t >= click.f ? (1 - r) * .95 : 0 })
}

function placeholder(s, t) {
  // Draft renders without captures show where a take belongs; nothing pretends to be the app.
  if (params.has('strict')) throw new Error(`strict render: capture ${s.tape} missing`)
  const win = $('#term .window')
  Object.assign(win.style, { width: '1500px', height: '860px', transform: 'translate(210px, 110px)', clipPath: '' })
  let note = $('#term .missing')
  if (!note) {
    note = document.createElement('div')
    note.className = 'missing'
    note.style.cssText = 'position:absolute;left:250px;top:150px;font:28px var(--mono);color:#8b95ab'
    $('#term').append(note)
  }
  note.textContent = `capture "${s.tape}" missing: run video/build.sh capture`
  $('#term .surface').style.visibility = 'hidden'
}

function tagline(tag, t) {
  const el = $('#tag')
  el.textContent = tag.text
  el.style.opacity = (easeOut((t - tag.t0) / .4) * (1 - smooth(tag.t1 - .3, tag.t1, t))).toFixed(3)
}

// --- keycaps: keys actually sent, shown on the beat they land ---------------------------
const KEYNAMES = { '\x0e': ['Ctrl', 'N'], '\x10': ['Ctrl', 'P'], '\x13': ['Ctrl', 'S'], '\x15': ['Ctrl', 'U'], '\t': ['Tab'],
  '\r': ['Enter'], '\x1b': ['Esc'], ' ': ['Space'], '\x7f': ['⌫'] }
function keys(s, t) {
  const live = (s.keys || []).filter((k) => t >= k.f - .02 && t < k.f + 1.15).slice(-5)
  const host = $('#keys')
  host.className = s.keysAt === 'right' ? 'right' : ''
  host.innerHTML = live.map((k) => {
    const age = t - k.f, labels = KEYNAMES[k.keys] || [k.keys]
    const press = age < .1 ? 1.12 - .12 * (age / .1) : 1
    const heat = 1 - smooth(.04, .55, age), alpha = 1 - smooth(.85, 1.15, age)
    const style = `transform:scale(${press.toFixed(3)});opacity:${alpha.toFixed(3)};border-color:rgb(${mix(58, 255, heat) | 0},${mix(66, 158, heat) | 0},${mix(88, 97, heat) | 0});` +
      `box-shadow:inset 0 1px 0 rgba(255,255,255,.07),0 10px 30px rgba(0,0,0,.55),0 0 ${(28 * heat).toFixed(1)}px rgba(255,140,60,${(.75 * heat).toFixed(3)})`
    return labels.map((label) => `<div class="key${label.length > 2 ? ' small' : ''}" style="${style}">${escape(label)}</div>`).join('')
  }).join('<div style="width:22px"></div>')
}
const escape = (text) => text.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' })[c])

// --- captions: confident lines rising out of a molten seam -----------------------------
const POSITIONS = {
  left: 'left:110px;top:380px;width:660px', 'left-low': 'left:110px;top:640px;width:640px',
  bottom: 'left:110px;bottom:170px;width:1400px', 'bottom-low': 'left:110px;bottom:70px;width:1500px',
  top: 'left:110px;top:96px;width:1500px', center: 'left:0;right:0;top:400px',
  stat: 'left:110px;top:258px;width:700px',
}
const SCRIM = { left: 'left', 'left-low': 'left', stat: 'stat', bottom: 'bottom', 'bottom-low': 'bottom', center: 'center', top: 'top' }
function scrims() {
  for (const side of ['left', 'bottom', 'center', 'top', 'stat']) {
    if (!$(`#captions .scrim.${side}`)) {
      const el = document.createElement('div'); el.className = `scrim ${side}`; $('#captions').prepend(el)
    }
  }
}
// Every caption of every scene is evaluated on every frame, so a frame depends
// only on t: fade tails render even after their scene has cut away.
function captions(t) {
  for (const scrim of document.querySelectorAll('#captions .scrim')) scrim.style.opacity = 0
  for (const c of SCENES.flatMap((s) => s.captions)) {
    let el = document.getElementById(`cap-${c.id}`)
    const exitDur = c.quick ? .16 : .3, out = t - c.t1, local = t - c.t0 - (c.delay || 0)
    if (local < 0 || out > exitDur) { if (el) el.style.display = 'none'; continue }
    if (!el) {
      el = document.createElement('div')
      el.id = `cap-${c.id}`
      el.className = `cap ${c.pos === 'center' ? 'center' : ''} ${c.style || ''}`
      el.style.cssText = POSITIONS[c.pos || 'left']
      el.innerHTML = `${c.kicker ? `<div class="kicker">${c.kicker}</div>` : ''}<div class="clip"><div class="big">${c.big}</div></div>` +
        `<div class="seam"></div>${c.small ? `<div class="small">${c.small}</div>` : ''}`
      $('#captions').append(el)
    }
    el.style.display = 'block'
    const exit = easeIn(out / exitDur)
    el.style.opacity = (1 - exit).toFixed(3)
    const side = c.scrim === false ? null : SCRIM[c.pos || 'left']
    if (side) {
      const scrim = $(`#captions .scrim.${side}`), v = easeOut(local / .35) * (1 - exit)
      scrim.style.opacity = Math.max(+scrim.style.opacity || 0, v).toFixed(3)
    }
    el.style.transform = `translateY(${(-16 * exit).toFixed(1)}px)`
    const big = $('.big', el), seamEl = $('.seam', el), small = $('.small', el), kicker = $('.kicker', el)
    // A stat leads with its kicker; the figure itself rises half a beat later, on the beat.
    const lead = kicker ? M.beat / 2 : 0
    if (kicker) {
      const kk = easeOut(local / .35)
      kicker.style.opacity = kk.toFixed(3); kicker.style.transform = `translateX(${((1 - kk) * -24).toFixed(1)}px)`
    }
    const k = viscous((local - lead - .05) / .55), heat = 1 - smooth(lead + .12, lead + 1.2, local)
    big.style.transform = `translateY(${((1 - k) * 105).toFixed(2)}%)`
    if (c.style === 'molten' || c.style === 'stat') big.style.backgroundPosition = `${(-t * 40) % 200}% 0`
    else big.style.color = `rgb(${mix(244, 255, heat) | 0}, ${mix(240, 214, heat) | 0}, ${mix(247, 168, heat) | 0})`
    big.style.textShadow = c.style === 'molten' || c.style === 'stat' ? `0 0 ${18 + 30 * heat}px rgba(255, 130, 50, ${.35 + .4 * heat})` : heat > .01 ? `0 0 ${36 * heat}px rgba(255, 140, 60, ${.6 * heat})` : ''
    seamEl.style.transform = `scaleX(${easeOut((local - lead) / .3).toFixed(4)})`
    seamEl.style.setProperty('--hotspot', `${(15 + 75 * ((local * .45) % 1)).toFixed(1)}%`)
    seamEl.style.opacity = (.45 + .55 * heat).toFixed(3)
    seamEl.style.boxShadow = `0 0 ${(4 + 18 * heat).toFixed(1)}px rgba(255, 140, 60, ${(.25 + .6 * heat).toFixed(3)})`
    if (small) {
      const ks = easeOut((local - lead - .3) / .4)
      small.style.opacity = ks.toFixed(3); small.style.transform = `translateY(${((1 - ks) * 12).toFixed(1)}px)`
    }
  }
}

// --- CLI cameo: the exact one-shot command and its real output --------------------------
function cli(s, t) {
  show('#cli')
  const a = s.at, body = $('#cli .body'), panel = $('#cli .panel')
  const k = viscous((t - s.t0) / .25)
  panel.style.transform = `translateX(${(1 - k) * 60}px)`; panel.style.opacity = k
  const command = CLI?.command || 'omagma mail list --fixtures --account work@example.com --limit 3'
  const typeEnd = (a.out ?? s.t0 + 1) - M.beat * .25
  const n = Math.floor(clamp((t - (a.type ?? s.t0)) / Math.max(.2, typeEnd - (a.type ?? s.t0))) * command.length + 1e-6)
  let html = `<span class="ps">❯</span> ${escape(command.slice(0, n))}`
  if (a.out !== undefined && t >= a.out && CLI) {
    const lines = highlight(CLI.stdout).split('\n').slice(0, s.lines || 18)
    const shown = Math.min(lines.length, Math.floor((t - a.out) / (M.beat / 6)) + 1)
    html += '\n' + lines.slice(0, shown).join('\n')
  }
  body.innerHTML = html
}
function highlight(text) {
  const max = 66
  return text.split('\n').map((line) => {
    const clipped = line.length > max ? line.slice(0, max - 1) + '…' : line
    return escape(clipped).replace(/("(?:[^"\\]|\\.)*")(\s*:)?|(-?\d+(?:\.\d+)?)|([{}[\],])/g, (m, str, colon, num, punct) =>
      str ? (colon ? `<span class="k">${str}</span>${colon}` : `<span class="s">${str}</span>`) : num ? `<span class="n">${num}</span>` : `<span class="p">${punct}</span>`)
  }).join('\n')
}

// --- outro ------------------------------------------------------------------------------
function outro(s, t) {
  show('#outro')
  const a = s.at, el = $('#outro')
  const hit = a.hit !== undefined && t >= a.hit ? Math.exp(-(t - a.hit) * 2.2) : 0
  const canvas = LOGO.flow.draw(t, { amount: 1, glow: clamp(.35 + .5 * hit + .2 * M.level(t), 0, .9) })
  const logo = $('.logo', el), ctx = logo.getContext('2d')
  ctx.clearRect(0, 0, 520, 520); ctx.drawImage(canvas, 0, 0)
  const k = viscous((t - (a.logo ?? s.t0)) / .9)
  Object.assign(logo.style, { opacity: k, transform: `scale(${.92 + .08 * k + .04 * hit})`,
    filter: `drop-shadow(0 0 ${40 + 70 * hit}px rgba(236, 122, 53, ${.3 + .45 * hit}))` })
  rise($('#outro .word'), t, a.word)
  if (a.word !== undefined) {
    const w = t - a.word
    seam(fx, 960 - 320, 582, 960 + 320, 582, { progress: easeOut(w / .45), heat: Math.max(1 - smooth(.3, 2, w), hit), t, width: 3, seed: 4 })
  }
  for (const [selector, cue] of [['.tagline', a.tag], ['.platforms', a.platforms], ['.url', a.url], ['.fine', a.fine ?? a.url]]) {
    const node = $(selector, el), v = cue === undefined ? 0 : easeOut((t - cue) / .5)
    node.style.opacity = v.toFixed(3); node.style.transform = `translateY(${((1 - v) * 14).toFixed(1)}px)`
  }
}

const KINDS = { ember, bar, term, cli, outro }

// The poster: one real tape state, framed like the film, with logo, name and one line.
function poster() {
  const spec = CUT.poster, tape = TAPES[spec?.tape]
  if (!tape) throw new Error(`poster needs captured tape ${spec?.tape}`)
  show('#term'); show('#poster')
  const view = TERM.view, index = tape.frameAt(tape.mark(spec.mark).t)
  view.show(tape, index, { blink: false })
  const ww = view.width + 2 * PAD, wh = view.height + 2 * PAD, win = $('#term .window')
  Object.assign(win.style, { width: `${ww}px`, height: `${wh}px`, clipPath: '' })
  Object.assign($('#term .surface').style, { left: `${PAD}px`, top: `${PAD}px` })
  const r = region(spec.view || { cols: [26, 131], rows: [2, 24] }, tape, index, ww, wh)
  const box = { x: 720, y: 130, w: 1150, h: 820 }, s = Math.min(box.w / r.w, box.h / r.h)
  // Show only the framed panes, as a clean window of their own.
  win.style.clipPath = `inset(${r.y}px ${ww - r.x - r.w}px ${wh - r.y - r.h}px ${r.x}px round 18px)`
  win.style.maskImage = `linear-gradient(to bottom, #000 ${r.y + r.h - 150}px, transparent ${r.y + r.h}px)`
  const cx = r.x + r.w / 2 - (box.x + box.w / 2 - W / 2) / s, cy = r.y + r.h / 2 - (box.y + box.h / 2 - H / 2) / s
  win.style.transform = `translate(${(W / 2 - cx * s).toFixed(2)}px, ${(H / 2 - cy * s).toFixed(2)}px) scale(${s.toFixed(5)})`
  pulses({ pulses: [{ t: 0, dur: 1, pane: 'focused' }] }, .5, tape, index)
  $('#term .pointer').style.display = 'none'
  const memory = $('#poster .memory'), m = spec.memory
  memory.style.display = m ? 'block' : 'none'
  if (m) {
    $('.line', memory).innerHTML = `${m.kicker} <span>${m.big}</span>`
    $('.small', memory).textContent = m.small
  }
  const ctx = $('#poster .logo').getContext('2d')
  ctx.clearRect(0, 0, 520, 520); ctx.drawImage(LOGO.flow.draw(2.4, { amount: 1, glow: .55 }), 0, 0)
  $('#bg .heat').style.opacity = .34
}

window.render = async function (t) {
  pending.length = 0
  for (const layer of document.querySelectorAll('.layer')) layer.classList.remove('on')
  fx.clearRect(0, 0, W, H)
  $('#keys').innerHTML = ''
  $('#tag').style.opacity = 0
  if (params.has('poster')) {
    for (const cap of document.querySelectorAll('.cap')) cap.style.display = 'none'
    poster()
    return
  }
  const current = SCENES.findLast((s) => t >= s.t0) || SCENES[0]
  background(t, current)
  for (const s of SCENES) {
    const pre = s.pre ?? 0, post = s.post ?? 0
    if (t >= s.t0 - pre && t < s.t1 + post) KINDS[s.kind](s, t)
  }
  captions(t)
  const fade = M.landmarks.fade !== undefined ? smooth(M.landmark('fade'), M.duration, t) : 0
  $('#fade').style.opacity = fade.toFixed(3)
  await Promise.all(pending)
}

function scrubber() {
  const bar = $('#scrub'), input = $('input', bar), out = $('output', bar)
  bar.hidden = false
  input.max = M.duration
  input.oninput = () => { out.textContent = (+input.value).toFixed(2) + ' s'; window.render(+input.value) }
}

window.READY = init().catch((error) => { console.error(error); throw error })
