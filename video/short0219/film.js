'use strict';
// In Good Time — What's new in Omagma v0.2.19. Deterministic picture source:
// render(t) depends only on t. Every UI pixel is a genuine capture from the manifest.
// Attention: each beat announces over the empty atmosphere (no UI), leaves 1.9 s to
// read once the words settle, then demonstrates with its narration held fixed. The UI
// folds back into its seam before the next words build.
(() => {
// Clock of the approved v0.2.7 soundtrack (2527 frames), packet-copied unchanged.
const FPS = 30, FRAMES = 2527, W = 1920, H = 1080;
window.FILM = {duration: FRAMES / FPS, fps: FPS, width: W, height: H};
const REVISION = new URLSearchParams(location.search).get('revision') || 'revision-01';
const BASE = '/video/cache/short0219/' + REVISION + '/';
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

// Decorative glow pulses on the soundtrack's bars (same measured grid as v0.2.18):
// phrase downbeats to 70.476 s (closing-phrase attack), last phrase 78.965 s, stop 81.393 s.
const PHRASES = [8.928, 17.752, 26.552, 35.352, 44.13, 52.91, 61.69, 70.476];
const DOWNBEATS = [0.104, 2.31, 4.516, 6.722];
for (let i = 0; i < PHRASES.length - 1; i++) {
  for (let b = 0; b < 4; b++) DOWNBEATS.push(PHRASES[i] + b * (PHRASES[i + 1] - PHRASES[i]) / 4);
}
DOWNBEATS.push(70.476, 72.615, 74.754, 76.893, 78.965, 81.104, 83.243);
const DROP = 2114, LAST_PHRASE = 2369, STOP = 2442;

const BOXES = {default: [120, 284, 1680, 760], foot: [120, 300, 1680, 744]};
const K_MAX = 1.0;          // never magnify DPR2 captures beyond 1 image px per CSS px
const FONT_MAX = 34;        // small crops stay calm instead of ballooning (target 29–31)
const FONT_MIN = 26;        // review floor for meaningful native text
const MATTE = 14;           // editorial matte: rounded corners never touch UI pixels
const CELL_FONT = 0.6;      // JetBrains Mono advance / em
const CLOSE = 10;           // frames for a demo frame to fold back into its seam
const BEAD_X = 30;          // ember rests this far left of the frame edge, outside UI pixels
const SETTLE = 24;          // kicker, headline words and typed supporting line
const READ = 57;            // 1.9 s of settled reading before any UI appears
const GLIDE = 18;           // contextual camera glide after an atomic state change

// ---------------------------------------------------------------- timeline
// Feature beat: in = announceStart → textSettled (in + 24) → demo (+57 reading) →
// demoEnd (frame folds away, CLOSE frames) → out. One fixed headline + one fixed line
// per beat; only action keycaps appear during a demo, 20 frames before the real press.
// Within a shot, states switch atomically on the press frame; spots belong to one state.
const SCENES = [
  {id: 'intro', kind: 'intro', in: 0, out: 135},
  {id: 'grid', kind: 'feature', in: 135, demo: 216, demoEnd: 595, out: 605,
    band: {kicker: '01 · CALENDAR', head: 'Your calendar, now a real grid.', hl: ['grid.'],
      sub: 'Blocks on a time axis, in orange & blue. Ctrl+T for Classic.'},
    shots: [
      // Week overview at full width (104 cols), a contextual push into today's column of
      // blocks (genuine now line in the blank row between earlier and later events; a
      // 14-cell Week column shows overlap as its genuine +1), then Day (2), where the
      // overlap genuinely splits into side-by-side lanes, and the look toggle.
      {id: 'grid-native', from: 216, to: 595, tone: 'cool', states: [
        {at: 216, asset: 'calendar.week', cam: 'week', moves: [{at: 272, cam: 'today', dur: 24}],
          spots: [['column', 302, 346]]},
        {at: 352, asset: 'calendar.day', cam: 'day', spots: [['lanes', 376, 428]]},
        {at: 446, asset: 'calendar.day-classic', cam: 'day'},
        {at: 510, asset: 'calendar.day-back', cam: 'day', spots: [['allday', 524, 588]]}]}],
    keys: [{keys: ['2'], label: 'Day view', cue: 332, press: 352},
      {keys: ['Ctrl', 'T'], label: 'Classic look', cue: 426, press: 446},
      {keys: ['Ctrl', 'T'], label: 'Orange & Blue', cue: 490, press: 510}]},
  {id: 'guests', kind: 'feature', in: 605, demo: 686, demoEnd: 995, out: 1005,
    band: {kicker: '02 · CALENDAR GUESTS', head: 'Type two letters. Pick your guest.', hl: ['guest.'],
      sub: 'From your contacts and recent mail. Only your pick is added.'},
    shots: [
      {id: 'guests-native', from: 686, to: 995, tone: 'cool', states: [
        {at: 686, asset: 'guest.empty', cam: 'form', spots: [['guests', 702, 742]]},
        {at: 746, asset: 'guest.typed', cam: 'form', optional: true},
        {at: 754, asset: 'guest.suggest', cam: 'form', spots: [['suggest', 766, 832]]},
        {at: 838, asset: 'guest.selected', cam: 'form', spots: [['choice', 848, 892]]},
        {at: 900, asset: 'guest.added', cam: 'form', spots: [['field', 912, 988]]}]}],
    keys: [{keys: ['a', 'l'], seq: true, label: 'Type', cue: 726, press: 746},
      {keys: ['↓'], label: 'Choose', cue: 818, press: 838},
      {keys: ['Enter'], label: 'Add guest', cue: 880, press: 900}]},
  {id: 'rsvp', kind: 'feature', in: 1005, demo: 1086, demoEnd: 1370, out: 1380,
    band: {kicker: '03 · CALENDAR', head: 'RSVP without leaving your calendar.', hl: ['RSVP'],
      sub: 'Press r to review your answer. Nothing changes until y.'},
    shots: [
      {id: 'rsvp-native', from: 1086, to: 1370, tone: 'cool', states: [
        {at: 1086, asset: 'rsvp.before', cam: 'result', spots: [['event', 1100, 1146]]},
        {at: 1156, asset: 'rsvp.review', cam: 'dialog', spots: [['choices', 1176, 1212]]},
        // Each dialog state has its own exact native border box (the wrapped consequence adds
        // a row), so the camera cuts atomically with the state instead of gliding.
        {at: 1220, asset: 'rsvp.accept', cam: 'dialog', camDur: 0, spots: [['confirm', 1230, 1274]]},
        // The genuine 'Accepted · …' status is the proof of the saved answer: 2 s of focus.
        {at: 1286, asset: 'rsvp.done', cam: 'result', spots: [['status', 1304, 1366]]}]}],
    keys: [{keys: ['r'], label: 'Answer', cue: 1136, press: 1156},
      {keys: ['a'], label: 'Accept', cue: 1200, press: 1220},
      {keys: ['y'], label: 'Confirm', cue: 1266, press: 1286}]},
  {id: 'ics', kind: 'feature', in: 1380, demo: 1461, demoEnd: 1790, out: 1800,
    band: {kicker: '04 · MAIL → CALENDAR', head: 'Bill due? Put it on your calendar.', hl: ['calendar.'],
      sub: 'Press A on the attached .ics. Your own event, reminder included.'},
    shots: [
      {id: 'ics-mail', from: 1461, to: 1680, states: [
        {at: 1461, asset: 'ics.mail', cam: 'reader', spots: [['card', 1476, 1518]]},
        {at: 1528, asset: 'ics.review', cam: 'modal', spots: [['details', 1548, 1602]]},
        {at: 1610, asset: 'ics.saved', cam: 'modal', spots: [['status', 1620, 1674]]}]},
      // The populated result: the due date's Day view with the new all-day item.
      {id: 'ics-calendar', from: 1680, to: 1790, open: 'cut', tone: 'cool', states: [
        {at: 1680, asset: 'ics.calendar', cam: 'day', spots: [['added', 1700, 1784]]}]}],
    keys: [{keys: ['A'], label: 'Add to calendar', cue: 1508, press: 1528},
      {keys: ['y'], label: 'Confirm', cue: 1590, press: 1610}]},
  // The restored words land on the closing-phrase attack (2114) and hold 2.5 s under the
  // unchanged narration, then fold straight into the recap: no empty stage, no payoff card.
  {id: 'draft', kind: 'feature', in: 1800, demo: 1881, demoEnd: 2190, out: 2200,
    band: {kicker: '05 · COMPOSE', head: 'Discarded too soon? Get it back.', hl: ['back.'],
      sub: 'Ctrl+X asks first. Ctrl+Z brings back every word.',
      foot: 'Later, even after a restart: :restore-draft (up to 7 days)'},
    shots: [
      {id: 'draft-native', from: 1881, to: 2190, box: 'foot', run: true, states: [
        {at: 1881, asset: 'draft.typing', cam: 'compose', spots: [['body', 1896, 1946]]},
        {at: 1960, asset: 'draft.review', cam: 'review', spots: [['prompt', 1980, 2028]]},
        {at: 2034, asset: 'draft.discarded', cam: 'mail', spots: [['status', 2056, 2100]]},
        // Atomic camera cut on the attack: no glide across the genuine recovery footer
        // ('Message size unavailable: UnfinishedDraft') below the composer.
        {at: 2114, asset: 'draft.restored', cam: 'compose', camDur: 0, spots: [['body', 2134, 2184]]}]}],
    keys: [{keys: ['Ctrl', 'X'], label: 'Discard', cue: 1940, press: 1960},
      {keys: ['Ctrl', 'X'], label: 'Confirm discard', cue: 2014, press: 2034},
      {keys: ['Ctrl', 'Z'], label: 'Undo', cue: 2094, press: 2114}]},
  {id: 'recap', kind: 'text', in: 2200, out: 2392,
    rows: [[2212, 'Reconnect an expired account with Ctrl+O'],
      [2226, 'Delete Calendar events after one clear review'],
      [2240, 'Clearer Sent dates, names and label chips'],
      [2254, 'Jump between unread mail with n and N'],
      [2268, 'Unusual mail still opens, emoji stay aligned']]},
  {id: 'outro', kind: 'outro', in: 2392, out: 2527}
];
const POSTER_TIME = 13.4;

const settledOf = sc => sc.band ? sc.in + SETTLE : null;
// Narration stays fully opaque through demoEnd and leaves while its UI folds away.
const exitStartOf = sc => sc.demoEnd != null ? sc.demoEnd : sc.out - 8;
function phaseOf(sc, f) {
  if (!sc.band) return sc.kind;
  if (f < settledOf(sc)) return 'announce';
  if (sc.demo == null) return f < exitStartOf(sc) ? 'hold' : 'exit';
  if (f < sc.demo) return 'read';
  if (f < sc.demoEnd) return 'demo';
  return 'exit';
}

// Authoring guard: contiguous beats, exact announce/read/demo/close clock, shots inside
// their demo, keycaps 20 frames before presses that fall inside the demo.
function validateTimeline() {
  if (SCENES[0].in !== 0 || SCENES[SCENES.length - 1].out !== FRAMES) throw Error('timeline must cover every frame');
  SCENES.forEach((sc, i) => {
    if (i && SCENES[i - 1].out !== sc.in) throw Error('non-contiguous beat ' + sc.id);
    if (sc.kind !== 'feature') return;
    if (sc.demo !== sc.in + SETTLE + READ || sc.out !== sc.demoEnd + CLOSE) throw Error('beat clock mismatch ' + sc.id);
    for (const shot of sc.shots) {
      if (shot.from < sc.demo || shot.to > sc.demoEnd || shot.states[0].at !== shot.from) throw Error('shot outside demo ' + shot.id);
    }
    for (const k of sc.keys || []) {
      if (k.press - k.cue !== 20 || k.cue < sc.demo || k.press >= sc.demoEnd) throw Error('key cue timing ' + sc.id);
    }
  });
}

// ---------------------------------------------------------------- state built by READY
const M = {entries: {}, shots: [], warnings: [], fallbacks: new Set(), skipped: []};
const EL = {};

function entryOf(key) {
  const e = M.entries[key];
  if (!e) throw Error('missing required asset: ' + key);
  return e;
}
const gridOf = e => [Number(e.columns) || 0, Number(e.rows) || 0];
const normRect = v => Array.isArray(v) && v.length === 4 && v.every(Number.isFinite) && v[2] > 0 && v[3] > 0;
// Spotlight ROI: the named binding, else a reported fallback (focus → full frame).
function roiOf(key, name) {
  const rois = entryOf(key).rois || {};
  if (normRect(rois[name])) return rois[name];
  const tier = normRect(rois.focus) ? 'focus' : 'full';
  M.fallbacks.add(key + ':' + name + '→' + tier);
  return tier === 'focus' ? rois.focus : [0, 0, 1, 1];
}
// Contextual camera: kept separate from the tighter spotlight even when names match.
function cameraRoiOf(key, name) {
  const r = entryOf(key).cameraRois?.[name];
  return normRect(r) ? r : roiOf(key, name);
}

// An optional state whose asset was not captured hands its start to the next state.
function expandStates(shot) {
  const out = [];
  let carry = null;
  for (const s of shot.states) {
    if (s.optional && !M.entries[s.asset]) {
      M.skipped.push(s.asset);
      if (carry == null) carry = s.at;
      continue;
    }
    out.push({...s, at: carry ?? s.at});
    carry = null;
  }
  if (!out.length) throw Error('shot has no captured states: ' + shot.id);
  return out;
}

// ---------------------------------------------------------------- READY
async function fontsReady() {
  await Promise.all(['800 76px "Adwaita Sans"', '600 34px "Adwaita Sans"', '700 24px "JetBrainsMono Nerd Font"']
    .map(f => document.fonts.load(f).catch(() => null)));
  await document.fonts.ready;
  const ctx = document.createElement('canvas').getContext('2d');
  const width = font => { ctx.font = font; return ctx.measureText('In Good Time · Omagma 0123456789 WWWiii mmm').width; };
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

// film-plan.json must mirror this clock and copy exactly; any drift rejects READY.
async function checkPlan() {
  const res = await fetch('film-plan.json', {cache: 'no-store'});
  if (!res.ok) throw Error('missing film-plan.json');
  const plan = await res.json();
  const fmt = plan.format || {};
  if (fmt.frames !== FRAMES || fmt.fps !== FPS || fmt.width !== W || fmt.height !== H || plan.posterTime !== POSTER_TIME) {
    throw Error('film-plan.json format/poster mismatch');
  }
  if ((plan.beats || []).length !== SCENES.length) throw Error('film-plan.json beat count mismatch');
  for (const sc of SCENES) {
    const p = plan.beats.find(s => s.id === sc.id);
    if (!p || p.in !== sc.in || p.out !== sc.out || p.kind !== sc.kind) throw Error('film-plan.json beat mismatch: ' + sc.id);
    if (sc.band && (p.announceStart !== sc.in || p.textSettled !== settledOf(sc) ||
        (p.demoStart ?? null) !== (sc.demo ?? null) || (p.demoEnd ?? null) !== (sc.demoEnd ?? null))) {
      throw Error('film-plan.json phase mismatch: ' + sc.id);
    }
    if (sc.band && (p.narration.kicker !== sc.band.kicker || p.narration.headline !== sc.band.head ||
        p.narration.sub !== sc.band.sub || (p.narration.footnote ?? null) !== (sc.band.foot ?? null))) {
      throw Error('film-plan.json narration mismatch: ' + sc.id);
    }
    const sig = list => JSON.stringify((list || []).map(k => [k.keys, k.label, k.cue, k.press, k.seq === true]));
    if (sig(sc.keys) !== sig(p.keys)) throw Error('film-plan.json key mismatch: ' + sc.id);
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
    // One PTY session per shot: identical grid and raster size, so normalized camera
    // rectangles glide between states without distorting the native cells.
    const grids = new Set(states.map(s => { const e = entryOf(s.asset); return gridOf(e).join('×') + '@' + e.width + '×' + e.height; }));
    if (grids.size !== 1) throw Error(`shot ${shot.id} mixes capture grids: ${[...grids].join(', ')}`);
    const el = document.createElement('div');
    el.className = 'frame' + (shot.tone === 'cool' ? ' cool' : '');
    el.dataset.shot = shot.id;
    el.innerHTML = '<div class="halo"></div><div class="clip"><div class="win"></div><div class="spot"></div></div><div class="edge"></div>' +
      '<svg class="run"><rect class="glow" fill="none" stroke="rgba(236,122,53,.55)" stroke-width="12" pathLength="1"/>' +
      '<rect class="core" fill="none" stroke="#ffe6c4" stroke-width="4" stroke-linecap="round" pathLength="1"/></svg>';
    const win = el.querySelector('.win');
    const img = {};
    for (const s of states) {
      if (img[s.asset]) continue;
      const e = entryOf(s.asset);
      img[s.asset] = await loadImage(assetSrc(e), e, s.asset);
      win.appendChild(img[s.asset]);
    }
    const seam = document.createElement('div');
    seam.className = 'seam';
    host.appendChild(el);
    host.appendChild(seam);
    const cams = [];
    states.forEach((s, i) => {
      // camDur 0 is an atomic camera cut together with the atomic state change.
      cams.push({at: s.at, roi: cameraRoiOf(s.asset, s.cam), dur: i === 0 ? 0 : (s.camDur ?? GLIDE)});
      for (const m of s.moves || []) cams.push({at: m.at, roi: cameraRoiOf(s.asset, m.cam), dur: m.dur || GLIDE});
    });
    const spots = [];
    states.forEach((s, i) => {
      const end = i + 1 < states.length ? states[i + 1].at : shot.to;
      for (const [name, from, to] of s.spots || []) {
        if (from < s.at || to > end || from >= to) throw Error(`spot ${name} lies outside its state ${s.asset} in ${shot.id}`);
        roiOf(s.asset, name); // registers any binding fallback before the first frame
        spots.push({name, from, to, asset: s.asset, bead: !s.noBead});
      }
    });
    M.shots.push({sc, shot, el, win, img, states, cams, spots, seam,
      spotEl: el.querySelector('.spot'), svg: el.querySelector('svg.run')});
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
  for (const id of ['bandA', 'bandB']) $(id).querySelector('.sub').innerHTML = '<span class="sa"></span>';
  const rows = $('rc-rows');
  EL.rows = RECAP.rows.map(([at, text], i) => {
    const r = document.createElement('div');
    r.className = 'rc-row';
    r.style.top = (378 + i * 96) + 'px';
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

const RECAP = SCENES.find(s => s.id === 'recap');
const OUTRO = SCENES.find(s => s.id === 'outro');

window.READY = (async () => {
  if (!/^revision-\d{2}$/.test(REVISION)) throw Error('revision must have the form revision-XX');
  validateTimeline();
  await fontsReady();
  await Promise.all([loadManifest(), checkPlan()]);
  await buildStatic();
  await buildShots();
  M.warnings = [...M.fallbacks].map(f => 'roi-fallback ' + f);
  renderFrame(0);
  return {revision: REVISION, frames: FRAMES, assets: Object.keys(M.entries).length,
    roiFallbacks: M.warnings, skippedOptional: M.skipped};
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
  $('lk-pos').style.transform = 'translate(960px,360px)';
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
  Object.assign($('lk-word-clip').style, {left: (960 - EL.wordW / 2) + 'px', top: '480px', height: '175px'});
  $('lk-word').style.transform = `translateY(${(1 - easeOut(ramp(f, 32, 50))) * 110}%)`;
  const meta = $('lk-meta'), pm = easeOut(ramp(f, 69, 80));
  Object.assign(meta.style, {left: (960 - EL.metaW / 2) + 'px', top: '684px', opacity: pm, transform: `translateY(${(1 - pm) * 16}px)`});
  const q = easeIO(ramp(f, 104, 130));
  lk.style.transformOrigin = '960px 430px';
  lk.style.transform = `translate(${(1700 - 960) * q}px,${(47 - 430) * q}px) scale(${1 - .8 * q})`;
  lk.style.opacity = 1 - ramp(f, 112, 130);
}

function bug(f) {
  const b = $('bug');
  const op = ramp(f, 118, 134) * (1 - ramp(f, OUTRO.in - 10, OUTRO.in));
  vis(b, op > 0);
  b.style.left = (1800 - EL.bugW) + 'px';
  b.style.opacity = op;
}

// Frame geometry for a shot at frame f: active asset, interpolated contextual ROI and a
// scale bounded by the box, 1 image px per CSS px and the calm FONT_MAX ceiling.
function camera(r, f) {
  let si = 0;
  for (let j = 0; j < r.states.length; j++) if (r.states[j].at <= f) si = j;
  const st = r.states[si];
  let ci = 0;
  for (let j = 0; j < r.cams.length; j++) if (r.cams[j].at <= f) ci = j;
  const cur = r.cams[ci], prev = r.cams[Math.max(0, ci - 1)];
  const p = ci === 0 || !cur.dur ? 1 : easeIO(ramp(f, cur.at, cur.at + cur.dur));
  const roi = cur.roi.map((v, n) => lerp(prev.roi[n], v, p));
  const glides = p < 1 && cur.roi.some((v, n) => Math.abs(v - prev.roi[n]) > 1e-6);
  const img = r.img[st.asset], IW = img.naturalWidth, IH = img.naturalHeight;
  const e = entryOf(st.asset), cols = Number(e.columns) || 0;
  const [bx, by, bw, bh] = BOXES[r.shot.box || 'default'];
  const m = MATTE;
  const rw = roi[2] * IW, rh = roi[3] * IH;
  const kFont = cols ? FONT_MAX * CELL_FONT / (IW / cols) : K_MAX;
  const k = Math.min((bw - 2 * m) / rw, (bh - 2 * m) / rh, K_MAX, kFont);
  const cw = rw * k, ch = rh * k;
  const fw = cw + 2 * m, fh = ch + 2 * m;
  const fx = bx + (bw - fw) / 2, fy = by + (bh - fh) / 2;
  return {si, st, roi, fx, fy, fw, fh, cw, ch, m, k, ox: roi[0] * IW, oy: roi[1] * IH, IW, IH,
    moving: glides, fontPx: cols ? (IW / cols) * k / CELL_FONT : null};
}
// Normalized asset rect → stage rect via a camera (same offsets as the image window).
function toStage(c, n) {
  return [c.fx + c.m + (n[0] * c.IW - c.ox) * c.k, c.fy + c.m + (n[1] * c.IH - c.oy) * c.k,
    n[2] * c.IW * c.k, n[3] * c.IH * c.k];
}

// How a shot leaves: a hard cut into the next shot of the same demo, or folding back
// into its seam so the next announcement plays on an empty stage.
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
  if (!on) { vis(r.spotEl, false); vis(r.svg, false); return null; }
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
  Object.assign(r.win.style, {left: c.m + 'px', top: c.m + 'px', width: c.cw + 'px', height: c.ch + 'px'});
  // Genuine captures switch atomically: only the active state is shown, fully opaque,
  // so native cells never blend across two screens.
  for (const [key, img] of Object.entries(r.img)) {
    const active = key === c.st.asset;
    vis(img, active);
    if (!active) continue;
    img.style.transform = `translate(${-c.ox * c.k}px,${-c.oy * c.k}px) scale(${c.k})`;
    img.style.opacity = 1;
  }
  // Spotlight: warm wash and dimmed surroundings on its own state's tight ROI.
  const sp = f < r.shot.to && open >= 1 ? r.spots.find(s => f >= s.from && f < s.to && s.asset === c.st.asset) : null;
  vis(r.spotEl, !!sp);
  let target = null;
  if (sp) {
    target = toStage(c, roiOf(c.st.asset, sp.name));
    // 10 px horizontal, 3 px vertical: the wash edge stays in the inter-row gap and never
    // slices the glyphs of the neighbouring row.
    const [x, y, w2, h] = target, padX = 10, padY = 3;
    const op = ramp(f, sp.from, sp.from + 6) * (1 - ramp(f, sp.to - 6, sp.to));
    Object.assign(r.spotEl.style, {left: (x - c.fx - padX) + 'px', top: (y - c.fy - padY) + 'px',
      width: (w2 + 2 * padX) + 'px', height: (h + 2 * padY) + 'px', opacity: op});
  }
  // One molten bead along the frame border on the closing-phrase attack.
  const runOn = !!r.shot.run && f >= DROP && f < DROP + 26;
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
  info.assets.push(...Object.keys(r.img).filter(k => shownEl(r.img[k])));
  const cam = {shot: r.shot.id, asset: c.st.asset, roi: c.roi.map(v => +v.toFixed(4)),
    frame: [c.fx, c.fy, c.fw, c.fh].map(v => +v.toFixed(1)), scale: +c.k.toFixed(4),
    fontPx: c.fontPx && +c.fontPx.toFixed(1), opacity: +opacity.toFixed(3),
    // Actual wrapper state: ROI glide, seam open/close clip, cut pop and fades all count as motion.
    moving: c.moving || shut > 0 || pop !== 1 || opacity < 1,
    wrapper: {scale: +pop.toFixed(4), clip: +shut.toFixed(4), opacity: +opacity.toFixed(4)},
    window: [c.fx + c.m, c.fy + c.m, c.cw, c.ch].map(v => +v.toFixed(1)), matte: c.m,
    spot: sp ? sp.name : null, target: target && target.map(v => +v.toFixed(1)), exit: w.mode};
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
    const kp = easeOut(ramp(f, s0 - 1, s0 + 7));
    const kick = el.querySelector('.kicker');
    kick.style.opacity = kp;
    kick.querySelector('i').style.transform = `scaleX(${kp})`;
    let settle = kp;
    const words = el.querySelectorAll('.head .w'), n = words.length;
    const stagger = n > 1 ? 4 / (n - 1) : 0;
    words.forEach((w, j) => {
      const w0 = s0 + j * stagger, p = easeOut(ramp(f, w0, w0 + 8));
      settle = Math.min(settle, p);
      w.style.opacity = p;
      w.style.transform = `translateY(${(1 - p) * 40}px)`;
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
  // A chord shows '+'; a typed sequence (seq) shows its keys side by side.
  const html = k.keys.map(x => `<span class="cap">${esc(x)}</span>`).join(k.seq ? '' : '<span class="plus">+</span>') +
    `<span class="act">${esc(k.label)}</span>`;
  if (chip.dataset.html !== html) { chip.innerHTML = html; chip.dataset.html = html; chip.classList.toggle('seq', !!k.seq); }
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
  info.keys = {keys: k.keys, label: k.label, cue: k.cue, press: k.press, seq: k.seq === true, pressed: f >= k.press};
}

// The ember lives in the editorial margin left of the frame and only travels vertically
// there, so it never sweeps across glyphs. It rests beside the spotlit row.
function beadTargets(sc) {
  const out = [];
  for (const r of M.shots.filter(x => x.sc === sc)) for (const s of r.spots) if (s.bead) out.push({r, ...s});
  return out.sort((a, b) => a.from - b.from);
}
function beadRest(tg, shots) {
  const d = shots.find(x => x.r === tg.r);
  if (!d || d.c.st.asset !== tg.asset) return null;
  const [, y, , h] = toStage(d.c, roiOf(tg.asset, tg.name));
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
  // Glide on from the previous rest only when it marked the same genuine state just before.
  const prevRest = prev && prev.r === tg.r && prev.asset === tg.asset && prev.to >= tg.from - 2 ? beadRest(prev, shots) : null;
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

function drawBurst(f, shots) {
  const el = $('burst');
  const on = f >= DROP && f < DROP + 26;
  vis(el, on);
  if (!on) return;
  const d = shots.find(x => x.r.shot.run);
  const cx = d ? d.c.fx + d.c.fw / 2 : 960, cy = d ? d.c.fy + d.c.fh / 2 : 660;
  el.style.transform = `translate(${cx}px,${cy}px)`;
  const p = ramp(f, DROP, DROP + 24);
  const ring = el.querySelector('.ring');
  ring.style.transform = `scale(${lerp(.35, 2.6, easeOut(p))})`;
  ring.style.opacity = Math.pow(1 - p, 1.3);
  el.querySelector('.heat').style.opacity = (f < DROP + 3 ? ramp(f, DROP, DROP + 2) : 1 - ramp(f, DROP + 3, DROP + 26)) * .85;
}

// ---------------------------------------------------------------- recap and outro
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
  // Elements stagger from the outro start so the flare still lands on the music stop.
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
    keys: (sc.keys || []).map(k => ({keys: k.keys, label: k.label, cue: k.cue, press: k.press, seq: k.seq === true}))};
}
function renderFrame(f) {
  const t = f / FPS;
  const sc = sceneAt(f);
  const info = {frame: f, t: +t.toFixed(4), scene: sc.id, beat: beatOf(sc, f), assets: [], cameras: [], text: {},
    textState: null, textMoving: false, keys: null, guide: null, warnings: []};
  atmosphere(f, t);
  intro(f, t);
  bug(f);
  const shots = M.shots.map(r => drawShot(r, f, info)).filter(Boolean);
  drawBands(f, info);
  drawKeys(f, sc, info);
  drawBead(f, sc, shots, info);
  drawBurst(f, shots);
  drawRecap(f, info);
  drawOutro(f, t);
  $('fade').style.opacity = ramp(f, FRAMES - 18, FRAMES - 1);
  // Native opacity binding: the visible genuine frames and their effective wrapper opacity.
  const visible = info.cameras.filter(c => c.opacity > 0 && c.wrapper.clip < 1);
  info.native = {visible: visible.length > 0, shots: visible.map(c => c.shot), assets: visible.map(c => c.asset),
    opacity: visible.length ? Math.max(...visible.map(c => c.opacity)) : 0};
  info.shots = shots;
  return info;
}
const frameOf = t => clamp(Math.round(t * FPS), 0, FRAMES - 1);

window.render = async t => {
  await window.READY;
  renderFrame(frameOf(t));
  return true;
};

// Inspection: beat phase, fixed narration, visible genuine assets, camera ROI and warnings.
// Semantic assertions: no UI during announce/read; narration fixed and settled during a
// demo; no headline/subline motion while a camera moves; legible native text.
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
  if (beat.kind !== 'feature' && visibleShots.length) warn.push(beat.kind + ' shows UI');
  if (beat.phase === 'demo') {
    if (info.textMoving) warn.push(`narration moving during demo (opacity ${info.textState?.opacity}, settle ${info.textState?.settle})`);
    if (info.text.headline !== beat.narration.headline || info.text.sub !== beat.narration.sub ||
        (info.text.footnote ?? null) !== beat.narration.footnote) warn.push('narration differs from fixed beat narration');
  }
  if (info.textMoving && info.cameras.some(c => c.moving && c.opacity > 0) && beat.phase !== 'exit') {
    warn.push('headline/subline motion overlaps a camera move');
  }
  if (info.band) {
    const words = [...info.band.querySelectorAll('.head .w')];
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
      if (keysOn && fr.right + 24 > box(keys).left && fr.top < box(keys).bottom) warn.push('footnote collides with key cue');
      for (const sh of visibleShots) if (fr.bottom + 8 > sh.c.fy) warn.push('footnote touches frame ' + sh.cam.shot);
    }
  }
  for (const sh of info.shots) {
    const c = sh.cam;
    if (c.frame[1] < 268) warn.push(`frame ${c.shot} rises into the headline band`);
    if (c.frame[0] < 0 || c.frame[1] < 0 || c.frame[0] + c.frame[2] > W || c.frame[1] + c.frame[3] > H) warn.push(`frame ${c.shot} leaves the stage`);
    if (c.fontPx && !c.moving && c.fontPx < FONT_MIN) warn.push(`native text ${c.fontPx}px in ${c.asset} (target 29–31, floor ${FONT_MIN})`);
    if (c.target && !c.moving) {
      const [x, y, w, h] = c.target, [wx, wy, ww, wh] = c.window;
      if (x < wx - .5 || y < wy - .5 || x + w > wx + ww + .5 || y + h > wy + wh + .5) {
        warn.push(`spotlit target ${c.spot} in ${c.asset} is cut by the camera window`);
      }
    }
  }
  if (info.guide && info.guide.frameLeft !== null && info.guide.at[0] + 33 > info.guide.frameLeft + MATTE) {
    warn.push('ember glow reaches native pixels');
  }
  if (shownEl($('recap'))) for (const row of EL.rows) if (box(row.el.querySelector('span')).right > 1800) warn.push('recap row overflows');
  const visible = new Set(info.assets);
  for (const fb of M.warnings) if ([...visible].some(a => fb.startsWith('roi-fallback ' + a + ':'))) warn.push(fb);
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
