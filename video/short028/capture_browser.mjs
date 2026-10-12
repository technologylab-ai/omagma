#!/usr/bin/env node
// Media-only capture of the shared Zig/WASM App, using an owned headless CDP
// pipe/profile. Only loopback static assets reach a server; fixed Google URLs
// are fulfilled by synthetic fixtures before network. No desktop/live profile.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {createServer} from 'node:http';
import {mkdir, mkdtemp, readFile, writeFile, rm, realpath} from 'node:fs/promises';
import {dirname, extname, join, relative, resolve, sep} from 'node:path';
import {fileURLToPath} from 'node:url';
import {performance} from 'node:perf_hooks';
import {reservation} from '../short027/cdp.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const cacheRoot = join(root, 'video/cache/short028/browser');
const pause = milliseconds => new Promise(accept => setTimeout(accept, milliseconds));
const sha256 = value => createHash('sha256').update(value).digest('hex');
const hashParts = parts => sha256(parts.map(part => part + '\0').join(''));
const accounts = ['alex@example.com', 'studio@example.com', 'team@example.com'];
const owners = ['Alex', 'Studio', 'Team'];
const scopes = ['https://www.googleapis.com/auth/gmail.modify'];
const clientId = 'fictional-film-client.apps.googleusercontent.com';
const clientSecret = 'SYNTHETIC_FILM_CLIENT_SECRET_NEVER_VALID';
const refreshTokens = accounts.map((_, index) => `SYNTHETIC_FILM_REFRESH_${index}_NEVER_VALID`);
const accessTokens = accounts.map((_, index) => `SYNTHETIC_FILM_ACCESS_${index}_NEVER_VALID`);
const secrets = [clientSecret, ...refreshTokens, ...accessTokens];
const note = 'See you Friday.';
const subjects = [
  ['Friday plans — see you at 10', 'A few photos from the weekend', 'Book club: next Thursday', 'Your workshop notes', 'Lunch next week?'],
  ['Studio — design review', 'Autumn palette: final notes', 'Workshop schedule', 'A new project brief', 'Friday walkthrough'],
  ['Team — release checklist', 'Demo rehearsal at 14:00', 'This week in the studio', 'Documentation review', 'A quick thank you'],
];
const bodies = [
  'Hi Alex,\n\nHere is our Friday plan:\n\n10:00  Studio walkthrough\n10:30  Demo review\n12:00  Lunch with the team\n\nSee you Friday!\nMorgan\n',
  'Hi team,\n\nThe autumn palette is ready for review.\nWarm orange, calm blue, and plenty of room to read.\n\nPlease bring your notes on Friday.\nSam\n',
  'Hello everyone,\n\nThe release checklist is ready:\n• Review the demo\n• Check the documentation\n• Save the final notes\n\nThanks for the careful work.\nMorgan\n',
];
const originalHtml = '<html><body><h2>Friday plan</h2><p>Hi Alex,</p><table style="border-collapse:collapse;width:100%"><tr><th style="text-align:left;padding:8px;background:#eef3e8">Time</th><th style="text-align:left;padding:8px;background:#eef3e8">Together</th></tr><tr><td style="padding:8px">10:00</td><td style="padding:8px">Studio walkthrough</td></tr><tr><td style="padding:8px">10:30</td><td style="padding:8px">Demo review</td></tr><tr><td style="padding:8px">12:00</td><td style="padding:8px">Lunch with the team</td></tr></table><p>See you Friday!<br>Morgan</p></body></html>';

