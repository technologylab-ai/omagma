'use strict';
// Heavy Lifting — What's new in Omagma v0.2.18. Deterministic picture source:
// render(t) depends only on t. All UI pixels are actual captures from the manifest.
// Choreography: every beat announces first (text only, no UI), gives ~1.9 s to read,
// then demonstrates with its narration held fixed.
(() => {
// Clock of the approved v0.2.7 soundtrack (2527 frames), packet-copied unchanged.
const FPS = 30, FRAMES = 2527, W = 1920, H = 1080;
window.FILM = {duration: FRAMES / FPS, fps: FPS, width: W, height: H};
const REVISION = new URLSearchParams(location.search).get('revision') || 'revision-27';
const BASE = '/video/cache/short0218/' + REVISION + '/';
const LOGO = '/video/assets/omagma-logo-master.png';

const $ = id => document.getElementById(id);
const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
const lerp = (a, b, p) => a + (b - a) * p;
const ramp = (f, a, b) => b <= a ? (f >= a ? 1 : 0) : clamp((f - a) / (b - a));
const easeOut = p => 1 - Math.pow(1 - p, 3);
const easeIn = p => p * p * p;
const easeIO = p => p < .5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2;
const hash = n => { const x = Math.sin(n * 127.1 + 311.7) * 43758.5453; return x - Math.floor(x); };
const esc = s => String(s).replace(/[&<>"]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'})[c]);

// Decorative glow pulses on the soundtrack's bars. The original song runs to 70.476 s
// (measured phrase downbeats to 44.13 s; 52.91/61.69 continue the same 8.8 s phrase
// grid), then the closing-phrase attack at 70.476 s, last phrase 78.965 s, stop 81.393 s.
const PHRASES = [8.928, 17.752, 26.552, 35.352, 44.13, 52.91, 61.69, 70.476];
const DOWNBEATS = [0.104, 2.31, 4.516, 6.722];
for (let i = 0; i < PHRASES.length - 1; i++) {
  for (let b = 0; b < 4; b++) DOWNBEATS.push(PHRASES[i] + b * (PHRASES[i + 1] - PHRASES[i]) / 4);
}
DOWNBEATS.push(70.476, 72.615, 74.754, 76.893, 78.965, 81.104, 83.243);
const DROP = 2114, LAST_PHRASE = 2369, STOP = 2442;

const BOXES = {default: [120, 284, 1680, 760], meet: [120, 300, 1680, 744]};
const K_MAX = 1.0;          // never magnify DPR2 captures beyond 1 image px per CSS px
const BAR = 52;             // decorative browser chrome height
const MATTE = 14;           // editorial matte around native captures: rounded corners never touch UI pixels
const CELL_FONT = 0.6;      // JetBrains Mono advance / em
const CLOSE = 10;           // frames for a demo frame to fold back into its seam
const BEAD_X = 30;          // ember rests this far left of the frame edge, outside all UI pixels

// Cell ROI fallbacks bound to the verified rev-06 capture geometry. Used only when
// the asset grid matches; named manifest ROIs always win.
const CELLS = [
  {prefix: 'clipboard', grid: [132, 36], rois: {body: [0, 8.6, 79, 13.8], cursor: [0.6, 9.9, 50, 3.2], marker: [0.6, 13.9, 77.6, 2.2]}},
  {prefix: 'booking.review', grid: [132, 36], rois: {modal: [19, 8.5, 94, 18.5], add: [24.6, 22.9, 20, 1.2]}},
  {prefix: 'calendar.now', grid: [132, 32], rois: {hero: [0, 6, 60, 22], nowRow: [0, 22, 23.6, 1]}},
  {prefix: 'meet', grid: [132, 36], rois: {form: [21, 6.6, 62, 21], checkbox: [23.6, 18.9, 36.4, 1.2]}, click: [25, 19.5]},
  {prefix: 'drive.complete', grid: [132, 36], rois: {result: [0, 29, 72, 7], status: [0, 34.9, 23, 1.2]}},
  // Actual Sent reader (100×24): border/title row 2 → subject, From, To/Cc, Labels: SENT,
  // body, 'Files shared via Google Drive', file + URL → bottom border row 21.
  {prefix: 'drive.sent', grid: [100, 24], rois: {reader: [55, 2, 45, 20], link: [56.6, 16.9, 42.6, 4.05]}}
];

// ---------------------------------------------------------------- timeline
// Feature beat: in = announceStart → textSettled (in+24) → demo (demoStart) →
// demoEnd (frame folds away, CLOSE frames) → out. Narration is one fixed headline +
// one fixed line for the whole beat; only action keycaps appear during a demo.
const SCENES = [
  {id: 'intro', kind: 'intro', in: 0, out: 135},
  {id: 'paste', kind: 'feature', in: 135, demo: 216, demoEnd: 512, out: 522,
    band: {kicker: '01 · COMPOSE', head: 'Paste images straight into your mail.', hl: ['images'],
      sub: 'Ctrl+V drops the image right where your cursor is.'},
    shots: [
      {id: 'paste-native', from: 216, to: 362, box: 'default', states: [
        {at: 216, asset: 'clipboard.before', cam: 'body', spot: ['cursor', 230, 268]},
        {at: 269, series: 'clipboard.typing', until: 302, cam: 'body', optional: true},
        {at: 302, asset: 'clipboard.after', cam: 'body', spot: ['marker', 306, 360]}]},
      {id: 'paste-browser', from: 362, to: 512, box: 'default', browser: true, push: [1, 1.035], states: [
        {at: 362, asset: 'browser.inline', cam: 'focus', bead: ['image', 380, 506]}]}],
    keys: [{keys: ['Ctrl', 'V'], label: 'Paste image', cue: 248, press: 268}]},
  {id: 'booking', kind: 'feature', in: 522, demo: 603, demoEnd: 821, out: 831,
    band: {kicker: '02 · MAIL → CALENDAR', head: 'Booked a haircut? Add it to your calendar.', hl: ['calendar.'],
      sub: 'Press A on the booking email. It becomes your own appointment.'},
    shots: [
      {id: 'booking-native', from: 603, to: 821, box: 'default', states: [
        {at: 603, asset: 'booking.mail', cam: 'reader', spot: ['card', 620, 661]},
        {at: 661, asset: 'booking.review', cam: 'modal', spot: ['add', 676, 741]},
        {at: 741, asset: 'booking.complete', cam: 'result', spot: ['status', 748, 815]}]}],
    keys: [{keys: ['A'], label: 'Add to calendar', cue: 641, press: 661},
      {keys: ['y'], label: 'Add appointment', cue: 721, press: 741}]},
  {id: 'now', kind: 'feature', in: 831, demo: 912, demoEnd: 1012, out: 1022,
    band: {kicker: '03 · CALENDAR', head: 'Your week marks exactly where now is.', hl: ['now'],
      sub: 'A red line across today, between what’s done and what’s next.'},
    shots: [
      // Genuine live week view whose now row is empty in today's column (no overlapping event).
      {id: 'now-week', from: 912, to: 1012, box: 'default', states: [
        {at: 912, asset: 'calendar.clear', cam: 'hero', spot: ['nowRow', 928, 1006]}]}]},
  {id: 'meet', kind: 'feature', in: 1022, demo: 1103, demoEnd: 1396, out: 1406,
    band: {kicker: '04 · CALENDAR', head: 'New meeting? Switch on Meet AI notes.', hl: ['AI', 'notes.'],
      sub: 'Tick one box on a new event with a Meet link. Google confirms it.',
      foot: 'Eligible Google Workspace plans'},
    shots: [
      {id: 'meet-native', from: 1103, to: 1396, box: 'meet', states: [
        {at: 1103, asset: 'meet.unchecked', cam: 'form', spot: ['checkbox', 1124, 1232], noBead: true},
        {at: 1172, asset: 'meet.checked', cam: 'form'},
        {at: 1232, asset: 'meet.review', cam: 'review', spot: ['confirm', 1248, 1312]},
        {at: 1312, asset: 'meet.complete', cam: 'result', spot: ['result', 1320, 1390]}]}],
    pointer: {asset: 'meet.unchecked', appear: 1124, move: [1130, 1158], press: 1170, hide: [1194, 1204]},
    keys: [{keys: ['Ctrl', 'S'], label: 'Review', cue: 1212, press: 1232},
      {keys: ['y'], label: 'Create event', cue: 1292, press: 1312}]},
  {id: 'drive', kind: 'feature', in: 1406, demo: 1487, demoEnd: 1760, out: 1770,
    band: {kicker: '05 · BIG FILES', head: 'Too big to attach? Send it via Drive.', hl: ['Drive.'],
      sub: 'Choose Drive for the file. Only your To and Cc can view it.'},
    shots: [
      {id: 'drive-native', from: 1487, to: 1760, box: 'default', states: [
        {at: 1487, asset: 'drive.choice', cam: 'modal', spot: ['options', 1504, 1551]},
        {at: 1551, asset: 'drive.selected', cam: 'attachments', spot: ['drive', 1562, 1617]},
        {at: 1617, asset: 'drive.review', cam: 'top'},
        {at: 1650, asset: 'drive.access', cam: 'access', camDur: 21, spot: ['access', 1675, 1754]}]}],
    keys: [{keys: ['d'], label: 'Drive', cue: 1531, press: 1551},
      {keys: ['Ctrl', 'S'], label: 'Review', cue: 1597, press: 1617}]},
  // The send demo keeps its fixed narration through the actual result: the sent mail in
  // Sent lands on the closing-phrase attack (2114) and holds 2.53 s, then folds straight
  // into the recap rows (no empty UI, no empty stage).
  {id: 'send', kind: 'feature', in: 1770, demo: 1851, demoEnd: 2190, out: 2200,
    band: {kicker: '05 · BIG FILES', head: 'Nothing uploads until you send.', hl: ['send.'],
      sub: 'Undo during the countdown, or send right away.'},
    shots: [
      {id: 'drive-send', from: 1851, to: 2114, box: 'default', states: [
        {at: 1851, asset: 'drive.access', cam: 'access', spot: ['access', 1868, 1918]},
        {at: 1918, series: 'drive.countdown', until: 1984, min: 2, cam: 'countdown', spot: ['countdown', 1924, 1984]},
        {at: 1984, series: 'drive.progress', samples: [1984, 2006, 2028, 2049, 2071, 2093], min: 2, cam: 'progress'}]},
      {id: 'drive-sent', from: 2114, to: 2190, box: 'default', open: 'cut', run: true, states: [
        {at: 2114, asset: 'drive.sent', cam: 'reader', spot: ['link', 2132, 2184]}]}],
    keys: [{keys: ['y'], label: 'Send', cue: 1898, press: 1918},
      {keys: ['Ctrl', 'S'], label: 'Send now', cue: 1964, press: 1984}]},
  {id: 'recap', kind: 'text', in: 2200, out: 2392,
    rows: [[2212, 'Link lists show each link’s title above its full address'],
      [2228, 'Calendar guests suggested from people you mail'],
      [2244, 'Move an event’s start, and its end follows'],
      [2260, 'Scroll the send review with your mouse wheel']]},
  {id: 'outro', kind: 'outro', in: 2392, out: 2527}
];
const POSTER_TIME = 56.7;

const settledOf = sc => sc.band ? sc.in + 24 : null;
// Narration stays fully opaque through demoEnd and leaves while its UI folds away;
// a text-only beat fades in its last 8 frames.
const exitStartOf = sc => sc.demoEnd != null ? sc.demoEnd : sc.out - 8;
function phaseOf(sc, f) {
  if (!sc.band) return sc.kind;
  if (f < settledOf(sc)) return 'announce';
  if (sc.demo == null) return f < exitStartOf(sc) ? 'hold' : 'exit';
  if (f < sc.demo) return 'read';
  if (f < sc.demoEnd) return 'demo';
  return 'exit';
}

// ---------------------------------------------------------------- state built by READY
const M = {entries: {}, images: {}, shots: [], warnings: [], fallbacks: new Set()};
const EL = {};

function entryOf(key) {
  const e = M.entries[key];
  if (!e) throw Error('missing required asset: ' + key);
  return e;
}
function gridOf(e) {
  return [Number(e.columns) || 0, Number(e.rows) || 0];
}
function cellsFallback(key, name) {
  const spec = CELLS.find(c => key === c.prefix || key.startsWith(c.prefix + '.'));
  if (!spec) return null;
  const e = entryOf(key), [c, r] = gridOf(e);
  if (c !== spec.grid[0] || r !== spec.grid[1]) return null;
  const cells = name === 'click' ? spec.click : spec.rois[name];
  if (!cells) return null;
  return name === 'click' ? [cells[0] / c, cells[1] / r] : [cells[0] / c, cells[1] / r, cells[2] / c, cells[3] / r];
}
// Normalized ROI [x,y,w,h] for an asset: named → cell fallback → focus → full.
function roiOf(key, name) {
  const e = entryOf(key), rois = e.rois || {};
  const norm = v => Array.isArray(v) && v.length === 4 && v.every(Number.isFinite) && v[2] > 0 && v[3] > 0;
  if (norm(rois[name])) return rois[name];
  const cells = cellsFallback(key, name);
  const note = tier => { const id = key + ':' + name + '→' + tier; if (!M.fallbacks.has(id)) M.fallbacks.add(id); };
  if (cells) { note('cells'); return cells; }
  if (norm(rois.focus)) { note('focus'); return rois.focus; }
  note('full');
  return norm(rois.full) ? rois.full : [0, 0, 1, 1];
}
// Engineering binding: Opus distinguishes a contextual camera from a tight
// spotlight even when the authored names are identical.
function cameraRoiOf(key, name) {
  const r = entryOf(key).cameraRois?.[name];
  if (Array.isArray(r) && r.length === 4 && r.every(Number.isFinite) && r[2] > 0 && r[3] > 0) return r;
  return roiOf(key, name);
}
function clickOf(key) {
  const e = entryOf(key);
  const pick = [e.targets && e.targets.click, e.click, e.rois && e.rois.click].find(v => Array.isArray(v) && v.length >= 2);
  if (pick) return pick.length === 4 ? [pick[0] + pick[2] / 2, pick[1] + pick[3] / 2] : pick;
  const cells = cellsFallback(key, 'click');
  if (cells) { M.fallbacks.add(key + ':click→cells'); return cells; }
  throw Error('missing recorded click target for ' + key);
}
function seriesKeys(prefix) {
  const re = new RegExp('^' + prefix.replace(/\./g, '\\.') + '(\\d*)$');
  const seen = new Set();
  return Object.keys(M.entries).filter(k => re.test(k))
    .sort((a, b) => (Number(re.exec(a)[1]) || 0) - (Number(re.exec(b)[1]) || 0))
    .filter(k => { // A reference alias must not count as another genuine tick.
      const e = entryOf(k), id = e.tape && Number.isInteger(e.frame) ? e.tape + ':' + e.frame : e.sha256 || k;
      if (seen.has(id)) return false; seen.add(id); return true;
    });
}

// Expand series states into concrete timed states; drop an empty optional series.
function expandStates(shot) {
  const out = [];
  shot.states.forEach((s, i) => {
    if (!s.series) { out.push({...s}); return; }
    const keys = seriesKeys(s.series);
    if (!keys.length && s.optional) {
      const next = shot.states[i + 1];
      if (next) next.at = s.at;
      return;
    }
    if (keys.length < (s.min || 1)) throw Error(`missing required asset series ${s.series}* (need ≥${s.min || 1}, found ${keys.length})`);
    let picked = keys, at;
    if (s.samples) {
      const n = s.samples.length;
      if (keys.length >= n) {
        // Evenly chosen genuine frames, always including the first and the last.
        picked = s.samples.map((_, j) => keys[Math.round(j * (keys.length - 1) / (n - 1))]);
        at = s.samples.slice();
      } else {
        const span = s.samples[n - 1] - s.samples[0] + (s.samples[n - 1] - s.samples[n - 2]);
        at = keys.map((_, j) => s.samples[0] + Math.round(j * span / keys.length));
      }
    } else {
      at = keys.map((_, j) => Math.round(s.at + j * (s.until - s.at) / keys.length));
    }
    picked.forEach((k, j) => {
      out.push({at: at[j], asset: k, cam: s.cam, spot: j === 0 ? s.spot : null, series: s.series});
    });
  });
  return out;
}

// ---------------------------------------------------------------- READY
async function fontsReady() {
  await Promise.all(['800 76px "Adwaita Sans"', '600 34px "Adwaita Sans"', '700 24px "JetBrainsMono Nerd Font"',
    '400 32px "Noto Color Emoji"'].map(f => document.fonts.load(f).catch(() => null)));
  await document.fonts.ready;
  const ctx = document.createElement('canvas').getContext('2d');
  const width = font => { ctx.font = font; return ctx.measureText('Heavy Lifting · Omagma 0123456789 WWWiii mmm').width; };
  for (const family of ['Adwaita Sans', 'JetBrainsMono Nerd Font']) {
    if (Math.abs(width(`800 200px "${family}"`) - width('800 200px serif')) < 0.5) throw Error('font missing: ' + family);
  }
}

async function loadManifest() {
  const res = await fetch(BASE + 'assets-manifest.json', {cache: 'no-store'});
  if (!res.ok) throw Error('missing capture manifest ' + BASE + 'assets-manifest.json');
  const man = await res.json();
  if (Array.isArray(man.errors) && man.errors.length) throw Error('native source errors: ' + JSON.stringify(man.errors).slice(0, 400));
  const assets = man.assets && typeof man.assets === 'object' ? man.assets : man;
  for (const [key, e] of Object.entries(assets)) {
    if (!e || typeof e !== 'object' || !e.file) continue;
    if (e.error || e.ok === false) throw Error('native source error in ' + key + ': ' + (e.error || 'not ok'));
    M.entries[key] = e;
  }
  M.manifest = man;
}

// film-plan.json must mirror the beat clock exactly; any drift rejects READY.
async function checkPlan() {
  const res = await fetch('film-plan.json', {cache: 'no-store'});
  if (!res.ok) throw Error('missing film-plan.json');
  const plan = await res.json();
  if (plan.format.frames !== FRAMES || plan.posterTime !== POSTER_TIME) throw Error('film-plan.json format/poster mismatch');
  for (const sc of SCENES) {
    const p = (plan.beats || []).find(s => s.id === sc.id);
    if (!p || p.in !== sc.in || p.out !== sc.out) throw Error('film-plan.json beat mismatch: ' + sc.id);
    if (sc.band && (p.announceStart !== sc.in || p.textSettled !== settledOf(sc) ||
        (p.demoStart ?? null) !== (sc.demo ?? null) || (p.demoEnd ?? null) !== (sc.demoEnd ?? null))) {
      throw Error('film-plan.json phase mismatch: ' + sc.id);
    }
    if (sc.band && (p.narration.headline !== sc.band.head || p.narration.sub !== sc.band.sub)) throw Error('film-plan.json narration mismatch: ' + sc.id);
    const a = (sc.keys || []).map(k => k.cue + ':' + k.press).join(), b = (p.keys || []).map(k => k.cue + ':' + k.press).join();
    if (a !== b) throw Error('film-plan.json key timing mismatch: ' + sc.id);
  }
}

function loadImage(src, e, key) {
  const img = new Image();
  img.className = 'shot';
  img.alt = '';
  img.decoding = 'sync';
  img.src = src;
  return img.decode().then(() => {
    if ((e.width && img.naturalWidth !== e.width) || (e.height && img.naturalHeight !== e.height)) {
      throw Error(`native image size mismatch for ${key}: ${img.naturalWidth}×${img.naturalHeight}`);
    }
    return img;
  }, () => { throw Error('missing required asset image: ' + key + ' (' + src + ')'); });
}
const assetSrc = e => e.file.startsWith('/') ? e.file : BASE + e.file.replace(/^\.\//, '');

async function buildShots() {
  const host = $('frames');
  for (const sc of SCENES) for (const shot of sc.shots || []) {
    const states = expandStates(shot);
    const el = document.createElement('div');
    el.className = 'frame' + (shot.browser ? ' browser' : '');
    el.innerHTML = '<div class="halo"></div><div class="clip"><div class="win"></div><div class="spot"></div>' +
      (shot.browser ? `<div class="bbar"><div class="dots"><i></i><i></i><i></i></div><div class="tab"><img src="${LOGO}" alt=""><span></span></div></div>` : '') +
      '</div><div class="edge"></div>' +
      '<svg class="run"><rect class="glow" fill="none" stroke="rgba(236,122,53,.55)" stroke-width="12" pathLength="1"/>' +
      '<rect class="core" fill="none" stroke="#ffe6c4" stroke-width="4" stroke-linecap="round" pathLength="1"/></svg>';
    const clip = el.querySelector('.clip'), win = el.querySelector('.win');
    const img = {};
    for (const s of states) {
      if (img[s.asset]) continue;
      const e = entryOf(s.asset);
      img[s.asset] = await loadImage(assetSrc(e), e, s.asset);
      win.appendChild(img[s.asset]);
    }
    if (shot.browser) {
      const e = entryOf(states[0].asset);
      el.querySelector('.bbar .tab span').textContent = e.title || (M.manifest.browser && M.manifest.browser.title) || 'Outgoing preview';
    }
    const seam = document.createElement('div');
    seam.className = 'seam';
    host.appendChild(el);
    host.appendChild(seam);
    // Camera keys: a series holds the ROI of its first frame so genuine ticks never jitter the camera.
    const cams = [];
    states.forEach((s, i) => {
      const prev = states[i - 1];
      const roi = prev && s.series && prev.series === s.series ? cams[cams.length - 1].roi : cameraRoiOf(s.asset, s.cam);
      cams.push({at: s.at, roi, dur: i === 0 ? 0 : (s.camDur || 18)});
      for (const m of s.moves || []) cams.push({at: m.at, roi: cameraRoiOf(s.asset, m.cam), dur: m.dur || 18});
    });
    const spots = [], beads = [];
    for (const s of states) {
      if (s.spot) spots.push({name: s.spot[0], from: s.spot[1], to: s.spot[2], bead: !s.noBead});
      if (s.bead) beads.push({name: s.bead[0], from: s.bead[1], to: s.bead[2]});
    }
    const rec = {sc, shot, el, clip, win, img, states, cams, spots, beads, seam,
      spotEl: el.querySelector('.spot'), svg: el.querySelector('svg.run'), bar: el.querySelector('.bbar')};
    // Register ROI fallbacks for every asset a spot can touch.
    for (const sp of spots.concat(beads)) for (const s of states) {
      if (s.at < sp.to && (states.find(x => x.at > s.at) || {at: Infinity}).at > sp.from) roiOf(s.asset, sp.name);
    }
    M.shots.push(rec);
  }
  M.shots.forEach((r, i) => { r.next = M.shots[i + 1] || null; });
}

function buildStatic() {
  const em = $('embers');
  EL.embers = [];
  for (let i = 0; i < 24; i++) {
    const d = document.createElement('div');
    d.className = 'e';
    em.appendChild(d);
    EL.embers.push({el: d, size: 3 + hash(i) * 6, x: hash(i + .31) * W, speed: 14 + hash(i + .77) * 30,
      phase: hash(i + .53) * 1240, glow: .25 + .5 * hash(i + .11)});
  }
  for (const id of ['bandA', 'bandB']) {
    const sub = $(id).querySelector('.sub');
    sub.innerHTML = '<span class="sa"></span>';
  }
  const rows = $('rc-rows');
  const recap = SCENES.find(s => s.id === 'recap');
  EL.rows = recap.rows.map(([at, text], i) => {
    const r = document.createElement('div');
    r.className = 'rc-row';
    r.style.top = (378 + i * 104) + 'px';
    r.innerHTML = `<i class="dot"></i><span>${esc(text)}</span><div class="seam"></div>`;
    rows.appendChild(r);
    return {el: r, at, seam: r.querySelector('.seam')};
  });
  for (const id of ['lk-logo', 'o-logo']) {
    const flow = $(id).querySelector('.flow');
    flow.style.webkitMaskImage = flow.style.maskImage = `url("${LOGO}")`;
  }
  const logo = new Image();
  logo.src = LOGO;
  return logo.decode().then(() => {
    EL.wordW = $('lk-word').offsetWidth + 24;
    EL.metaW = $('lk-meta').offsetWidth;
    EL.bugW = $('bug').offsetWidth;
  }, () => { throw Error('missing approved logo ' + LOGO); });
}

window.READY = (async () => {
  if (!/^revision-\d{2}$/.test(REVISION)) throw Error('revision must have the form revision-XX');
  await fontsReady();
  await Promise.all([loadManifest(), checkPlan()]);
  await buildStatic();
  await buildShots();
  M.warnings = [...M.fallbacks].map(f => 'roi-fallback ' + f);
  renderFrame(0);
  return {revision: REVISION, frames: FRAMES, assets: Object.keys(M.entries).length, roiFallbacks: M.warnings};
})();
window.READY.catch(error => { window.READY_ERROR = String(error); });

// ---------------------------------------------------------------- drawing helpers
// 'inherit' (not 'visible') so a hidden parent always hides its children.
const vis = (el, on) => { el.style.visibility = on ? 'inherit' : 'hidden'; };
const shownEl = el => el.style.visibility !== 'hidden' && el.style.visibility !== '';
const sceneAt = f => SCENES.find(s => f >= s.in && f < s.out) || SCENES[SCENES.length - 1];

function atmosphere(f, t) {
  let pulse = 0;
  for (const db of DOWNBEATS) if (t >= db && t - db < 1.2) pulse = Math.max(pulse, Math.exp(-(t - db) / .35));
  const base = f < 135 ? lerp(.18, .62, ramp(f, 0, 135)) : f < LAST_PHRASE ? .66 : .8;
  const drop = f >= DROP ? .32 * Math.exp(-(f - DROP) / 36) : 0;
  const glow = $('glow');
  glow.style.opacity = clamp(base + (f < 135 ? .05 : .16) * pulse + drop, 0, 1);
  glow.style.transform = `scale(${1 + .035 * pulse + .06 * drop})`;
  $('contours').style.transform = `translateY(${-t * 3}px)`;
  const fadeIn = clamp(t / 1.5);
  for (let i = 0; i < EL.embers.length; i++) {
    const e = EL.embers[i];
    const y = 1120 - ((t * e.speed + e.phase) % 1240);
    const x = e.x + Math.sin(t * .6 + i) * 18;
    e.el.style.width = e.el.style.height = (e.size * 2) + 'px';
    e.el.style.transform = `translate(${x}px,${y}px)`;
    e.el.style.opacity = e.glow * (.6 + .4 * Math.sin(t * 2.1 + i * 1.7)) * fadeIn;
  }
}

function logoFlow(el, f) {
  el.querySelector('.flow').style.backgroundPosition = `${(f * 1.1) % 300}% ${(f * .6) % 300}%`;
}

function intro(f, t) {
  const lk = $('lockup');
  vis(lk, f < 132);
  if (f >= 132) return;
  const pos = $('lk-pos');
  pos.style.transform = 'translate(960px,360px)';
  const em = $('lk-ember');
  em.style.opacity = ramp(f, 0, 6) * (1 - ramp(f, 22, 44));
  em.style.transform = `scale(${lerp(.2, 1.3, easeOut(ramp(f, 0, 22)))})`;
  const halo = $('lk-halo');
  halo.style.opacity = ramp(f, 4, 40) * (.85 + .15 * Math.sin(t * 2.2));
  halo.style.transform = `scale(${.9 + .1 * ramp(f, 4, 40)})`;
  const logo = $('lk-logo'), size = 230;
  Object.assign(logo.style, {left: -size / 2 + 'px', top: -size / 2 + 'px', width: size + 'px', height: size + 'px',
    opacity: easeOut(ramp(f, 8, 40)), transform: `scale(${lerp(.84, 1, easeOut(ramp(f, 8, 52)))})`});
  logoFlow(logo, f);
  const seam = $('lk-seam');
  vis(seam, f >= 26);
  Object.assign(seam.style, {left: '640px', top: '655px', width: '640px',
    transform: `scaleX(${easeOut(ramp(f, 26, 38))})`, opacity: 1 - .6 * ramp(f, 54, 100)});
  const clip = $('lk-word-clip');
  Object.assign(clip.style, {left: (960 - EL.wordW / 2) + 'px', top: '480px', height: '175px'});
  $('lk-word').style.transform = `translateY(${(1 - easeOut(ramp(f, 32, 50))) * 110}%)`;
  const meta = $('lk-meta'), pm = easeOut(ramp(f, 69, 80));
  Object.assign(meta.style, {left: (960 - EL.metaW / 2) + 'px', top: '684px', opacity: pm, transform: `translateY(${(1 - pm) * 16}px)`});
  const q = easeIO(ramp(f, 104, 130));
  lk.style.transformOrigin = '960px 430px';
  lk.style.transform = `translate(${(1700 - 960) * q}px,${(47 - 430) * q}px) scale(${1 - .8 * q})`;
  lk.style.opacity = 1 - ramp(f, 112, 130);
}

const OUTRO = SCENES.find(s => s.id === 'outro');
function bug(f) {
  const b = $('bug');
  const op = ramp(f, 118, 134) * (1 - ramp(f, OUTRO.in - 10, OUTRO.in));
  vis(b, op > 0);
  b.style.left = (1800 - EL.bugW) + 'px';
  b.style.opacity = op;
}

// Frame geometry for a shot at frame f, from the active asset and interpolated ROI.
function camera(r, f) {
  let si = 0;
  for (let j = 0; j < r.states.length; j++) if (r.states[j].at <= f) si = j;
  const st = r.states[si];
  let ci = 0;
  for (let j = 0; j < r.cams.length; j++) if (r.cams[j].at <= f) ci = j;
  const cur = r.cams[ci], prev = r.cams[Math.max(0, ci - 1)];
  const p = ci === 0 || !cur.dur ? 1 : easeIO(ramp(f, cur.at, cur.at + cur.dur));
  const roi = cur.roi.map((v, n) => lerp(prev.roi[n], v, p));
  const img = r.img[st.asset], IW = img.naturalWidth, IH = img.naturalHeight;
  const [bx, by, bw, bh] = BOXES[r.shot.box || 'default'];
  const bar = r.shot.browser ? BAR : 0;
  // Native captures sit in a square window inset by the matte; the browser keeps its own chrome.
  const m = r.shot.browser ? 0 : MATTE;
  const rw = roi[2] * IW, rh = roi[3] * IH;
  const k = Math.min((bw - 2 * m) / rw, (bh - bar - 2 * m) / rh, K_MAX);
  const cw = rw * k, ch = rh * k;
  const fw = cw + 2 * m, fh = ch + bar + 2 * m;
  const fx = bx + (bw - fw) / 2, fy = by + (bh - fh) / 2;
  const push = r.shot.push ? lerp(r.shot.push[0], r.shot.push[1], easeIO(ramp(f, r.shot.from, r.shot.to))) : 1;
  const kk = k * push;
  const ox = roi[0] * IW + rw / 2 - cw / 2 / kk, oy = roi[1] * IH + rh / 2 - ch / 2 / kk;
  const e = entryOf(st.asset), cols = Number(e.columns) || 0;
  return {si, st, roi, fx, fy, fw, fh, cw, ch, m, k: kk, ox, oy, bar, IW, IH, moving: p < 1,
    fontPx: cols ? (IW / cols) * kk / CELL_FONT : null};
}
// Normalized asset rect → stage rect via a camera (same offsets as the image window).
function toStage(c, n) {
  return [c.fx + c.m + (n[0] * c.IW - c.ox) * c.k, c.fy + c.bar + c.m + (n[1] * c.IH - c.oy) * c.k,
    n[2] * c.IW * c.k, n[3] * c.IH * c.k];
}

// How a shot leaves: a handoff to the next shot of the same demo, a hard cut into the
// payoff, or folding back into its seam so the next beat's announcement plays on an empty stage.
function shotWindow(r) {
  const n = r.next, to = r.shot.to;
  if (n && n.shot.from === to) return n.shot.open === 'cut' ? {mode: 'cut', end: to} : {mode: 'handoff', end: to + 5, fade: [to - 2, to + 5]};
  return {mode: 'close', end: to + CLOSE};
}

function drawShot(r, f, info) {
  const w = shotWindow(r);
  const on = f >= r.shot.from && f < w.end;
  vis(r.el, on);
  vis(r.seam, false);
  if (!on) { vis(r.spotEl, false); vis(r.svg, false); if (r.bar) vis(r.bar, false); return null; }
  const c = camera(r, f);
  const cut = r.shot.open === 'cut';
  const open = cut ? 1 : easeOut(ramp(f, r.shot.from, r.shot.from + 14));
  const closing = w.mode === 'close' ? easeIn(ramp(f, r.shot.to, w.end)) : 0;
  const shut = Math.max(1 - open, closing);
  const opacity = w.mode === 'handoff' ? 1 - ramp(f, w.fade[0], w.fade[1]) : w.mode === 'close' ? 1 - ramp(f, r.shot.to + 6, w.end) : 1;
  const pop = cut ? lerp(1.025, 1, easeOut(ramp(f, r.shot.from, r.shot.from + 10))) : 1;
  Object.assign(r.el.style, {left: c.fx + 'px', top: c.fy + 'px', width: c.fw + 'px', height: c.fh + 'px', opacity,
    transform: `scale(${pop})`, transformOrigin: '50% 50%',
    clipPath: shut > 0 ? `inset(${(c.fh / 2) * shut}px 0 ${(c.fh / 2) * shut}px 0 round 22px)` : 'none'});
  const opening = !cut && f < r.shot.from + 16;
  if (opening || closing > 0) {
    vis(r.seam, true);
    const op = opening ? 1 - ramp(f, r.shot.from + 8, r.shot.from + 16) : ramp(f, r.shot.to, r.shot.to + 3) * (1 - ramp(f, r.shot.to + 6, w.end));
    const sx = opening ? easeOut(ramp(f, r.shot.from - 3, r.shot.from + 3)) : 1;
    Object.assign(r.seam.style, {left: (c.fx - 40) + 'px', top: (c.fy + c.fh / 2) + 'px', width: (c.fw + 80) + 'px',
      transform: `scaleX(${sx})`, opacity: op});
  }
  if (r.bar) vis(r.bar, true);
  Object.assign(r.win.style, {left: c.m + 'px', top: (c.bar + c.m) + 'px', width: c.cw + 'px', height: c.ch + 'px'});
  // Actual capture images: within-shot state changes are atomic. Only the active
  // capture is shown, fully opaque, so native cells never mix across states.
  for (const [key, img] of Object.entries(r.img)) {
    const active = key === c.st.asset;
    vis(img, active);
    if (!active) continue;
    img.style.transform = `translate(${-c.ox * c.k}px,${-c.oy * c.k}px) scale(${c.k})`;
    img.style.opacity = 1;
    img.style.zIndex = 1;
  }
  // Spotlight: warm wash and dimmed surroundings, never an outline rectangle.
  const sp = f < r.shot.to ? r.spots.find(s => f >= s.from && f < s.to) : null;
  vis(r.spotEl, !!sp && open >= 1);
  let target = null;
  if (sp && open >= 1) {
    const [x, y, w2, h] = toStage(c, roiOf(c.st.asset, sp.name));
    target = [x, y, w2, h];
    const pad = 10;
    const op = ramp(f, sp.from, sp.from + 6) * (1 - ramp(f, sp.to - 6, sp.to));
    Object.assign(r.spotEl.style, {left: (x - c.fx - pad) + 'px', top: (y - c.fy - pad) + 'px',
      width: (w2 + 2 * pad) + 'px', height: (h + 2 * pad) + 'px', opacity: op});
  }
  // One molten bead along the actual frame border on the closing-phrase attack.
  const runOn = r.shot.run && f >= DROP && f < DROP + 26;
  vis(r.svg, runOn);
  if (runOn) {
    r.svg.setAttribute('width', c.fw);
    r.svg.setAttribute('height', c.fh);
    for (const rect of r.svg.querySelectorAll('rect')) {
      Object.entries({x: 2, y: 2, width: c.fw - 4, height: c.fh - 4, rx: 20}).forEach(([a, v]) => rect.setAttribute(a, v));
      rect.setAttribute('stroke-dasharray', '0.18 0.82');
      rect.setAttribute('stroke-dashoffset', String(-easeOut(ramp(f, DROP, DROP + 24))));
    }
    r.svg.style.opacity = 1 - ramp(f, DROP + 18, DROP + 26);
  }
  const shown = Object.keys(r.img).filter(k => shownEl(r.img[k]));
  info.assets.push(...shown);
  const cam = {shot: r.shot.id, asset: c.st.asset, roi: c.roi.map(v => +v.toFixed(4)),
    frame: [c.fx, c.fy, c.fw, c.fh].map(v => +v.toFixed(1)), scale: +c.k.toFixed(4),
    fontPx: c.fontPx && +c.fontPx.toFixed(1), opacity: +opacity.toFixed(3),
    // Actual wrapper state: ROI glide, seam open/close clip, cut pop scale and fades all count as motion.
    moving: c.moving || shut > 0 || pop !== 1 || opacity < 1,
    wrapper: {scale: +pop.toFixed(4), clip: +shut.toFixed(4), opacity: +opacity.toFixed(4)},
    window: [c.fx + c.m, c.fy + c.bar + c.m, c.cw, c.ch].map(v => +v.toFixed(1)), matte: c.m,
    target: target && target.map(v => +v.toFixed(1)), exit: w.mode};
  info.cameras.push(cam);
  return {r, c, cam};
}

// ---------------------------------------------------------------- headline bands
// Announce first: kicker, headline words, then the one supporting line type on over the
// empty atmosphere. The narration then stays fixed until the beat's demo folds away.
const BAND_SCENES = SCENES.filter(s => s.band);
function wordsHTML(b) {
  return b.head.split(' ').map(w => `<span class="w${(b.hl || []).includes(w) ? ' hl' : ''}">${esc(w)}</span>`).join(' ');
}
function drawBands(f, info) {
  const els = [$('bandA'), $('bandB')];
  els.forEach(el => vis(el, false));
  BAND_SCENES.forEach((sc, i) => {
    const el = els[i % 2];
    if (f < sc.in || f >= sc.out) return;
    const b = sc.band;
    if (el.dataset.scene !== sc.id) {
      el.dataset.scene = sc.id;
      el.classList.toggle('molten', !!b.molten);
      el.querySelector('.kicker span').textContent = b.kicker;
      el.querySelector('.head').innerHTML = wordsHTML(b);
      el.querySelector('.sub span').textContent = b.sub;
      el.querySelector('.foot span').textContent = b.foot || '';
    }
    vis(el, true);
    const x0 = exitStartOf(sc), x1 = Math.min(sc.out, x0 + 8);
    const bandOpacity = 1 - ramp(f, x0, x1);
    el.style.opacity = bandOpacity;
    const s0 = sc.in + 1;
    let settle = 1;
    const kp = easeOut(ramp(f, s0 - 1, s0 + 7));
    const kick = el.querySelector('.kicker');
    kick.style.opacity = kp;
    kick.querySelector('i').style.transform = `scaleX(${kp})`;
    const words = el.querySelectorAll('.head .w'), n = words.length;
    const stagger = n > 1 ? 4 / (n - 1) : 0;
    settle = Math.min(settle, kp);
    words.forEach((w, j) => {
      const w0 = s0 + j * stagger, p = easeOut(ramp(f, w0, w0 + 8));
      settle = Math.min(settle, p);
      w.style.opacity = p;
      w.style.transform = b.molten ? `translateY(${(1 - p) * 46}px) scale(${lerp(.9, 1, p)})` : `translateY(${(1 - p) * 40}px)`;
    });
    const sub = el.querySelector('.sub span'), at = s0 + 13, p = easeOut(ramp(f, at, at + 10));
    vis(sub, f >= at);
    sub.style.opacity = ramp(f, at, at + 3);
    sub.style.clipPath = `inset(-8px ${(1 - p) * 100}% -8px 0)`;
    sub.style.transform = `translateY(${(1 - p) * 10}px)`;
    const foot = el.querySelector('.foot'), fp = b.foot ? easeOut(ramp(f, at + 2, at + 10)) : 0;
    vis(foot, fp > 0);
    foot.style.opacity = fp;
    settle = Math.min(settle, p, b.foot ? fp : 1);
    info.text = {kicker: b.kicker, headline: b.head, sub: f >= at ? b.sub : null, footnote: fp > 0 ? b.foot : null};
    // Actual rendered state, not phase labels: any entrance progress < 1 or band fade counts.
    info.textState = {opacity: +bandOpacity.toFixed(4), settle: +settle.toFixed(4)};
    info.textMoving = settle < 1 || bandOpacity < 1;
    info.textExiting = bandOpacity < 1;
    info.band = el;
  });
}

// ---------------------------------------------------------------- guidance
function drawKeys(f, sc, info) {
  const chip = $('keys');
  const k = (sc.keys || []).filter(x => f >= x.cue && f < x.press + 20).pop();
  vis(chip, !!k);
  if (!k) return;
  const flash = f >= k.press && f < k.press + 6;
  const html = k.keys.map(x => `<span class="cap">${esc(x)}</span>`).join('<span class="plus">+</span>') + `<span class="act">${esc(k.label)}</span>`;
  if (chip.dataset.html !== html) { chip.innerHTML = html; chip.dataset.html = html; }
  chip.querySelectorAll('.cap').forEach(cap => {
    cap.style.background = flash ? 'rgba(255,158,97,.62)' : 'rgba(255,158,97,.10)';
    cap.style.color = flash ? '#1a0f0a' : '#ffc49c';
    cap.style.transform = flash ? 'translateY(3px)' : 'none';
    cap.style.boxShadow = flash ? '0 2px 0 rgba(236,122,53,.55), 0 0 26px rgba(236,122,53,.6)' : '0 5px 0 rgba(236,122,53,.55)';
  });
  const p = easeOut(ramp(f, k.cue, k.cue + 6));
  chip.style.left = (1800 - chip.offsetWidth) + 'px';
  chip.style.top = '182px';
  chip.style.opacity = p * (1 - ramp(f, k.press + 14, k.press + 20));
  chip.style.transform = `translateY(${(1 - p) * 14}px)`;
  info.keys = {keys: k.keys, label: k.label, cue: k.cue, press: k.press, pressed: f >= k.press};
}

// The ember lives in the editorial margin just left of the frame and only travels
// vertically there, so it never sweeps across UI glyphs. It rests beside the target row
// while the spotlight wash marks the row itself.
function beadTargets(sc) {
  const out = [];
  for (const r of M.shots.filter(x => x.sc === sc)) {
    for (const s of r.spots) if (s.bead) out.push({r, name: s.name, from: s.from, to: s.to});
    for (const b of r.beads) out.push({r, ...b});
  }
  return out.sort((a, b) => a.from - b.from);
}
function beadRest(tg, shots) {
  const d = shots.find(x => x.r === tg.r);
  if (!d) return null;
  const [, y, , h] = toStage(d.c, roiOf(d.c.st.asset, tg.name));
  const top = d.c.fy + 22, bottom = d.c.fy + d.c.fh - 22;
  return {x: d.c.fx - BEAD_X, y: clamp(y + h / 2, top, bottom), top};
}
function beadPos(tg, f, shots, prevRest) {
  const rest = beadRest(tg, shots);
  if (!rest) return null;
  const y0 = prevRest ? prevRest.y : Math.max(rest.top, rest.y - 200);
  const p = easeIO(ramp(f, tg.from, tg.from + 14));
  // A slight outward bow keeps the whole path in the margin, away from the frame.
  return [rest.x - 16 * Math.sin(Math.PI * p), lerp(y0, rest.y, p)];
}
function drawBead(f, sc, shots, info) {
  const bead = $('bead');
  const list = beadTargets(sc);
  const i = list.map(t => f >= t.from && f < t.to).lastIndexOf(true);
  vis(bead, i >= 0);
  if (i < 0) return;
  const tg = list[i], prev = list[i - 1];
  const prevRest = prev && prev.to >= tg.from - 2 ? beadRest(prev, shots) : null;
  const pos = beadPos(tg, f, shots, prevRest);
  if (!pos) { vis(bead, false); return; }
  const back = beadPos(tg, f - 1.5, shots, prevRest) || pos;
  const vx = pos[0] - back[0], vy = pos[1] - back[1], speed = Math.hypot(vx, vy);
  bead.style.transform = `translate(${pos[0]}px,${pos[1]}px)`;
  bead.style.opacity = ramp(f, tg.from, tg.from + 3) * (1 - ramp(f, tg.to - 6, tg.to));
  const tail = bead.querySelector('.tail');
  tail.style.width = Math.min(60, speed * 3) + 'px';
  tail.style.transform = `rotate(${Math.atan2(-vy, -vx)}rad)`;
  tail.style.opacity = clamp(speed / 6);
  const arrive = tg.from + 14, q = ramp(f, arrive, arrive + 14);
  const rip = bead.querySelector('.ripple');
  vis(rip, f >= arrive && q < 1);
  rip.style.transform = `scale(${lerp(.4, 1.15, easeOut(q))})`;
  rip.style.opacity = .8 * (1 - q);
  const d = shots.find(x => x.r === tg.r);
  info.guide = {bead: tg.name, at: pos.map(v => +v.toFixed(1)), frameLeft: d ? +d.c.fx.toFixed(1) : null, margin: true};
}

function drawPointer(f, sc, shots, info) {
  const el = $('pointer');
  const pt = sc.pointer;
  const on = !!pt && f >= pt.appear && f < pt.hide[1];
  vis(el, on);
  if (!on) return;
  const d = shots.find(x => x.r.states.some(s => s.asset === pt.asset));
  if (!d) { vis(el, false); return; }
  const [cx, cy] = clickOf(pt.asset);
  const [tx, ty] = toStage(d.c, [cx, cy, 0, 0]);
  const p = easeIO(ramp(f, pt.move[0], pt.move[1]));
  const x = lerp(tx + 240, tx, p), y = lerp(ty + 170, ty, p);
  const pressed = f >= pt.press && f < pt.press + 4;
  el.style.transform = `translate(${x}px,${y}px)`;
  el.style.opacity = ramp(f, pt.appear, pt.appear + 5) * (1 - ramp(f, pt.hide[0], pt.hide[1]));
  el.querySelector('svg').style.transform = pressed ? 'scale(.88)' : 'none';
  const q = ramp(f, pt.press, pt.press + 16), rip = el.querySelector('.press');
  vis(rip, f >= pt.press && q < 1);
  rip.style.transform = `scale(${lerp(.4, 1.5, easeOut(q))})`;
  rip.style.opacity = 1 - q;
  info.pointer = {target: [tx, ty].map(v => +v.toFixed(1)), at: [x, y].map(v => +v.toFixed(1)), press: pt.press, pressed: f >= pt.press};
}

function drawBurst(f, shots) {
  const el = $('burst');
  const on = f >= DROP && f < DROP + 26;
  vis(el, on);
  if (!on) return;
  const d = shots.find(x => x.r.shot.id === 'drive-sent');
  const cx = d ? d.c.fx + d.c.fw / 2 : 960, cy = d ? d.c.fy + d.c.fh / 2 : 660;
  el.style.transform = `translate(${cx}px,${cy}px)`;
  const p = ramp(f, DROP, DROP + 24);
  const ring = el.querySelector('.ring');
  ring.style.transform = `scale(${lerp(.35, 2.6, easeOut(p))})`;
  ring.style.opacity = Math.pow(1 - p, 1.3);
  el.querySelector('.heat').style.opacity = (f < DROP + 3 ? ramp(f, DROP, DROP + 2) : 1 - ramp(f, DROP + 3, DROP + 26)) * .85;
}

// ---------------------------------------------------------------- recap and outro
const RECAP = SCENES.find(s => s.id === 'recap');
function drawRecap(f, info) {
  const el = $('recap');
  const on = f >= RECAP.in && f < RECAP.out + 4;
  vis(el, on);
  if (!on) return;
  el.style.opacity = 1 - ramp(f, RECAP.out - 12, RECAP.out);
  const p = easeOut(ramp(f, RECAP.in, RECAP.in + 12));
  for (const id of ['rc-kicker', 'rc-title']) {
    $(id).style.opacity = p;
    $(id).style.transform = `translateY(${(1 - p) * 30}px)`;
  }
  for (const row of EL.rows) {
    const q = easeOut(ramp(f, row.at, row.at + 10));
    const span = row.el.querySelector('span');
    span.style.opacity = q;
    span.style.transform = `translateY(${(1 - q) * 34}px)`;
    row.el.querySelector('.dot').style.opacity = q;
    vis(row.seam, f >= row.at - 2);
    row.seam.style.transform = `scaleX(${easeOut(ramp(f, row.at - 2, row.at + 6))})`;
    row.seam.style.opacity = 1 - .75 * ramp(f, row.at + 10, row.at + 30);
  }
  info.text = {headline: 'And smaller wins:', rows: RECAP.rows.filter(([at]) => f >= at).map(([, t]) => t)};
}

function drawOutro(f, t) {
  const el = $('outro');
  // Outro opens after the recap; its elements stagger so the flare still lands on the music stop.
  const L = OUTRO.in;
  const on = f >= L - 4;
  vis(el, on);
  if (!on) return;
  const p = easeOut(ramp(f, L, L + 18));
  const logo = $('o-logo'), size = 250;
  Object.assign(logo.style, {left: -size / 2 + 'px', top: -size / 2 + 'px', width: size + 'px', height: size + 'px',
    opacity: p, transform: `scale(${lerp(.8, 1, p)})`});
  logoFlow(logo, f);
  const flare = f >= STOP ? .5 * Math.exp(-(f - STOP) / 10) : 0;
  $('o-halo').style.opacity = clamp(p * (.85 + .15 * Math.sin(t * 2.2)) + flare);
  $('o-halo').style.transform = `scale(${1 + .25 * flare})`;
  const q = ramp(f, L + 44, L + 76), ring = $('o-ring');
  vis(ring, f >= L + 44 && q < 1);
  ring.style.transform = `scale(${lerp(.7, 2, easeOut(q))})`;
  ring.style.opacity = 1 - q;
  [['o-title', L + 10], ['o-now', L + 22], ['o-url', L + 34], ['o-fine', L + 44]].forEach(([id, at]) => {
    const s = easeOut(ramp(f, at, at + 12));
    $(id).style.opacity = s;
    $(id).style.transform = `translateY(${(1 - s) * 26}px)`;
  });
}

// ---------------------------------------------------------------- frame
function beatOf(sc, f) {
  return {id: sc.id, kind: sc.kind, phase: phaseOf(sc, f), in: sc.in, out: sc.out,
    announceStart: sc.band ? sc.in : null, textSettled: settledOf(sc),
    demoStart: sc.demo ?? null, demoEnd: sc.demoEnd ?? null,
    narration: sc.band ? {kicker: sc.band.kicker, headline: sc.band.head, sub: sc.band.sub, footnote: sc.band.foot || null} : null,
    keys: (sc.keys || []).map(k => ({keys: k.keys, label: k.label, cue: k.cue, press: k.press}))};
}
function renderFrame(f) {
  const t = f / FPS;
  const sc = sceneAt(f);
  const info = {frame: f, t: +t.toFixed(4), scene: sc.id, beat: beatOf(sc, f), assets: [], cameras: [], text: {},
    textMoving: false, keys: null, guide: null, pointer: null, warnings: []};
  atmosphere(f, t);
  intro(f, t);
  bug(f);
  const shots = M.shots.map(r => drawShot(r, f, info)).filter(Boolean);
  drawBands(f, info);
  drawKeys(f, sc, info);
  drawBead(f, sc, shots, info);
  drawPointer(f, sc, shots, info);
  drawBurst(f, shots);
  drawRecap(f, info);
  drawOutro(f, t);
  $('fade').style.opacity = ramp(f, FRAMES - 18, FRAMES - 1);
  info.shots = shots;
  return info;
}
const frameOf = t => clamp(Math.round(t * FPS), 0, FRAMES - 1);

window.render = async t => {
  await window.READY;
  renderFrame(frameOf(t));
  return true;
};

// Inspection: beat phase, fixed narration, visible actual assets, camera ROI and warnings.
// Semantic assertions: no UI during announce/read; narration fixed and settled during a
// demo; no headline/subline motion while a camera moves.
window.qa = async t => {
  await window.READY;
  const info = renderFrame(frameOf(t));
  const warn = info.warnings, beat = info.beat;
  const box = el => el.getBoundingClientRect();
  const keys = $('keys'), keysOn = shownEl(keys);
  const visibleShots = info.shots.filter(s => s.cam.opacity > 0);
  if (['announce', 'read', 'hold'].includes(beat.phase) && visibleShots.length) {
    warn.push('UI visible during ' + beat.phase + ': ' + visibleShots.map(s => s.cam.shot).join(','));
  }
  if (beat.phase === 'demo' && beat.kind === 'feature') {
    // Uses the band's actual rendered opacity and entrance progress through demoEnd.
    if (info.textMoving) warn.push(`narration moving during demo (opacity ${info.textState?.opacity}, settle ${info.textState?.settle})`);
    if (info.text.headline !== beat.narration.headline || info.text.sub !== beat.narration.sub) warn.push('narration differs from fixed beat narration');
  }
  if (info.textMoving && info.cameras.some(c => c.moving && c.opacity > 0) && beat.phase !== 'exit') {
    warn.push('headline/subline motion overlaps a camera move');
  }
  if (beat.kind === 'payoff' && visibleShots.length) warn.push('payoff shows UI');
  if (info.band) {
    const head = info.band.querySelector('.head');
    const words = [...head.querySelectorAll('.w')];
    const right = words.length ? Math.max(...words.map(w => box(w).right)) : 0;
    if (right > 1800) warn.push(`headline overflows: right ${right.toFixed(0)}px`);
    const s = info.band.querySelector('.sub span');
    if (shownEl(s)) {
      const rr = box(s);
      if (rr.right > 1800) warn.push(`subline overflows: right ${rr.right.toFixed(0)}px`);
      if (keysOn && rr.right + 24 > box(keys).left) warn.push('subline collides with key cue');
    }
    const foot = info.band.querySelector('.foot');
    if (shownEl(foot)) {
      const fr = box(foot);
      for (const sh of visibleShots) if (fr.bottom + 8 > sh.c.fy) warn.push('footnote touches frame ' + sh.cam.shot);
    }
  }
  for (const sh of info.shots) {
    const c = sh.cam;
    if (c.frame[1] < 268 && info.band) warn.push(`frame ${c.shot} rises into the headline band`);
    if (c.frame[0] < 0 || c.frame[1] < 0 || c.frame[0] + c.frame[2] > W || c.frame[1] + c.frame[3] > H) warn.push(`frame ${c.shot} leaves the stage`);
    if (c.fontPx && !c.moving && c.fontPx < 26) warn.push(`native text ${c.fontPx}px in ${c.asset} (target 29–31)`);
    if (c.target && !c.moving) {
      const [x, y, w, h] = c.target, [wx, wy, ww, wh] = c.window;
      if (x < wx - .5 || y < wy - .5 || x + w > wx + ww + .5 || y + h > wy + wh + .5) {
        warn.push(`spotlit target in ${c.asset} is cut by the camera window`);
      }
    }
  }
  if (info.guide && info.guide.frameLeft !== null && info.guide.at[0] + 33 > info.guide.frameLeft + MATTE) {
    warn.push('ember glow reaches native pixels');
  }
  for (const row of EL.rows) if (box(row.el.querySelector('span')).right > 1800) warn.push('recap row overflows');
  const visible = new Set(info.assets);
  for (const fb of M.warnings) if ([...visible].some(a => fb.includes(' ' + a + ':'))) warn.push(fb);
  const out = {...info};
  delete out.shots;
  delete out.band;
  out.visibleAssets = [...visible];
  out.cameraROI = info.cameras.map(c => ({asset: c.asset, roi: c.roi, frame: c.frame, scale: c.scale, fontPx: c.fontPx}));
  return out;
};
window.FILM_PLAN = {
  frames: FRAMES, posterTime: POSTER_TIME, revision: REVISION,
  beats: SCENES.map(s => beatOf(s, s.in))
};
})();
