#!/usr/bin/env node
// Browser acceptance against literal synthetic Google responses. CDP pauses
// every request before network: only this test's static origin is continued.
// Fixed production Google URLs receive synthetic responses from Chromium's
// Fetch domain, never from Google or a configurable application endpoint.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, extname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const args = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  assert(process.argv[index].startsWith("--") && process.argv[index + 1], `invalid argument ${process.argv[index]}`);
  args.set(process.argv[index], process.argv[index + 1]);
}
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const site = resolve(args.get("--site-dir") || join(root, "web-demo/dist"));
const work = resolve(args.get("--work-dir") || "/tmp/omagma-wasm-browser-live");
assert(work !== site && !site.startsWith(work + sep), "browser scratch directory must not contain the site");
await mkdir(work, { recursive: true, mode: 0o700 });
const readScope = "https://www.googleapis.com/auth/gmail.readonly";
const sendScope = "https://www.googleapis.com/auth/gmail.send";
const clientId = "synthetic-browser-test.apps.googleusercontent.com";
const clientSecret = "synthetic-client-secret-never-valid";
const accounts = ["ada.browser@example.test", "bea.browser@example.test"];
const refreshSecrets = accounts.map((_, index) => `synthetic-refresh-${index}-never-valid`);
const accessSecrets = accounts.map((_, index) => `synthetic-access-${index}-never-valid`);
const syntheticSecrets = [clientSecret, ...refreshSecrets, ...accessSecrets];
const hashParts = (parts) => createHash("sha256").update(parts.map((part) => part + "\0").join("")).digest("hex");
async function credentialFiles(name, address, scopes, changes = {}) {
  const directory = join(work, "synthetic-credentials", name);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const grantId = hashParts(["omagma-terminal-grant-v1", ...scopes]);
  const grant = { account: address, clientFile: "synthetic-oauth-client.json", clientId,
    grantId, capabilities: scopes.includes(sendScope) ? ["mail-read", "mail-send"] : ["mail-read"],
    scopes, enabled: true, ...changes.grant };
  const tokenName = `terminal-${hashParts(["omagma-credential-value-v1", "terminal", address, grant.clientId, grant.grantId])}.token`;
  const oauth = { installed: { client_id: clientId, project_id: "synthetic-browser-project",
    auth_uri: "https://accounts.google.com/o/oauth2/auth", token_uri: "https://oauth2.googleapis.com/token",
    auth_provider_x509_cert_url: "https://www.googleapis.com/oauth2/v1/certs", client_secret: clientSecret,
    redirect_uris: ["http://localhost"], ...changes.client } };
  const files = [join(directory, "synthetic-oauth-client.json"), join(directory, "terminal-grants.json"), join(directory, tokenName)];
  await writeFile(files[0], JSON.stringify(oauth) + "\n", { mode: 0o600 });
  await writeFile(files[1], JSON.stringify({ version: 1, accounts: [grant] }) + "\n", { mode: 0o600 });
  await writeFile(files[2], refreshSecrets[accounts.indexOf(address)], { mode: 0o600 });
  return files;
}
const files = {
  ada: await credentialFiles("ada", accounts[0], [readScope, sendScope]),
  bea: await credentialFiles("bea", accounts[1], [readScope, sendScope]),
  readonly: await credentialFiles("readonly", accounts[0], [readScope]),
  badClient: await credentialFiles("bad-client", accounts[0], [readScope, sendScope], { client: { client_id: "different-client.apps.googleusercontent.com" } }),
};
const combinedDirectory = join(work, "synthetic-credentials", "both");
await mkdir(combinedDirectory, { recursive: true, mode: 0o700 });
files.both = [join(combinedDirectory, "synthetic-oauth-client.json"), join(combinedDirectory, "terminal-grants.json"),
  ...[files.ada[2], files.bea[2]].map((path) => join(combinedDirectory, path.split(sep).at(-1)))];