function parseArgs() {
  if (process.argv.includes('--help')) {
    console.log('Usage: HOST_TOKEN=… node video/short028/capture_browser.mjs --site-dir ABS --expected-wasm-sha256 HEX --source-revision REV [--expected-app-sha256 HEX] [--output-dir video/cache/short028/browser/TAKE] [--width 1440] [--height 900] [--fps 12] [--duration 14] [--chromium /usr/bin/chromium]');
    return null;
  }
  const allowed = new Set(['--site-dir', '--expected-wasm-sha256', '--expected-app-sha256', '--source-revision', '--output-dir', '--width', '--height', '--fps', '--duration', '--chromium']);
  const values = new Map();
  for (let index = 2; index < process.argv.length; index += 2) {
    const key = process.argv[index], value = process.argv[index + 1];
    assert(allowed.has(key) && value && !values.has(key), `Invalid capture option ${key}`);
    values.set(key, value);
  }
  for (const key of ['--site-dir', '--expected-wasm-sha256', '--source-revision']) assert(values.has(key), `${key} required for immutable capture provenance`);
  for (const key of ['--expected-wasm-sha256', '--expected-app-sha256']) if (values.has(key)) assert(/^[a-f0-9]{64}$/.test(values.get(key)), `${key} must be a full SHA-256`);
  assert(/^[a-f0-9]{7,40}$/.test(values.get('--source-revision')), 'Source revision must be a commit identity');
  const options = {site: resolve(values.get('--site-dir')), wasmSha: values.get('--expected-wasm-sha256'), appSha: values.get('--expected-app-sha256'), revision: values.get('--source-revision'),
    output: resolve(values.get('--output-dir') || join(cacheRoot, `take-${Date.now()}`)), width: Number(values.get('--width') || 1440), height: Number(values.get('--height') || 900),
    fps: Number(values.get('--fps') || 12), duration: Number(values.get('--duration') || 14), chromium: values.get('--chromium') || process.env.CHROMIUM || '/usr/bin/chromium'};
  assert(options.output.startsWith(cacheRoot + sep), 'Capture output must be a new ignored browser take directory');
  assert(Number.isInteger(options.width) && options.width >= 1200 && options.width <= 2200 && Number.isInteger(options.height) && options.height >= 800 && options.height <= 1400, 'Film viewport is out of bounds');
  assert(Number.isInteger(options.fps) && options.fps >= 6 && options.fps <= 24, 'Frame rate is out of bounds');
  assert(options.duration >= 14 && options.duration <= 15, 'Continuous take must be 14–15 seconds');
  return options;
}

function providerMessage(accountIndex, index, format) {
  assert(index >= 0 && index < 5, 'Unknown fictional message');
  const id = `film-${accountIndex}-${index}`;
  const plain = index === 0 ? bodies[accountIndex] : `Hi ${owners[accountIndex]},\n\nA short fictional update for ${subjects[accountIndex][index]}.\nMore details on Friday.\n\nSam\n`;
  const headers = [{name: 'From', value: index % 2 ? 'Sam Rivera <sam@example.org>' : 'Morgan Chen <morgan@example.org>'},
    {name: 'To', value: accounts[accountIndex]}, {name: 'Subject', value: subjects[accountIndex][index]},
    {name: 'Message-ID', value: `<${id}@example.org>`}, {name: 'Date', value: 'Mon, 12 Oct 2026 10:00:00 +0000'},
    {name: 'References', value: '<fictional-prior-thread@example.org>'}];
  const payload = {partId: '', mimeType: accountIndex === 0 && index === 0 ? 'multipart/alternative' : 'text/plain', filename: '', headers};
  if (format !== 'metadata') {
    const leaf = (partId, mimeType, body) => ({partId, mimeType, filename: '', headers: [{name: 'Content-Type', value: `${mimeType}; charset=utf-8`}, {name: 'Content-Transfer-Encoding', value: 'base64'}], body: {size: Buffer.byteLength(body), data: Buffer.from(body).toString('base64url')}});
    if (payload.mimeType === 'multipart/alternative') payload.parts = [leaf('0', 'text/plain', plain), leaf('1', 'text/html', originalHtml)];
    else payload.body = {size: Buffer.byteLength(plain), data: Buffer.from(plain).toString('base64url')};
  } else payload.body = {size: 0};
  return {id, threadId: `thread-${id}`, labelIds: index === 0 ? ['INBOX', 'UNREAD', 'STARRED'] : ['INBOX'], internalDate: String(1791802800000 - index * 60000),
    historyId: '1200', snippet: index === 0 ? 'Here is our Friday plan. See you soon.' : 'A short note for the week ahead.', sizeEstimate: 1600, payload};
}

