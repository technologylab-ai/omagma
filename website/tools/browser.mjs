// Isolated browser support for public-site QA and synthetic social artwork.
// No debugging socket, existing browser profile, desktop or live account is used.
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtemp, readFile, realpath, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.png': 'image/png', '.gif': 'image/gif', '.svg': 'image/svg+xml', '.webp': 'image/webp' };

export async function reservation() {
  if (!process.env.HOST_TOKEN) throw Error('A delegated HOST_TOKEN is required; this tool never acquires or releases its coordinator’s reservation.');
  const child = spawn('python3', [path.join(root, 'video/tools/host_lock.py'), 'verify', process.env.HOST_TOKEN], { stdio: ['ignore', 'ignore', 'pipe'] });
  let error = '';
  child.stderr.on('data', data => { error = (error + data).slice(-2000); });
  await new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', code => code === 0 ? resolve() : reject(Error(error.trim() || 'Matching live host reservation required')));
  });
}

// Materialize only individually reviewed files. Real paths must remain under
// their declared root; a directory traversal or symlink cannot widen the server.
export async function fileAsset(filename, directory) {
  const [actual, parent] = await Promise.all([realpath(filename), realpath(directory)]);
  const relative = path.relative(parent, actual);
  if (!relative || relative.startsWith('..') || path.isAbsolute(relative) || !(await stat(actual)).isFile()) throw Error('Public asset escapes its declared directory');
  return { data: await readFile(actual), type: types[path.extname(actual)] || 'application/octet-stream' };
}