await writeFile(files.both[0], await readFile(files.ada[0]), { mode: 0o600 });
await writeFile(files.both[1], JSON.stringify({ version: 1, accounts: [
  JSON.parse(await readFile(files.ada[1], "utf8")).accounts[0], JSON.parse(await readFile(files.bea[1], "utf8")).accounts[0],
] }) + "\n", { mode: 0o600 });
await writeFile(files.both[2], await readFile(files.ada[2]), { mode: 0o600 });
await writeFile(files.both[3], await readFile(files.bea[2]), { mode: 0o600 });
const bodyText = (owner, index) => index === 0 ? `Hello ${owner},\n\nSynthetic live read in WebAssembly.\nNothing touched Google.\n` : `Synthetic ${owner} message ${index}.\n`;
const bodyHtml = '<!doctype html><html><body><h1>Literal HTML fixture</h1><p>A safe café and Japanese 日本語.</p><script>window.mailInjected = "must-never-run";</script><img src="https://invalid-resource.example.test/never-fetch.png"><a href="javascript:alert(1)">Unsafe link text</a></body></html>';
const subject = (owner, index) => index === 0 ? `${owner} live mailbox` : index === 1 ? `${owner} HTML-only mailbox` : `${owner} bounded message ${index}`;
function providerMessage(accountIndex, index, format) {
  const owner = accountIndex === 0 ? "Ada" : "Bea";
  const mimeType = index === 1 ? "text/html" : "text/plain";
  const body = index === 1 ? bodyHtml : bodyText(owner, index);
  return { id: `${owner.toLowerCase()}-message-${index}`, threadId: `${owner.toLowerCase()}-thread-${index}`,
    labelIds: ["INBOX", "UNREAD"], snippet: `Synthetic ${owner} preview ${index}`, historyId: "1200",
    internalDate: "1791712800000", sizeEstimate: 600,
    payload: { partId: "", mimeType, filename: "", headers: [
      { name: "From", value: "Morgan Browser <morgan@example.test>" },
      { name: "To", value: accounts[accountIndex] }, { name: "Subject", value: subject(owner, index) },
      { name: "Message-ID", value: `<${owner.toLowerCase()}-source-${index}@example.test>` },
      { name: "Date", value: "Sun, 11 Oct 2026 10:00:00 +0000" },
      { name: "Reply-To", value: "reply.synthetic@example.test" },
      { name: "References", value: "<prior-thread@example.test>" },
    ], ...(format === "metadata" ? { body: { size: 0 } } : { body: { size: Buffer.byteLength(body), data: Buffer.from(body).toString("base64url") } }) } };
}
function outgoingMessage(record) {
  const separator = record.raw.indexOf("\r\n\r\n");
  assert(separator >= 0, "outgoing message lacks an RFC5322 header separator");
  const headers = record.raw.slice(0, separator).replace(/\r\n[ \t]+/g, " ");
  const values = Object.fromEntries(headers.split("\r\n").map((line) => {
    const colon = line.indexOf(":");
    assert(colon > 0, "outgoing message has a malformed header");
    return [line.slice(0, colon).toLowerCase(), line.slice(colon + 1).trim()];
  }));
  assert.match(values["content-type"], /^text\/plain;\s*charset=UTF-8$/i, "browser composed a non-plain message");
  assert.equal(values["content-transfer-encoding"], "base64");
  assert.match(values["message-id"], /^<omagma-[a-f0-9]{64}@mail\.invalid>$/);
  assert(values.date && /\+0000$/.test(values.date), "outgoing message lost its native date");
  const body = Buffer.from(record.raw.slice(separator + 4).replace(/\s/g, ""), "base64").toString("utf8").replace(/\r\n/g, "\n");
  return { headers: values, body };
}

const staticRequests = [];
const mime = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".wasm": "application/wasm" };
const server = createServer(async (request, response) => {
  staticRequests.push(request.url);
  try {
    const pathname = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
    const path = resolve(site, "." + (pathname === "/" ? "/index.html" : pathname));
    assert(path.startsWith(site + sep), "request escaped site directory");
    response.writeHead(200, { "Content-Type": mime[extname(path)] || "application/octet-stream", "Cache-Control": "no-store" });
    response.end(await readFile(path));
  } catch { response.writeHead(404, { "Content-Type": "text/plain" }); response.end("Not found"); }
});
await new Promise((accept) => server.listen(0, "127.0.0.1", accept));
const origin = `http://127.0.0.1:${server.address().port}`;
const profile = join(work, `chrome-profile-${process.pid}`);
await mkdir(profile, { recursive: true, mode: 0o700 });
const browser = spawn(args.get("--chromium") || "/usr/bin/chromium", [
  "--headless=new", "--disable-gpu", "--disable-background-networking", "--no-first-run",
  "--no-default-browser-check", "--disable-extensions", "--disable-sync", "--metrics-recording-only",
  "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0", `--user-data-dir=${profile}`,
  "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1, EXCLUDE localhost", "about:blank",
], { detached: true, stdio: ["ignore", "ignore", "pipe"], cwd: work,
  env: { PATH: process.env.PATH, LANG: "C.UTF-8", HOME: work, XDG_CONFIG_HOME: join(work, "config"),
    XDG_CACHE_HOME: join(work, "cache"), XDG_DATA_HOME: join(work, "data") } });
