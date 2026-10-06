// Renders the film page frame by frame with headless Chromium.
//
//   node video/render.mjs --cut video/tracks/<song>.json --strict    all frames -> video/cache/frames/<song>/
//   node video/render.mjs --cut … --sheet --scale .5                  start/middle/end stills of every scene
//   node video/render.mjs --cut … --stills 3.2,14,41.5 --out DIR      chosen moments as PNG (checks)
//   node video/render.mjs --cut … --poster --strict                    the poster composition (cut map "poster")
//   node video/render.mjs --cut … --from 20 --to 30 --scale .5        a cheap partial draft
//   node video/render.mjs --cut … --preview                           serve ?scrub=1 for review in a browser
//
// No npm dependencies: a loopback-only static server for video/ and assets/,
// and the Chrome DevTools protocol over --remote-debugging-pipe with a
// throwaway profile. Every frame is window.render(i / fps), awaited, then
// captured. Workers render interleaved frames in separate pages. --strict
// (used by final builds) refuses missing captures instead of drawing labelled
// draft stand-ins. Outputs live under video/cache/ or video/out/, and a
// directory is only replaced if this tool created it (marker file).
import { spawn } from 'node:child_process'
import { createServer } from 'node:http'
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync, existsSync, statSync } from 'node:fs'
import { tmpdir, availableParallelism } from 'node:os'
import { join, extname, resolve, relative, basename } from 'node:path'
import { parseArgs } from 'node:util'

const here = new URL('.', import.meta.url).pathname
const repo = resolve(here, '..')
const { values: opt } = parseArgs({ options: {
  cut: { type: 'string' }, out: { type: 'string' }, fps: { type: 'string' }, from: { type: 'string' }, to: { type: 'string' },
  step: { type: 'string', default: '1' }, scale: { type: 'string', default: '1' }, format: { type: 'string', default: 'jpeg' },
  quality: { type: 'string', default: '95' }, workers: { type: 'string' }, stills: { type: 'string' }, preview: { type: 'boolean' },
  chromium: { type: 'string', default: process.env.CHROMIUM || '/usr/bin/chromium' }, logo: { type: 'string' }, capture: { type: 'string' },
  label: { type: 'string' }, sheet: { type: 'boolean' }, strict: { type: 'boolean' }, poster: { type: 'boolean' },
} })
const usage = (message) => { console.error(`render: ${message}`); process.exit(2) }
if (!opt.cut) usage('usage: node video/render.mjs --cut video/tracks/<name>.json [options]')
const integer = (name, value, min, max) => {
  const n = Number(value)
  if (!Number.isInteger(n) || n < min || n > max) usage(`--${name} must be an integer from ${min} to ${max}`)
  return n
}
const number = (name, value, min, max) => {
  const n = Number(value)
  if (!Number.isFinite(n) || n < min || n > max) usage(`--${name} must be a number from ${min} to ${max}`)
  return n
}
const STEP = integer('step', opt.step, 1, 1000)
const SCALE = number('scale', opt.scale, .1, 2)
const QUALITY = integer('quality', opt.quality, 1, 100)
const FPS_ARG = opt.fps === undefined ? null : integer('fps', opt.fps, 1, 120)
const WORKERS = opt.workers === undefined ? null : integer('workers', opt.workers, 1, 32)
const FROM = opt.from === undefined ? 0 : number('from', opt.from, 0, 36000)
const TO = opt.to === undefined ? null : number('to', opt.to, 0, 36000)
if (TO !== null && TO <= FROM) usage('--to must be after --from')
if (!['jpeg', 'png'].includes(opt.format)) usage('--format must be jpeg or png')
const STILLS = opt.stills === undefined ? null : opt.stills.split(',').map((v) => number('stills', v, 0, 36000))
const cutPath = resolve(opt.cut)
const name = basename(cutPath, '.json')

