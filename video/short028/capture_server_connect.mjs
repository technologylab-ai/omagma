#!/usr/bin/env node
// Media-only capture of the shared Zig/WASM App in owned real Chromium chrome.
// A private virtual output and throwaway profile isolate its full window.
// Only loopback assets reach a server; fixed Google calls use CDP fixtures.
// Window and viewport screenshots are paired to audit compositor paint after reload.
import assert from 'node:assert/strict';
import {spawn, execFile} from 'node:child_process';
import {promisify} from 'node:util';
const execute = promisify(execFile);
let OWN_OUTPUT;
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
    console.log('Usage: HOST_TOKEN=… node video/short028/capture_server_connect.mjs --binary ABS --expected-binary-sha256 HEX --site-dir ABS --expected-wasm-sha256 HEX --source-revision REV [--expected-app-sha256 HEX] [--port PORT] [--output-dir video/cache/short028/browser/TAKE] [--width 1680] [--height 880] [--fps 12] [--duration 14] [--chromium /usr/bin/chromium]');
    return null;
  }
  const allowed = new Set(['--port', '--binary', '--expected-binary-sha256', '--site-dir', '--expected-wasm-sha256', '--expected-app-sha256', '--source-revision', '--output-dir', '--width', '--height', '--fps', '--duration', '--chromium']);
  const values = new Map();
  for (let index = 2; index < process.argv.length; index += 2) {
    const key = process.argv[index], value = process.argv[index + 1];
    assert(allowed.has(key) && value && !values.has(key), `Invalid capture option ${key}`);
    values.set(key, value);
  }
  for (const key of ['--binary', '--expected-binary-sha256', '--site-dir', '--expected-wasm-sha256', '--source-revision']) assert(values.has(key), `${key} required for immutable capture provenance`);
  for (const key of ['--expected-binary-sha256', '--expected-wasm-sha256', '--expected-app-sha256']) if (values.has(key)) assert(/^[a-f0-9]{64}$/.test(values.get(key)), `${key} must be a full SHA-256`);
  assert(/^[a-f0-9]{7,40}$/.test(values.get('--source-revision')), 'Source revision must be a commit identity');
  const options = {binary:resolve(values.get('--binary')),binarySha:values.get('--expected-binary-sha256'),site: resolve(values.get('--site-dir')), wasmSha: values.get('--expected-wasm-sha256'), appSha: values.get('--expected-app-sha256'), revision: values.get('--source-revision'),port:values.has('--port')?Number(values.get('--port')):null,
    output: resolve(values.get('--output-dir') || join(cacheRoot, `server-connect-${Date.now()}`)), width: Number(values.get('--width') || 1680), height: Number(values.get('--height') || 880),
    fps: Number(values.get('--fps') || 12), duration: Number(values.get('--duration') || 14), chromium: values.get('--chromium') || process.env.CHROMIUM || '/usr/bin/chromium'};
  assert(options.output.startsWith(cacheRoot + sep), 'Capture output must be a new ignored browser take directory');
  assert(Number.isInteger(options.width) && options.width >= 1200 && options.width <= 2200 && Number.isInteger(options.height) && options.height >= 800 && options.height <= 1400, 'Film viewport is out of bounds');
  assert(Number.isInteger(options.fps) && options.fps >= 6 && options.fps <= 24, 'Frame rate is out of bounds');
  assert(options.width===1680 && options.height===880,'This owned chrome take uses fixed 1680×880 logical geometry');
  assert(options.duration >= 14 && options.duration <= 15, 'Legacy duration option must remain 14–15 seconds; this script records selected stable states');
  if(options.port!==null)assert(Number.isInteger(options.port)&&options.port>0&&options.port<65536,'Invalid native server port');
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