async function ownedBrowser(options, output) {
  const site = await realpath(options.site), requests = [], blocked = [], transportErrors = [], errors = [], staticRequests = [], networkReplies = [];
  const mime = {'.html': 'text/html; charset=utf-8', '.mjs': 'text/javascript', '.js': 'text/javascript', '.css': 'text/css', '.wasm': 'application/wasm', '.png': 'image/png', '.svg': 'image/svg+xml', '.woff2': 'font/woff2'};
  const server = createServer(async (request, response) => {
    try {
      const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
      const file = resolve(site, '.' + (pathname === '/' ? '/index.html' : pathname));
      assert(file.startsWith(site + sep), 'Static request escaped immutable site');
      assert((await realpath(file)).startsWith(site + sep), 'Static symlink escaped immutable site');
      const bytes = await readFile(file);
      staticRequests.push(pathname);
      response.writeHead(200, {'content-type': mime[extname(file)] || 'application/octet-stream', 'cache-control': 'no-store'});
      response.end(bytes);
    } catch { response.writeHead(404); response.end('Not found'); }
  });
  await new Promise(accept => server.listen(0, '127.0.0.1', accept));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const profile = await mkdtemp(join(output, 'owned-chrome-profile-'));
  const chrome = spawn(options.chromium, ['--headless=new', '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check',
    '--disable-extensions', '--disable-background-networking', '--disable-sync', '--disable-component-update', '--disable-client-side-phishing-detection', '--metrics-recording-only',
    '--mute-audio', '--hide-scrollbars', '--font-render-hinting=none', '--force-color-profile=srgb', '--disable-renderer-backgrounding', '--disable-background-timer-throttling',
    '--disable-backgrounding-occluded-windows', '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1, EXCLUDE localhost', 'about:blank'],
    {detached: true, stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], cwd: output,
      env: {PATH: process.env.PATH, LANG: 'C.UTF-8', HOME: output, XDG_CONFIG_HOME: join(profile, 'config'), XDG_CACHE_HOME: join(profile, 'cache'), XDG_DATA_HOME: join(profile, 'data')}});
  let next = 0, buffer = '', gone = null, log = '';
  const pending = new Map(), listeners = [];
  function rejectAll(reason) { gone = reason; for (const entry of pending.values()) entry.reject(Error(reason)); pending.clear(); }
  chrome.on('error', error => rejectAll(error.message));
  chrome.on('exit', (code, signal) => rejectAll(`Owned Chromium exited ${signal || code}`));
  chrome.stderr.on('data', bytes => { log = (log + bytes).slice(-6000); });
  chrome.stdio[3].on('error', () => rejectAll('Owned CDP input closed'));
  chrome.stdio[4].setEncoding('utf8');
  chrome.stdio[4].on('data', chunk => {
    buffer += chunk;
    let end;
    while ((end = buffer.indexOf('\0')) >= 0) {
      const message = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
      if (message.id && pending.has(message.id)) {
        const entry = pending.get(message.id); pending.delete(message.id);
        message.error ? entry.reject(Error(message.error.message)) : entry.resolve(message.result);
      } else for (const listener of listeners) listener(message);
    }
  });
  function send(method, params = {}, sessionId, timeout = 15000) {
    if (gone) return Promise.reject(Error(gone));
    const id = ++next;
    return new Promise((accept, reject) => {
      const timer = setTimeout(() => { pending.delete(id); reject(Error(`${method} deadline`)); }, timeout);
      pending.set(id, {resolve: value => { clearTimeout(timer); accept(value); }, reject: error => { clearTimeout(timer); reject(error); }});
      chrome.stdio[3].write(JSON.stringify({id, method, params, ...(sessionId ? {sessionId} : {})}) + '\0');
    });
  }
  async function close() {
    await send('Browser.close', {}, undefined, 3000).catch(() => {});
    if (chrome.exitCode === null) {
      try { process.kill(-chrome.pid, 'SIGTERM'); } catch {}
      await Promise.race([new Promise(accept => chrome.once('exit', accept)), pause(3000)]);
    }
    if (chrome.exitCode === null) {
      try { process.kill(-chrome.pid, 'SIGKILL'); } catch {}
      await Promise.race([new Promise(accept => chrome.once('exit', accept)), pause(1500)]);
    }
    server.closeAllConnections();
    await new Promise(accept => server.close(accept));
    assert(chrome.exitCode !== null || chrome.signalCode !== null, 'Owned Chromium was not reaped');
    await rm(profile, {recursive: true, force: true});
  }
  try {
  const {targetId} = await send('Target.createTarget', {url: 'about:blank', newWindow: true});
  const {sessionId} = await send('Target.attachToTarget', {targetId, flatten: true});
  const call = (method, params = {}, timeout) => send(method, params, sessionId, timeout);
  async function fulfill(requestId, payload, status = 200) {
    await call('Fetch.fulfillRequest', {requestId, responseCode: status,
      responseHeaders: [{name: 'Content-Type', value: 'application/json'}, {name: 'Access-Control-Allow-Origin', value: origin},
        {name: 'Access-Control-Allow-Headers', value: 'authorization,content-type'}, {name: 'Access-Control-Allow-Methods', value: 'GET,POST,OPTIONS'}, {name: 'Cache-Control', value: 'no-store'}],
      body: payload === null ? '' : Buffer.from(JSON.stringify(payload)).toString('base64')});
  }
  async function respond({requestId, request}) {
    const url = new URL(request.url);
    if (url.origin === origin || ['data:', 'about:', 'blob:'].includes(url.protocol)) return call('Fetch.continueRequest', {requestId});
    if (!['https://oauth2.googleapis.com', 'https://gmail.googleapis.com', 'https://people.googleapis.com'].includes(url.origin)) {
      blocked.push({origin: url.origin, path: url.pathname, method: request.method});
      return call('Fetch.failRequest', {requestId, errorReason: 'BlockedByClient'});
    }
    if (request.method === 'OPTIONS') return fulfill(requestId, null, 204);
    const authorization = Object.entries(request.headers).find(([name]) => name.toLowerCase() === 'authorization')?.[1];
    let index = accessTokens.findIndex(value => authorization === `Bearer ${value}`);
    const record = {origin: url.origin, path: url.pathname, method: request.method, accountIndex: index, fixture: true, observedAt: Date.now()};
    requests.push(record);
    if (url.origin === 'https://oauth2.googleapis.com' && url.pathname === '/token' && request.method === 'POST') {
      const form = new URLSearchParams(request.postData);
      index = refreshTokens.indexOf(form.get('refresh_token')); record.accountIndex = index;
      assert(index >= 0 && form.get('client_id') === clientId && form.get('client_secret') === clientSecret && form.get('grant_type') === 'refresh_token', 'Unknown synthetic credential request');
      return fulfill(requestId, {access_token: accessTokens[index], token_type: 'Bearer', expires_in: 3600, scope: scopes.join(' ')});
    }
    assert(index >= 0, 'Unknown synthetic account bearer');
    assert.equal(request.method, 'GET', 'Film must never submit mail or provider mutations');
    if (url.origin === 'https://people.googleapis.com') return fulfill(requestId, {connections: [], results: []});
    assert.equal(url.origin, 'https://gmail.googleapis.com');
    const prefix = '/gmail/v1/users/me';
    if (url.pathname === `${prefix}/profile`) return fulfill(requestId, {emailAddress: accounts[index], historyId: '1200'});
    if (url.pathname === `${prefix}/labels`) return fulfill(requestId, {labels: ['INBOX', 'SENT', 'DRAFT', 'UNREAD', 'STARRED', 'TRASH', 'SPAM'].map(id => ({id, name: id, type: 'system'}))});
    if (url.pathname === `${prefix}/settings/sendAs`) return fulfill(requestId, {sendAs: [{sendAsEmail: accounts[index], displayName: owners[index], signature: '', isPrimary: true, isDefault: true, verificationStatus: 'accepted'}]});
    if (url.pathname === `${prefix}/history`) return fulfill(requestId, {historyId: '1200', history: []});
    if (url.pathname === `${prefix}/messages`) return fulfill(requestId, {messages: Array.from({length: 5}, (_, item) => ({id: `film-${index}-${item}`, threadId: `thread-film-${index}-${item}`}))});
    const message = url.pathname.match(/\/messages\/film-(\d)-(\d)$/);
    if (message) {
      assert.equal(Number(message[1]), index, 'Message crossed fictional account');
      return fulfill(requestId, providerMessage(index, Number(message[2]), url.searchParams.get('format')));
    }
    const thread = url.pathname.match(/\/threads\/thread-film-(\d)-(\d)$/);
    if (thread) {
      assert.equal(Number(thread[1]), index, 'Thread crossed fictional account');
      return fulfill(requestId, {id: `thread-film-${index}-${thread[2]}`, messages: [providerMessage(index, Number(thread[2]), 'full')]});
    }
    throw Error(`Unrecognized fictional route ${url.pathname}`);
  }
  listeners.push(message => {
    if (message.sessionId !== sessionId) return;
    if (message.method === 'Fetch.requestPaused') void respond(message.params).catch(async error => {
      transportErrors.push(String(error));
      await call('Fetch.failRequest', {requestId: message.params.requestId, errorReason: 'BlockedByClient'}).catch(() => {});
    });
    if (message.method === 'Runtime.exceptionThrown') errors.push(message.params.exceptionDetails?.exception?.description || message.params.exceptionDetails.text);
    if (message.method === 'Network.responseReceived') {
      const response = message.params.response;
      if (response.url.startsWith('https://') && response.remoteIPAddress) networkReplies.push({url: response.url, remoteIPAddress: response.remoteIPAddress});
    }
  });
  await call('Page.enable'); await call('Runtime.enable'); await call('Network.enable'); await call('DOM.enable');
  await call('Fetch.enable', {patterns: [{urlPattern: '*'}]});
  await call('Emulation.setDeviceMetricsOverride', {width: options.width, height: options.height, deviceScaleFactor: 1, mobile: false});
  await call('Page.navigate', {url: origin + '/'});
  async function evaluate(expression) {
    const reply = await call('Runtime.evaluate', {expression, awaitPromise: true, returnByValue: true}, 30000);
    if (reply.exceptionDetails) throw Error(reply.exceptionDetails.exception?.description || reply.exceptionDetails.text);
    return reply.result.value;
  }
  return {call, evaluate, requests, blocked, transportErrors, errors, staticRequests, networkReplies, origin, close, version: () => send('Browser.getVersion'), log: () => log};
  } catch (error) { await close(); throw error; }
}