// Output directories: inside video/cache or video/out, and replaced only when owned.
const MARKER = '.omagma-render-output'
function ownedDir(path, replace) {
  const dir = resolve(path)
  const scope = [join(here, 'cache'), join(here, 'out')]
  if (!scope.some((root) => dir.startsWith(root + '/'))) usage(`output ${dir} must be inside video/cache/ or video/out/`)
  if (existsSync(dir)) {
    if (!statSync(dir).isDirectory()) usage(`output ${dir} is not a directory`)
    const owned = existsSync(join(dir, MARKER)) || readdirSync(dir).length === 0
    if (!owned) usage(`output ${dir} exists and was not created by render.mjs; choose another --out`)
    if (replace) rmSync(dir, { recursive: true, force: true })
  }
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, MARKER), 'render.mjs output\n')
  return dir
}

// --- loopback static server, limited to the film's own files ----------------------
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml' }
const ALLOWED = ['video/web/', 'video/tracks/', 'video/cache/capture/', 'video/cache/logo-master.png', 'assets/omagma-logo.png']
const server = createServer((req, res) => {
  const path = decodeURIComponent(new URL(req.url, 'http://x').pathname).replace(/^\/+/, '')
  const file = resolve(repo, path)
  const rel = relative(repo, file)
  if (rel.startsWith('..') || !ALLOWED.some((prefix) => rel === prefix || rel.startsWith(prefix)) || !existsSync(file) || !statSync(file).isFile()) {
    res.writeHead(404); res.end(); return
  }
  res.writeHead(200, { 'content-type': TYPES[extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' })
  res.end(readFileSync(file))
})
await new Promise((ok) => server.listen(0, '127.0.0.1', ok))
const origin = `http://127.0.0.1:${server.address().port}`
const query = new URLSearchParams({ cut: '/' + relative(repo, cutPath) })
if (opt.logo) query.set('logo', opt.logo)
if (opt.capture) query.set('capture', opt.capture)
if (opt.label) query.set('label', opt.label)
if (opt.strict) query.set('strict', '1')
if (opt.poster) query.set('poster', '1')
const pageUrl = `${origin}/video/web/timeline.html?${query}`

if (opt.preview) {
  console.log(`preview: ${pageUrl}&scrub=1  (loopback only; Ctrl+C stops the server)`)
  await new Promise(() => {})
}

// --- Chromium over the DevTools pipe ------------------------------------------------
const profile = mkdtempSync(join(tmpdir(), 'omagma-film-chromium-'))
const chrome = spawn(opt.chromium, ['--headless', '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-first-run',
  '--no-default-browser-check', '--disable-extensions', '--disable-background-networking', '--disable-sync', '--mute-audio',
  '--hide-scrollbars', '--font-render-hinting=none', '--force-color-profile=srgb', '--disable-renderer-backgrounding',
  '--disable-background-timer-throttling', '--disable-backgrounding-occluded-windows', 'about:blank'],
{ stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'] })
let chromeLog = '', chromeGone = null
chrome.stderr.on('data', (d) => { chromeLog = (chromeLog + d).slice(-4000) })
const waiting = new Map(), listeners = []
const abandon = (reason) => {
  chromeGone = reason
  for (const { fail } of waiting.values()) fail(new Error(reason))
  waiting.clear()
}
chrome.on('error', (error) => abandon(`chromium failed to start: ${error.message}`))
chrome.on('exit', (code, signal) => abandon(`chromium exited (${signal || code})`))
chrome.stdio[3].on('error', () => abandon('chromium closed its command pipe'))
const cleanup = () => {
  try { chrome.kill('SIGTERM') } catch { /* already gone */ }
  server.close()
  rmSync(profile, { recursive: true, force: true })
}
process.on('SIGINT', () => { cleanup(); process.exit(130) })
process.on('SIGTERM', () => { cleanup(); process.exit(143) })

let nextId = 1, buffer = ''
chrome.stdio[4].setEncoding('utf8')
chrome.stdio[4].on('data', (chunk) => {
  buffer += chunk
  let end
  while ((end = buffer.indexOf('\0')) >= 0) {
    const message = JSON.parse(buffer.slice(0, end))
    buffer = buffer.slice(end + 1)
    if (message.id && waiting.has(message.id)) {
      const { ok, fail } = waiting.get(message.id)
      waiting.delete(message.id)
      message.error ? fail(new Error(`${message.error.message} ${message.error.data || ''}`)) : ok(message.result)
    } else for (const listener of listeners) listener(message)
  }
})
// Every command rejects if Chromium exits, errors or does not answer in time.
function send(method, params = {}, sessionId, timeout = 90000) {
  if (chromeGone) return Promise.reject(new Error(chromeGone))
  const id = nextId++
  return new Promise((ok, fail) => {
    const timer = setTimeout(() => { waiting.delete(id); fail(new Error(`${method} timed out after ${timeout / 1000} s`)) }, timeout)
    waiting.set(id, { ok: (v) => { clearTimeout(timer); ok(v) }, fail: (e) => { clearTimeout(timer); fail(e) } })
    chrome.stdio[3].write(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }) + '\0')
  })
}
function once(sessionId, method, timeout = 60000) {
  return new Promise((ok, fail) => {
    const timer = setTimeout(() => { remove(); fail(new Error(`${method} not received within ${timeout / 1000} s`)) }, timeout)
    const remove = () => { const i = listeners.indexOf(listener); if (i >= 0) listeners.splice(i, 1) }
    const listener = (m) => { if (m.sessionId === sessionId && m.method === method) { clearTimeout(timer); remove(); ok(m.params) } }
    listeners.push(listener)
  })
}

async function openPage(scale) {
  // Each worker gets its own window: a background tab in a shared headless window never paints.
  const { targetId } = await send('Target.createTarget', { url: 'about:blank', newWindow: true })
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true })
  const call = (method, params, timeout) => send(method, params, sessionId, timeout)
  const errors = []
  listeners.push((m) => {
    if (m.sessionId !== sessionId) return
    if (m.method === 'Runtime.exceptionThrown') errors.push(m.params.exceptionDetails?.exception?.description || m.params.exceptionDetails?.text)
    if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error') errors.push(m.params.args.map((a) => a.value ?? a.description).join(' '))
  })
  await call('Page.enable'); await call('Runtime.enable')
  await call('Emulation.setDeviceMetricsOverride', { width: 1920, height: 1080, deviceScaleFactor: scale, mobile: false })
  const loaded = once(sessionId, 'Page.loadEventFired')
  await call('Page.navigate', { url: pageUrl })
  await loaded
  const ready = await call('Runtime.evaluate', { expression: 'window.READY', awaitPromise: true, returnByValue: true }, 180000)
  if (ready.exceptionDetails) throw new Error(`page failed to initialise: ${errors.join('\n') || ready.exceptionDetails.exception?.description || ready.exceptionDetails.text}`)
  return { call, info: ready.result.value, errors }
}

async function frame(page, t, path, format) {
  const result = await page.call('Runtime.evaluate', { expression: `window.render(${t})`, awaitPromise: true })
  if (result.exceptionDetails) throw new Error(`render(${t}) failed: ${page.errors.join('\n') || result.exceptionDetails.exception?.description || result.exceptionDetails.text}`)
  const shot = await page.call('Page.captureScreenshot', { format, ...(format === 'jpeg' ? { quality: QUALITY } : {}), optimizeForSpeed: true })
  writeFileSync(path, Buffer.from(shot.data, 'base64'))
}

try {
  const first = await openPage(SCALE)
  const info = first.info, fps = FPS_ARG ?? info.fps ?? 30
  const missing = info.missing.tapes.length || info.missing.bar || info.missing.cli
  if (missing && opt.strict) throw new Error(`missing captures: ${JSON.stringify(info.missing)} (run video/build.sh capture)`)
  if (missing) console.log('render: DRAFT stand-ins for missing captures:', JSON.stringify(info.missing))
  const resolved = (await first.call('Runtime.evaluate', { expression: 'window.RESOLVED', returnByValue: true })).result.value
  mkdirSync(join(here, 'out'), { recursive: true })
  writeFileSync(join(here, 'out', `${name}.cuts.json`), JSON.stringify(resolved, null, 1) + '\n')
  let jobs
  if (opt.poster) {
    const out = ownedDir(opt.out || join(here, 'cache', 'poster', name), true)
    jobs = [{ t: 0, path: join(out, 'poster.png'), format: 'png' }]
  } else if (opt.sheet) {
    const out = ownedDir(opt.out || join(here, 'cache', 'sheet', name), true)
    jobs = resolved.scenes.flatMap((scene, n) => [scene.start + .12, (scene.start + scene.end) / 2, scene.end - .12]
      .map((t, k) => ({ t, format: 'png', path: join(out, `${String(n).padStart(2, '0')}${'abc'[k]}-${scene.id}-${t.toFixed(2)}s.png`) })))
  } else if (STILLS) {
    const out = ownedDir(opt.out || join(here, 'cache', 'stills', name), false)
    jobs = STILLS.map((t) => ({ t, path: join(out, `t${t.toFixed(2).padStart(6, '0')}.png`), format: 'png' }))
  } else {
    const out = ownedDir(opt.out || join(here, 'cache', 'frames', name), true)
    const total = Math.round(info.duration * fps)
    const from = Math.round(FROM * fps), to = Math.min(total, TO === null ? total : Math.round(TO * fps))
    jobs = []
    for (let i = from, n = 0; i < to; i += STEP, n++) {
      jobs.push({ t: i / fps, path: join(out, `${String(n).padStart(5, '0')}.${opt.format === 'png' ? 'png' : 'jpg'}`), format: opt.format })
    }
    writeFileSync(join(out, 'frames.json'), JSON.stringify({ cut: relative(repo, cutPath), fps: fps / STEP, from: from / fps, count: jobs.length, scale: SCALE, strict: !!opt.strict }) + '\n')
  }
  if (!jobs.length) throw new Error('nothing to render')
  const workers = Math.min(jobs.length, WORKERS ?? Math.min(6, Math.max(1, availableParallelism() >> 2)))
  const pages = [first, ...(await Promise.all(Array.from({ length: workers - 1 }, () => openPage(SCALE))))]
  const started = Date.now()
  let done = 0
  await Promise.all(pages.map(async (page, w) => {
    for (let j = w; j < jobs.length; j += workers) {
      await frame(page, jobs[j].t, jobs[j].path, jobs[j].format)
      if (++done % (STILLS || opt.sheet ? 10 : 150) === 0) console.log(`render: ${done}/${jobs.length} (${((Date.now() - started) / 1000).toFixed(0)} s)`)
    }
  }))
  const errors = pages.flatMap((p) => p.errors)
  if (errors.length) throw new Error(`page errors:\n${[...new Set(errors)].join('\n')}`)
  console.log(`render: ${jobs.length} ${STILLS || opt.sheet || opt.poster ? 'stills' : 'frames'} with ${workers} workers in ${((Date.now() - started) / 1000).toFixed(1)} s`)
} catch (error) {
  console.error(`render: ${error.message}`, chromeLog ? `\nchromium: ${chromeLog.slice(-800)}` : '')
  process.exitCode = 1
} finally {
  if (!chromeGone) {
    const exited = new Promise((ok) => chrome.once('exit', ok))
    await Promise.race([send('Browser.close', {}, undefined, 3000).catch(() => {}), new Promise((ok) => setTimeout(ok, 3000))])
    await Promise.race([exited, new Promise((ok) => setTimeout(ok, 3000))])
  }
  cleanup()
}
