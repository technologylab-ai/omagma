// Promo-only isolated CDP transport. All heavy use runs under resource_guard.py.
import {spawn, spawnSync} from 'node:child_process';
import {createServer} from 'node:http';
import {createReadStream, mkdtempSync, realpathSync, rmSync, statSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, extname, isAbsolute, join, relative, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

export const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const allowed = ['video/short0219/', 'video/cache/short0219/',
  'video/assets/omagma-logo-master.png', 'assets/omagma-logo.png'];
const types = {'.html':'text/html', '.js':'text/javascript', '.mjs':'text/javascript',
  '.css':'text/css', '.json':'application/json', '.png':'image/png', '.jpg':'image/jpeg',
  '.woff2':'font/woff2', '.woff':'font/woff', '.ttf':'font/ttf', '.otf':'font/otf', '.mp4':'video/mp4', '.m4a':'audio/mp4'};
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

export async function reservation() {
  const child = spawn(process.env.PYTHON || 'python3',
    [join(root, 'video/short0219/resource_guard.py'), 'verify'], {stdio:'inherit'});
  await new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', code => code === 0 ? resolve() : reject(Error('matching live host reservation required')));
  });
  if (process.env.OMAGMA_RESOURCE_GUARD !== 'short0219'
      || !/^\d+$/.test(process.env.OMAGMA_RESOURCE_GUARD_PID || '')) {
    throw Error('run this media stage through video/short0219/resource_guard.py run');
  }
  process.kill(Number(process.env.OMAGMA_RESOURCE_GUARD_PID), 0);
}

function processRows() {
  const result = spawnSync('/bin/ps', ['-axo','pid=,ppid=,pgid='], {encoding:'utf8', timeout:3000});
  if (result.status !== 0) return new Map();
  return new Map(result.stdout.trim().split('\n').filter(Boolean).map(line => {
    const [pid, ppid, pgid] = line.trim().split(/\s+/).map(Number);
    return [pid, {pid, ppid, pgid}];
  }));
}

