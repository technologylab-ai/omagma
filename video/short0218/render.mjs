// Deterministic frame driver only; actual Opus authors film design and copy.
import {createHash} from 'node:crypto';
import {existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync} from 'node:fs';
import {dirname, isAbsolute, join, relative, resolve} from 'node:path';
import {parseArgs} from 'node:util';
import {browser, reservation, root} from './cdp.mjs';

const {values:options} = parseArgs({options:{
  stills:{type:'string'}, out:{type:'string'}, scale:{type:'string', default:'1'},
  workers:{type:'string', default:'1'}, step:{type:'string', default:'1'},
  from:{type:'string', default:'0'}, to:{type:'string'},
  revision:{type:'string', default:'revision-27'}
}});
if (!/^revision-\d{2}$/.test(options.revision)) throw Error('revision must have the form revision-XX');
const FRAMES = 2527;
const scale = Number(options.scale), workers = Number(options.workers), step = Number(options.step);
if (!(scale >= .1 && scale <= 2 && workers === 1 && Number.isInteger(step) && step >= 1 && step <= FRAMES)) {
  throw Error(`scale must be .1–2, workers must be 1, and step must be an integer 1–${FRAMES}`);
}
await reservation();
const digest = path => createHash('sha256').update(readFileSync(join(root, path))).digest('hex');
const sourceFiles = Object.fromEntries(['film.html','film.css','film.js','film-plan.json',
  ...readdirSync(join(root, 'video/short0218')).filter(name => /^timeline\.(json|mjs|js)$/.test(name))]
  .map(name => ['video/short0218/' + name, digest('video/short0218/' + name)]));
const manifest = name => {
  const path = `video/cache/short0218/${options.revision}/${name}`;
  return {path, sha256:digest(path)};
};
const captureManifest = manifest('capture-manifest.json'), assetsManifest = manifest('assets-manifest.json');
const sourceSha256 = sourceFiles['video/short0218/film.html'];
const out = resolve(options.out || join(root, 'video/cache/short0218', options.revision, options.stills ? 'stills' : 'frames'));
const bases = [join(root, 'video/cache/short0218'), join(root, 'video/out/short0218')];
if (!bases.some(base => {
  const name = relative(base, out);
  return name && !name.startsWith('..') && !isAbsolute(name);
})) throw Error('output must be an owned short0218 cache/out subdirectory');
for (let path = out; path !== root; path = dirname(path)) {
  if (existsSync(path) && lstatSync(path).isSymbolicLink()) throw Error('render output must not traverse symlinks');
}
const marker = join(out, '.short0218-render');
if (existsSync(out) && readdirSync(out).length) {
  if (!existsSync(marker) || readFileSync(marker, 'utf8') !== 'owned short0218 media output\n') {
    throw Error('refuse to replace an unowned directory');
  }
  rmSync(out, {recursive:true});
}
mkdirSync(out, {recursive:true, mode:0o700});
writeFileSync(marker, 'owned short0218 media output\n');
const engine = await browser({scale});
const started = Date.now();
let completed = 0;
const audits = [];
try {
  // One page and one raster worker. Parallel promises never render frames.
  const page = await engine.page('video/short0218/film.html?revision=' + encodeURIComponent(options.revision),
    {width:1920, height:1080, scale});
  const film = await page.evaluate('window.FILM');
  if (!film || film.fps !== 30 || film.width !== 1920 || film.height !== 1080
      || !Number.isFinite(film.duration) || Math.round(film.duration * film.fps) !== FRAMES) {
    throw Error('expected 1920×1080 at 30fps, 2527 frames (~84.233s)');
  }
  const first = Math.round(Number(options.from) * 30);
  const last = options.to === undefined ? FRAMES : Math.round(Number(options.to) * 30);
  if (!Number.isInteger(first) || !Number.isInteger(last) || first < 0 || last > FRAMES || first >= last) {
    throw Error('invalid half-open frame range');
  }
  const times = options.stills
    ? options.stills.split(',').map(Number)
    : Array.from({length:Math.ceil((last - first) / step)}, (_, index) => (first + index * step) / 30);
  if (!times.length || times.some(time => !Number.isFinite(time) || time < 0 || time >= film.duration)) {
    throw Error('invalid frame times');
  }
  const names = times.map((time, index) => options.stills
    ? `t${time.toFixed(3).padStart(7, '0')}.png`
    : `${String(first + index * step).padStart(5, '0')}.jpg`);
  if (new Set(names).size !== names.length) throw Error('frame times resolve to duplicate filenames');
  for (let index = 0; index < times.length; index++) {
    const time = times[index];
    await page.evaluate(`(async()=>{if(typeof window.render!=="function")throw Error("window.render required");await window.render(${JSON.stringify(time)});await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));return true;})()`);
    writeFileSync(join(out, names[index]), await page.screenshot(options.stills ? 'png' : 'jpeg'));
    if (options.stills) audits.push(await page.evaluate('window.qa(' + JSON.stringify(time) + ')'));
    completed++;
    if (completed % 150 === 0) console.log(`${completed}/${times.length} frames`);
  }
  for (const [path, sha256] of Object.entries(sourceFiles)) {
    if (digest(path) !== sha256) throw Error('film source changed during render: ' + path);
  }
  for (const item of [captureManifest, assetsManifest]) {
    if (digest(item.path) !== item.sha256) throw Error('capture manifest changed during render: ' + item.path);
  }
  writeFileSync(join(out, 'render.json'), JSON.stringify({
    schema:'omagma.video.render.v1', passed:true, film, sourceSha256, sourceFiles,
    revision:options.revision, captureManifest, assetsManifest,
    count:times.length, scale, pixelWidth:Math.round(1920 * scale), pixelHeight:Math.round(1080 * scale),
    step, firstFrame:first, endFrame:last, workers:1, times, files:names, wallSeconds:(Date.now() - started) / 1000
  }, null, 2) + '\n');
  if (options.stills) writeFileSync(join(out, 'qa.json'), JSON.stringify(audits, null, 2) + '\n');
  console.log(`Rendered ${times.length} ${options.stills ? 'stills' : 'frames'} sequentially.`);
} catch (error) {
  writeFileSync(join(out, 'render-failed.json'), JSON.stringify({passed:false, sourceSha256, sourceFiles,
    revision:options.revision, captureManifest, assetsManifest,
    completed, error:String(error), wallSeconds:(Date.now() - started) / 1000}, null, 2) + '\n');
  throw error;
} finally {
  await engine.close();
}