export async function browser(assets) {
  await reservation();
  if (!(assets instanceof Map) || !assets.size) throw Error('An explicit public asset map is required');
  const requests = [], blocked = [], errors = [], waiting = new Map(), listeners = new Set();
  let profile, chrome, origin, buffer = '', nextId = 0, gone, closing, diagnostics = '';
  const server = createServer((req, res) => {
    let url;
    try { url = new URL(req.url, origin); } catch { res.writeHead(400).end(); return; }
    const entry = assets.get(url.pathname);
    requests.push({ path: url.pathname, status: entry ? 200 : 404 });
    if (req.headers.host !== new URL(origin).host || !['GET', 'HEAD'].includes(req.method) || !entry) { res.writeHead(404).end(); return; }
    res.writeHead(200, {
      'content-type': entry.type, 'content-length': entry.data.length, 'cache-control': 'no-store',
      'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer',
      'content-security-policy': "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'",
    });
    res.end(req.method === 'HEAD' ? undefined : entry.data);
  });
  const rejectAll = reason => { gone = reason; for (const pending of waiting.values()) pending.reject(Error(reason)); waiting.clear(); };
  const send = (method, params = {}, sessionId, timeout = 15000) => {
    if (gone) return Promise.reject(Error(gone));
    const id = ++nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { waiting.delete(id); reject(Error(`${method} timed out`)); }, timeout);
      waiting.set(id, { resolve: value => { clearTimeout(timer); resolve(value); }, reject: error => { clearTimeout(timer); reject(error); } });
      chrome.stdio[3].write(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }) + '\0', error => { if (error) rejectAll('Owned browser pipe closed'); });
    });
  };
  async function close() {
    if (closing) return closing;
    closing = (async () => {
      if (chrome && !gone) await send('Browser.close', {}, undefined, 2000).catch(() => {});
      if (chrome?.pid) {
        // Chromium renderer children share this newly owned process group.
        // Signal the group even if its leader already exited during Browser.close.
        for (const signal of ['SIGTERM', 'SIGKILL']) {
          try { process.kill(-chrome.pid, signal); } catch (error) { if (error.code !== 'ESRCH') throw error; }
          if (chrome.exitCode === null && chrome.signalCode === null) await Promise.race([new Promise(resolve => chrome.once('exit', resolve)), delay(signal === 'SIGTERM' ? 1500 : 1000)]);
        }
      }
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
      if (profile) await rm(profile, { recursive: true, force: true });
      process.off('SIGINT', interrupt); process.off('SIGTERM', terminate);
    })();
    return closing;
  }
  const interrupt = () => { void close().finally(() => process.exit(130)); };
  const terminate = () => { void close().finally(() => process.exit(143)); };
  try {
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
    origin = `http://127.0.0.1:${server.address().port}`;
    profile = await mkdtemp(path.join(tmpdir(), 'omagma-public-site-browser-'));
    chrome = spawn(process.env.CHROMIUM || '/usr/bin/chromium', [
      '--headless', '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check',
      '--disable-extensions', '--disable-background-networking', '--disable-sync', '--disable-component-update',
      '--disable-default-apps', '--mute-audio', '--font-render-hinting=none', '--force-color-profile=srgb',
      '--proxy-server=127.0.0.1:9', '--proxy-bypass-list=127.0.0.1', '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1',
      'about:blank',
    ], { detached: true, stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], env: { ...process.env, DISPLAY: '', WAYLAND_DISPLAY: '', DBUS_SESSION_BUS_ADDRESS: '' } });
    process.once('SIGINT', interrupt); process.once('SIGTERM', terminate);
    chrome.on('error', error => rejectAll(error.message));
    chrome.on('exit', (code, signal) => rejectAll(`Owned Chromium exited (${signal || code})`));
    chrome.stderr.on('data', data => { diagnostics = (diagnostics + data).slice(-6000); });
    chrome.stdio[3].on('error', () => rejectAll('Owned browser command pipe closed'));
    chrome.stdio[4].on('error', () => rejectAll('Owned browser result pipe closed'));
    chrome.stdio[4].setEncoding('utf8');
    chrome.stdio[4].on('data', chunk => {
      buffer += chunk;
      let end;
      while ((end = buffer.indexOf('\0')) >= 0) {
        let message;
        try { message = JSON.parse(buffer.slice(0, end)); } catch { rejectAll('Invalid owned browser protocol message'); return; }
        buffer = buffer.slice(end + 1);
        if (message.id && waiting.has(message.id)) {
          const pending = waiting.get(message.id); waiting.delete(message.id);
          message.error ? pending.reject(Error(message.error.message)) : pending.resolve(message.result);
        } else for (const listener of listeners) listener(message);
      }
    });
    // A cold CI browser may spend longer starting than an ordinary CDP call.
    await send('Browser.getVersion', {}, undefined, 45000);
  } catch (error) {
    await close();
    throw new Error(`${error.message}${diagnostics ? '\nOwned Chromium diagnostics: ' + diagnostics : ''}`, { cause: error });
  }

  async function page(route, { width = 1440, height = 1080, reducedMotion = false } = {}) {
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
    const call = (method, params = {}, timeout) => send(method, params, sessionId, timeout);
    const pageErrors = [];
    const listener = message => {
      if (message.sessionId !== sessionId) return;
      if (message.method === 'Runtime.exceptionThrown') {
        const detail = message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text;
        errors.push(detail); pageErrors.push(detail);
      }
      if (message.method === 'Fetch.requestPaused') {
        const { requestId, request } = message.params;
        let allowed = false;
        try { const url = new URL(request.url); allowed = url.origin === origin && assets.has(url.pathname); } catch {}
        if (!allowed) blocked.push(request.url.startsWith(origin) ? new URL(request.url).pathname : request.url.split('?')[0]);
        void call(allowed ? 'Fetch.continueRequest' : 'Fetch.failRequest', { requestId, ...(allowed ? {} : { errorReason: 'BlockedByClient' }) }).catch(() => {});
      }
    };
    listeners.add(listener);
    const evaluate = async expression => {
      const result = await call('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, 30000);
      if (result.exceptionDetails) throw Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
      return result.result.value;
    };
    await call('Page.enable'); await call('Runtime.enable');
    await call('Fetch.enable', { patterns: [{ urlPattern: '*' }] });
    await call('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: width < 500 });
    await call('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: reducedMotion ? 'reduce' : 'no-preference' }] });
    // Exercise the real copy handler against an in-page clipboard. Neither
    // success nor fallback can replace the shared desktop's clipboard contents.
    await call('Page.addScriptToEvaluateOnNewDocument', { source: "Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async text=>{if(window.__qaClipboardReject)throw Error('QA clipboard denied');window.__qaCopied=text;}}});" });
    const loaded = new Promise((resolve, reject) => {
      const ready = message => {
        if (message.sessionId !== sessionId || message.method !== 'Page.loadEventFired') return;
        clearTimeout(timer); listeners.delete(ready); resolve();
      };
      const timer = setTimeout(() => { listeners.delete(ready); reject(Error('Page load timed out')); }, 15000);
      listeners.add(ready);
    });
    await call('Page.navigate', { url: origin + route });
    await loaded;
    await evaluate("(async()=>{await document.fonts.ready;for(const image of document.images)image.loading='eager';await Promise.all([...document.images].map(image=>image.decode().catch(()=>null)));await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));})()");
    return {
      call, evaluate, errors: pageErrors,
      key: async key => {
        const virtual = { Enter: 13, Escape: 27, ArrowLeft: 37, ArrowRight: 39, ArrowDown: 40, Tab: 9 }[key] || 0;
        const event = { key, code: key, windowsVirtualKeyCode: virtual, nativeVirtualKeyCode: virtual };
        await call('Input.dispatchKeyEvent', { type: 'keyDown', ...event, ...(key === 'Enter' ? { text: '\r', unmodifiedText: '\r' } : {}) });
        await call('Input.dispatchKeyEvent', { type: 'keyUp', ...event });
      },
      screenshot: async (full = false) => {
        const size = full ? (await call('Page.getLayoutMetrics')).cssContentSize : null;
        const result = await call('Page.captureScreenshot', { format: 'png', captureBeyondViewport: full, ...(full ? { clip: { x: 0, y: 0, width, height: Math.ceil(size.height), scale: 1 } } : {}) });
        return Buffer.from(result.data, 'base64');
      },
      close: async () => { listeners.delete(listener); await send('Target.closeTarget', { targetId }); },
    };
  }
  return { origin, page, close, requests, blocked, errors, diagnostics: () => diagnostics };
}