export async function browser({scale=1} = {}) {
  if (!Number.isFinite(scale) || scale < .1 || scale > 2) throw Error('browser scale must be .1–2');
  await reservation();
  const server = createServer((req, res) => {
    if (!['GET','HEAD'].includes(req.method)) { res.writeHead(405); res.end(); return; }
    let file;
    try {
      const path = decodeURIComponent(new URL(req.url, 'http://localhost').pathname).replace(/^\/+/, '');
      file = realpathSync(resolve(root, path));
      const name = relative(root, file).split('\\').join('/');
      if (name.startsWith('..') || isAbsolute(name)
          || !allowed.some(item => name === item || (item.endsWith('/') && name.startsWith(item)))) throw Error('outside media allowlist');
      const metadata = statSync(file);
      if (!metadata.isFile() || metadata.size > 64 * 1024 * 1024) throw Error('invalid media asset');
      res.writeHead(200, {'content-type':types[extname(file)] || 'application/octet-stream',
        'content-length':metadata.size, 'cache-control':'no-store'});
      if (req.method === 'HEAD') res.end();
      else {
        const stream = createReadStream(file);
        stream.on('error', () => res.destroy());
        res.on('close', () => stream.destroy());
        stream.pipe(res);
      }
    } catch { res.writeHead(404); res.end(); }
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const origin = `http://127.0.0.1:${server.address().port}`;
  const profile = mkdtempSync(join(tmpdir(), 'omagma-short0219-chrome-'));
  const chrome = spawn(process.env.CHROMIUM || '/usr/bin/chromium', [
    '--headless', '--remote-debugging-pipe', `--user-data-dir=${profile}`,
    '--no-first-run', '--no-default-browser-check', '--disable-default-apps',
    '--disable-extensions', '--disable-background-networking', '--disable-component-update',
    '--disable-sync', '--mute-audio', '--hide-scrollbars', '--disable-gpu',
    '--num-raster-threads=1', '--renderer-process-limit=1', '--font-render-hinting=none',
    '--force-color-profile=srgb', `--force-device-scale-factor=${scale}`, '--disable-renderer-backgrounding',
    '--disable-background-timer-throttling', '--disable-backgrounding-occluded-windows', 'about:blank'
  ], {stdio:['ignore','ignore','pipe','pipe','pipe'],
    // Keep Chrome and renderers inside the resource guard's isolated group.
    detached:false,
    env:{...process.env, DISPLAY:'', WAYLAND_DISPLAY:'', DBUS_SESSION_BUS_ADDRESS:''}});
  const waiting = new Map(), listeners = new Set();
  let nextId = 0, buffer = '', gone = null, log = '', active = null, closing;
  const knownChrome = new Map();
  function rememberChrome() {
    const rows = processRows(), selected = new Set(chrome.pid ? [chrome.pid] : []);
    let changed = true;
    while (changed) {
      changed = false;
      for (const row of rows.values()) if (!selected.has(row.pid) && selected.has(row.ppid)) {
        selected.add(row.pid); changed = true;
      }
    }
    for (const pid of selected) if (rows.has(pid)) knownChrome.set(pid, rows.get(pid).pgid);
  }
  function signalChrome(signal) {
    const rows = processRows();
    for (const [pid, group] of knownChrome) if (rows.get(pid)?.pgid === group) {
      try { process.kill(pid, signal); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    }
  }
  function rejectAll(reason) {
    gone = reason;
    for (const pending of waiting.values()) pending.reject(Error(reason));
    waiting.clear();
  }
  chrome.on('error', error => rejectAll(error.message));
  chrome.on('exit', (code, signal) => rejectAll(`owned Chrome exited ${signal || code}`));
  chrome.stderr.on('data', chunk => { log = (log + chunk).slice(-5000); });
  chrome.stdio[3].on('error', () => rejectAll('owned Chrome command pipe closed'));
  chrome.stdio[4].on('error', () => rejectAll('owned Chrome event pipe closed'));
  chrome.stdio[4].setEncoding('utf8');
  chrome.stdio[4].on('data', chunk => {
    buffer += chunk;
    if (buffer.length > 48 * 1024 * 1024) { rejectAll('CDP response exceeded media bound'); return; }
    let end;
    while ((end = buffer.indexOf('\0')) >= 0) {
      let message;
      try { message = JSON.parse(buffer.slice(0, end)); }
      catch { rejectAll('malformed owned Chrome response'); return; }
      buffer = buffer.slice(end + 1);
      if (message.id && waiting.has(message.id)) {
        const pending = waiting.get(message.id); waiting.delete(message.id);
        message.error ? pending.reject(Error(message.error.message)) : pending.resolve(message.result);
      } else for (const listener of listeners) listener(message);
    }
  });
  function send(method, params = {}, sessionId, timeout = 30000) {
    if (gone) return Promise.reject(Error(gone));
    const id = ++nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { waiting.delete(id); reject(Error(`${method} timed out`)); }, timeout);
      waiting.set(id, {resolve:value => {clearTimeout(timer); resolve(value);},
        reject:error => {clearTimeout(timer); reject(error);}});
      chrome.stdio[3].write(JSON.stringify({id, method, params, ...(sessionId ? {sessionId} : {})}) + '\0', error => {
        if (error) { const pending = waiting.get(id); waiting.delete(id); pending?.reject(error); }
      });
    });
  }
  async function close() {
    if (closing) return closing;
    closing = (async () => {
      rememberChrome();
      if (!gone) await send('Browser.close', {}, undefined, 3000).catch(() => {});
      const exited = () => chrome.exitCode !== null || chrome.signalCode !== null;
      for (const signal of ['SIGTERM','SIGKILL']) {
        if (exited()) break;
        signalChrome(signal);
        const deadline = Date.now() + (signal === 'SIGTERM' ? 3000 : 1000);
        while (!exited() && Date.now() < deadline) await delay(25);
      }
      // Only identity/group-bound Chrome descendants are affected. The outer
      // guard also sweeps its owned tree before releasing the reservation.
      signalChrome('SIGTERM');
      await delay(30);
      signalChrome('SIGKILL');
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
      rmSync(profile, {recursive:true, force:true});
    })();
    return closing;
  }
  async function page(path, {width=1920, height=1080, scale=1, ready=true} = {}) {
    if (active) throw Error('short0219 permits one active page only; close or reuse it first');
    const targets = await send('Target.getTargets');
    const pages = targets.targetInfos.filter(target => target.type === 'page');
    const targetId = pages.length ? pages[0].targetId : (await send('Target.createTarget', {url:'about:blank'})).targetId;
    for (const extra of pages.slice(1)) await send('Target.closeTarget', {targetId:extra.targetId});
    const {sessionId} = await send('Target.attachToTarget', {targetId, flatten:true});
    active = targetId;
    const call = (method, params={}, timeout) => send(method, params, sessionId, timeout);
    const errors = [], requests = [];
    const listener = message => {
      if (message.sessionId !== sessionId) return;
      if (message.method === 'Runtime.exceptionThrown') errors.push(message.params.exceptionDetails?.exception?.description || message.params.exceptionDetails.text);
      if (message.method === 'Fetch.requestPaused') {
        const url = message.params.request.url;
        const method = url.startsWith(origin + '/') || url.startsWith('data:') ? 'Fetch.continueRequest' : 'Fetch.failRequest';
        if (requests.length < 128) requests.push({url:url.startsWith('data:') ? url.split(',')[0] : url.slice(0, 512), allowed:method === 'Fetch.continueRequest'});
        call(method, {requestId:message.params.requestId,
          ...(method === 'Fetch.failRequest' ? {errorReason:'BlockedByClient'} : {})}).catch(error => errors.push(error.message));
      }
    };
    listeners.add(listener);
    await call('Page.enable'); await call('Runtime.enable');
    await call('Fetch.enable', {patterns:[{urlPattern:'*'}]});
    await call('Emulation.setDeviceMetricsOverride', {width, height, deviceScaleFactor:scale, mobile:false});
    await call('Emulation.setEmulatedMedia', {features:[{name:'prefers-color-scheme', value:'light'}]});
    const loaded = new Promise((resolve, reject) => {
      const onLoad = message => {
        if (message.sessionId === sessionId && message.method === 'Page.loadEventFired') {
          clearTimeout(timer); listeners.delete(onLoad); resolve();
        }
      };
      const timer = setTimeout(() => {listeners.delete(onLoad); reject(Error('media page load timed out'));}, 30000);
      listeners.add(onLoad);
    });
    await call('Page.navigate', {url:origin + '/' + path.replace(/^\/+/, '')});
    await loaded;
    const evaluate = async expression => {
      const result = await call('Runtime.evaluate', {expression, awaitPromise:true, returnByValue:true}, 45000);
      if (result.exceptionDetails) throw Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
      return result.result.value;
    };
    const info = ready
      ? await evaluate('(()=>{if(!window.READY||typeof window.READY.then!=="function")throw Error("window.READY promise required");return window.READY;})()')
      : await evaluate('Promise.all([document.fonts.ready,...Array.from(document.images).map(i=>i.complete?(i.naturalWidth?Promise.resolve():Promise.reject(Error("image failed"))):new Promise((r,j)=>{i.onload=r;i.onerror=()=>j(Error("image failed"));}))])');
    return {call, evaluate, info, errors, requests,
      close:async () => {listeners.delete(listener); await send('Target.closeTarget', {targetId}); active = null;},
      screenshot:async (format='png', quality=94) => {
        if (errors.length) throw Error(errors.join('\n'));
        const result = await call('Page.captureScreenshot', {format,
          ...(format === 'jpeg' ? {quality} : {}), optimizeForSpeed:true, fromSurface:true, captureBeyondViewport:false});
        return Buffer.from(result.data, 'base64');
      }};
  }
  return {page, close, call:send, origin, log:() => log};
}