let browserLog = "";
browser.stderr.on("data", (bytes) => { browserLog = (browserLog + bytes).slice(-32768); });
let socket;
let captureFailure;
const pause = (milliseconds) => new Promise((accept) => setTimeout(accept, milliseconds));
async function until(condition, message, milliseconds = 15000) {
  const deadline = Date.now() + milliseconds;
  while (!(await condition())) {
    assert(Date.now() < deadline, `${message}; browser status ${browser.exitCode}; ${browserLog.slice(-1000)}`);
    await pause(30);
  }
}
try {
  let port;
  await until(async () => {
    try { port = Number((await readFile(join(profile, "DevToolsActivePort"), "utf8")).split("\n")[0]); return port > 0; }
    catch { return false; }
  }, "Chromium did not expose its owned debug port");
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const target = targets.find((entry) => entry.type === "page");
  assert(target, "owned headless page missing");
  socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((accept, reject) => {
    socket.addEventListener("open", accept, { once: true });
    socket.addEventListener("error", reject, { once: true });
  });
  let sequence = 0;
  const pending = new Map();
  const events = [];
  const transportErrors = [];
  const requests = [];
  const unexpectedDestinations = [];
  let wrongProfile = false;
  let scopeMode = "send";
  let sendMode = "success";
  let listFailure = null;
  let holdNextFullRead = false;
  const heldReads = [];
  const canceledRequests = new Set();
  let activeRequests = 0;
  let maximumActiveRequests = 0;
  socket.addEventListener("message", (event) => {
    const value = JSON.parse(event.data);
    if (value.id) {
      const waiter = pending.get(value.id);
      if (waiter) { pending.delete(value.id); clearTimeout(waiter.timer); value.error ? waiter.reject(new Error(JSON.stringify(value.error))) : waiter.accept(value.result); }
    } else {
      events.push(value);
      if (value.method === "Fetch.requestPaused") void respond(value.params).catch((error) => transportErrors.push(error));
    }
  });
  function call(method, params = {}) {
    return new Promise((accept, reject) => {
      const id = ++sequence;
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP deadline: ${method}`)); }, 15000);
      pending.set(id, { accept, reject, timer });
      socket.send(JSON.stringify({ id, method, params }));
    });
  }
  async function respond({ requestId, request }) {
    const url = new URL(request.url);
    if (url.origin === origin) return call("Fetch.continueRequest", { requestId });
    if (!["https://oauth2.googleapis.com", "https://gmail.googleapis.com"].includes(url.origin)) {
      unexpectedDestinations.push(request.url);
      return call("Fetch.failRequest", { requestId, errorReason: "BlockedByClient" });
    }
    const headers = [
      { name: "Content-Type", value: "application/json" }, { name: "Access-Control-Allow-Origin", value: origin },
      { name: "Access-Control-Allow-Headers", value: "authorization,content-type" },
      { name: "Access-Control-Allow-Methods", value: "GET,POST,OPTIONS" },
      { name: "Cache-Control", value: "no-store" },
    ];
    if (request.method === "OPTIONS") return call("Fetch.fulfillRequest", { requestId, responseCode: 204, responseHeaders: headers, body: "" });
    activeRequests++;
    maximumActiveRequests = Math.max(maximumActiveRequests, activeRequests);
    try {
      const authorization = Object.entries(request.headers).find(([key]) => key.toLowerCase() === "authorization")?.[1];
      let accountIndex = accessSecrets.findIndex((token) => authorization === `Bearer ${token}`);
      const record = { url: request.url, method: request.method, accountIndex, body: request.postData || "", observedAt: Date.now() };
      requests.push(record);
      let payload;
      let responseCode = 200;
      if (url.origin === "https://oauth2.googleapis.com" && url.pathname === "/token" && request.method === "POST") {
        const form = new URLSearchParams(request.postData);
        accountIndex = refreshSecrets.indexOf(form.get("refresh_token"));
        assert(accountIndex >= 0, "refresh request used an unknown synthetic token");
        assert.equal(form.get("client_id"), clientId, "refresh request used the wrong client");
        assert.equal(form.get("client_secret"), clientSecret, "refresh request lost the selected client secret");
        assert.equal(form.get("grant_type"), "refresh_token");
        record.accountIndex = accountIndex;
        payload = { access_token: accessSecrets[accountIndex], token_type: "Bearer", expires_in: 3600,
          ...(scopeMode === "omitted" ? {} : { scope: (scopeMode === "readonly" ? [readScope] : [readScope, sendScope]).join(" ") }) };
      } else {
        assert(accountIndex >= 0, "Gmail request used an unknown synthetic bearer");
        assert.equal(url.origin, "https://gmail.googleapis.com");
        if (url.pathname === "/gmail/v1/users/me/profile" && request.method === "GET") {
          payload = { emailAddress: wrongProfile ? "wrong.browser@example.test" : accounts[accountIndex], messagesTotal: 30, threadsTotal: 30, historyId: "1200" };
        } else if (url.pathname === "/gmail/v1/users/me/messages" && request.method === "GET") {
          const limit = Number(url.searchParams.get("maxResults"));
          assert(limit >= 1 && limit <= 30, "mail head request exceeds the bounded row limit");
          assert(!url.searchParams.has("pageToken"), "browser followed unbounded Gmail pagination");
          const owner = accountIndex === 0 ? "ada" : "bea";
          if (listFailure?.accountIndex === accountIndex) {
            if (listFailure.mode === "forbidden") {
              responseCode = 403;
              payload = { error: { code: 403, message: "Synthetic forbidden response", status: "PERMISSION_DENIED" } };
            } else payload = { messages: [{ deliberatelyMissingMessageId: true }] };
          } else payload = { messages: Array.from({ length: limit }, (_, index) => ({ id: `${owner}-message-${index}`, threadId: `${owner}-thread-${index}` })), nextPageToken: "must-not-be-followed", resultSizeEstimate: 5000 };
        } else if (/^\/gmail\/v1\/users\/me\/messages\/(ada|bea)-message-\d+$/.test(url.pathname) && request.method === "GET") {
          const index = Number(url.pathname.match(/-(\d+)$/)[1]);
          assert.equal(url.pathname.includes("ada-message"), accountIndex === 0, "account session requested another account's message id");
          if (holdNextFullRead && url.searchParams.get("format") === "full") {
            holdNextFullRead = false;
            await new Promise((release) => heldReads.push({ requestId, url: request.url, release }));
          }
          payload = providerMessage(accountIndex, index, url.searchParams.get("format"));
        } else if (url.pathname === "/gmail/v1/users/me/messages/send" && request.method === "POST") {
          const sent = JSON.parse(request.postData);
          assert(typeof sent.raw === "string" && sent.raw.length > 0, "send request has no RFC5322 message");
          record.raw = Buffer.from(sent.raw, "base64url").toString("utf8");
          record.threadId = sent.threadId;
          if (sendMode === "uncertain") return call("Fetch.failRequest", { requestId, errorReason: "ConnectionClosed" });
          payload = { id: "synthetic-sent-message", threadId: sent.threadId || "synthetic-new-thread", labelIds: ["SENT"] };
        } else throw new Error(`unhandled synthetic transport request: ${request.method} ${url.pathname}`);
      }
      try {
        return await call("Fetch.fulfillRequest", { requestId, responseCode, responseHeaders: headers,
          body: Buffer.from(JSON.stringify(payload)).toString("base64") });
      } catch (error) {
        if (canceledRequests.has(requestId) && /interception|request.*not found|resource/i.test(error.message)) return;
        throw error;
      }
    } catch (error) {
      await call("Fetch.failRequest", { requestId, errorReason: "BlockedByClient" });
      throw error;
    } finally { activeRequests--; }
  }
  async function evaluate(expression) {
    const response = await call("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
    assert(!response.exceptionDetails, JSON.stringify(response.exceptionDetails));
    return response.result.value;
  }
  const screen = () => evaluate("window.omagmaDemo.screenText()");
  async function key(key, code, modifiers = 0) {
    const virtual = { Enter: 13, Escape: 27, Backspace: 8, Tab: 9, ArrowDown: 40, ArrowUp: 38, ArrowLeft: 37, ArrowRight: 39 }[key] || (key.length === 1 ? key.toUpperCase().charCodeAt(0) : 0);
    const params = { key, code, modifiers, windowsVirtualKeyCode: virtual, nativeVirtualKeyCode: virtual };
    await call("Input.dispatchKeyEvent", { ...params, type: "keyDown", ...(key === "Enter" ? { text: "\r", unmodifiedText: "\r" } : {}) });
    await call("Input.dispatchKeyEvent", { ...params, type: "keyUp" });
  }
  async function text(value) { await call("Input.insertText", { text: value }); }
  async function focus() { await evaluate("document.querySelector('.xterm-helper-textarea').focus();true"); }
  async function click(selector) {
    const rect = await evaluate(`(()=>{const element=document.querySelector(${JSON.stringify(selector)});element.scrollIntoView({block:'nearest',inline:'nearest'});const r=element.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()`);
    await call("Input.dispatchMouseEvent", { type: "mousePressed", ...rect, button: "left", clickCount: 1 });
    await call("Input.dispatchMouseEvent", { type: "mouseReleased", ...rect, button: "left", clickCount: 1 });
  }
  async function choose(selector, paths) {
    const { root } = await call("DOM.getDocument");
    const { nodeId } = await call("DOM.querySelector", { nodeId: root.nodeId, selector });
    assert(nodeId > 0, `credential file input missing: ${selector}`);
    await call("DOM.setFileInputFiles", { nodeId, files: paths });
  }
  async function screenshot(name) {
    const result = await call("Page.captureScreenshot", { format: "png", captureBeyondViewport: false });
    await writeFile(join(work, name), Buffer.from(result.data, "base64"), { mode: 0o600 });
  }
  captureFailure = async (error) => {
    const stamp = Date.now();
    const details = { error: error.message, screen: await screen(), session: await evaluate("window.omagmaDemo?.sessionInfo?.()"),
      credentialError: await evaluate("document.querySelector('#credential-error')?.textContent"),
      requests: requests.map(({url,method,accountIndex})=>({url,method,accountIndex})), transportErrors: transportErrors.map(String) };
    details.networkFailures = events.filter((event) => event.method === "Network.loadingFailed").map((event) => event.params);
    const redacted = syntheticSecrets.reduce((text, secret) => text.replaceAll(secret, "[synthetic credential]"), JSON.stringify(details, null, 2));
    await writeFile(join(work, `failure-${stamp}.json`), redacted + "\n", { mode: 0o600 });
    await screenshot(`failure-${stamp}.png`);
  };
  const sends = () => requests.filter((request) => request.method === "POST" && new URL(request.url).pathname.endsWith("/messages/send"));
  const session = () => evaluate("window.omagmaDemo.sessionInfo()");
  const credentialError = () => evaluate("document.querySelector('#credential-error').textContent.trim()");
  async function act(action) {
    const before = await evaluate("window.omagmaDemo.frameCount");
    await action();
    await until(async () => (await evaluate("window.omagmaDemo.frameCount")) > before, "terminal input did not complete a rendered frame", 20000);
    assert.equal(await evaluate("window.omagmaDemo.error"), null, "terminal operation stopped the browser experiment");
    return screen();
  }
  async function importFiles(paths) {
    if (!(await evaluate("document.querySelector('#credential-dialog').open"))) await click("#connect-open");
    await until(async () => evaluate("document.querySelector('#credential-dialog').open"), "credential chooser did not open");
    await choose("#credential-clients", [paths[0]]);
    await choose("#credential-grants", [paths[1]]);
    await choose("#credential-tokens", paths.slice(2));
    await click("#credential-connect");
  }
  async function connected(count) {
    await until(async () => {
      const info = await session();
      return info.mode === "live" && info.accountCount === count && !info.busy && (await evaluate("window.omagmaDemo.ready"));
    }, "selected synthetic grants did not connect", 30000);
    await until(async () => evaluate("!document.querySelector('#credential-dialog').open"), "successful credential chooser did not close");
    assert.equal(await evaluate("window.omagmaDemo.error"), null);
    await focus();
  }
  async function disconnect() {
    const info = await session();
    if (info.mode !== "demo") await click("#disconnect-session");
    else if (await evaluate("document.querySelector('#credential-dialog').open")) await click("#credential-cancel");
    await until(async () => {
      const current = await session();
      return current.mode === "demo" && current.accountCount === 0 && !current.busy && (await evaluate("window.omagmaDemo.ready"));
    }, "disconnect did not erase the live session");
    await until(async () => (await screen()).includes("Omagma, now in your browser"), "disconnect did not restore fictional mail");
    assert(!(await screen()).includes("Ada live mailbox") && !(await screen()).includes("Bea live mailbox"), "disconnect retained live message content");
    await focus();
  }
  async function paste(value) {
    const before = await evaluate("window.__omagmaTestPasteCount");
    await evaluate(`navigator.clipboard.writeText(${JSON.stringify(value)})`);
    await key("V", "KeyV", 10);
    await until(async () => (await evaluate("window.__omagmaTestPasteCount")) > before, "owned browser did not deliver a real clipboard paste event");
  }
  async function waitGrace() {
    await until(async () => (await session()).sendPhase === "grace", "explicit confirmation did not enter the local send window");
    assert(await evaluate("!document.querySelector('#send-grace').hidden"), "local send window is not visible");
  }
  async function explicitSend(label) {
    const before = sends().length;
    const startedAt = Date.now();
    await text("y");
    await waitGrace();
    await pause(200);
    assert.equal(sends().length, before, `${label}: send reached Gmail before the local cancellation window`);
    await until(async () => sends().length === before + 1, `${label}: confirmed send did not make exactly one Gmail request`, 18000);
    assert(sends().at(-1).observedAt - startedAt >= 9500, `${label}: send bypassed the ten-second local cancellation window`);
    await until(async () => !(await session()).busy, `${label}: send operation did not settle`, 15000);
    await pause(100);
    assert.equal(sends().length, before + 1, `${label}: browser submitted a duplicate send`);
    return sends().at(-1);
  }
  await call("Page.enable");
  await call("Runtime.enable");
  await call("Emulation.setFocusEmulationEnabled", { enabled: true });
  await call("Page.bringToFront");
  await call("Network.enable");
  await call("Network.setBypassServiceWorker", { bypass: true });
  await call("Fetch.enable", { patterns: [{ urlPattern: "*", requestStage: "Request" }] });
  // An opaque u32 handle crosses WASM's signed i32 JavaScript boundary.
  // Force that boundary deterministically without altering UUID generation,
  // credentials, transport destinations, or the production application.
  await call("Page.addScriptToEvaluateOnNewDocument", { source: `(()=>{
    const native=crypto.getRandomValues.bind(crypto);let handle=0x80000001;
    Object.defineProperty(crypto,'getRandomValues',{value:function(array){
      if(array instanceof Uint32Array&&array.length===1){array[0]=handle++;return array}
      return native(array);
    }});
    window.__omagmaTestPasteCount=0;
    document.addEventListener('paste',()=>window.__omagmaTestPasteCount++,true);
  })()` });
  await call("Browser.grantPermissions", { origin, permissions: ["clipboardReadWrite", "clipboardSanitizedWrite"] });
  await call("Emulation.setDeviceMetricsOverride", { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
  const version = await call("Browser.getVersion");
  await call("Page.navigate", { url: origin + "/" });
  await until(async () => evaluate("window.omagmaDemo?.ready === true || Boolean(window.omagmaDemo?.error)"), "WASM terminal did not load");
  assert.equal(await evaluate("window.omagmaDemo.error"), null);
  assert(await evaluate("typeof WebAssembly.Suspending === 'function' && typeof WebAssembly.promising === 'function'"), "owned browser lacks JSPI support");
  assert.equal(requests.length, 0, "default fictional demo unexpectedly connected Google");
  const nativeGrant = JSON.parse(await readFile(files.ada[1], "utf8")).accounts[0];
  const packetReview = await evaluate(`(async()=>{
    const encoder=new TextEncoder(),decoder=new TextDecoder();let instance;let posted=0;
    const fixture=${JSON.stringify(providerMessage(0, 0, "full"))};
    async function http(_session,mp,ml,up,ul,bp,bl,rp,cap,meta){
      const e=instance.exports;const memory=()=>e.memory.buffer;
      const method=decoder.decode(new Uint8Array(memory(),mp,ml));
      const url=new URL(decoder.decode(new Uint8Array(memory(),up,ul)));
      let payload;
      if(url.pathname.endsWith('/profile'))payload={emailAddress:${JSON.stringify(accounts[0])}};
      else if(url.pathname.endsWith('/messages')&&method==='GET')payload={messages:[{id:fixture.id,threadId:fixture.threadId}]};
      else if(url.pathname.endsWith('/messages/'+fixture.id))payload=fixture;
      else if(url.pathname.endsWith('/messages/send')&&method==='POST'){posted++;payload={id:'packet-synthetic-sent',threadId:'packet-thread'}}
      else throw new Error('Unexpected native packet fixture URL');
      const bytes=encoder.encode(JSON.stringify(payload));if(bytes.length>cap)throw new Error('Fixture exceeds transport capacity');
      new Uint8Array(memory(),rp,bytes.length).set(bytes);const status=new DataView(memory(),meta,8);status.setUint32(0,200,true);status.setUint32(4,bytes.length,true);return 0;
    }
    const module=await WebAssembly.compile(await(await fetch('./omagma.wasm')).arrayBuffer());
    instance=await WebAssembly.instantiate(module,{env:{http_request:new WebAssembly.Suspending(http),now_ms:()=>Date.now()}});
    const e=instance.exports;
    const invoke=name=>WebAssembly.promising(e[name]);
    if(await invoke('init')(140,35)!==0)throw new Error('Packet fixture initialization failed');
    const connection=encoder.encode(JSON.stringify({session:1,nonce:'01234567-89ab-4cde-8123-456789abcdef',
      account:${JSON.stringify(accounts[0])},clientId:${JSON.stringify(clientId)},grantId:${JSON.stringify(nativeGrant.grantId)},
      capabilities:['mail-read','mail-send'],scopes:${JSON.stringify(nativeGrant.scopes)},actualScopes:${JSON.stringify(nativeGrant.scopes)}}));
    new Uint8Array(e.memory.buffer,e.connect_ptr(),connection.length).set(connection);
    if(await invoke('connect')(connection.length)!==0)throw new Error('Packet fixture connection failed');
    async function input(bytes){new Uint8Array(e.memory.buffer,e.input_ptr(),bytes.length).set(bytes);if(await invoke('input')(bytes.length)!==0)throw new Error('Packet fixture input failed')}
    await input(encoder.encode('crecipient@example.test\t\t\tBuffered review regression\tPlain packet body'));
    await input(new Uint8Array([0x13,0x79]));
    const before=posted;
    const review=decoder.decode(new Uint8Array(e.memory.buffer,e.output_ptr(),e.output_len()));
    await input(new Uint8Array([0x79]));
    return {samePacketPosts:before,separateConfirmationPosts:posted,status:e.send_status(),reviewContainsSubject:review.includes('Buffered review regression')};
  })()`);
  assert.equal(packetReview.samePacketPosts, 0, "buffered Ctrl+S+y bypassed the native review frame");
  assert(packetReview.reviewContainsSubject, "buffered review did not produce a native review frame");
  assert.equal(packetReview.separateConfirmationPosts, 1, "separate confirmation did not submit the reviewed native draft exactly once");
  assert.equal(packetReview.status, 1);
  await focus();
  const pastedBrowse = await act(() => paste("c\ny"));
  assert(pastedBrowse.includes("Omagma, now in your browser") && !pastedBrowse.includes("Session draft"), "clipboard command text triggered a browse action");
  assert.equal(sends().length, 0);

  const badClientStart = requests.length;
  await importFiles(files.badClient);
  await until(async () => (await credentialError()).length > 0, "mismatched OAuth client did not fail validation");
  assert.equal(requests.length, badClientStart, "mismatched OAuth client reached Google");
  await disconnect();

  wrongProfile = true;
  const wrongProfileStart = requests.length;
  await importFiles(files.ada);
  await until(async () => (await credentialError()).length > 0, "wrong Google profile identity was not refused", 30000);
  const wrongProfileRequests = requests.slice(wrongProfileStart);
  assert(wrongProfileRequests.some((request) => new URL(request.url).pathname.endsWith("/profile")), "identity rejection did not verify the Google profile");
  assert(!wrongProfileRequests.some((request) => new URL(request.url).pathname.endsWith("/messages")), "wrong identity fetched mailbox messages");
  wrongProfile = false;
  await disconnect();

  listFailure = { accountIndex: 0, mode: "forbidden" };
  await importFiles(files.ada);
  await until(async () => (await credentialError()).length > 0, "first live list denial was not reported", 30000);
  const failedFirstList = await screen();
  assert(!(failedFirstList.includes(accounts[0]) && failedFirstList.includes("Omagma, now in your browser")), "first live list failure displayed fictional mail under a live account");
  listFailure = null;
  await disconnect();

  scopeMode = "readonly";
  await importFiles(files.readonly);
  await connected(1);
  assert.deepEqual((await session()).canSend, [false], "read-only grant enabled sending");
  const readonlyBefore = sends().length;
  const readonlyCompose = await act(() => text("c"));
  assert(/PermissionDenied|read.only|read only/i.test(readonlyCompose), "read-only compose did not explain its permission refusal");
  assert.equal(sends().length, readonlyBefore);
  await disconnect();

  await importFiles(files.ada);
  await connected(1);
  assert.deepEqual((await session()).canSend, [false], "explicitly narrowed token scopes retained the declared send capability");
  await disconnect();

  scopeMode = "omitted";
  await importFiles(files.ada);
  await connected(1);
  assert.deepEqual((await session()).canSend, [true], "valid omitted-scope refresh did not retain the recorded grant scope set");
  assert((await screen()).includes("Synthetic live read in WebAssembly"), "omitted-scope refresh did not permit verified mail reading");
  await disconnect();

  scopeMode = "send";
  await importFiles(files.both);
  await connected(2);
  const liveDiagnostics = await evaluate("JSON.stringify({diagnostics:window.omagmaDemo,session:window.omagmaDemo.sessionInfo(),state:window.omagmaDemo.state()})");
  for (const secret of syntheticSecrets) assert(!liveDiagnostics.includes(secret), "active live diagnostics exposed OAuth credential material");
  assert.equal(await evaluate("window.omagmaDemo.state()"), null, "live diagnostics expose the native mailbox or credential state");
  await act(() => text("1"));
  assert((await screen()).includes("Ada live mailbox") && (await screen()).includes("Hello Ada,"), "first connected account did not render its own message and body");
  listFailure = { accountIndex: 1, mode: "malformed" };
  const failedSwitch = await act(() => text("2"));
  assert(!failedSwitch.includes("Ada live mailbox") && !failedSwitch.includes("Hello Ada,"), "failed second-account list retained the first account's mail");
  const failedReply = await act(() => text("r"));
  assert(!failedReply.includes("Re: Ada live mailbox") && !failedReply.includes("> Hello Ada,"), "failed account switch retained another account's reply source");
  listFailure = null;
  const bea = await act(() => key("r", "KeyR", 2));
  assert(bea.includes("Bea live mailbox") && bea.includes("Hello Bea,"), "second account did not recover its own mailbox after a failed list");
  assert(!bea.includes("Ada live mailbox") && !bea.includes("Hello Ada,"), "second account leaked first-account content");
  await act(() => text("1"));
  const html = await act(() => key("j", "KeyJ"));
  assert(html.includes("Literal HTML fixture") && html.includes("safe café"), "HTML-only provider body did not use the native semantic reader");
  assert(!html.includes("window.mailInjected") && !html.includes("javascript:"), "semantic HTML reader retained active source instructions");
  assert.equal(await evaluate("typeof window.mailInjected"), "undefined", "received HTML executed in the browser");
  await act(() => key("k", "KeyK"));
  await screenshot("live-inbox.png");

  const composeBody = "Hello synthetic recipient,\nPlain UTF-8 café 🚀.\n" + "界🚀 café ".repeat(260) + "\n";
  assert(Buffer.byteLength(composeBody) > 2048, "paste fixture does not cross multiple bridge input chunks");
  await act(() => text("c"));
  await act(() => text("recipient@example.test"));
  await act(() => key("Tab", "Tab"));
  await act(() => key("Tab", "Tab"));
  await act(() => key("Tab", "Tab"));
  await act(() => text("Browser synthetic compose"));
  await act(() => key("Tab", "Tab"));
  await act(() => paste(composeBody));
  const composed = await act(() => key("g", "KeyG", 2));
  assert(composed.includes("café") && composed.includes("synthetic recipient"), "clipboard body was not retained as literal composer text");
  assert.equal(sends().length, 0, "editing a draft sent mail");
  const review = await act(() => key("s", "KeyS", 2));
  assert(review.includes("Browser synthetic compose") && review.includes("recipient@example.test"), "send review lost its subject or recipient");
  assert.equal(sends().length, 0, "opening send review submitted mail");
  await screenshot("live-compose-review.png");
  await act(() => paste("y"));
  assert.equal(sends().length, 0, "pasted review confirmation sent mail");
  assert.equal((await session()).sendPhase, null, "pasted review confirmation started a send window");
  await act(() => key("Enter", "Enter"));
  assert.equal(sends().length, 0, "default Back button submitted mail");
  await act(() => key("s", "KeyS", 2));
  await call("Emulation.setDeviceMetricsOverride", { width: 260, height: 300, deviceScaleFactor: 1, mobile: false });
  await until(async () => (await evaluate("window.omagmaDemo.cols")) < 30, "tiny viewport did not exercise the review visibility guard");
  await pause(100);
  await act(() => text("y"));
  assert.equal(sends().length, 0, "hidden tiny-viewport review submitted mail");
  assert.equal((await session()).sendPhase, null, "hidden tiny-viewport review started a send window");
  await call("Emulation.setDeviceMetricsOverride", { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
  await until(async () => (await evaluate("window.omagmaDemo.cols")) > 100, "normal viewport did not restore readable review");
  await pause(100);
  await focus();
  await text("y");
  await waitGrace();
  assert.equal(sends().length, 0, "explicit confirmation reached Google before the local grace window");
  await act(() => click("#send-grace-cancel"));
  assert.equal(sends().length, 0, "local cancellation made a Gmail send request");
  assert((await screen()).includes("Browser synthetic compose"), "local cancellation discarded the session draft");
  assert.equal(await evaluate("localStorage.getItem('omagma-browser-pending-send-v1')"), null, "local cancellation created a remote-send receipt");
  await focus();
  await act(() => key("s", "KeyS", 2));
  const newSend = await explicitSend("plain compose");
  await until(async () => (await screen()).includes("Gmail confirmed"), "successful synthetic send did not report confirmation");
  const newMail = outgoingMessage(newSend);
  assert(newMail.headers.from.includes(accounts[0]) && newMail.headers.to.includes("recipient@example.test"));
  assert.equal(newMail.headers.subject, "Browser synthetic compose");
  assert.equal(newMail.body, composeBody, "plain MIME body changed pasted Unicode or line endings");
  assert.equal(newSend.threadId ?? null, null, "new compose unexpectedly joined an existing thread");

  await focus();
  await act(() => text("r"));
  await act(() => paste("Browser reply.\n"));
  await act(() => key("s", "KeyS", 2));
  const replyBefore = sends().length;
  const replySend = await explicitSend("plain reply");
  assert.equal(sends().length, replyBefore + 1);
  const replyMail = outgoingMessage(replySend);
  assert(replyMail.headers.from.includes(accounts[0]) && replyMail.headers.to.includes("reply.synthetic@example.test"), "reply lost the verified sender or incoming Reply-To");
  assert.equal(replyMail.headers.subject, "Re: Ada live mailbox");
  assert.equal(replySend.threadId, "ada-thread-0");
  assert.equal(replyMail.headers["in-reply-to"], "<ada-source-0@example.test>");
  assert.equal(replyMail.headers.references, "<prior-thread@example.test> <ada-source-0@example.test>");
  assert(replyMail.body.startsWith("Browser reply.\n") && replyMail.body.includes("> Hello Ada,"), "plain reply lost its typed prefix or quoted body");

  // Pause a full-body request, then exercise resize/input/disconnect while
  // the WASM stack is suspended. Old responses may not revive that session.
  holdNextFullRead = true;
  await focus();
  await key("j", "KeyJ");
  await until(async () => heldReads.length === 1, "body request was not suspended by the synthetic transport");
  const heldRequestCount = requests.length;
  await text("jj");
  await call("Emulation.setDeviceMetricsOverride", { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false });
  await pause(100);
  assert.equal(requests.length, heldRequestCount, "WASM reentered the transport while another body request was suspended");
  await click("#disconnect-session");
  for (const held of heldReads) { canceledRequests.add(held.requestId); held.release(); }
  await disconnect();
  await pause(200);
  assert(!(await screen()).includes("Ada live mailbox") && !(await screen()).includes("Literal HTML fixture"), "late body response revived a disconnected account");
  assert.equal(await evaluate("window.omagmaDemo.error"), null, "suspended disconnect trapped the WASM instance");
  await call("Emulation.setDeviceMetricsOverride", { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
  await pause(100);

  await importFiles(files.ada);
  await connected(1);
  await act(() => text("c"));
  await act(() => text("uncertain.recipient@example.test"));
  for (let field = 0; field < 3; field++) await act(() => key("Tab", "Tab"));
  await act(() => text("Synthetic uncertain send"));
  await act(() => key("Tab", "Tab"));
  await act(() => paste("Protected uncertain body.\n"));
  await act(() => key("s", "KeyS", 2));
  sendMode = "uncertain";
  const uncertainBefore = sends().length;
  const uncertainSend = await explicitSend("uncertain network outcome");
  await until(async () => /outcome unknown|draft protected/i.test(await screen()), "unknown write outcome did not protect the draft");
  await focus();
  await act(() => key("s", "KeyS", 2));
  await act(() => text("y"));
  await pause(200);
  assert.equal(sends().length, uncertainBefore + 1, "uncertain send retried the Gmail mutation");
  const receipt = await evaluate("JSON.parse(localStorage.getItem('omagma-browser-pending-send-v1'))");
  assert.deepEqual(Object.keys(receipt).sort(), ["id", "startedAt"], "uncertain receipt persisted account, message or credential data");
  assert.equal(typeof receipt.id, "string");
  assert.equal(typeof receipt.startedAt, "number");
  await screenshot("live-uncertain.png");
  const sendIds = sends().map((request) => outgoingMessage(request).headers["message-id"]);
  assert.equal(new Set(sendIds).size, sends().length, "new session sends reused a native RFC5322 operation id");
  assert.equal(outgoingMessage(uncertainSend).body, "Protected uncertain body.\n");
  const beforeReload = requests.length;
  const reloadMarker = events.length;
  await call("Page.reload", { ignoreCache: true });
  await until(async () => events.slice(reloadMarker).some((event) => event.method === "Page.loadEventFired"), "reload did not create a new document");
  await until(async () => evaluate("window.omagmaDemo?.ready === true"), "reload did not recreate fictional mode");
  assert.equal((await session()).mode, "demo");
  assert.equal((await session()).accountCount, 0, "reload restored private live credentials");
  assert.equal(requests.length, beforeReload, "reload retried a Google operation");
  assert(await evaluate("!document.querySelector('#send-uncertainty').hidden"), "reload lost the generic uncertain-send warning");
  const privacy = await evaluate(`(async()=>({
    diagnostics:JSON.stringify(window.omagmaDemo),session:window.omagmaDemo.sessionInfo(),html:document.documentElement.outerHTML,
    localStorage:Object.fromEntries(Object.keys(localStorage).map(key=>[key,localStorage.getItem(key)])),
    sessionStorage:Object.fromEntries(Object.keys(sessionStorage).map(key=>[key,sessionStorage.getItem(key)])),
    databases:await indexedDB.databases(),caches:await caches.keys(),cookies:document.cookie
  }))()`);
  const privacyText = JSON.stringify(privacy) + JSON.stringify(events.filter((event) => event.method === "Runtime.consoleAPICalled" || event.method === "Runtime.exceptionThrown"));
  for (const secret of syntheticSecrets) assert(!privacyText.includes(secret), "credentials leaked into browser diagnostics, logs or persistence");
  assert.deepEqual(privacy.sessionStorage, {});
  assert.deepEqual(privacy.databases, []);
  assert.deepEqual(privacy.caches, []);
  assert.equal(privacy.cookies, "");
  assert.deepEqual(Object.keys(privacy.localStorage), ["omagma-browser-pending-send-v1"]);
  assert(!JSON.stringify(privacy.localStorage).includes("Protected uncertain body") && !JSON.stringify(privacy.localStorage).includes(accounts[0]), "uncertain receipt retained mail content or account details");
  await click("#send-acknowledge");
  assert.equal(await evaluate("localStorage.getItem('omagma-browser-pending-send-v1')"), null, "explicit acknowledgement did not clear the generic receipt");
  assert.deepEqual(transportErrors, [], "synthetic transport handler failed");
  assert.deepEqual(unexpectedDestinations, [], "message content or host attempted an unapproved external destination");
  const report = { synthetic: true, desktopUsed: false, actualGoogleRequests: 0, browser: version.product,
    fixedGoogleUrlsIntercepted: true, defaultDemoRequests: 0, requestCount: requests.length,
    maximumActiveRequests, staticRequests, packetReview, mismatchedClientRejected: true, profileIdentityChecked: true,
    failedAccountListsIsolated: true, readonlyCapabilitiesAndNarrowedScopes: true, omittedScopeRefresh: true,
    twoAccountIsolation: true, nativePlainAndSemanticHtmlRead: true, bracketedClipboardPasteSafe: true,
    plainComposeAndReply: true, tinyReviewCannotSend: true, localCancellationWrites: 0,
    confirmedComposeRequests: 1, confirmedReplyRequests: 1, uncertainSendRequests: 1,
    tenSecondGraceVerified: true, suspendedResizeAndDisconnect: true, unknownOutcomeNoRetry: true,
    reloadNoCredentialsOrRetry: true, genericReceiptAcknowledgement: true,
    credentialPersistenceOrLogLeaks: 0 };
  await writeFile(join(work, "live-acceptance.json"), JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
  console.log(JSON.stringify(report));
} catch (error) {
  try { await captureFailure?.(error); } catch {}
  throw error;
} finally {
  socket?.close();
  try { process.kill(-browser.pid, "SIGTERM"); } catch (error) { if (error.code !== "ESRCH") throw error; }
  await Promise.race([new Promise((accept) => browser.once("exit", accept)), pause(3000)]);
  if (browser.exitCode === null && browser.signalCode === null) {
    try { process.kill(-browser.pid, "SIGKILL"); } catch (error) { if (error.code !== "ESRCH") throw error; }
  }
  await new Promise((accept) => server.close(accept));
}