async function capture(options) {
  await reservation(); // Parent owns/reaps/releases this verified host token.
  const wasm = await readFile(join(options.site, 'omagma.wasm'));
  assert.equal(sha256(wasm), options.wasmSha, 'WASM snapshot differs from supplied provenance');
  assert.deepEqual([...wasm.subarray(0, 8)], [0, 97, 115, 109, 1, 0, 0, 0], 'Missing genuine WASM module');
  const appBytes = await readFile(join(options.site, 'app.mjs'));
  if (options.appSha) assert.equal(sha256(appBytes), options.appSha, 'Browser JS snapshot differs from supplied provenance');
  await mkdir(cacheRoot, {recursive: true, mode: 0o700});
  await mkdir(options.output, {mode: 0o700}); // Refuse to overwrite any previous take.
  await mkdir(join(options.output, 'frames'), {mode: 0o700});
  const connectionPath = join(options.output, 'fictional-browser-connection.json');
  await writeFile(connectionPath, JSON.stringify({format: 'omagma-browser-connection', version: 1,
    accounts: accounts.map((account, index) => ({account, clientId, clientSecret, grantId: hashParts(['omagma-terminal-grant-v1', ...scopes]),
      capabilities: ['mail-read', 'mail-send', 'mail-modify'], scopes, refreshToken: refreshTokens[index]}))}), {mode: 0o600});
  const receipt = {passed: false, sourceRevision: options.revision, wasmSha256: sha256(wasm), appSha256: sha256(appBytes),
    experimental: true, syntheticOnly: true, fictionalAccounts: accounts, syntheticDomainAllowlist: ['example.com', 'example.org', 'example.net'],
    actualSharedApp: true, desktopUsed: false, existingBrowserProfileUsed: false, actualGoogleNetworkCalls: 0, providerWrites: 0,
    capturedRegion: 'Genuine application/browser viewport, including the web-demo application tab bar; native browser toolbar is not captured.',
    editorialFrame: 'Any surrounding browser/address/tab frame must be clearly labelled editorial; never present it as native browser chrome.',
    requiredCaption: 'Experimental Zig/WebAssembly browser TUI · fictional accounts · not for everyday use',
    memoryMeasurement: 'None. These synthetic screenshots do not qualify memory use; any memory badge needs separately attributed evidence.',
    width: options.width, height: options.height, fps: options.fps, requestedContinuousSeconds: options.duration, frames: [], assets: [], input: [], states: []};
  let browser, began = 0, stateName = 'pre-roll', stopping = false, recorder, recordingError;
  const wallTime = () => ({wallUtc: new Date().toISOString(), monotonicMs: performance.now(), sceneMs: began ? performance.now() - began : null});
  const saveReceipt = () => writeFile(join(options.output, 'capture-receipt.json'), JSON.stringify(receipt, null, 2) + '\n', {mode: 0o600});
  try {
    browser = await ownedBrowser(options, options.output);
    async function until(test, description, timeout = 12000) {
      const end = performance.now() + timeout;
      while (!(await test())) {
        assert(performance.now() < end, `${description}; ${browser.log().slice(-700)}`);
        assert.equal(browser.transportErrors.length, 0, browser.transportErrors.join('\n'));
        await pause(20);
      }
    }
    const screen = () => browser.evaluate('window.omagmaDemo.screenText()');
    async function idle() {
      await until(() => browser.evaluate(`Boolean(window.omagmaDemo?.ready && !window.omagmaDemo.error && !window.omagmaDemo.sessionInfo().busy && !document.querySelector('#request-status').classList.contains('is-busy') && document.querySelector('#runtime-message').hidden)`), 'Complete idle WASM frame missing');
      await browser.evaluate('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
    }
    async function focus() { await browser.evaluate("document.querySelector('.xterm-helper-textarea').focus();true"); }
    async function key(key, code, modifiers = 0, text) {
      const virtual = {Enter: 13, Escape: 27, Tab: 9, Home: 36, ArrowDown: 40, ArrowUp: 38,
        '.': 190, ',': 188, '/': 191, '?': 191, ':': 186, ';': 186, ' ': 32}[key] || (key.length === 1 ? key.toUpperCase().charCodeAt(0) : 0);
      const params = {key, code, modifiers, windowsVirtualKeyCode: virtual, nativeVirtualKeyCode: virtual};
      receipt.input.push({type: 'key', key, code, modifiers, ...(text ? {text} : {}), ...wallTime()});
      await browser.call('Input.dispatchKeyEvent', {...params, type: 'keyDown', ...(text ? {text, unmodifiedText: text} : key === 'Enter' ? {text: '\r', unmodifiedText: '\r'} : {})});
      await browser.call('Input.dispatchKeyEvent', {...params, type: 'keyUp'});
    }
    const letter = value => key(value, `Key${value.toUpperCase()}`, 0, value);
    async function click(selector) {
      const point = await browser.evaluate(`(()=>{const r=document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();return{x:r.x+r.width/2,y:r.y+r.height/2}})()`);
      receipt.input.push({type: 'mouse', selector, ...point, ...wallTime()});
      await browser.call('Input.dispatchMouseEvent', {type: 'mousePressed', ...point, button: 'left', clickCount: 1});
      await browser.call('Input.dispatchMouseEvent', {type: 'mouseReleased', ...point, button: 'left', clickCount: 1});
    }
    async function connect() {
      await until(() => browser.evaluate('Boolean(window.omagmaDemo?.ready)'), 'Browser sample did not load');
      await click('#connect-open');
      await until(() => browser.evaluate("document.querySelector('#credential-dialog').open"), 'Connection-file dialog missing');
      const {root: documentNode} = await browser.call('DOM.getDocument');
      const {nodeId} = await browser.call('DOM.querySelector', {nodeId: documentNode.nodeId, selector: '#credential-bundle'});
      assert(nodeId, 'Synthetic connection-file input missing');
      await browser.call('DOM.setFileInputFiles', {nodeId, files: [connectionPath]});
      await until(() => browser.evaluate("!document.querySelector('#credential-connect').disabled"), 'Synthetic bundle was not loaded');
      await click('#credential-connect');
      await until(() => browser.evaluate("window.omagmaDemo?.ready && window.omagmaDemo.sessionInfo().mode==='live' && window.omagmaDemo.sessionInfo().accountCount===3 && !document.querySelector('#credential-dialog').open"), 'Three synthetic accounts did not connect');
      await idle(); await focus();
    }
    function assertPublicText(text) {
      for (const secret of secrets) assert(!text.includes(secret), 'Synthetic credential appeared in public UI capture');
      const addresses = text.match(/[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+/g) || [];
      for (const address of addresses) assert(/@(example\.(com|org|net))$/.test(address), `Unexpected public capture address ${address}`);
    }
    async function screenshot(name, frames = false) {
      for (let attempt = 0; attempt < 4; attempt++) {
        await browser.evaluate('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
        const before = await browser.evaluate('({frame:window.omagmaDemo.frameCount,text:window.omagmaDemo.screenText(),error:window.omagmaDemo.error})');
        assert.equal(before.error, null); assertPublicText(before.text);
        const result = await browser.call('Page.captureScreenshot', {format: 'png', captureBeyondViewport: false, optimizeForSpeed: true});
        const after = await browser.evaluate('window.omagmaDemo.frameCount');
        if (after !== before.frame) continue; // Never keep a screenshot across a changing full frame.
        const bytes = Buffer.from(result.data, 'base64');
        const path = join(options.output, frames ? 'frames' : '', `${name}.png`);
        await writeFile(path, bytes, {mode: 0o600});
        const value = {name, width: options.width, height: options.height, state: stateName, timestamps: wallTime(), path: relative(root, path),
          sha256: sha256(bytes), terminalFrame: before.frame, cols: await browser.evaluate('window.omagmaDemo.cols'), rows: await browser.evaluate('window.omagmaDemo.rows')};
        (frames ? receipt.frames : receipt.assets).push(value);
        return value;
      }
      if (frames) { receipt.unstableFramesSkipped = (receipt.unstableFramesSkipped || 0) + 1; return null; }
      throw Error('No complete stable browser frame for capture');
    }
    async function mark(name) {
      stateName = name;
      await idle();
      receipt.states.push({name, screenText: await screen(), syntheticRequestCount: browser.requests.length, ...wallTime()});
    }
    async function nativeFolder(name) {
      const point = await browser.evaluate(`(()=>{const a=window.omagmaDemo;const rows=a.screenText().split(${JSON.stringify('\n')});let y=rows.findIndex((line,index)=>index>2&&index<20&&line.includes(${JSON.stringify(name)}));if(y<0)return null;const x=rows[y].indexOf(${JSON.stringify(name)});const r=a.geometry().screen;return{x:r.x+(x+1.5)*r.width/a.cols,y:r.y+(y+.5)*r.height/a.rows}})()`);
      assert(point, `Native ${name} folder not visible`);
      receipt.input.push({type: 'mouse', nativeFolder: name, ...point, ...wallTime()});
      await browser.call('Input.dispatchMouseEvent', {type: 'mousePressed', ...point, button: 'left', clickCount: 1});
      await browser.call('Input.dispatchMouseEvent', {type: 'mouseReleased', ...point, button: 'left', clickCount: 1});
      await idle(); await focus();
    }
    async function savedDrafts() {
      return browser.evaluate(`new Promise((resolve,reject)=>{const request=indexedDB.open('omagma-browser-drafts-v1',1);request.onerror=()=>reject(Error('draft DB unavailable'));request.onsuccess=()=>{const db=request.result;const tx=db.transaction('actors','readonly');const all=tx.objectStore('actors').getAll();all.onsuccess=()=>{db.close();resolve(all.result)};all.onerror=()=>{db.close();reject(Error('draft records unavailable'))}}})`);
    }
    await connect();
    // Pre-roll is real input and fetch completion, but not part of the 14s scene.
    for (const digit of ['2', '3', '1']) { await key(digit, `Digit${digit}`, 0, digit); await idle(); await until(async () => (await screen()).includes(bodies[Number(digit) - 1].split('\n')[0]), 'Warm cached body missing'); }
    await key('Home', 'Home'); await idle();
    assert((await screen()).includes(subjects[0][0]));
    began = performance.now();
    await mark('browser.context'); await screenshot('browser.context');
    recorder = (async () => {
      let index = 0;
      while (!stopping && performance.now() - began < options.duration * 1000) {
        const target = began + index * 1000 / options.fps;
        if (performance.now() < target) await pause(target - performance.now());
        if (stopping) break;
        await screenshot(`frame-${String(index++).padStart(5, '0')}`, true);
      }
    })().catch(error => { recordingError = error; stopping = true; });
    async function at(seconds, action) { const remaining = began + seconds * 1000 - performance.now(); if (remaining > 0) await pause(remaining); await action(); }
    for (const [seconds, digit] of [[1.5, '2'], [3, '3'], [4.5, '1']]) {
      await at(seconds, async () => {
        const before = browser.requests.length;
        await key(digit, `Digit${digit}`, 0, digit); await idle();
        const current = await screen(); assert(current.includes(accounts[Number(digit) - 1]));
        assert.equal(browser.requests.length, before, 'A warmed account switch requested provider data');
        await mark(`cached-account-${digit}`);
        if (digit !== '1') await screenshot(`browser.account${digit}`);
      });
    }
    await at(4.6, async () => { await key('Enter', 'Enter'); await mark('received-reader'); await screenshot('browser.reader'); });
    await at(6.2, async () => { await letter('r'); await idle(); await until(async () => /Keep formatting/.test(await screen()), 'Real reply formatting choice missing'); await mark('reply-format-choice'); });
    await at(7.8, async () => {
      await letter('k'); await idle(); await until(async () => /Compose/.test(await screen()), 'Preserved-format reply composer missing');
      await key('g', 'KeyG', 2); await idle();
      if (!(await screen()).includes('INSERT')) await letter('i');
      for (const character of note) { await key(character, /[a-z]/i.test(character) ? `Key${character.toUpperCase()}` : character === ' ' ? 'Space' : 'Period', 0, character); await pause(45); }
      await key('Escape', 'Escape'); await mark('browser.draft');
    });
    await at(9.9, async () => { assert((await screen()).includes(note)); await screenshot('browser.draft'); });
    await at(10.3, async () => { await letter('q'); await idle(); await until(async () => JSON.stringify(await savedDrafts()).includes(note), 'Typed draft was not durably saved'); await mark('draft-saved'); });
    await at(10.6, async () => { await nativeFolder('Drafts'); await mark('saved-draft-list'); });
    await at(12.2, async () => { await key('Enter', 'Enter'); await idle(); await until(async () => (await screen()).includes(note), 'Saved draft did not reopen through real UI'); await mark('saved-draft-reopened'); });
    await at(options.duration, async () => {});
    stopping = true; await recorder;
    if (recordingError) throw recordingError;
    receipt.continuousSeconds = (performance.now() - began) / 1000;
    assert(receipt.continuousSeconds <= 15.5, 'Continuous scene exceeded its honest 15s capture budget');
    const beforeReload = await savedDrafts();
    assert(JSON.stringify(beforeReload).includes(note) && JSON.stringify(beforeReload).includes('Friday plan'), 'Saved note/original missing before reload');
    receipt.draftBeforeReloadSha256 = sha256(JSON.stringify(beforeReload));
    // Following proof state: a genuine browser reload + fresh fictional account
    // verification, not a hidden state injection or retyped replacement draft.
    stateName = 'reload-and-reconnect'; await browser.call('Page.reload', {ignoreCache: true});
    await until(() => browser.evaluate('Boolean(window.omagmaDemo?.ready)'), 'Reload did not return sample UI');
    await connect();
    // Connecting all three actors leaves the last actor selected. The saved
    // draft belongs to account one; restore that explicit account before its
    // native Drafts folder rather than assuming connection selected it.
    await key('1', 'Digit1', 0, '1'); await idle();
    assert((await screen()).split('\n')[0].includes(accounts[0]), 'Reload recovery selected the wrong account');
    await nativeFolder('Drafts'); await key('Enter', 'Enter'); await idle();
    await until(async () => (await screen()).includes(note), 'Durable draft/original did not recover after reload and reconnect');
    await mark('browser.reloaded'); await screenshot('browser.reloaded');
    const recovered = await savedDrafts();
    assert(JSON.stringify(recovered).includes(note) && JSON.stringify(recovered).includes('Friday plan'));
    receipt.draftAfterReloadSha256 = sha256(JSON.stringify(recovered));
    receipt.reloadedStateOutsideContinuousTake = true;
    assert.equal(browser.transportErrors.length, 0, browser.transportErrors.join('\n'));
    assert.equal(browser.errors.length, 0, browser.errors.join('\n'));
    assert.equal(browser.networkReplies.length, 0, 'An HTTPS response used a real network peer');
    assert.equal(browser.requests.filter(request => request.origin !== 'https://oauth2.googleapis.com' && request.method !== 'GET').length, 0, 'Provider write occurred');
    receipt.syntheticRequests = browser.requests;
    receipt.externalRequestsBlocked = browser.blocked;
    receipt.staticRequests = browser.staticRequests;
    receipt.browserVersion = await browser.version();
    receipt.passed = true;
    await writeFile(join(options.output, 'asset-manifest.json'), JSON.stringify({sourceRevision: receipt.sourceRevision, wasmSha256: receipt.wasmSha256, appSha256: receipt.appSha256,
      genuineBrowserViewport: true, nativeBrowserToolbarCaptured: false, editorialFrameLabelRequired: true, requiredCaption: receipt.requiredCaption,
      continuousSeconds: receipt.continuousSeconds, reloadedStateOutsideContinuousTake: true, assets: receipt.assets, frames: receipt.frames}, null, 2) + '\n', {mode: 0o600});
  } catch (error) {
    receipt.error = String(error); stopping = true;
    if (recorder) await recorder.catch(() => {});
    if (browser) {
      receipt.syntheticRequests = browser.requests;
      receipt.externalRequestsBlocked = browser.blocked;
      receipt.transportErrors = browser.transportErrors;
      receipt.runtimeErrors = browser.errors;
      receipt.finalScreen = await browser.evaluate('window.omagmaDemo?.screenText()').catch(() => null);
      receipt.chromiumDiagnostics = browser.log();
    }
    throw error;
  } finally {
    stopping = true;
    if (recorder) await recorder.catch(() => {});
    if (browser) { await browser.close(); receipt.ownedBrowserReaped = true; receipt.throwawayProfileRemoved = true; }
    await rm(connectionPath, {force: true});
    await saveReceipt();
    console.log(JSON.stringify({passed: receipt.passed, output: relative(root, options.output), wasmSha256: receipt.wasmSha256, assets: receipt.assets.map(asset => asset.name), frames: receipt.frames.length, error: receipt.error}));
  }
}

const options = parseArgs();
if (options) await capture(options);