async function nativeServer(options, output) {
  const scratch=join(output,'native-server-private');await mkdir(scratch,{mode:0o700});
  const environment={PATH:process.env.PATH,LANG:'C.UTF-8',HOME:join(scratch,'home'),XDG_CONFIG_HOME:join(scratch,'config'),XDG_CACHE_HOME:join(scratch,'cache'),XDG_DATA_HOME:join(scratch,'data')};
  for(const path of [environment.HOME,environment.XDG_CONFIG_HOME,environment.XDG_CACHE_HOME,environment.XDG_DATA_HOME])await mkdir(path,{mode:0o700});
  const configDirectory=join(environment.XDG_CONFIG_HOME,'omagma'),credentialDirectory=join(scratch,'credentials');
  await mkdir(configDirectory,{mode:0o700});await mkdir(credentialDirectory,{mode:0o700});
  const clientFile=join(configDirectory,'fictional-oauth-client.json');
  const grants=accounts.map(account=>({account,clientFile,clientId,grantId:hashParts(['omagma-terminal-grant-v1',...scopes]),capabilities:['mail-read','mail-send','mail-modify'],scopes,enabled:true}));
  await writeFile(clientFile,JSON.stringify({installed:{client_id:clientId,client_secret:clientSecret,project_id:'fictional-film-project',auth_uri:'https://accounts.google.com/o/oauth2/auth',token_uri:'https://oauth2.googleapis.com/token',redirect_uris:['http://localhost']}})+'\n',{mode:0o600});
  await writeFile(join(configDirectory,'config.json'),JSON.stringify({oauthClientFile:clientFile,credentialStore:'file',credentialDirectory,accounts:accounts.map((address,index)=>({address,profile:`Profile ${index+1}`,enabled:true,required:true}))})+'\n',{mode:0o600});
  await writeFile(join(configDirectory,'terminal-grants.json'),JSON.stringify({version:1,accounts:grants})+'\n',{mode:0o600});
  for(const [index,grant] of grants.entries()){
    const directory=join(credentialDirectory,hashParts(['omagma-credential-account-v1',grant.account]));await mkdir(directory,{mode:0o700});
    const token=`terminal-${hashParts(['omagma-credential-value-v1','terminal',grant.account,clientId,grant.grantId])}.token`;
    await writeFile(join(directory,token),refreshTokens[index],{mode:0o600});
  }
  const buildInfo=JSON.parse((await execute(options.binary,['build-info'],{cwd:scratch,env:environment})).stdout);
  assert.equal(buildInfo.zigVersion,'0.17.0');
  const command=['server',...(options.port===null?[]:['--port',String(options.port)])];
  const child=spawn(options.binary,command,{cwd:scratch,env:environment,detached:true,stdio:['ignore','pipe','pipe']});
  let stdout='',stderr='',nonce='';child.stdout.on('data',b=>stdout=(stdout+b).slice(-32768));child.stderr.on('data',b=>stderr=(stderr+b).slice(-8192));
  function sanitized(value){return [nonce,...secrets].filter(Boolean).reduce((v,s)=>v.replaceAll(s,'[private synthetic value]'),value.replace(/#omagma-session=[a-f0-9]{64}/g,''));}
  async function close(){
    if(child.exitCode===null&&child.signalCode===null){try{process.kill(-child.pid,'SIGTERM');}catch{}await Promise.race([new Promise(r=>child.once('exit',r)),pause(2000)]);}
    if(child.exitCode===null&&child.signalCode===null){try{process.kill(-child.pid,'SIGKILL');}catch{}await Promise.race([new Promise(r=>child.once('exit',r)),pause(1000)]);}
    assert(child.exitCode!==null||child.signalCode!==null,'Native server child was not reaped');
    await writeFile(join(output,'native-server.stdout.txt'),sanitized(stdout),{mode:0o600});
    await writeFile(join(output,'native-server.stderr.txt'),sanitized(stderr),{mode:0o600});
    await rm(scratch,{recursive:true,force:true});
  }
  try{
    const deadline=Date.now()+12000;let match;
    while(!(match=stdout.match(/http:\/\/127\.0\.0\.1:\d+\/#omagma-session=([a-f0-9]{64})/))){assert(child.exitCode===null&&child.signalCode===null,'Native server exited before readiness');assert(Date.now()<deadline,'Native server readiness deadline');await pause(20);}
    nonce=match[1];const launchURL=match[0],origin=new URL(launchURL).origin;
    for(const [asset,expected] of [['omagma.wasm',options.wasmSha],['app.mjs',options.appSha]]){
      const response=await fetch(origin+'/'+asset);assert.equal(response.status,200);const bytes=Buffer.from(await response.arrayBuffer());if(expected)assert.equal(sha256(bytes),expected,'Native embedded asset identity mismatch');
    }
    return {origin,launchURL,nonce,buildInfo,close,stdout:()=>sanitized(stdout),stderr:()=>sanitized(stderr)};
  }catch(error){await close();throw error;}
}

async function ownedBrowser(options, output) {
  const oldOutputs=JSON.parse((await execute('hyprctl',['monitors','-j'])).stdout).map(m=>m.name);
  await execute('hyprctl',['output','create','headless']);
  for(let n=0;n<50;n++){const added=JSON.parse((await execute('hyprctl',['monitors','-j'])).stdout).filter(m=>!oldOutputs.includes(m.name));if(added.length){assert.equal(added.length,1);OWN_OUTPUT=added[0].name;break;}await pause(30);}
  assert(OWN_OUTPUT?.startsWith('HEADLESS-'),'Owned output was not created');
  await execute('hyprctl',['eval',`hl.monitor({output="${OWN_OUTPUT}",mode="3360x1960@60",position="-1680x10000",scale=2})`]);
  await execute('hyprctl',['eval',`hl.window_rule({match={class="^omagma-server-connect028$"},monitor="${OWN_OUTPUT}",float=true,no_initial_focus=true,no_dim=true,opacity="1 1",border_size=0,rounding=0,no_shadow=true,size={"1680","880"},move={"0","60"}})`]);
  const requests = [], blocked = [], transportErrors = [], errors = [], staticRequests = [], networkReplies = [], localConnections=[];
  let oauthHeld=false;
  const origin = options.serverOrigin;
  const profile = await mkdtemp(join(output, 'owned-chrome-profile-'));
  const chrome = spawn(options.chromium, ['--test-type', '--disable-gpu', '--ozone-platform=wayland', '--disable-features=Vulkan', '--use-angle=gl', '--class=omagma-server-connect028', '--window-size=1680,880', '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check',
    '--disable-extensions', '--disable-background-networking', '--disable-sync', '--disable-component-update', '--disable-client-side-phishing-detection', '--metrics-recording-only',
    '--mute-audio', '--hide-scrollbars', '--font-render-hinting=none', '--force-color-profile=srgb', '--disable-renderer-backgrounding', '--disable-background-timer-throttling',
    '--disable-backgrounding-occluded-windows', '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1, EXCLUDE localhost', 'about:blank'],
    {detached: true, stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], cwd: output,
      env: {PATH: process.env.PATH, WAYLAND_DISPLAY:process.env.WAYLAND_DISPLAY, XDG_RUNTIME_DIR:process.env.XDG_RUNTIME_DIR, DBUS_SESSION_BUS_ADDRESS:process.env.DBUS_SESSION_BUS_ADDRESS, LANG: 'C.UTF-8', HOME: output, XDG_CONFIG_HOME: join(profile, 'config'), XDG_CACHE_HOME: join(profile, 'cache'), XDG_DATA_HOME: join(profile, 'data')}});
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
    assert(chrome.exitCode !== null || chrome.signalCode !== null, 'Owned Chromium was not reaped');
    await rm(profile, {recursive: true, force: true});
    await execute('hyprctl', ['output','remove',OWN_OUTPUT]);
  }
  try {
  let targetId;
  for(let n=0;n<100;n++){ const pages=(await send('Target.getTargets')).targetInfos.filter(t=>t.type==='page'); if(pages.length){targetId=pages[0].targetId;break;} await pause(50); }
  assert(targetId,'Owned browser initial page missing');
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
    if(url.origin===origin){
      staticRequests.push(url.pathname);
      if(url.pathname==='/connection.json'){
        const auth=Object.entries(request.headers).find(([k])=>k.toLowerCase()==='authorization')?.[1];
        assert.equal(auth,`Omagma-Session ${options.sessionNonce}`,'Native broker authorization mismatch');
        assert.equal(request.method,'GET');
        localConnections.push({path:url.pathname,method:request.method,authorized:true,at:Date.now()});
      }
      return call('Fetch.continueRequest',{requestId});
    }
    if(['data:','about:','blob:'].includes(url.protocol))return call('Fetch.continueRequest',{requestId});
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
      if(!oauthHeld){oauthHeld=true;await pause(1800);}
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
  await call('Emulation.setFocusEmulationEnabled',{enabled:true});
  await call('Fetch.enable', {patterns: [{urlPattern: '*'}]});

  await call('Page.navigate', {url:options.launchURL});
  async function evaluate(expression) {
    const reply = await call('Runtime.evaluate', {expression, awaitPromise: true, returnByValue: true}, 30000);
    if (reply.exceptionDetails) throw Error(reply.exceptionDetails.exception?.description || reply.exceptionDetails.text);
    return reply.result.value;
  }
  async function windowScreenshot(){
    const clients=JSON.parse((await execute('hyprctl',['clients','-j'])).stdout);
    const owned=clients.filter(c=>c.class==='omagma-server-connect028');
    assert.equal(owned.length,1,'Must capture exactly one owned browser');
    const monitors=JSON.parse((await execute('hyprctl',['monitors','-j'])).stdout);
    const monitor=monitors.find(m=>m.name===OWN_OUTPUT);
    assert(monitor && owned[0].monitor===monitor.id,`Owned browser must remain on owned headless output ${OWN_OUTPUT}; owned monitor=${owned[0].monitor}; monitors=${monitors.map(m=>m.name+':'+m.id)}`);
    const c=owned[0], [x,y]=c.at, [w,h]=c.size;
    assert(x>=monitor.x && y>=monitor.y && x+w<=monitor.x+monitor.width/monitor.scale && y+h<=monitor.y+monitor.height/monitor.scale,'Owned window exceeds private output');
    const geometry=`${x},${y} ${w}x${h}`;
    const {stdout}=await execute('grim',['-g',geometry,'-s',String(monitor.scale),'-'],{encoding:'buffer',maxBuffer:32*1024*1024});
    const browserGeometry=await evaluate('({outerWidth,outerHeight,innerWidth,innerHeight,dpr:devicePixelRatio})');
    return {bytes:stdout,width:stdout.readUInt32BE(16),height:stdout.readUInt32BE(20),window:{at:c.at,size:c.size,monitor:OWN_OUTPUT,pid:c.pid},browserGeometry};
  }
  return {call, evaluate, windowScreenshot, localConnections, requests, blocked, transportErrors, errors, staticRequests, networkReplies, origin, close, version: () => send('Browser.getVersion'), log: () => log};
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
  assert.equal(sha256(await readFile(options.binary)),options.binarySha,'Native binary identity mismatch');
  const receipt = {passed: false, sourceRevision: options.revision, wasmSha256: sha256(wasm), appSha256: sha256(appBytes),
    experimental: true, syntheticOnly: true, fictionalAccounts: accounts, syntheticDomainAllowlist: ['example.com', 'example.org', 'example.net', 'example.test'],
    actualSharedApp: true, actualNativeServer:true, command:'omagma server'+(options.port===null?'':` --port ${options.port}`), nativeBinarySha256:options.binarySha, launchCapabilityPublic:false, addressFragmentRemovedAfterBootstrap:true, simulatedFirstOAuthDelayMs:1800, desktopUsed: true, privateVirtualOutput: true, existingBrowserProfileUsed: false, actualGoogleNetworkCalls: 0, providerWrites: 0,
    capturedRegion: 'Exact owned Chromium window on a private virtual output, including real tabs, favicon and address bar.',
    editorialFrame: 'None; tabs and address bar are genuine owned Chromium window pixels.',
    requiredCaption: 'Experimental Zig/WebAssembly browser TUI · fictional accounts · not for everyday use',
    memoryMeasurement: 'None. These synthetic screenshots do not qualify memory use; any memory badge needs separately attributed evidence.',
    width: options.width, height: options.height, fps: options.fps, captureMethod: 'Continuous actual native Connect Gmail click, fixture verification and three-account rendering', legacyRequestedDuration: options.duration, frames: [], assets: [], input: [], states: []};
  let browser, native, began = 0, stateName = 'pre-roll', stopping = false, recorder, recordingError;
  const wallTime = () => ({wallUtc: new Date().toISOString(), monotonicMs: performance.now(), sceneMs: began ? performance.now() - began : null});
  const saveReceipt = () => writeFile(join(options.output, 'capture-receipt.json'), JSON.stringify(receipt, null, 2) + '\n', {mode: 0o600});
  try {
    native=await nativeServer(options,options.output);options.serverOrigin=native.origin;options.launchURL=native.launchURL;options.sessionNonce=native.nonce;
    receipt.buildInfo=native.buildInfo;receipt.serverOrigin=native.origin;secrets.push(native.nonce);
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
    function assertPublicText(text) {
      for (const secret of secrets) assert(!text.includes(secret), 'Synthetic credential appeared in public UI capture');
      const addresses = text.match(/[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+/g) || [];
      for (const address of addresses) assert(/@(example\.(com|org|net|test))$/.test(address), `Unexpected public capture address ${address}`);
    }
    async function screenshot(name, frames = false) {
      for (let attempt = 0; attempt < 4; attempt++) {
        await browser.evaluate('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
        const before = await browser.evaluate('({frame:window.omagmaDemo.frameCount,text:window.omagmaDemo.screenText(),error:window.omagmaDemo.error})');
        assert.equal(before.error, null); assertPublicText(before.text);
        const publicLocation=await browser.evaluate('location.href');assert(!publicLocation.includes(options.sessionNonce)&&!publicLocation.includes('omagma-session'),'Private launch capability remained visible');
        assertPublicText(await browser.evaluate('document.body.innerText'));
        const result = await browser.windowScreenshot();
        const viewport = await browser.call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false,optimizeForSpeed:true});
        const after = await browser.evaluate('window.omagmaDemo.frameCount');
        if (after !== before.frame) continue; // Never keep a screenshot across a changing full frame.
        const bytes = result.bytes;
        const path = join(options.output, frames ? 'frames' : '', `${name}.png`);
        await writeFile(path, bytes, {mode: 0o600});
        const viewportPath=join(options.output,frames?'frames':'',`${name}.viewport.png`);
        await writeFile(viewportPath,Buffer.from(viewport.data,'base64'),{mode:0o600});
        const value = {name, width: result.width, height: result.height, state: stateName, stage: stateName, window:result.window, browserGeometry:result.browserGeometry, toolbarRectangle:{x:0,y:0,width:result.width,height:Math.round((result.browserGeometry.outerHeight-result.browserGeometry.innerHeight)*result.browserGeometry.dpr)}, timestamps: wallTime(), path: relative(root, path),
          sha256: sha256(bytes), viewportPath:relative(root,viewportPath), viewportSha256:sha256(Buffer.from(viewport.data,'base64')), terminalFrame: before.frame, cols: await browser.evaluate('window.omagmaDemo.cols'), rows: await browser.evaluate('window.omagmaDemo.rows')};
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
    await until(()=>browser.evaluate('Boolean(window.omagmaDemo?.ready)'),'Native embedded sample UI did not become ready');
    assert.equal(browser.requests.length,0,'Native server bootstrap fetched Google before Connect');
    assert.equal((await browser.evaluate('window.omagmaDemo.sessionInfo()')).mode,'demo');
    await browser.evaluate("history.replaceState(null,'',location.pathname);true");await pause(250);await idle();
    began=performance.now();
    async function hold(name,seconds=1.5,busy=false){
      stateName=name;if(!busy)await idle();
      receipt.states.push({name,screenText:await screen(),session:await browser.evaluate('window.omagmaDemo.sessionInfo()'),...wallTime()});
      await screenshot(name);const end=performance.now()+seconds*1000;let index=0;
      while(performance.now()<end){await screenshot(`${name}-${String(index++).padStart(3,'0')}`,true);await pause(100);}
      await saveReceipt();console.log(JSON.stringify({progress:name,path:receipt.assets.at(-1).path}));
    }
    const button=await browser.evaluate("(()=>{const b=document.querySelector('#connect-open');return{text:b.textContent,visible:b.checkVisibility(),disabled:b.disabled,rect:JSON.parse(JSON.stringify(b.getBoundingClientRect()))}})()");
    assert(button.visible&&!button.disabled&&/Connect Gmail/i.test(button.text));receipt.connectButton=button;
    await hold('browser.server-connect-button',1.5);
    await click('#connect-open');
    await until(()=>browser.evaluate("document.querySelector('#connect-open').disabled || window.omagmaDemo.sessionInfo().busy || document.querySelector('#request-status').classList.contains('is-busy')"),'Actual Connect click did not enter loading');
    await hold('browser.server-connect-loading',.6,true);
    await until(()=>browser.evaluate("window.omagmaDemo?.ready && window.omagmaDemo.sessionInfo().mode==='live' && window.omagmaDemo.sessionInfo().accountCount===3 && !document.querySelector('#credential-dialog').open"),'Native broker did not connect all three fixture accounts',20000);
    await idle();await focus();
    assert.equal(browser.localConnections.length,1,'Connect must fetch exactly one actual authenticated native bundle');
    const verified=new Set(browser.requests.filter(r=>r.path.endsWith('/profile')).map(r=>r.accountIndex));assert.deepEqual([...verified].sort(),[0,1,2]);
    await hold('browser.server-connected-three',1.8);
    await key('1','Digit1',0,'1');await idle();await until(async()=> (await screen()).includes(subjects[0][0])&&(await screen()).includes('Hi Alex,'),'Connected first account body missing');
    await hold('browser.server-connected-alex',1.5);
    receipt.localConnectionRequests=browser.localConnections;receipt.allThreeGoogleProfilesVerified=true;receipt.connectionDialogOpened=false;receipt.continuousSceneClaim=true;receipt.continuousSeconds=(performance.now()-began)/1000;
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
      genuineBrowserWindow: true, nativeBrowserToolbarCaptured: true, editorialFrameLabelRequired: false, nativeConnectProofPassed:true, requiredCaption: receipt.requiredCaption,
      continuousSeconds: receipt.continuousSeconds, actualNativeServer:true, launchCapabilityPublic:false, assets: receipt.assets, frames: receipt.frames}, null, 2) + '\n', {mode: 0o600});
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
    try{if (browser) { await browser.close(); receipt.ownedBrowserReaped = true; receipt.throwawayProfileRemoved = true; }}
    finally{if(native){await native.close();receipt.ownedNativeServerReaped=true;receipt.syntheticCredentialTreeRemoved=true;}}
    receipt.nativeConnectProofPassed=receipt.passed;
    await saveReceipt();
    console.log(JSON.stringify({passed: receipt.passed, output: relative(root, options.output), wasmSha256: receipt.wasmSha256, assets: receipt.assets.map(asset => asset.name), frames: receipt.frames.length, error: receipt.error}));
  }
}

const options = parseArgs();
if (options) await capture(options);
