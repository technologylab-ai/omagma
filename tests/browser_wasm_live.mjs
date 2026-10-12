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
import { originalFixture, originalProviderMessage, originalAttachment, originalRecipients, decodeOutgoingOriginal } from "./browser_originals_fixtures.mjs";

const args = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  assert(process.argv[index].startsWith("--") && process.argv[index + 1], `invalid argument ${process.argv[index]}`);
  args.set(process.argv[index], process.argv[index + 1]);
}
const originalsFixtureEnabled = args.get("--originals-only") === "true" || args.get("--originals-size-only") === "true" || args.get("--originals-medium-only") === "true";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const site = resolve(args.get("--site-dir") || join(root, "web-demo/dist"));
const work = resolve(args.get("--work-dir") || "/tmp/omagma-wasm-browser-live");
let suppliedOrigin = null;
if (args.has("--origin")) {
  const url = new URL(args.get("--origin"));
  assert(url.protocol === "http:" && ["127.0.0.1", "localhost", "[::1]"].includes(url.hostname) && !url.username && !url.password && url.pathname === "/" && !url.search && !url.hash, "--origin must be an owned loopback HTTP origin");
  suppliedOrigin = url.origin;
}
let suppliedLaunchURL = null;
let localSessionNonce = "";
if (args.get("--native-connect") === "true") {
  assert(suppliedOrigin, "--native-connect requires --origin for the real native server");
  let url;
  try { url = new URL(process.env.OMAGMA_TEST_LAUNCH_URL || ""); }
  catch { assert.fail("native server test launch URL was not provided privately"); }
  const fragment = url.hash.match(/^#omagma-session=([a-f0-9]{64})$/);
  assert(url.origin === suppliedOrigin && url.pathname === "/" && !url.search && fragment, "native test launch URL does not match the owned guarded server");
  suppliedLaunchURL = url.href;
  localSessionNonce = fragment[1];
}
assert(work !== site && !site.startsWith(work + sep), "browser scratch directory must not contain the site");
await mkdir(work, { recursive: true, mode: 0o700 });
const readScope = "https://www.googleapis.com/auth/gmail.readonly";
const sendScope = "https://www.googleapis.com/auth/gmail.send";
const contactsScope = "https://www.googleapis.com/auth/contacts.readonly";
const capabilitiesFor = (scopes) => ["mail-read", ...(scopes.includes(sendScope) ? ["mail-send"] : []), ...(scopes.includes(contactsScope) ? ["contacts-read"] : [])];
const clientId = "synthetic-browser-test.apps.googleusercontent.com";
const clientSecret = "synthetic-client-secret-never-valid";
const accounts = ["ada.browser@example.test", "bea.browser@example.test"];
const refreshSecrets = accounts.map((_, index) => `synthetic-refresh-${index}-never-valid`);
const accessSecrets = accounts.map((_, index) => `synthetic-access-${index}-never-valid`);
const syntheticSecrets = [clientSecret, ...refreshSecrets, ...accessSecrets, ...(localSessionNonce ? [localSessionNonce] : [])];
const hashParts = (parts) => createHash("sha256").update(parts.map((part) => part + "\0").join("")).digest("hex");
async function credentialFiles(name, address, scopes, changes = {}) {
  const directory = join(work, "synthetic-credentials", name);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const grantId = hashParts(["omagma-terminal-grant-v1", ...scopes]);
  const grant = { account: address, clientFile: "synthetic-oauth-client.json", clientId,
    grantId, capabilities: capabilitiesFor(scopes),
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
async function bundleRecord(address, scopes) {
  return { account: address, clientId, clientSecret, grantId: hashParts(["omagma-terminal-grant-v1", ...scopes]),
    capabilities: capabilitiesFor(scopes),
    scopes, refreshToken: refreshSecrets[accounts.indexOf(address)] };
}
const adaBundleRecord = await bundleRecord(accounts[0], [readScope, sendScope]);
const beaBundleRecord = await bundleRecord(accounts[1], [readScope, sendScope]);
async function connectionBundle(name, entries, changes = {}) {
  const directory = join(work, "synthetic-credentials", "bundles");
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const path = join(directory, `${name}.json`);
  await writeFile(path, JSON.stringify({ format: "omagma-browser-connection", version: 1, accounts: entries, ...changes }) + "\n", { mode: 0o600 });
  return path;
}
const bundles = {
  both: await connectionBundle("both", [adaBundleRecord, beaBundleRecord]),
  ada: await connectionBundle("ada", [adaBundleRecord]),
  readonly: await connectionBundle("readonly", [await bundleRecord(accounts[0], [readScope])]),
  workflows: await connectionBundle("workflows", await Promise.all(accounts.map(address => bundleRecord(address, [readScope, sendScope, contactsScope])))),
  contactsReadonly: await connectionBundle("contacts-readonly", [await bundleRecord(accounts[0], [readScope, contactsScope])]),
  workflowAda: await connectionBundle("workflow-ada", [await bundleRecord(accounts[0], [readScope, sendScope, contactsScope])]),
  invalid: [
    ["format", await connectionBundle("bad-format", [adaBundleRecord], { format: "unsupported-browser-format" })],
    ["version", await connectionBundle("bad-version", [adaBundleRecord], { version: 2 })],
    ["grant identity", await connectionBundle("bad-grant", [{ ...adaBundleRecord, grantId: "0".repeat(64) }])],
    ["capabilities", await connectionBundle("bad-capabilities", [{ ...adaBundleRecord, capabilities: ["mail-send"] }])],
    ["scope binding", await connectionBundle("bad-scopes", [{ ...adaBundleRecord, scopes: [readScope] }])],
    ["client", await connectionBundle("bad-client", [{ ...adaBundleRecord, clientId: "unrecognized-client.example.test" }])],
    ["missing token", await connectionBundle("missing-token", [{ ...adaBundleRecord, refreshToken: "" }])],
    ["account limit", await connectionBundle("too-many-accounts", Array.from({ length: 4 }, () => adaBundleRecord))],
  ],
};
const bodyText = (owner, index) => index === 0 ? `Hello ${owner},\n\nSynthetic live read in WebAssembly.\nNothing touched Google.\n` : `Synthetic ${owner} message ${index}.\n`;
const bodyHtml = '<!doctype html><html><body><h1>Literal HTML fixture</h1><p>A safe café and Japanese 日本語.</p><script>window.mailInjected = "must-never-run";</script><img src="https://invalid-resource.example.test/never-fetch.png"><a href="javascript:alert(1)">Unsafe link text</a></body></html>';
const subject = (owner, index) => index === 0 ? `${owner} live mailbox` : index === 1 ? `${owner} HTML-only mailbox` : `${owner} bounded message ${index}`;
function providerMessage(accountIndex, index, format) {
  if (originalsFixtureEnabled && [0, 2, 3, 4, 5, 6, 8].includes(index)) return originalProviderMessage(accountIndex, format, index);
  const owner = accountIndex === 0 ? "Ada" : "Bea";
  const mimeType = index === 1 ? "text/html" : "text/plain";
  const body = index === 1 ? bodyHtml : bodyText(owner, index);
  return { id: `${owner.toLowerCase()}-message-${index}`, threadId: `${owner.toLowerCase()}-thread-${index}`,
    labelIds: args.get("--workflows-only") === "true" ? (index === 2 ? [] : index === 3 ? ["UNREAD"] : index === 1 ? ["INBOX"] : index === 4 ? ["INBOX", "UNREAD", "CATEGORY_UPDATES"] : ["INBOX", "UNREAD"]) : ["INBOX", "UNREAD"], snippet: `Synthetic ${owner} preview ${index}`, historyId: "1200",
    internalDate: String(1791712800000 - index * 60000), sizeEstimate: 600,
    payload: { partId: "", mimeType, filename: "", headers: [
      { name: "From", value: "Morgan Browser <morgan@example.test>" },
      { name: "To", value: accounts[accountIndex] }, { name: "Subject", value: subject(owner, index) },
      { name: "Message-ID", value: `<${owner.toLowerCase()}-source-${index}@example.test>` },
      { name: "Date", value: "Sun, 11 Oct 2026 10:00:00 +0000" },
      { name: "Reply-To", value: "reply.synthetic@example.test" },
      { name: "References", value: "<prior-thread@example.test>" },
    ], ...(format === "metadata" ? { body: { size: 0 } } : { body: { size: Buffer.byteLength(body), data: Buffer.from(body).toString("base64url") } }) } };
}
const contactNames = [["Ada Contact One", "Ada Café Contact"], ["Bea Contact One", "Bea Café Contact"]];
const contactAddresses = [["ada.contact@example.test", "ada.cafe@example.test"], ["bea.contact@example.test", "bea.cafe@example.test"]];
function providerContacts(accountIndex, query = "") {
  const owner = accountIndex === 0 ? "ada" : "bea";
  return contactNames[accountIndex].map((name, index) => ({
    resourceName: `people/${owner}-contact-${index}`, etag: `synthetic-${owner}-person-etag-${index}`,
    names: [{ displayName: name, givenName: name, metadata: { primary: true, source: { type: "CONTACT", id: `${owner}-contact-${index}` } } }],
    emailAddresses: [{ value: contactAddresses[accountIndex][index], type: "work", metadata: { primary: true } }],
    metadata: { sources: [{ type: "CONTACT", id: `${owner}-contact-${index}`, etag: `synthetic-${owner}-source-etag-${index}` }] },
  })).filter(person => !query || JSON.stringify(person).toLowerCase().includes(query.toLowerCase()));
}
function providerRemoteContact(accountIndex) {
  const owner = accountIndex === 0 ? "ada" : "bea";
  return { resourceName: `people/${owner}-outside-first-page`, names: [{ displayName: `${owner.toUpperCase()} Contact Outside First Page`, metadata: { primary: true } }],
    emailAddresses: [{ value: `remote.${owner}@example.test` }], metadata: { sources: [{ type: "CONTACT", etag: `outside-${owner}` }] } };
}
function outgoingMessage(record, { allowMarkdown = false } = {}) {
  const separator = record.raw.indexOf("\r\n\r\n");
  assert(separator >= 0, "outgoing message lacks an RFC5322 header separator");
  const headers = record.raw.slice(0, separator).replace(/\r\n[ \t]+/g, " ");
  const values = Object.fromEntries(headers.split("\r\n").map((line) => {
    const colon = line.indexOf(":");
    assert(colon > 0, "outgoing message has a malformed header");
    return [line.slice(0, colon).toLowerCase(), line.slice(colon + 1).trim()];
  }));
  assert.match(values["message-id"], /^<omagma-[a-f0-9]{64}@mail\.invalid>$/);
  assert(values.date && /\+0000$/.test(values.date), "outgoing message lost its native date");
  const payload = record.raw.slice(separator + 4);
  const decode = (value) => Buffer.from(value.replace(/\s/g, ""), "base64").toString("utf8").replace(/\r\n/g, "\n");
  if (/^text\/plain;\s*charset=UTF-8$/i.test(values["content-type"])) {
    assert.equal(values["content-transfer-encoding"], "base64");
    return { headers: values, body: decode(payload), html: null };
  }
  assert(allowMarkdown && /^multipart\/alternative;/i.test(values["content-type"]), "unexpected outgoing message format");
  const leaves = [];
  function parseEntity(headers, body, depth = 0) {
    assert(depth <= 4 && leaves.length < 10, "outgoing MIME structure exceeds the bounded fixture");
    const type = headers["content-type"] || "";
    if (/^multipart\//i.test(type)) {
      const boundary = type.match(/boundary=(?:"([^"\r\n]+)"|([^;\s]+))/i);
      assert(boundary, "multipart has no boundary");
      const marker = "--" + (boundary[1] || boundary[2]);
      assert(body.includes(marker + "--"), "multipart is incomplete");
      for (const part of body.split(marker).slice(1)) {
        if (part.startsWith("--")) break;
        const entity = part.replace(/^\r\n/, "");
        const split = entity.indexOf("\r\n\r\n");
        assert(split >= 0, "outgoing MIME part has no header separator");
        const partHeaders = Object.fromEntries(entity.slice(0, split).replace(/\r\n[ \t]+/g, " ").split("\r\n").map(line => {
          const colon = line.indexOf(":");assert(colon > 0);return [line.slice(0, colon).toLowerCase(), line.slice(colon + 1).trim()];
        }));
        parseEntity(partHeaders, entity.slice(split + 4), depth + 1);
      }
    } else {
      assert.equal(headers["content-transfer-encoding"], "base64");
      leaves.push({ type, text: /^text\//i.test(type) ? decode(body) : null, contentId: headers["content-id"] });
    }
  }
  parseEntity(values, payload);
  const plain = leaves.filter(part => /^text\/plain;\s*charset=UTF-8$/i.test(part.type));
  const html = leaves.filter(part => /^text\/html;\s*charset=UTF-8$/i.test(part.type));
  assert.equal(plain.length, 1, "Markdown MIME lost or duplicated its plain alternative");
  assert.equal(html.length, 1, "Markdown MIME lost or duplicated its HTML alternative");
  assert(leaves.every(part => /^text\/(plain|html);/i.test(part.type) || (/^image\/png$/i.test(part.type) && /omagma.*logo/i.test(part.contentId || ""))), "Markdown added an unexpected attachment");
  return { headers: values, body: plain[0].text, html: html[0].text };

}

const staticRequests = [];
const mime = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".wasm": "application/wasm" };
const server = suppliedOrigin ? null : createServer(async (request, response) => {
  staticRequests.push(request.url);
  try {
    const pathname = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
    const path = resolve(site, "." + (pathname === "/" ? "/index.html" : pathname));
    assert(path.startsWith(site + sep), "request escaped site directory");
    response.writeHead(200, { "Content-Type": mime[extname(path)] || "application/octet-stream", "Cache-Control": "no-store" });
    response.end(await readFile(path));
  } catch { response.writeHead(404, { "Content-Type": "text/plain" }); response.end("Not found"); }
});
if (server) await new Promise((accept) => server.listen(0, "127.0.0.1", accept));
const origin = suppliedOrigin || `http://127.0.0.1:${server.address().port}`;
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
  const linearMemorySamples = [];
  let wrongProfile = false;
  let scopeMode = "send";
  let mailVariant = "";
  let sendMode = "success";
  let listFailure = null;
  let originalAttachmentFailure = null;
  let holdNextFullRead = false;
  let holdNextProfile = false;
  const heldProfiles = [];
  const heldReads = [];
  const canceledRequests = new Set();
  let expectedDialog = null;
  const handledDialogs = [];
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
      if (value.method === "Page.javascriptDialogOpening") void handleOwnedDialog(value.params).catch(error => transportErrors.push(error));
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
  async function handleOwnedDialog(params) {
    const intent = expectedDialog;
    expectedDialog = null;
    if (!intent || params.type !== intent.type || (intent.type === "confirm" && !/disconnect.*discard.*drafts/i.test(params.message))) {
      await call("Page.handleJavaScriptDialog", { accept: false });
      throw new Error(`Unexpected owned browser dialog: ${params.type}`);
    }
    await call("Page.handleJavaScriptDialog", { accept: intent.accept });
    handledDialogs.push({ purpose: intent.purpose, type: params.type, accept: intent.accept });
  }
  async function disconnectDecision(accept) {
    assert.equal(expectedDialog, null, "another dialog decision is pending");
    const intent = { purpose: accept ? "discard-session-drafts" : "keep-session-drafts", type: "confirm", accept };
    const before = handledDialogs.length;
    expectedDialog = intent;
    try { await click("#disconnect-session"); await pause(50); }
    finally { if (expectedDialog === intent) expectedDialog = null; }
    if (!accept) assert(handledDialogs.slice(before).some(dialog => dialog.purpose === intent.purpose), "Cancel-disconnect test did not display a draft-loss confirmation");
  }
  async function respond({ requestId, request, networkId }) {
    const url = new URL(request.url);
    if (url.origin === origin) return call("Fetch.continueRequest", { requestId });
    if (!["https://oauth2.googleapis.com", "https://gmail.googleapis.com", "https://people.googleapis.com"].includes(url.origin)) {
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
    if (originalsFixtureEnabled && /\/(messages\/ada-message-[48]|threads\/ada-thread-[48])(\/attachments\/[^/?]+)?$/.test(url.pathname) && url.searchParams.get("format") !== "metadata") {
      await sampleMemory(`GET ${url.pathname.split("/").slice(-2).join("/")} before response`);
    }
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
          ...(scopeMode === "omitted" ? {} : { scope: (scopeMode === "readonly" ? [readScope] : scopeMode === "workflows" ? [readScope, sendScope, contactsScope] : [readScope, sendScope]).join(" ") }) };
      } else if (url.origin === "https://people.googleapis.com") {
        assert(accountIndex >= 0, "People request used an unknown synthetic bearer");
        assert.equal(request.method, "GET", "browser attempted a People mutation");
        const expectedFields = "names,emailAddresses,metadata";
        if (url.pathname === "/v1/people/me/connections") {
          assert.equal(url.searchParams.get("personFields"), expectedFields);
          assert.equal(url.searchParams.get("sources"), "READ_SOURCE_TYPE_CONTACT");
          assert(Number(url.searchParams.get("pageSize")) >= 1 && Number(url.searchParams.get("pageSize")) <= 100, "People list exceeds its bounded contact limit");
          assert(!url.searchParams.get("pageToken"), "browser followed unbounded People pagination");
          payload = { connections: providerContacts(accountIndex), nextPageToken: "must-not-be-followed", totalPeople: 5000, totalItems: 5000 };
        } else if (url.pathname === "/v1/people:searchContacts") {
          assert.equal(url.searchParams.get("readMask"), expectedFields);
          assert(Number(url.searchParams.get("pageSize")) >= 1 && Number(url.searchParams.get("pageSize")) <= 30, "People search exceeds the bounded page limit");
          const query = url.searchParams.get("query") || "";
          const outside = providerRemoteContact(accountIndex);
          const matches = [...providerContacts(accountIndex, query), ...(JSON.stringify(outside).toLowerCase().includes(query.toLowerCase()) ? [outside] : [])];
          payload = { results: matches.map(person => ({ person })), nextPageToken: "must-not-be-followed" };
        } else throw new Error(`unhandled synthetic People request: ${request.method} ${url.pathname}`);
      } else {
        assert(accountIndex >= 0, "Gmail request used an unknown synthetic bearer");
        assert.equal(url.origin, "https://gmail.googleapis.com");
        if (url.pathname === "/gmail/v1/users/me/profile" && request.method === "GET") {
          if (holdNextProfile) {
            holdNextProfile = false;
            await new Promise(release => heldProfiles.push({ requestId, networkId, release }));
          }
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
          } else {
            let indices = Array.from({ length: limit }, (_, index) => index);
            if (args.get("--workflows-only") === "true") {
              const query = (url.searchParams.get("q") || "").trim();
              const labels = url.searchParams.getAll("labelIds");
              if (query.includes("-in:inbox")) indices = [2, 3];
              else if (query === "is:unread" || labels.includes("UNREAD")) indices = indices.filter(index => index !== 1 && index !== 2);
              else if (labels.includes("INBOX")) indices = indices.filter(index => index !== 2 && index !== 3);
              if (query === "live mailbox") indices = [0];
              if (query === "category:updates") indices = [4];
            }
            payload = { messages: indices.map(index => ({ id: `${owner}-message-${index}`, threadId: `${owner}-thread-${index}` })), nextPageToken: "must-not-be-followed", resultSizeEstimate: 5000 };
          }
        } else if (url.pathname === "/gmail/v1/users/me/settings/sendAs" && request.method === "GET") {
          const owner = accountIndex === 0 ? "ada" : "bea";
          payload = { sendAs: [
            { sendAsEmail: accounts[accountIndex], displayName: "Synthetic Browser", signature: "", isPrimary: true, isDefault: true, verificationStatus: "accepted" },
            { sendAsEmail: `${owner}.alias@example.test`, displayName: "Verified synthetic alias", signature: "", isPrimary: false, isDefault: false, verificationStatus: "accepted" },
            { sendAsEmail: `${owner}.unverified@example.test`, displayName: "Unverified synthetic alias", signature: "", isPrimary: false, isDefault: false, verificationStatus: "pending" },
          ] };
        } else if (originalsFixtureEnabled && /^\/gmail\/v1\/users\/me\/messages\/(ada|bea)-message-[0234568]\/attachments\/(ada|bea)-source-(image|style|document)(-[234568](-\d+)?)?$/.test(url.pathname) && request.method === "GET") {
          assert.equal(url.pathname.includes("ada-message"), accountIndex === 0, "source attachment request crossed account ownership");
          payload = originalAttachment(accountIndex, url.pathname.split("/").at(-1), Number(url.pathname.match(/-message-(\d+)\//)[1]));
          if (originalAttachmentFailure === url.pathname.split("/").at(-1)) payload.data = Buffer.from(payload.data, "base64url").subarray(0, -1).toString("base64url");
        } else if (/^\/gmail\/v1\/users\/me\/messages\/(ada|bea)-message-\d+$/.test(url.pathname) && request.method === "GET") {
          const index = Number(url.pathname.match(/-(\d+)$/)[1]);
          assert.equal(url.pathname.includes("ada-message"), accountIndex === 0, "account session requested another account's message id");
          if (holdNextFullRead && url.searchParams.get("format") === "full") {
            holdNextFullRead = false;
            await new Promise((release) => heldReads.push({ requestId, networkId, url: request.url, release }));
          }
          payload = providerMessage(accountIndex, index, url.searchParams.get("format"));
          if (mailVariant && accountIndex === 0 && index === 0) {
            payload.payload.headers.find(header => header.name === "Subject").value = `${mailVariant} Ada live mailbox`;
            if (url.searchParams.get("format") === "full") {
              const body = `${mailVariant} synthetic cache body.\n`;
              payload.payload.body = { size: Buffer.byteLength(body), data: Buffer.from(body).toString("base64url") };
            }
          }
        } else if (/^\/gmail\/v1\/users\/me\/threads\/(ada|bea)-thread-\d+$/.test(url.pathname) && request.method === "GET") {
          const index = Number(url.pathname.match(/-(\d+)$/)[1]);
          assert.equal(url.pathname.includes("ada-thread"), accountIndex === 0, "thread request crossed accounts");
          if (holdNextFullRead) {
            holdNextFullRead = false;
            await new Promise(release => heldReads.push({ requestId, networkId, url: request.url, release }));
          }
          payload = { id: `${accountIndex === 0 ? "ada" : "bea"}-thread-${index}`, historyId: "1200", messages: [providerMessage(accountIndex, index, "full")] };
        } else if (url.pathname === "/gmail/v1/users/me/messages/send" && request.method === "POST") {
          const sent = JSON.parse(request.postData);
          assert(typeof sent.raw === "string" && sent.raw.length > 0, "send request has no RFC5322 message");
          record.rawBytes = Buffer.from(sent.raw, "base64url");
          record.raw = record.rawBytes.toString("utf8"); // Existing text-only oracles; original MIME uses rawBytes.
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
  async function sampleMemory(stage) {
    if (!originalsFixtureEnabled || linearMemorySamples.length >= 128) return;
    const bytes = await evaluate("window.__omagmaTestWasmMemory?.buffer.byteLength ?? 0");
    assert(Number.isInteger(bytes) && bytes >= 0 && bytes <= 64 * 1024 * 1024, "WASM linear memory exceeded its unchanged 64 MiB maximum");
    linearMemorySamples.push({ stage, bytes, requestCount: requests.length });
  }
  const screen = () => evaluate("window.omagmaDemo.screenText()");
  async function key(key, code, modifiers = 0) {
    const virtual = { Enter: 13, Escape: 27, Backspace: 8, Tab: 9, ArrowDown: 40, ArrowUp: 38, ArrowLeft: 37, ArrowRight: 39,
      "/": 191, "\\": 220, ".": 190, ",": 188, "-": 189, ";": 186, ":": 186, "'": 222, "=": 187 }[key] || (key.length === 1 ? key.toUpperCase().charCodeAt(0) : 0);
    const params = { key, code, modifiers, windowsVirtualKeyCode: virtual, nativeVirtualKeyCode: virtual };
    const printable = key.length === 1 && !(modifiers & 7);
    await call("Input.dispatchKeyEvent", { ...params, type: "keyDown", ...(key === "Enter" ? { text: "\r", unmodifiedText: "\r" } : printable ? { text: key, unmodifiedText: key } : {}) });
    await call("Input.dispatchKeyEvent", { ...params, type: "keyUp" });
  }
  async function text(value) {
    // xterm's screenReaderMode deliberately ignores bare insertText input
    // events. Real printable keydown/keyup events exercise its keyboard path.
    for (const character of value) {
      const code = /^[A-Za-z]$/.test(character) ? `Key${character.toUpperCase()}` : /^[0-9]$/.test(character) ? `Digit${character}` : character === " " ? "Space" : "";
      await key(character, code);
    }
  }
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
    await sampleMemory("failure");
    const stamp = Date.now();
    const details = { error: error.message, screen: await screen(), session: await evaluate("window.omagmaDemo?.sessionInfo?.()"),
      inputState: await evaluate(`(()=>{const el=document.activeElement,ta=document.querySelector('.xterm-helper-textarea');return {active:{tagName:el?.tagName,className:el?.className,value:el?.value,disabled:el?.disabled,readOnly:el?.readOnly},textarea:{attributes:Object.fromEntries([...ta.attributes].map(a=>[a.name,a.value])),value:ta.value,disabled:ta.disabled,readOnly:ta.readOnly},runtime:document.querySelector('#runtime-status')?.textContent,hint:document.querySelector('#request-status-hint')?.textContent,cacheButtonDisabled:document.querySelector('#cache-clear')?.disabled}})()`),
      credentialError: await evaluate("document.querySelector('#credential-error')?.textContent"), linearMemorySamples,
      requests: requests.map(({url,method,accountIndex})=>({url,method,accountIndex})), transportErrors: transportErrors.map(String) };
    details.networkFailures = events.filter((event) => event.method === "Network.loadingFailed").map((event) => event.params);
    const redacted = syntheticSecrets.reduce((text, secret) => text.replaceAll(secret, "[synthetic credential]"), JSON.stringify(details, null, 2));
    await writeFile(join(work, `failure-${stamp}.json`), redacted + "\n", { mode: 0o600 });
    await screenshot(`failure-${stamp}.png`);
  };
  const peopleRequests = () => requests.filter(request => new URL(request.url).origin === "https://people.googleapis.com");
  const gmailGets = () => requests.filter(request => request.method === "GET" && new URL(request.url).origin === "https://gmail.googleapis.com");
  const fullReads = () => gmailGets().filter(request => new URL(request.url).searchParams.get("format") === "full");
  const sends = () => requests.filter((request) => request.method === "POST" && new URL(request.url).pathname.endsWith("/messages/send"));
  const session = () => evaluate("window.omagmaDemo.sessionInfo()");
  const credentialError = () => evaluate("document.querySelector('#credential-error').textContent.trim()");
  const cacheDatabase = "omagma-browser-cache-v1";
  async function cacheRows() {
    return evaluate(`(async()=>{
      if(!(await indexedDB.databases()).some(db=>db.name===${JSON.stringify(cacheDatabase)}))return [];
      const db=await new Promise((resolve,reject)=>{const r=indexedDB.open(${JSON.stringify(cacheDatabase)},1);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});
      try{return await new Promise((resolve,reject)=>{const tx=db.transaction('actors','readonly'),r=tx.objectStore('actors').getAll();r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)})}finally{db.close()}
    })()`);
  }
  async function putCacheRows(rows, replace = false) {
    await evaluate(`(async()=>{
      const db=await new Promise((resolve,reject)=>{const r=indexedDB.open(${JSON.stringify(cacheDatabase)},1);r.onupgradeneeded=()=>{if(!r.result.objectStoreNames.contains('actors'))r.result.createObjectStore('actors',{keyPath:'key'})};r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});
      try{await new Promise((resolve,reject)=>{const tx=db.transaction('actors','readwrite'),store=tx.objectStore('actors');if(${JSON.stringify(replace)})store.clear();for(const row of ${JSON.stringify(rows)})store.put(row);tx.oncomplete=()=>resolve();tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error)})}finally{db.close()};return true
    })()`);
  }
  function assertCacheDatabases(databases) {
    assert(databases.length <= 1 && databases.every(db => db.name === cacheDatabase && db.version === 1), "unexpected browser persistence database");
  }
  async function settled(message = "browser job did not settle") {
    await until(async () => !(await session()).busy && await evaluate("document.querySelector('#terminal').getAttribute('aria-busy')==='false'"), message, 30000);
  }

  async function act(action) {
    await focus();
    const before = await evaluate("window.omagmaDemo.frameCount");
    await action();
    await until(async () => (await evaluate("window.omagmaDemo.frameCount")) > before, "terminal input did not complete a rendered frame", 20000);
    assert.equal(await evaluate("window.omagmaDemo.error"), null, "terminal operation stopped the browser experiment");
    return screen();
  }
  async function editComposer({ plain = false, body = false } = {}) {
    const current = await screen();
    if (/original format/i.test(current) && /Text quote/i.test(current)) await act(() => text("t"));
    if (plain && /\bMD ·|Format: Markdown|Markdown → HTML/.test(await screen())) await act(() => key("t", "KeyT", 2));
    if (body) await act(() => key("g", "KeyG", 2));
    if (!/INSERT/.test(await screen())) await act(() => text("i"));
  }
  let nativeFolderGetsBeforeEnter = 0;
  async function chooseNativeFolder(account, count, folder) {
    await act(() => text(String(account)));
    await act(() => text("hh"));
    await act(() => text("k".repeat(32))); // Native restores navigation context; reach the first row explicitly.
    await act(() => text("j".repeat(count + folder)));
    nativeFolderGetsBeforeEnter = gmailGets().length;
    return act(() => key("Enter", "Enter"));
  }
  async function importFiles(paths) {
    if (!(await evaluate("document.querySelector('#credential-dialog').open"))) await click("#connect-open");
    await until(async () => evaluate("document.querySelector('#credential-dialog').open"), "credential chooser did not open");
    if (await evaluate("Boolean(document.querySelector('#credential-bundle'))")) {
      await choose("#credential-bundle", []);
      if (!(await evaluate("document.querySelector('#credential-separate').open"))) await click("#credential-separate > summary");
    }
    await choose("#credential-clients", [paths[0]]);
    await choose("#credential-grants", [paths[1]]);
    await choose("#credential-tokens", paths.slice(2));
    await click("#credential-connect");
  }
  async function importBundle(path) {
    if (!(await evaluate("document.querySelector('#credential-dialog').open"))) await click("#connect-open");
    await until(async () => evaluate("document.querySelector('#credential-dialog').open"), "single-file connection chooser did not open");
    await choose("#credential-bundle", [path]);
    await click("#credential-connect");
  }
  async function connected(count) {
    await until(async () => {
      const info = await session();
      return info.mode === "live" && info.accountCount === count && !info.busy && (await evaluate("window.omagmaDemo.ready"));
    }, "selected synthetic grants did not connect", 30000);
    await until(async () => evaluate("!document.querySelector('#credential-dialog').open"), "successful credential chooser did not close");
    assert.equal(await evaluate("window.omagmaDemo.error"), null);
    await settled("connected account job/cache did not settle");
    await focus();
    assert(await evaluate("document.activeElement===document.querySelector('.xterm-helper-textarea')"), "connected terminal input did not receive focus");
  }
  async function disconnect() {
    const info = await session();
    if (info.mode !== "demo") await disconnectDecision(true);
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
  async function activity() {
    return evaluate(`(()=>{
      const bar=document.querySelector('#request-status'),title=document.querySelector('#runtime-status'),hint=document.querySelector('#request-status-hint'),spinner=document.querySelector('#request-status-spinner');
      const rect=element=>{const r=element.getBoundingClientRect();return {left:r.left,right:r.right,top:r.top,bottom:r.bottom,width:r.width,height:r.height}};
      const heading=getComputedStyle(title),detail=getComputedStyle(hint),surface=getComputedStyle(bar),spin=getComputedStyle(spinner);
      return {busy:bar.classList.contains('is-busy'),title:title.textContent.trim(),hint:hint.textContent.trim(),
        spinnerVisible:spinner.checkVisibility(),spinnerAnimation:spin.animationName,spinnerDuration:spin.animationDuration,
        ariaBusy:document.querySelector('#terminal').getAttribute('aria-busy'),fontSize:parseFloat(heading.fontSize),
        hintFontSize:parseFloat(detail.fontSize),fontWeight:Number(heading.fontWeight),foreground:heading.color,
        hintForeground:detail.color,background:surface.backgroundColor,banner:rect(bar),windowBar:rect(document.querySelector('.window-bar')),
        terminal:rect(document.querySelector('#terminal')),titleRect:rect(title),hintRect:rect(hint),
        viewport:{width:innerWidth,height:innerHeight}};
    })()`);
  }
  function contrast(foreground, background) {
    const parse = (color) => color.match(/[\d.]+/g).slice(0, 3).map(Number);
    const luminance = (color) => parse(color).map((channel) => {
      const value = channel / 255;
      return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
    }).reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);
    const a = luminance(foreground), b = luminance(background);
    return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
  }
  function assertBusyActivity(value, label) {
    assert(value.busy && value.spinnerVisible, `${label}: visible request activity is missing`);
    assert.equal(value.ariaBusy, "true", `${label}: terminal does not announce its busy state`);
    assert.match(value.title, /Google request in progress/i, `${label}: headline does not explain the Google request`);
    assert.match(value.hint, /Keyboard input is paused.*Ctrl\+C cancels/i, `${label}: paused input and cancellation are unexplained`);
    assert(value.fontSize >= 14 && value.hintFontSize >= 12 && value.fontWeight >= 600, `${label}: request status text is too small or weak`);
    assert(contrast(value.foreground, value.background) >= 4.5 && contrast(value.hintForeground, value.background) >= 4.5,
      `${label}: request status text has insufficient contrast`);
    assert(value.banner.top >= value.windowBar.bottom - 0.75 && value.banner.bottom <= value.terminal.top + 0.75,
      `${label}: request status is not above the terminal and below its controls`);
    assert(value.banner.left >= -0.75 && value.banner.right <= value.viewport.width + 0.75 && value.banner.top >= 0 && value.banner.bottom <= value.viewport.height,
      `${label}: request status is outside the viewport`);
    assert(value.titleRect.right <= value.banner.right + 0.75 && value.hintRect.right <= value.banner.right + 0.75,
      `${label}: request text overflows its status row`);
  }
  function assertIdleActivity(value, label) {
    assert(!value.busy && !value.spinnerVisible, `${label}: busy styling or spinner remains after the request`);
    assert.equal(value.ariaBusy, "false", `${label}: terminal is still marked busy`);
    assert.equal(value.hint, "", `${label}: pause/cancel guidance remains during idle`);
    assert.match(value.title, /Running locally in WebAssembly/i, `${label}: idle status was not restored`);
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
    const remember=result=>{const instance=result instanceof WebAssembly.Instance?result:result?.instance;if(instance?.exports.memory)window.__omagmaTestWasmMemory=instance.exports.memory;return result};
    for(const name of ['instantiate','instantiateStreaming']){const native=WebAssembly[name].bind(WebAssembly);WebAssembly[name]=async(...args)=>remember(await native(...args))}
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
  await call("Page.navigate", { url: suppliedLaunchURL || origin + "/" });
  await until(async () => evaluate("window.omagmaDemo?.ready === true || Boolean(window.omagmaDemo?.error)"), "WASM terminal did not load");
  assert.equal(await evaluate("window.omagmaDemo.error"), null);
  assert(await evaluate("typeof WebAssembly.Suspending === 'function' && typeof WebAssembly.promising === 'function'"), "owned browser lacks JSPI support");
  assert.equal(requests.length, 0, "default fictional demo unexpectedly connected Google");
  if (args.get("--keyboard-only") === "true") {
    await focus();
    await evaluate(`(()=>{window.__omagmaKeyboardEvents=[];for(const type of ['keydown','keypress','keyup'])document.addEventListener(type,event=>window.__omagmaKeyboardEvents.push({type,key:event.key,code:event.code,keyCode:event.keyCode,charCode:event.charCode,which:event.which,ctrl:event.ctrlKey,target:event.target.className}),true);return true})()`);
    await act(() => text("\\"));
    await act(() => text("live"));
    const beforeSpace = (await screen()).split("\n").find(line => line.includes("Gmail \\"));
    await act(() => key(" ", "Space"));
    const afterSpace = (await screen()).split("\n").find(line => line.includes("Gmail \\"));
    await act(() => text("mailbox"));
    const afterWord = (await screen()).split("\n").find(line => line.includes("Gmail \\"));
    await act(() => key("Escape", "Escape"));
    await act(() => text("\\"));
    await act(() => text("live mailbox"));
    const afterFastWord = (await screen()).split("\n").find(line => line.includes("Gmail \\"));
    const report = { beforeSpace, afterSpace, afterWord, afterFastWord, events: await evaluate("window.__omagmaKeyboardEvents") };
    await writeFile(join(work, "keyboard-diagnostic.json"), JSON.stringify(report, null, 2)+"\n", {mode:0o600});
    console.log(JSON.stringify(report));
  } else if (args.get("--account-switch-only") === "true") {
    const checks = {};
    const localSelections = [];
    const explicitRequests = [];
    const owner = index => index === 0 ? "Ada" : "Bea";
    const googlePauses = () => events.filter(event => event.method === "Fetch.requestPaused" &&
      ["https://oauth2.googleapis.com", "https://gmail.googleapis.com", "https://people.googleapis.com"].includes(new URL(event.params.request.url).origin));
    function assertActor(terminalText, index, { empty = false, missingBody = false } = {}) {
      assert(terminalText.includes(`> ${accounts[index].split("@")[0]}`), `account ${index + 1}: native active-account marker did not change`);
      assert(!terminalText.includes(subject(owner(1 - index), 0)) && !terminalText.includes(`Hello ${owner(1 - index)},`),
        `account ${index + 1}: another actor's mailbox or body remained visible`);
      if (empty) {
        assert(!terminalText.includes(subject(owner(index), 0)) && !terminalText.includes(`Hello ${owner(index)},`),
          `account ${index + 1}: an empty cache reused a prior mailbox`);
        assert.match(terminalText, /No cached mail|Local cache cleared/i, "empty account selection did not explain the cache miss");
        assert.match(terminalText, /Ctrl\+R.*(?:fetch|refresh)/i, "empty account selection did not explain explicit refresh");
      } else {
        assert(terminalText.includes(subject(owner(index), 0)), `account ${index + 1}: cached mailbox rows are missing`);
        if (missingBody) {
          assert.match(terminalText, /Body not cached.*Enter fetches full mail/i, "uncached selected body did not show its explicit-fetch placeholder");
          assert(!terminalText.includes(`Hello ${owner(index)},`), "uncached body reused a previous reader snapshot");
        } else assert(terminalText.includes(`Hello ${owner(index)},`), `account ${index + 1}: its loaded cached body did not render`);
      }
    }
    async function localSelection(label, index, action, expected = {}) {
      const before = requests.length;
      const pausedBefore = googlePauses().length;
      const terminalText = await act(action);
      await settled(`${label}: account selection did not settle locally`);
      await pause(250); // Observe queued jobs as well as the first painted frame.
      assert.equal(requests.length, before, `${label}: account selection called Google or refreshed an OAuth token`);
      assert.equal(googlePauses().length, pausedBefore, `${label}: account selection emitted a provider request, including a preflight`);
      assertActor(await screen(), index, expected);
      localSelections.push({ label, account: index + 1, googleRequests: 0, missingBody: Boolean(expected.missingBody), empty: Boolean(expected.empty) });
      return terminalText;
    }
    async function pointerAccount(index) {
      const target = await evaluate(`(()=>{
        const api=window.omagmaDemo,needle=${JSON.stringify(accounts[index].split("@")[0])};
        const rect=document.querySelector('.xterm-screen').getBoundingClientRect();
        for(let row=0;row<Math.min(api.rows,14);row++)for(let col=0;col<Math.min(api.cols,30);col++){
          let tail='';for(let cursor=col;cursor<Math.min(api.cols,30);cursor++)tail+=api.cell(cursor,row).chars;
          if(tail.startsWith(needle))return {row,col,x:rect.left+(col+3.5)*rect.width/api.cols,y:rect.top+(row+0.5)*rect.height/api.rows};
        }return null;
      })()`);
      assert(target, `account ${index + 1}: rendered sidebar pointer target is missing`);
      await call("Input.dispatchMouseEvent", { type: "mousePressed", x: target.x, y: target.y, button: "left", clickCount: 1 });
      await call("Input.dispatchMouseEvent", { type: "mouseReleased", x: target.x, y: target.y, button: "left", clickCount: 1 });
    }
    async function navigationAccount(index) {
      await text("hh" + "k".repeat(32) + "j".repeat(index));
      await key("Enter", "Enter");
    }
    function assertBootstrap(delta, label) {
      for (let index = 0; index < 2; index++) {
        const actor = delta.filter(request => request.accountIndex === index);
        assert(actor.some(request => new URL(request.url).origin === "https://oauth2.googleapis.com"), `${label}: actor ${index + 1} skipped token verification`);
        assert(actor.some(request => new URL(request.url).pathname.endsWith("/profile")), `${label}: actor ${index + 1} skipped profile verification`);
        assert(actor.some(request => new URL(request.url).pathname.endsWith("/messages")), `${label}: actor ${index + 1} did not bootstrap its absent mailbox cache`);
      }
    }
    async function explicit(label, index, action, predicate) {
      const before = requests.length;
      await act(action);
      await settled(`${label}: explicit request did not settle`);
      const delta = requests.slice(before);
      assert(delta.length > 0 && delta.every(request => request.accountIndex === index), `${label}: explicit request used another actor or performed no request`);
      assert(delta.some(predicate), `${label}: the intended provider request is missing`);
      explicitRequests.push({ label, account: index + 1, requests: delta.map(({ url, method, accountIndex }) => ({ url, method, accountIndex })) });
      return delta;
    }
    const isList = request => new URL(request.url).pathname.endsWith("/messages");

    // First Connect is an explicit verification/bootstrap operation, distinct
    // from subsequent account navigation over an already-valid local view.
    await importBundle(bundles.both);
    await connected(2);
    assertBootstrap(requests, "fresh Connect");
    const freshRows = await cacheRows();
    assert.equal(freshRows.length, 2, "fresh Connect did not save both verified actors");
    for (const row of freshRows) assert(row.snapshot.messages.length === 30 && row.snapshot.messages.some(message => message.id.endsWith("-message-0") && message.bodyCached), "bootstrap did not retain a bounded mailbox and its selected body");
    checks.firstConnectVerifiesAndBootstrapsBothActors = true;
    for (const index of [0, 1, 0, 1, 0]) await localSelection(`cached numeric ${index + 1}`, index, () => text(String(index + 1)));
    await screenshot("account-switch-cached.png");

    // Preserve valid headers while deliberately removing Ada's selected body.
    // This is a cache hit with a missing body, not an invalid/failing row.
    await disconnect();
    const missingBodyRows = structuredClone(freshRows);
    const adaRow = missingBodyRows.find(row => row.snapshot.account === accounts[0]);
    const selectedBody = adaRow.snapshot.messages.find(message => message.id === "ada-message-0");
    assert(selectedBody?.bodyCached, "body-miss fixture did not start from a retained body");
    Object.assign(selectedBody, { bodyCached: false, bodyText: "", bodyHtml: null, bodyHtmlAmbiguous: false, bodySource: "unknown", bodyCacheError: "" });
    adaRow.byteLength = Buffer.byteLength(JSON.stringify(adaRow.snapshot));
    await putCacheRows(missingBodyRows, true);
    const restoreBefore = requests.length;
    await importBundle(bundles.both);
    await connected(2);
    const restored = requests.slice(restoreBefore);
    for (const index of [0, 1]) assert(restored.some(request => request.accountIndex === index && new URL(request.url).pathname.endsWith("/profile")), "cached Connect skipped actor verification");
    assert(!restored.some(request => isList(request) || new URL(request.url).pathname.includes("/threads/") || new URL(request.url).searchParams.get("format") === "full"), "valid cached Connect implicitly refreshed mail or fetched its missing body");
    checks.verifiedCacheRestoreDoesNotBootstrapOrReadMissingBody = true;
    for (const index of [0, 1, 0, 1, 0]) await localSelection(`body-miss numeric ${index + 1}`, index, () => text(String(index + 1)), { missingBody: index === 0 });
    for (const index of [1, 0, 1, 0]) await localSelection(`body-miss pointer ${index + 1}`, index, () => pointerAccount(index), { missingBody: index === 0 });
    for (const index of [1, 0, 1, 0]) await localSelection(`body-miss navigation ${index + 1}`, index, () => navigationAccount(index), { missingBody: index === 0 });
    await screenshot("account-switch-body-placeholder.png");
    checks.cachedNumericPointerNavigationEmitZeroGoogleRequests = true;
    checks.missingSelectedBodyRemainsLocalAcrossSwitches = true;

    // Enter is deliberately explicit. It fetches Ada's missing selected body
    // without refreshing either mailbox or borrowing Bea's reader context.
    await act(() => text("l"));
    const bodyDelta = await explicit("Enter loads selected missing body", 0, () => key("Enter", "Enter"), request => /\/(?:threads\/ada-thread-0|messages\/ada-message-0)$/.test(new URL(request.url).pathname));
    assert(!bodyDelta.some(isList), "Enter on an uncached body refreshed the mailbox instead of reading the selection");
    assertActor(await screen(), 0);
    checks.explicitEnterReadsCorrectActorBody = true;

    await localSelection("cached numeric 2 before explicit refresh", 1, () => text("2"));
    await explicit("Ctrl+R refreshes Bea", 1, () => key("r", "KeyR", 2), isList);
    assertActor(await screen(), 1);
    checks.explicitRefreshUsesCorrectActor = true;

    // A failed explicit refresh is its own lifecycle. Selecting that actor
    // later must not turn navigation into an implicit retry.
    listFailure = { accountIndex: 1, mode: "forbidden" };
    await explicit("Bea explicit refresh fails", 1, () => key("r", "KeyR", 2), isList);
    assert.match(await screen(), /PermissionDenied|permission required/i, "explicit refresh failure was not reported");
    assertActor(await screen(), 1);
    for (const index of [0, 1, 0, 1]) await localSelection(`failed-refresh numeric ${index + 1}`, index, () => text(String(index + 1)));
    listFailure = null;
    await explicit("Bea explicit retry refreshes", 1, () => key("r", "KeyR", 2), isList);
    checks.failedRefreshDoesNotMakeAccountSelectionRetry = true;

    const searchBefore = requests.length;
    await act(() => text("\\"));
    await act(() => text("live mailbox"));
    await explicit("Bea explicit Gmail search", 1, () => key("Enter", "Enter"), request => isList(request) && new URL(request.url).searchParams.get("q")?.trim() === "live mailbox");
    assert(requests.slice(searchBefore).every(request => request.accountIndex === 1), "explicit Gmail search crossed account ownership");
    await localSelection("leave Gmail search by selecting Ada", 0, () => text("1"));
    checks.explicitGmailSearchStillUsesNetwork = true;

    // Clear both persistent and in-memory caches. Numeric, pointer and native
    // navigation remain local even though neither actor has mailbox rows.
    const clearBefore = requests.length;
    const clearPauses = googlePauses().length;
    await act(() => click("#cache-clear"));
    await settled();
    assert.deepEqual(await cacheRows(), [], "Clear cache retained persistent actor rows");
    assert.equal(requests.length, clearBefore, "Clear cache called Google");
    assert.equal(googlePauses().length, clearPauses, "Clear cache emitted a provider preflight");
    for (const index of [1, 0, 1, 0]) await localSelection(`empty numeric ${index + 1}`, index, () => text(String(index + 1)), { empty: true });
    for (const index of [1, 0]) await localSelection(`empty pointer ${index + 1}`, index, () => pointerAccount(index), { empty: true });
    for (const index of [1, 0]) await localSelection(`empty navigation ${index + 1}`, index, () => navigationAccount(index), { empty: true });
    await screenshot("account-switch-empty-cache.png");
    await explicit("Ctrl+R bootstraps cleared Ada cache", 0, () => key("r", "KeyR", 2), isList);
    assertActor(await screen(), 0);
    await localSelection("Bea remains uncached after Ada refresh", 1, () => text("2"), { empty: true });
    await localSelection("Ada refreshed cache is still local", 0, () => text("1"));
    checks.clearedCacheSelectionIsLocalUntilExplicitRefresh = true;

    await act(() => click("#cache-clear"));
    await settled();
    await disconnect();
    assert.deepEqual(await cacheRows(), [], "disconnect repopulated a cleared cache");
    const freshAgainBefore = requests.length;
    await importBundle(bundles.both);
    await connected(2);
    assertBootstrap(requests.slice(freshAgainBefore), "Connect after cleared cache");
    checks.explicitConnectBootstrapsAfterClearedCache = true;
    await screenshot("account-switch-explicit-connect.png");
    await disconnect();

    const privacy = await evaluate(`(async()=>({localStorage:{...localStorage},sessionStorage:{...sessionStorage},databases:await indexedDB.databases(),caches:await caches.keys(),cookies:document.cookie}))()`);
    const persisted = await cacheRows();
    assert.deepEqual(privacy.localStorage, {});
    assert.deepEqual(privacy.sessionStorage, {});
    assertCacheDatabases(privacy.databases);
    assert.deepEqual(privacy.caches, []);
    assert.equal(privacy.cookies, "");
    const diagnosticText = JSON.stringify(privacy) + JSON.stringify(persisted) + JSON.stringify(events.filter(event => event.method === "Runtime.consoleAPICalled" || event.method === "Runtime.exceptionThrown"));
    for (const secret of syntheticSecrets) assert(!diagnosticText.includes(secret), "account-switch test leaked credentials into storage or diagnostics");
    assert.equal(sends().length, 0, "account-switch test emitted a Gmail write");
    assert(maximumActiveRequests <= 1, "account-switch requests bypassed the serial worker");
    assert.deepEqual(transportErrors, [], "account-switch fixture transport failed");
    assert.deepEqual(unexpectedDestinations, [], "account-switch test attempted an unapproved external request");
    checks.noCredentialsPersistedOrLogged = true;
    const report = { synthetic: true, desktopUsed: false, actualGoogleRequests: 0, browser: version.product, origin,
      fixedGoogleUrlsIntercepted: true, requestCount: requests.length, googleFetchPauseCount: googlePauses().length,
      syntheticSendRequests: sends().length, maximumActiveRequests, localSelections, explicitRequests, checks,
      wasmSha256: createHash("sha256").update(await readFile(join(site, "omagma.wasm"))).digest("hex"),
      appSha256: createHash("sha256").update(await readFile(join(site, "app.mjs"))).digest("hex") };
    await writeFile(join(work, "account-switch-acceptance.json"), JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
    console.log(JSON.stringify(report));
  } else if (originalsFixtureEnabled) {
    const checks = {}, submitted = [];
    const source = originalFixture(0);
    const field = (label, value) => {
      const line = value.split("\n").find(line => new RegExp(`\\b${label}:`).test(line));
      assert(line, `original composer ${label} is not visible`);
      return line.slice(line.indexOf(label + ":") + label.length + 1).split(/[│┃]/)[0].replaceAll("▏", "").trim();
    };
    const addressesIn = value => [...(value || "").matchAll(/[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9.-]+/g)].map(match => match[0].toLowerCase());
    const expectRecipients = (mail, all) => {
      assert.deepEqual(addressesIn(mail.headers.to), [originalRecipients.reply], "reply did not honor Reply-To");
      assert.deepEqual(addressesIn(mail.headers.cc), all ? [originalRecipients.toPeer, originalRecipients.ccPeer] : [], "reply-all did not exclude self and deduplicate original To/Cc");
      assert.equal(mail.headers.bcc, undefined, "conversation reply invented Bcc");
      assert.equal(mail.headers["in-reply-to"], "<ada-original-source@example.test>");
      assert.equal(mail.headers.references, "<prior-original-thread@example.test> <ada-original-source@example.test>");
      assert.equal(mail.headers.subject, "Re: Ada original formatting");
    };
    function expectForward(mail, record, messageIndex = 0) {
      const fixture = originalFixture(0, messageIndex);
      assert.equal(mail.headers.subject, "Fwd: " + fixture.headers.find(header => header.name === "Subject").value);
      assert.equal(record.threadId ?? null, null, "forward joined the source Gmail thread");
      assert.equal(mail.headers["in-reply-to"], undefined, "forward retained source reply identity");
      assert.equal(mail.headers.references, undefined, "forward retained source References");
      assert.deepEqual(addressesIn(mail.headers.to), ["original.recipient@example.test"]);
      assert.deepEqual(addressesIn(mail.headers.cc), []);
    }
    function expectFile(mail, expected) {
      const matches = mail.leaves.filter(part => part.filename === expected.filename);
      assert.equal(matches.length, 1, `${expected.filename}: file was lost or duplicated`);
      assert.equal(matches[0].type, expected.mimeType);
      assert(matches[0].bytes.equals(expected.bytes), `${expected.filename}: decoded MIME bytes differ from the provider fixture`);
      return matches[0];
    }
    function expectFormatting(mail, fixture = source, { ordinary = false } = {}) {
      assert(mail.html?.includes(fixture.inlineStyle) && mail.html.includes(fixture.table), "original HTML/CSS layout was rewritten or lost");
      assert(mail.html.includes('data-conditional="original"') && mail.html.includes('data-original-tail="ada"'), "original conditional markup or document tail was lost");
      assert(mail.html.includes('window.__originalInjected="must-never-run"'), "opaque source script bytes were rewritten instead of retained as mail data");
      const image = expectFile(mail, fixture.files[0]), style = expectFile(mail, fixture.files[1]);
      assert.equal(image.contentId, fixture.cid, "source CID image identity changed");
      assert.equal(style.contentLocation, fixture.location, "source stylesheet Content-Location changed");
      if (ordinary) expectFile(mail, fixture.files[2]);
      else assert(!mail.leaves.some(part => part.filename === fixture.files[2].filename), "reply copied an ordinary source attachment");
      const expectedFiles = new Set(fixture.files.slice(0, ordinary ? 3 : 2).map(file => file.filename));
      assert(mail.leaves.every(part => ["text/plain", "text/html"].includes(part.type) || expectedFiles.has(part.filename) || /omagma.*logo/i.test(part.contentId)), "formatted MIME contains an unexpected file");
    }
    async function passive() {
      assert(await evaluate("window.__originalInjected===undefined"), "received original HTML executed in the browser");
      assert(await evaluate("!document.querySelector('table[data-layout],link[href*=\"invalid-resource\"],img[src*=\"invalid-resource\"]')"), "received original markup entered the browser DOM");
      assert.deepEqual(unexpectedDestinations, [], "original HTML fetched a remote resource");
      assert.equal(await evaluate("window.omagmaDemo.error"), null, "original workflow trapped the WASM session");
    }
    async function selectSource(messageIndex = 0) {
      await chooseNativeFolder(1, 2, 0); // Explicit Inbox selection is allowed to refresh.
      await act(() => text("/"));
      const title = originalFixture(0, messageIndex).headers.find(header => header.name === "Subject").value;
      await act(() => text(`subject:"${title}"`));
      const selected = await act(() => key("Enter", "Enter"));
      assert(selected.includes(title), "cache search did not select the exact original fixture");
      await act(() => key("Enter", "Enter"));
      await passive();
    }
    async function chooseSource(intent, mode, messageIndex = 0) {
      await selectSource(messageIndex);
      const before = sends().length;
      const chooser = await act(() => text(intent));
      assert(chooser.includes("original format") && chooser.includes("Text quote"), "conversation action skipped the shared source chooser");
      if (intent === "f") assert(chooser.includes("Attach original .eml"), "forward source chooser has no original-message option");
      if (messageIndex === 2 || messageIndex === 3) assert.match(chooser, /Plain.text source|Plain text.*original/i, "non-HTML source did not explain unavailable formatting");
      if (messageIndex === 4 || messageIndex === 8) await sampleMemory(`fixture${messageIndex} chooser before Keep formatting`);
      const drafted = await act(() => text(mode));
      assert(/Compose/.test(drafted) && /Subject:/.test(drafted), "source selection did not create the shared composer");
      assert.equal(sends().length, before, "source selection submitted without an explicit review");
      if (intent === "f") assert.equal(field("To", drafted), "", "forward inherited the source recipients");
      await passive();
      return drafted;
    }
    async function note(value) {
      await act(() => key("g", "KeyG", 2));
      if (!/INSERT/.test(await screen())) await act(() => text("i"));
      await act(() => paste(value));
      await act(() => key("Escape", "Escape"));
    }
    async function recipient(value = "original.recipient@example.test") {
      await act(() => key("g", "KeyG", 2));
      for (let index = 0; index < 4; index++) await act(() => key("Tab", "Tab", 8));
      const previous = field("To", await screen());
      if (!/INSERT/.test(await screen())) await act(() => text("i"));
      await act(() => key("e", "KeyE", 2));
      for (const character of previous) await act(() => key("Backspace", "Backspace"));
      await act(() => text(value));
      await act(() => key("Escape", "Escape"));
      assert.equal(field("To", await screen()), value, "real recipient editing did not replace the exact To field");
    }
    async function reviewSend(label) {
      const before = sends().length;
      const reviewed = await act(() => key("s", "KeyS", 2));
      assert(reviewed.includes("Review send"), `${label}: outgoing review is missing`);
      assert.equal(sends().length, before, `${label}: opening review submitted mail`);
      await passive();
      const record = await explicitSend(label);
      const mail = decodeOutgoingOriginal(record.rawBytes);
      assert.match(mail.headers["message-id"], /^<omagma-[a-f0-9]{64}@mail\.invalid>$/);
      assert.match(mail.headers.date, /\+0000$/);
      assert.equal(record.accountIndex, 0, `${label}: send crossed account ownership`);
      submitted.push({ label, account: 1, parts: mail.leaves.map(part => ({ type: part.type, filename: part.filename, bytes: part.bytes.length, sha256: createHash("sha256").update(part.bytes).digest("hex"), contentId: part.contentId, contentLocation: part.contentLocation })) });
      await writeFile(join(work, "originals-progress.json"), JSON.stringify({ synthetic: true, actualGoogleRequests: 0, submitted, linearMemorySamples }, null, 2) + "\n", { mode: 0o600 });
      await passive();
      return { record, mail };
    }

    await importBundle(bundles.both);
    await connected(2);
    await sampleMemory("connected");
    if (args.get("--originals-medium-only") === "true") {
      const medium = originalFixture(0, 8);
      await sampleMemory("before medium fixture8");
      await chooseSource("f", "k", 8);
      await sampleMemory("medium draft created");
      await recipient();
      await note("Medium original forward note.\n");
      const result = await reviewSend("medium formatted original forward");
      expectForward(result.mail, result.record, 8);
      expectFormatting(result.mail, medium, { ordinary: true });
      assert(result.mail.body.includes("Medium original forward note."));
      assert.equal(sends().length, 1, "legal medium original did not submit exactly once");
      await sampleMemory("medium send applied");
      checks.legal1200KiBOriginalSendsExactResourcesAndOrdinaryFile = true;
      await screenshot("originals-medium-applied.png");
    } else {
      if (args.get("--originals-size-only") !== "true") {
        await selectSource();
        await act(() => text("r"));
        originalAttachmentFailure = source.files[0].id;
        const failedHydrationBefore = sends().length;
        await act(() => text("k"));
        await settled();
        assert.equal(sends().length, failedHydrationBefore, "failed resource hydration submitted a partial original");
        assert(!/\bSubject:/.test(await screen()), "failed resource hydration created a partial composer");
        assert.match(await screen(), /BodySizeMismatch|size mismatch|Attachment|attachment|InvalidProvider|unavailable|failed/i, "resource hydration failure had no readable refusal");
        originalAttachmentFailure = null;
        await passive();
        checks.hydrationFailureRefusesPartialOriginalAndCanRecover = true;
        await chooseSource("r", "k");
        await note("Original reply note café.\n");
        const reply = await reviewSend("formatted original reply");
        expectRecipients(reply.mail, false);
        assert.equal(reply.record.threadId, "ada-thread-0");
        expectFormatting(reply.mail);
        assert(reply.mail.body.includes("Original reply note café."), "reply note did not survive native MIME assembly");
        const savedOriginal = (await cacheRows()).find(row => row.snapshot.account === accounts[0])?.snapshot.messages.find(message => message.id === "ada-message-0");
        assert.equal(savedOriginal?.attachments.find(file => file.filename === source.files[1].filename)?.contentLocation, source.location, "persisted source metadata lost its Content-Location identity");
        checks.formattedReplyResourcesAndThreading = true;

        await chooseSource("R", "k");
        await note("Original reply-all note.\n");
        const replyAll = await reviewSend("formatted original reply-all");
        expectRecipients(replyAll.mail, true);
        assert.equal(replyAll.record.threadId, "ada-thread-0");
        expectFormatting(replyAll.mail);
        checks.replyAllSelfExclusionDeduplicationAndThreading = true;

        // Deliberately incomplete addressing exercises the shared recovery-save
        // path, including the immutable original and ordinary attachment bytes.
        await chooseSource("f", "k");
        await recipient("partial-recipient");
        await note("Recovered original forward note.\n");
        await act(() => text("q"));
        await act(() => text("2"));
        assert(!(await screen()).includes("Recovered original forward note."), "account switch exposed another actor's recovery draft");
        const drafts = await chooseNativeFolder(1, 2, 2);
        assert(drafts.includes("Fwd: Ada original formatting"), "incomplete original forward was not retained in native Drafts");
        const recovered = await act(() => key("Enter", "Enter"));
        assert.equal(field("To", recovered), "partial-recipient", "recovery dropped the incomplete recipient field");
        assert(recovered.includes("Recovered original forward note."), "recovery dropped the authored note");
        assert(recovered.includes(source.files[2].filename), "recovery dropped the ordinary source file");
        await recipient();
        const cancelBefore = sends().length;
        await act(() => key("s", "KeyS", 2));
        await text("y");
        await waitGrace();
        await act(() => click("#send-grace-cancel"));
        assert.equal(sends().length, cancelBefore, "canceling an original forward's grace window submitted it");
        assert((await screen()).includes("Recovered original forward note."), "grace cancellation discarded the recovered note");
        await screenshot("originals-forward-recovered.png");
        const formattedForward = await reviewSend("formatted original forward with ordinary file");
        expectForward(formattedForward.mail, formattedForward.record);
        expectFormatting(formattedForward.mail, source, { ordinary: true });
        checks.originalRecoveryAccountIsolationGraceCancelAndOrdinaryFile = true;

        await chooseSource("f", "t");
        await recipient();
        const textForward = await reviewSend("text quote forward with ordinary file");
        expectForward(textForward.mail, textForward.record);
        for (const file of source.files) assert.equal(expectFile(textForward.mail, file).disposition, "attachment", "text quote did not retain source files as ordinary attachments");
        assert(textForward.mail.body.includes("Original café") && textForward.mail.body.includes("https://example.test/source-link"), "text quote lost the semantic source or safe link target");
        assert(!textForward.mail.html.includes(source.inlineStyle) && !textForward.mail.html.includes("window.__originalInjected"), "text quote reused opaque original HTML");
        assert(!textForward.mail.leaves.some(part => part.contentId === source.cid || part.contentLocation === source.location), "text quote retained unnecessary original resources");
        checks.textQuoteSemanticSourceAndOrdinaryFile = true;

        await chooseSource("f", "e");
        await recipient();
        await note("Removed original attachment review.\n");
        const removeBefore = sends().length;
        const removeTarget = await evaluate(`(()=>{
          const api=window.omagmaDemo,r=document.querySelector('.xterm-screen').getBoundingClientRect();
          for(let row=0;row<api.rows;row++){
            let line='';for(let col=0;col<api.cols;col++)line+=api.cell(col,row).chars;
            if(!line.includes('.eml'))continue;
            for(let col=0;col<api.cols-2;col++)if(api.cell(col,row).chars==='['&&api.cell(col+1,row).chars==='x'&&api.cell(col+2,row).chars===']')return {x:r.left+(col+1.5)*r.width/api.cols,y:r.top+(row+0.5)*r.height/api.rows};
          }return null;
        })()`);
        assert(removeTarget, "attached original has no visible mouse removal control");
        await act(async () => {
          await call("Input.dispatchMouseEvent", { type: "mousePressed", ...removeTarget, button: "left", clickCount: 1 });
          await call("Input.dispatchMouseEvent", { type: "mouseReleased", ...removeTarget, button: "left", clickCount: 1 });
        });
        const removedReview = await act(() => key("s", "KeyS", 2));
        assert(removedReview.includes("Review send"), "removed-original note could not be reviewed");
        assert(!removedReview.includes("Original attached as .eml") && !removedReview.includes("original attached") && !/Attachment \d+:/i.test(removedReview), "review still claimed the removed original was attached");
        assert.equal(sends().length, removeBefore, "removing an original or reviewing the remaining note submitted it");
        await act(() => key("Escape", "Escape"));
        await act(() => text("d"));
        await act(() => key("Tab", "Tab", 8));
        await act(() => key("Enter", "Enter"));
        checks.removedOriginalStopsAttachmentClaimInReview = true;

        for (const messageIndex of [5, 6]) {
          await selectSource(messageIndex);
          const omitChooser = await act(() => text("f"));
          assert(omitChooser.includes("Text quote · omit files t"), "oversized ordinary forward did not expose its explicit omit-files choice");
          const omitFilesBefore = gmailGets().filter(request => new URL(request.url).pathname.includes("/attachments/")).length;
          const omitSendsBefore = sends().length;
          const omitted = await act(() => text("t"));
          assert.match(omitted, /original attachments are omitted/i, "explicit omit-files draft had no warning");
          assert(!omitted.includes("design-notes-ada.pdf"), "omitted ordinary file remained in the draft");
          await recipient();
          await note("Explicitly omitted oversized source file.\n");
          const omitReview = await act(() => key("s", "KeyS", 2));
          assert(omitReview.includes("Review send") && /original attachments are omitted/i.test(omitReview), "send review lost the explicit omitted-files warning");
          assert(!/Attachment \d+:/i.test(omitReview), "omit-files review claimed an outgoing attachment");
          await act(() => key("Escape", "Escape"));
          await act(() => text("q"));
          const omitDrafts = await chooseNativeFolder(1, 2, 2);
          assert(omitDrafts.includes("Fwd: " + originalFixture(0, messageIndex).headers.find(header => header.name === "Subject").value));
          const reopenedOmit = await act(() => key("Enter", "Enter"));
          assert.match(reopenedOmit, /original attachments are omitted/i, "retained draft lost its deliberate omission warning");
          assert.equal(gmailGets().filter(request => new URL(request.url).pathname.includes("/attachments/")).length, omitFilesBefore, "explicit omission downloaded the oversized file");
          assert.equal(sends().length, omitSendsBefore, "omission/retention checks submitted mail");
          await act(() => text("d"));
          await act(() => key("Tab", "Tab", 8));
          await act(() => key("Enter", "Enter"));
        }
        checks.oversizedOrdinaryFilesExplicitOmissionWarnsAndStaysLocal = true;
        checks.tooManyOrdinaryFilesExplicitOmissionWarnsAndStaysLocal = true;

        // All three source shapes reach the same common .eml choice. Its bytes
        // must match the literal RAW provider response, not a reconstruction.
        for (const messageIndex of [0, 2, 3]) {
          const fixture = originalFixture(0, messageIndex);
          const beforeRaw = gmailGets().filter(request => new URL(request.url).searchParams.get("format") === "raw").length;
          await chooseSource("f", "e", messageIndex);
          assert(gmailGets().filter(request => new URL(request.url).searchParams.get("format") === "raw").length > beforeRaw, ".eml mode did not request original RAW bytes");
          await recipient();
          await note(`Attached original ${messageIndex} note.\n`);
          const originalForward = await reviewSend(`attached .eml source ${messageIndex}`);
          expectForward(originalForward.mail, originalForward.record, messageIndex);
          const eml = originalForward.mail.leaves.filter(part => part.type === "message/rfc822");
          assert.equal(eml.length, 1, "original forward did not contain exactly one .eml");
          assert(eml[0].bytes.equals(fixture.raw), "attached .eml bytes differ from the provider RAW response");
          assert.match(eml[0].filename, /\.eml$/i);
          assert(!originalForward.mail.leaves.some(part => fixture.files.some(file => file.filename === part.filename)), ".eml forward duplicated its contained files as separate outgoing attachments");
        }
        checks.htmlPlainAndAttachmentOnlyOriginalEmlExactBytes = true;
      }

      // The decoded source resource is legal (<2 MiB), but nested MIME/base64
      // expansion cannot fit the bounded send form. This is a definite local
      // refusal before POST, and must leave an editable, retained draft.
      await sampleMemory("before fixture4");
      await chooseSource("f", "k", 4);
      await sampleMemory("fixture4 draft created");
      await recipient();
      await note("Locally rejected oversized formatted note.\n");
      const quotaBefore = sends().length;
      const quotaReview = await act(() => key("s", "KeyS", 2));
      await writeFile(join(work, "originals-size-review.txt"), quotaReview + "\n", { mode: 0o600 });
      await screenshot("originals-size-review.png");
      const sizeReviewVisible = quotaReview.includes("Review send") && quotaReview.includes("Sending account:");
      await sampleMemory(sizeReviewVisible ? "fixture4 Ctrl+S modal review visible" : "fixture4 Ctrl+S refused before modal review");
      if (sizeReviewVisible) {
        await act(() => text("y"));
        await sampleMemory("fixture4 explicit confirmation complete");
      }
      await settled();
      assert.equal(sends().length, quotaBefore, "locally oversized original reached Gmail POST");
      assert.equal((await session()).sendPhase, null, "locally oversized original entered a submission phase");
      assert.equal(await evaluate("localStorage.getItem('omagma-browser-pending-send-v1')"), null, "local form-size refusal created an uncertain-send receipt");
      assert.match(await screen(), /FormTooLarge|form.*large|size limit|too large|RequestTooLarge/i, "oversized send form had no visible local refusal");
      assert(!/outcome unknown|draft protected/i.test(await screen()), "local form-size refusal poisoned the draft as unknown");
      if ((await screen()).includes("Review send")) await act(() => key("Escape", "Escape"));
      await note("Still editable after local refusal.\n");
      assert((await screen()).includes("Still editable after local refusal."), "local size refusal froze the authored note");
      await act(() => text("q"));
      const oversizedDrafts = await chooseNativeFolder(1, 2, 2);
      assert(oversizedDrafts.includes("Fwd: Ada oversized original resource"), "local size refusal lost the retained original draft");
      checks.sendFormExpansionRejectedLocallyWithoutUnknown = true;
      await sampleMemory("local form refusal and editable retained draft");

      if (args.get("--originals-size-only") !== "true") {
        await chooseSource("f", "k");
        await recipient();
        await note("Uncertain original forward protected note.\n");
        sendMode = "uncertain";
        const uncertain = await reviewSend("uncertain formatted original forward");
        expectForward(uncertain.mail, uncertain.record);
        expectFormatting(uncertain.mail, source, { ordinary: true });
        await until(async () => /outcome unknown|draft protected/i.test(await screen()), "uncertain original send did not protect its draft");
        const uncertainCount = sends().length;
        await act(() => key("s", "KeyS", 2));
        await act(() => text("y"));
        assert.equal(sends().length, uncertainCount, "uncertain original replayed its Gmail mutation");
        const receipt = await evaluate("JSON.parse(localStorage.getItem('omagma-browser-pending-send-v1'))");
        assert.deepEqual(Object.keys(receipt).sort(), ["id", "startedAt"]);
        await act(() => click("#send-acknowledge"));
        assert.equal(await evaluate("localStorage.getItem('omagma-browser-pending-send-v1')"), null);
        const reReviewed = await act(() => key("s", "KeyS", 2));
        assert(reReviewed.includes("Review send"), "acknowledged original could not receive a fresh explicit review");
        sendMode = "success";
        await text("y");
        await waitGrace();
        await act(() => click("#send-grace-cancel"));
        assert.equal(sends().length, uncertainCount, "acknowledged original submitted without its new grace window");
        checks.uncertainOriginalNoRetryAcknowledgementRequiresFreshReview = true;
        await screenshot("originals-unknown-recovered.png");
      }
    }
    await passive();
    await disconnect();

    const privacy = await evaluate("(async()=>({localStorage:{...localStorage},sessionStorage:{...sessionStorage},databases:await indexedDB.databases(),cookies:document.cookie,caches:await caches.keys()}))()");
    const persisted = await cacheRows();
    assert.deepEqual(privacy.localStorage, {});
    assert.deepEqual(privacy.sessionStorage, {});
    assertCacheDatabases(privacy.databases);
    assert.deepEqual(privacy.caches, []);
    assert.equal(privacy.cookies, "");
    const storedText = JSON.stringify(persisted);
    assert(!storedText.includes("Recovered original forward note.") && !storedText.includes("Uncertain original forward protected note."), "browser cache persisted original draft notes");
    const diagnosticText = storedText + JSON.stringify(privacy) + JSON.stringify(events.filter(event => event.method === "Runtime.consoleAPICalled" || event.method === "Runtime.exceptionThrown"));
    for (const secret of syntheticSecrets) assert(!diagnosticText.includes(secret), "original workflow leaked credentials");
    assert(maximumActiveRequests <= 1, "original hydration bypassed the serial network worker");
    assert.deepEqual(transportErrors, [], "original fixture transport failed");
    assert.deepEqual(unexpectedDestinations, [], "original source requested an unapproved external resource");
    checks.sourceNeverExecutesOrLoadsRemoteResources = true;
    checks.noCredentialsOrOriginalDraftPersistence = true;
    const report = { synthetic: true, desktopUsed: false, actualGoogleRequests: 0, browser: version.product, origin,
      fixedGoogleUrlsIntercepted: true, requestCount: requests.length, maximumActiveRequests, syntheticSendRequests: sends().length,
      attachmentRequests: gmailGets().filter(request => new URL(request.url).pathname.includes("/attachments/")).length,
      rawOriginalRequests: gmailGets().filter(request => new URL(request.url).searchParams.get("format") === "raw").length, submitted, checks, linearMemorySamples,
      wasmSha256: createHash("sha256").update(await readFile(join(site, "omagma.wasm"))).digest("hex") };
    await writeFile(join(work, args.get("--originals-size-only") === "true" ? "originals-size-acceptance.json" : args.get("--originals-medium-only") === "true" ? "originals-medium-acceptance.json" : "originals-acceptance.json"), JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
    console.log(JSON.stringify({ ...report, submitted: submitted.map(({ label, account, parts }) => ({ label, account, parts: parts.length })) }));
  } else if (args.get("--workflows-only") === "true") {
    const checks = {};
    const inputField = (label, terminalText) => {
      const line = terminalText.split("\n").find(value => new RegExp(`\\b${label}:`).test(value));
      assert(line, `composer ${label} field is not visible`);
      return line.slice(line.indexOf(`${label}:`) + label.length + 1).split(/[│┃]/)[0].replaceAll("▏", "").trim();
    };
    scopeMode = "workflows";
    await importBundle(bundles.workflows);
    await connected(2);
    await act(() => text("1"));
    const firstPeople = peopleRequests().length;
    const adaContacts = await act(() => text("a"));
    assert(adaContacts.includes(contactNames[0][0]) && adaContacts.includes(contactAddresses[0][0]), "Ada's verified People contacts were not rendered");
    assert(!adaContacts.includes(contactNames[1][0]) && !adaContacts.includes(contactAddresses[1][0]), "Ada's contact list contains Bea's contacts");
    assert(peopleRequests().slice(firstPeople).some(request => request.accountIndex === 0 && new URL(request.url).pathname.endsWith("/connections")), "contacts did not use the active verified People session");
    await screenshot("workflows-contacts-ada.png");
    await act(() => text("q"));
    await act(() => text("2"));
    const beaContacts = await act(() => text("a"));
    assert(beaContacts.includes(contactNames[1][0]) && beaContacts.includes(contactAddresses[1][0]), "Bea's People contacts were not rendered");
    assert(!beaContacts.includes(contactNames[0][0]) && !beaContacts.includes(contactAddresses[0][0]), "switching account retained Ada's contact list");
    assert(peopleRequests().some(request => request.accountIndex === 1), "Bea's contacts used the wrong verified session");
    await act(() => text("q"));
    await act(() => text("1"));
    await act(() => text("a"));
    const contactSearchBefore = peopleRequests().length;
    await act(() => text("/"));
    await act(() => text("Café"));
    const searchedContact = await act(() => key("Enter", "Enter"));
    assert(searchedContact.includes(contactNames[0][1]) && !searchedContact.includes(contactNames[0][0]), "contact search did not replace the People result list");
    const contactSearchRequests = peopleRequests().slice(contactSearchBefore);
    assert.equal(contactSearchRequests.length, 2, "People contact search lost its bounded warm-up/search pair");
    assert.deepEqual(contactSearchRequests.map(request => new URL(request.url).searchParams.get("query")), ["", "Café"]);
    const selectedContact = await act(() => key("Enter", "Enter"));
    assert(/Compose/.test(selectedContact) && inputField("To", selectedContact).includes(contactAddresses[0][1]), "selecting a contact did not create an addressed composer");
    assert.equal(sends().length, 0, "selecting a contact submitted a message");
    checks.peopleListSearchSelectionAndAccountIsolation = true;
    const cancelSession = await session();
    const cancelScreen = await screen();
    const cancelRequests = requests.length;
    await disconnectDecision(false);
    assert.deepEqual(await session(), cancelSession, "Cancel-disconnect changed the verified session");
    assert.equal(await screen(), cancelScreen, "Cancel-disconnect discarded the retained contact draft");
    assert.equal(requests.length, cancelRequests, "Cancel-disconnect initiated a provider request");
    checks.disconnectCancelPreservesSessionAndDraft = true;
    await settled();
    const contactedRows = await cacheRows();
    assert(contactedRows.some(row => row.key[0] === accounts[0] && row.snapshot.contactsLoaded && row.snapshot.contacts.some(contact => contact.name === contactNames[0][0])), "Google contacts were not retained in the actor-scoped browser cache");
    assert(contactedRows.some(row => row.key[0] === accounts[1] && row.snapshot.contactsLoaded && row.snapshot.contacts.some(contact => contact.name === contactNames[1][0])), "second actor contacts were not independently retained");
    await disconnect();

    // The declared contact capability is insufficient if refresh narrows it.
    scopeMode = "send";
    await importBundle(bundles.workflowAda);
    await connected(1);
    const deniedPeopleBefore = peopleRequests().length;
    const deniedContacts = await act(() => text("a"));
    assert(/contacts?.*(permission|grant|access)|PermissionDenied|ContactsPermissionRequired/i.test(deniedContacts), "missing verified contact scope was not explained");
    assert.equal(peopleRequests().length, deniedPeopleBefore, "a narrowed contact scope still called People");
    assert(!deniedContacts.includes(contactNames[0][0]) && !deniedContacts.includes(contactNames[0][1]), "narrowed contact scope exposed previously cached contacts");
    checks.narrowedContactsScopesGateNetworkAndCache = true;
    await disconnect();

    scopeMode = "workflows";
    await importBundle(bundles.workflows);
    await connected(2);
    await act(() => text("1"));
    await act(() => text("c"));
    await editComposer();
    await act(() => text("ada.cont"));
    const completion = await act(() => key(" ", "Space", 2));
    assert(/Recipients|Choose recipient|Contacts/.test(completion) && completion.includes(contactAddresses[0][0]), "real Ctrl+Space did not provide a contact recipient completion");
    assert(!completion.includes(contactAddresses[1][0]), "recipient completion contains another account's contacts");
    const acceptedCompletion = await act(() => key("Enter", "Enter"));
    assert(inputField("To", acceptedCompletion).includes(contactAddresses[0][0]), "Enter did not accept the contact address into To");
    assert(!inputField("To", acceptedCompletion).includes("ada.cont "), "completion left an invalid partial recipient");
    await screenshot("workflows-recipient-completion.png");
    assert.equal(sends().length, 0, "recipient completion sent mail");
    checks.actualCtrlSpaceRecipientCompletion = true;
    await act(() => key("Tab", "Tab"));
    await act(() => text("remote.ada"));
    const outsideBefore = peopleRequests().length;
    const remoteCompletion = await act(() => key(" ", "Space", 2));
    assert(remoteCompletion.includes("remote.ada@example.test"), "Ctrl+Space could not find a recipient outside the cached People page");
    assert.deepEqual(peopleRequests().slice(outsideBefore).map(request => new URL(request.url).searchParams.get("query")), ["", "remote.ada"], "uncached recipient completion did not use the bounded People warm-up/search pair");
    const remoteAccepted = await act(() => key("Enter", "Enter"));
    assert(inputField("Cc", remoteAccepted).includes("remote.ada@example.test"), "remote recipient completion was not accepted into the selected Cc field");
    checks.explicitCompletionFindsContactsBeyondCachedPage = true;
    // Shared native drafts are retained across browse and account changes.
    await act(() => key("Tab", "Tab"));
    await act(() => key("Tab", "Tab"));
    await act(() => text("Retained Ada draft"));
    await act(() => key("Escape", "Escape"));
    await act(() => text("q"));
    const bea = await act(() => text("2"));
    assert(bea.includes(accounts[1]) && !bea.includes("Ada live mailbox"), "retained draft prevented isolated native account navigation");
    const freshDraft = await act(() => text("c"));
    assert.equal(inputField("To", freshDraft), "", "new Bea draft inherited Ada recipients");
    await editComposer();
    await act(() => text("bea.own@example.test"));
    for (let field = 0; field < 3; field++) await act(() => key("Tab", "Tab"));
    await act(() => text("Retained Bea draft"));
    await act(() => key("Escape", "Escape"));
    await act(() => text("q"));
    const beforeDrafts = gmailGets().length;
    const adaDrafts = await chooseNativeFolder(1, 2, 2);
    assert(adaDrafts.includes("Retained Ada draft") && !adaDrafts.includes("Retained Bea draft"), "native Drafts list leaked another actor's retained draft");
    assert.equal(gmailGets().length, nativeFolderGetsBeforeEnter, "session Drafts list unexpectedly fetched Gmail");
    assert(gmailGets().slice(beforeDrafts).every(request => request.accountIndex === 0), "native draft account switch refreshed another actor's mailbox");
    const reopenedAda = await act(() => key("Enter", "Enter"));
    assert(inputField("To", reopenedAda).includes(contactAddresses[0][0]) && inputField("Cc", reopenedAda).includes("remote.ada@example.test"), "native Drafts did not restore the exact Ada recipient fields");
    assert.equal(inputField("Subject", reopenedAda), "Retained Ada draft");
    await act(() => text("q"));
    const beaDrafts = await chooseNativeFolder(2, 2, 2);
    assert(beaDrafts.includes("Retained Bea draft") && !beaDrafts.includes("Retained Ada draft"));
    const reopenedBea = await act(() => key("Enter", "Enter"));
    assert(inputField("To", reopenedBea).includes("bea.own@example.test") && !inputField("To", reopenedBea).includes(contactAddresses[0][0]));
    const discard = await act(() => text("d"));
    assert(/Discard local draft/.test(discard) && discard.includes("Cancel"), "normal d did not open the shared discard review");
    const canceledDiscard = await act(() => key("Enter", "Enter"));
    assert.equal(inputField("Subject", canceledDiscard), "Retained Bea draft", "default Cancel discarded the native draft");
    await act(() => text("d"));
    await act(() => key("Tab", "Tab", 8)); // shared dialog defaults Cancel; previous control is Discard.
    await act(() => key("Enter", "Enter"));
    const afterDiscard = await chooseNativeFolder(2, 2, 2);
    assert(!afterDiscard.includes("Retained Bea draft"), "explicit shared Discard retained the draft");
    assert.equal(sends().length, 0, "local draft retention/discard sent mail");
    checks.nativeRetainedDraftsReopenAndDiscardRemainActorScoped = true;
    await disconnect();

    scopeMode = "workflows";
    await importBundle(bundles.workflowAda);
    await connected(1);
    assert((await screen()).includes("Hello Ada,"), "forward source body was not loaded");
    let forward = await act(() => text("f"));
    if (forward.includes("original format") && forward.includes("Text quote")) forward = await act(() => text("t"));
    assert(/Compose.*Forward|Forward.*Compose/i.test(forward), "f did not open a forward composer");
    assert.equal(inputField("To", forward), "", "forward copied the original recipients");
    assert.equal(inputField("Subject", forward), "Fwd: Ada live mailbox");
    assert(forward.includes("Hello Ada,") && forward.includes("Morgan") && forward.includes("Ada live mailbox"), "plain forward omitted its source envelope or quoted body");
    assert.equal(sends().length, 0, "forward submitted before review");
    await editComposer();
    await act(() => text("forward.recipient@example.test"));
    const forwardReview = await act(() => key("s", "KeyS", 2));
    assert(forwardReview.includes("Review send") && forwardReview.includes("forward.recipient@example.test"), "forward did not show the exact send review");
    assert.equal(sends().length, 0, "forward review itself submitted mail");
    await screenshot("workflows-forward-review.png");
    const forwardSend = await explicitSend("plain forward");
    const forwardMail = outgoingMessage(forwardSend, { allowMarkdown: true });
    assert.equal(forwardMail.headers.subject, "Fwd: Ada live mailbox");
    assert(forwardMail.headers.from.includes(accounts[0]) && forwardMail.headers.to.includes("forward.recipient@example.test"));
    assert(forwardMail.body.includes("Hello Ada,") && forwardMail.body.includes("Morgan") && forwardMail.body.includes("Ada live mailbox"), "forward MIME lost its literal source content");
    assert.equal(forwardSend.threadId ?? null, null, "forward joined the original Gmail thread");
    assert.equal(forwardMail.headers["in-reply-to"], undefined, "forward retained reply threading");
    assert.equal(forwardMail.headers.references, undefined, "forward retained source References");
    assert.equal(sends().length, 1, "forward did not submit exactly one synthetic POST");
    const expectedForward = "> ---------- Forwarded message ----------\n> From: Morgan Browser <morgan@example.test>\n> Subject: Ada live mailbox\n> \n> Hello Ada,\n> \n> Synthetic live read in WebAssembly.\n> Nothing touched Google.\n\nSent with omagma — https://technologylab-ai.github.io/omagma/ 🌋";
    assert.equal(forwardMail.body.trim(), expectedForward, "shared native forward quote changed the literal source envelope/body");
    assert(forwardMail.html?.includes("<blockquote") && !forwardMail.html.includes("<script"), "native Markdown forward lost its safe HTML alternative");
    checks.sharedMarkdownForwardWithoutReplyThreading = true;
    checks.tenSecondGraceAndExactOneSyntheticForwardPost = true;

    // The same loaded body and a cache search must remain fully local.
    await settled();
    await act(() => text("j"));
    const beforeBodyLoad = fullReads().length;
    await act(() => key("Enter", "Enter"));
    assert.equal(fullReads().length, beforeBodyLoad + 1, "Enter did not load the selected native conversation");
    await act(() => text("q"));
    const beforeRevisit = gmailGets().length;
    await act(() => text("k"));
    await act(() => text("j"));
    assert.equal(gmailGets().length, beforeRevisit, "revisiting a loaded message body fetched Gmail again");
    assert((await screen()).includes("Literal HTML fixture"), "cached HTML body revisit lost the native semantic reader");
    const beforeCacheSearch = gmailGets().length;
    await act(() => text("/"));
    await act(() => text("body:Hello"));
    const cachedSearch = await act(() => key("Enter", "Enter"));
    assert(cachedSearch.includes("Cache search") && cachedSearch.includes("Hello Ada,") && !cachedSearch.includes("Ada HTML-only mailbox"), "cache-only body search did not filter the retained bodies");
    assert.equal(gmailGets().length, beforeCacheSearch, "slash cache search called Gmail");
    await screenshot("workflows-cache-search.png");
    await act(() => text("q"));
    const beforeServerSearch = gmailGets().length;
    const serverPrompt = await act(() => text("\\"));
    assert.equal(serverPrompt.split("\n").find(line => line.startsWith("Gmail \\"))?.trim(), "Gmail \\ ▏", "Gmail search did not begin with an empty input");
    await act(() => text("live"));
    await act(() => key(" ", "Space"));
    const typedServerQuery = await act(() => text("mailbox"));
    assert.equal(typedServerQuery.split("\n").find(line => line.startsWith("Gmail \\"))?.trim(), "Gmail \\ live mailbox▏", "real keyboard typing changed the Gmail query");
    const serverSearch = await act(() => key("Enter", "Enter"));
    assert(serverSearch.includes("Gmail search") && serverSearch.includes("Ada live mailbox"), "backslash did not perform the Gmail search");
    assert(gmailGets().slice(beforeServerSearch).some(request => new URL(request.url).searchParams.get("q")?.trim() === "live mailbox"), "Gmail search lost its provider query");
    await act(() => text("q"));
    checks.localBodyRevisitAndCacheSearchNoGET = true;
    checks.explicitGmailSearchUsesGET = true;
    const operatorBefore = gmailGets().length;
    await act(() => text("\\"));
    await act(() => text("category:updates"));
    const gmailOperator = await act(() => key("Enter", "Enter"));
    assert(gmailGets().slice(operatorBefore).some(request => new URL(request.url).searchParams.get("q")?.includes("category:updates")), "Gmail-only operator was rejected by the optional local cache preview");
    assert(gmailOperator.includes("Ada bounded message 4"), "Gmail-only operator did not display the independent provider result");
    await act(() => text("q"));
    checks.gmailOnlyOperatorReachesProvider = true;


    const ax = await call("Accessibility.getFullAXTree");
    const accessibleText = ax.nodes.filter(node => !node.ignored).map(node => `${node.name?.value || ""} ${node.value?.value || ""}`).join("\n");
    assert(accessibleText.includes("Ada live mailbox") || accessibleText.includes("Hello Ada,"), "the accessible terminal tree does not expose synthetic mail text");
    checks.screenReaderTerminalTextExposed = true;
    const savedRows = await cacheRows();
    const adaKey = [accounts[0], clientId, hashParts(["omagma-terminal-grant-v1", readScope, sendScope, contactsScope])];
    const savedAda = savedRows.find(row => JSON.stringify(row.key) === JSON.stringify(adaKey));
    assert(savedAda?.snapshot.messages.some(message => message.bodyCached && message.bodyText.includes("Hello Ada,")), "mail body was not persisted in the exact grant cache");
    assert(savedRows.length <= 3 && savedRows.reduce((sum, row) => sum + row.byteLength, 0) <= 8 * 1024 * 1024, "browser cache exceeded its actor/byte quotas");
    for (const row of savedRows) {
      assert.deepEqual(Object.keys(row).sort(), ["byteLength", "key", "savedAt", "snapshot"]);
      assert(row.byteLength <= 3 * 1024 * 1024 && row.snapshot.messages.length <= 300 && row.snapshot.contacts.length <= 100);
      assert.deepEqual([row.snapshot.account, row.snapshot.clientId, row.snapshot.grantId], row.key, "stored snapshot is not bound to its exact actor tuple");
    }
    await disconnect();
    const reloadBefore = requests.length;
    const reloadMarker = events.length;
    await call("Page.reload", { ignoreCache: true });
    await until(async () => events.slice(reloadMarker).some(event => event.method === "Page.loadEventFired"), "cache reload did not create a new document");
    await until(async () => evaluate("window.omagmaDemo?.ready === true"), "cache reload did not restore fictional mode");
    assert.equal(requests.length, reloadBefore, "cache reload automatically connected Google");
    assert.equal((await session()).mode, "demo");
    assert(!(await screen()).includes("Hello Ada,"), "unverified cache data rendered before Connect");
    holdNextProfile = true;
    const verifiedRestoreBefore = requests.length;
    await importBundle(bundles.workflowAda);
    await until(async () => heldProfiles.length === 1, "cache restoration skipped Gmail profile verification");
    assert(!(await screen()).includes("Hello Ada,") && !(await screen()).includes("Ada live mailbox"), "staged cache appeared while profile verification was suspended");
    heldProfiles.at(-1).release();
    await connected(1);
    assert((await screen()).includes("Hello Ada,"), "verified exact-grant cache did not restore its loaded body");
    const restoreRequests = requests.slice(verifiedRestoreBefore);
    assert(restoreRequests.some(request => new URL(request.url).pathname.endsWith("/profile")));
    assert(!restoreRequests.some(request => new URL(request.url).searchParams.get("format") === "full"), "verified cache restore fetched an already-retained body");
    assert(restoreRequests.filter(request => new URL(request.url).pathname.endsWith("/messages")).every(request => request.accountIndex === 0), "native cache refresh used another actor");
    const beforeRestoredContacts = peopleRequests().length;
    const restoredContacts = await act(() => text("a"));
    assert(restoredContacts.includes(contactNames[0][0]), "verified contact cache was not restored");
    assert(peopleRequests().slice(beforeRestoredContacts).every(request => request.accountIndex === 0), "native contact refresh crossed the restored cache actor");
    await act(() => text("q"));
    checks.reloadRequiresProfileBeforeExactGrantRestore = true;

    // A different grant for the same email address gets a fresh provider view.
    await disconnect();
    scopeMode = "readonly";
    mailVariant = "Different-grant";
    const differentGrantBefore = gmailGets().length;
    await importBundle(bundles.readonly);
    await connected(1);
    assert((await screen()).includes("Different-grant Ada live mailbox") && (await screen()).includes("Different-grant synthetic cache body."), "a different grant reused the previous account-only cache");
    assert(gmailGets().slice(differentGrantBefore).some(request => new URL(request.url).pathname.endsWith("/messages")), "a different grant skipped its first mailbox load");
    checks.sameAccountDifferentGrantDoesNotAliasCache = true;
    await disconnect();
    scopeMode = "workflows";
    mailVariant = "";

    // Strictly invalid metadata and an oversized passive snapshot are refused
    // by the actual stored-row reader, then replaced by a verified fresh view.
    const invalidSnapshots = [
      { ...savedAda.snapshot, account: accounts[1] },
      { ...savedAda.snapshot, grantId: "0".repeat(64) },
      { ...savedAda.snapshot, clientId: "other-synthetic.apps.googleusercontent.com" },
      { ...savedAda.snapshot, messages: savedAda.snapshot.messages.map((message, index) => index === 0 ? { ...message, bodyText: "X".repeat(3 * 1024 * 1024 + 1) } : message) },
      { ...savedAda.snapshot, messages: Array.from({ length: 301 }, (_, index) => ({ ...savedAda.snapshot.messages[0], id: `invalid-inventory-${index}`, threadId: `invalid-thread-${index}` })) },
    ];
    for (let index = 0; index < invalidSnapshots.length; index++) {
      const snapshot = invalidSnapshots[index];
      await putCacheRows([{ ...savedAda, snapshot, byteLength: Buffer.byteLength(JSON.stringify(snapshot)) }], true);
      const beforeInvalid = gmailGets().length;
      await importBundle(bundles.workflowAda);
      await connected(1);
      assert(gmailGets().slice(beforeInvalid).some(request => new URL(request.url).pathname.endsWith("/messages")), "invalid/quota-exceeding stored cache bypassed a fresh mailbox load");
      const validReplacement = (await cacheRows()).find(row => JSON.stringify(row.key) === JSON.stringify(adaKey));
      assert(validReplacement?.snapshot.account === accounts[0] && validReplacement.snapshot.clientId === clientId && validReplacement.snapshot.grantId === adaKey[2] && validReplacement.byteLength <= 3 * 1024 * 1024, "invalid stored cache was retained instead of replaced");
      await disconnect();
    }
    checks.invalidBindingAndOversizeStoredCacheRejected = invalidSnapshots.length;

    // Exercise a real IndexedDB write refusal through the application's normal
    // post-HTTP save path; current native mail remains usable in the tab.
    await importBundle(bundles.workflowAda);
    await connected(1);
    await evaluate(`(()=>{const original=IDBObjectStore.prototype.put;window.__omagmaTestOriginalPut=original;IDBObjectStore.prototype.put=function(...args){if(this.name==='actors'&&this.transaction.db.name===${JSON.stringify(cacheDatabase)})throw new DOMException('Synthetic quota refusal','QuotaExceededError');return original.apply(this,args)};return true})()`);
    await act(() => key("r", "KeyR", 2));
    await settled();
    assert.match(await evaluate("document.querySelector('#runtime-status').textContent"), /cache could not be saved/i, "IndexedDB quota failure was not reported");
    assert((await screen()).includes("Ada live mailbox") && (await screen()).includes("Hello Ada,"), "storage quota failure discarded current native mail");
    assert.equal(await evaluate("window.omagmaDemo.error"), null, "storage quota failure trapped the application");
    await evaluate("IDBObjectStore.prototype.put=window.__omagmaTestOriginalPut;delete window.__omagmaTestOriginalPut;true");
    checks.storageQuotaFailureKeepsCurrentMailReadable = true;

    const beforeClear = gmailGets().length;
    await act(() => click("#cache-clear"));
    await settled();
    assert.deepEqual(await cacheRows(), [], "Clear cache retained IndexedDB actor rows");
    assert(!(await screen()).includes("Ada live mailbox") && !(await screen()).includes("Hello Ada,"), "Clear cache retained visible mailbox/body entries");
    assert.equal(gmailGets().length, beforeClear, "Clear cache unexpectedly refreshed Gmail");
    checks.clearCacheDeletesVisibleAndPersistedSnapshots = true;
    await act(() => key("r", "KeyR", 2));
    assert((await screen()).includes("Hello Ada,"), "explicit refresh could not repopulate the cleared cache");

    // Navigation uses only real terminal keys. Folder changes clear the old
    // projection before a failed remote list; clearing search keeps the folder.
    const chooseFolder = index => chooseNativeFolder(1, 1, index);
    listFailure = { accountIndex: 0, mode: "forbidden" };
    const failedArchive = await chooseFolder(3);
    assert(failedArchive.includes("Archive") && !failedArchive.includes("Ada live mailbox") && !failedArchive.includes("Hello Ada,"), "failed Archive fetch relabeled the old Inbox body or list");
    listFailure = null;
    const archive = await chooseFolder(3);
    assert(archive.includes("Ada bounded message 2") && archive.includes("Ada bounded message 3") && !archive.includes("Ada live mailbox"), "Archive fixture did not establish a distinct folder projection");
    const archiveSearchBefore = gmailGets().length;
    await act(() => text("/"));
    await act(() => text("bounded"));
    await act(() => key("Enter", "Enter"));
    assert.equal(gmailGets().length, archiveSearchBefore, "Archive cache search called Gmail");
    const archiveClear = await act(() => text("q"));
    assert(archiveClear.includes("Archive") && archiveClear.includes("Ada bounded message 2") && !archiveClear.includes("Ada live mailbox"), "clearing Archive cache search restored Inbox rows");
    assert(gmailGets().slice(archiveSearchBefore).filter(request => new URL(request.url).pathname.endsWith("/messages")).every(request => new URL(request.url).searchParams.get("q")?.includes("-in:inbox")), "native Archive refresh lost its folder scope while clearing search");
    const unread = await chooseFolder(7);
    assert(unread.includes("Unread") && unread.includes("Ada live mailbox") && !unread.includes("Ada HTML-only mailbox"), "Unread fixture retained read mail");
    await act(() => text("/"));
    await act(() => text("bounded"));
    await act(() => key("Enter", "Enter"));
    const unreadClear = await act(() => text("q"));
    assert(unreadClear.includes("Unread") && unreadClear.includes("Ada live mailbox") && !unreadClear.includes("Ada HTML-only mailbox"), "clearing Unread cache search restored read Inbox rows");
    checks.failedFolderDoesNotRelabelInboxAndSearchClearKeepsArchiveUnread = true;
    await disconnect();
    await putCacheRows([], true);
    await importBundle(bundles.workflowAda);
    await connected(1);
    await act(() => text("1")); // Explicit cached view: missing bodies need Enter.

    // While HTTP has suspended WASM, the browser keeps the old terminal grid
    // intact and covers it until the queued native resize can render safely.
    holdNextFullRead = true;
    await key("j", "KeyJ");
    await until(async () => heldReads.length === 1 && (await session()).busy, "synthetic body read did not suspend for resize regression");
    const heldGrid = await evaluate("({cols:window.omagmaDemo.cols,rows:window.omagmaDemo.rows,text:window.omagmaDemo.screenText()})");
    await call("Emulation.setDeviceMetricsOverride", { width: 600, height: 700, deviceScaleFactor: 1, mobile: false });
    await evaluate("new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))");
    assert.deepEqual(await evaluate("({cols:window.omagmaDemo.cols,rows:window.omagmaDemo.rows,text:window.omagmaDemo.screenText()})"), heldGrid, "xterm resized or corrupted its old grid during a suspended native request");
    assert(await evaluate("!document.querySelector('#runtime-message').hidden"), "suspended resize did not cover its temporarily clipped grid");
    assert.match(await evaluate("document.querySelector('#runtime-message-text').textContent"), /Resizing|waiting/i);
    await screenshot("workflows-held-resize.png");
    heldReads[0].release();
    await settled();
    await until(async () => evaluate("document.querySelector('#runtime-message').hidden && window.omagmaDemo.cols<100"), "queued resize did not render and uncover the new native grid");
    assert.equal(await evaluate("window.omagmaDemo.error"), null);
    await call("Emulation.setDeviceMetricsOverride", { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
    await until(async () => evaluate("window.omagmaDemo.cols>100"), "normal terminal dimensions did not restore after suspended resize");
    await screenshot("workflows-cache-inbox.png");
    checks.suspendedResizeDefersGridAndShowsCover = true;
    await disconnect();

    // An intercepted connection-close after dispatch exercises the native
    // uncertain-outcome guard and receipt-pinned acknowledgement in this instance.
    await importBundle(bundles.workflows);
    await connected(2);
    await act(() => text("1"));
    await act(() => text("c"));
    await editComposer({ plain: true });
    await act(() => text("unknown.workflow@example.test"));
    for (let field = 0; field < 3; field++) await act(() => key("Tab", "Tab"));
    await act(() => text("Workflow uncertain draft"));
    await act(() => key("Tab", "Tab"));
    await act(() => paste("Workflow protected draft body.\n"));
    await act(() => key("s", "KeyS", 2));
    sendMode = "uncertain";
    const unknownSend = await explicitSend("workflow unknown outcome");
    assert.equal(outgoingMessage(unknownSend).headers.subject, "Workflow uncertain draft", "real keyboard typing changed the outgoing subject");
    assert.equal(outgoingMessage(unknownSend).body, "Workflow protected draft body.\n");
    await until(async () => /outcome unknown|draft protected/i.test(await screen()), "uncertain workflow send did not protect its native draft");
    await act(() => key("s", "KeyS", 2));
    await act(() => text("y"));
    assert.equal(sends().length, 2, "an uncertain native draft retried its Gmail mutation");
    const unknownReceipt = await evaluate("JSON.parse(localStorage.getItem('omagma-browser-pending-send-v1'))");
    assert.deepEqual(Object.keys(unknownReceipt).sort(), ["id", "startedAt"], "workflow pending receipt retained mail or credentials");
    await act(() => text("q"));
    await act(() => text("2"));
    await act(() => text("c"));
    await editComposer({ plain: true });
    await act(() => text("bea.guard@example.test"));
    for (let field = 0; field < 3; field++) await act(() => key("Tab", "Tab"));
    await act(() => text("Bea acknowledgement guard"));
    await act(() => key("s", "KeyS", 2));
    await act(() => text("y"));
    assert.equal(sends().length, 2, "another actor's review bypassed the pending uncertainty guard");
    assert.deepEqual(await evaluate("JSON.parse(localStorage.getItem('omagma-browser-pending-send-v1'))"), unknownReceipt, "another actor's preflight cancellation cleared the old uncertainty receipt");
    const beforeAcknowledgement = requests.length;
    await act(() => click("#send-acknowledge"));
    assert.equal(requests.length, beforeAcknowledgement, "Checked Sent acknowledgement itself called Google");
    assert.equal(await evaluate("localStorage.getItem('omagma-browser-pending-send-v1')"), null, "Checked Sent acknowledgement retained the host receipt");
    assert((await screen()).includes("Bea acknowledgement guard"), "receipt-pinned acknowledgement mutated another actor's active draft");
    if (/INSERT/.test(await screen())) await act(() => key("Escape", "Escape"));
    await act(() => text("q"));
    const recoveredUnknownDrafts = await chooseNativeFolder(1, 2, 2);
    assert(recoveredUnknownDrafts.includes("Workflow uncertain draft"), "acknowledgement discarded the receipt's native draft");
    const recoveredUnknown = await act(() => key("Enter", "Enter"));
    assert.equal(inputField("Subject", recoveredUnknown), "Workflow uncertain draft");
    await act(() => text("y"));
    assert.equal((await session()).sendPhase, null, "acknowledgement reused the previous send review");
    const freshReview = await act(() => key("s", "KeyS", 2));
    assert(freshReview.includes("Review send"), "Checked Sent acknowledgement did not unlock a fresh explicit review without reconnect");
    sendMode = "success";
    await text("y");
    await waitGrace();
    await act(() => click("#send-grace-cancel"));
    assert.equal(sends().length, 2, "acknowledged draft submitted without completing its new local cancellation window");
    checks.actualUnknownOutcomeNoRetryAndAcknowledgementRequiresFreshReview = true;
    checks.unknownAcknowledgementPinnedAcrossActorsAndDrafts = true;
    await screenshot("workflows-unknown-acknowledged.png");
    await disconnect();
    const beforeGuardReload = requests.length;
    const guardReloadMarker = events.length;
    await call("Page.reload", { ignoreCache: true });
    await until(async () => events.slice(guardReloadMarker).some(event => event.method === "Page.loadEventFired"), "workflow reload did not create a new document");
    await until(async () => evaluate("window.omagmaDemo?.ready === true"), "workflow reload did not restore sample mode");
    assert.equal((await session()).mode, "demo", "reload revived live credentials");
    assert.equal(requests.length, beforeGuardReload, "reload replayed a Google operation");
    checks.reloadNoCredentialsOrRetry = true;
    const privacy = await evaluate(`(async()=>({
      diagnostics:JSON.stringify(window.omagmaDemo),session:window.omagmaDemo.sessionInfo(),html:document.documentElement.outerHTML,
      localStorage:Object.fromEntries(Object.keys(localStorage).map(key=>[key,localStorage.getItem(key)])),
      sessionStorage:Object.fromEntries(Object.keys(sessionStorage).map(key=>[key,sessionStorage.getItem(key)])),
      databases:await indexedDB.databases(),caches:await caches.keys(),cookies:document.cookie
    }))()`);
    privacy.indexedDBRows = await cacheRows();
    const privacyText = JSON.stringify(privacy) + JSON.stringify(events.filter(event => event.method === "Runtime.consoleAPICalled" || event.method === "Runtime.exceptionThrown"));
    for (const secret of syntheticSecrets) assert(!privacyText.includes(secret), "workflow leaked credentials into diagnostics, logs or persistence");
    assert.deepEqual(privacy.sessionStorage, {});
    assertCacheDatabases(privacy.databases);
    assert.deepEqual(privacy.caches, []);
    assert.equal(privacy.cookies, "");
    assert(!JSON.stringify(privacy.indexedDBRows).includes("Workflow protected draft body"), "browser snapshot persisted a session draft");
    assert.deepEqual(privacy.localStorage, {}, "acknowledged workflow left unexpected localStorage data");
    checks.noCredentialOrDraftPersistenceOrLogs = true;
    assert.deepEqual(transportErrors, [], "synthetic workflow transport failed");
    assert.deepEqual(unexpectedDestinations, [], "workflow attempted an unapproved external request");
    const report = { synthetic: true, desktopUsed: false, actualGoogleRequests: 0, browser: version.product, origin,
      realNativeServer: Boolean(suppliedOrigin), fixedGoogleAndPeopleUrlsIntercepted: true,
      requestCount: requests.length, peopleRequestCount: peopleRequests().length, maximumActiveRequests,
      syntheticSendRequests: sends().length, checks };
    await writeFile(join(work, "workflows-acceptance.json"), JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
    console.log(JSON.stringify(report));
  } else if (args.get("--activity-only") === "true") {
    assertIdleActivity(await activity(), "sample startup");
    scopeMode = "readonly";
    await importBundle(bundles.readonly);
    await connected(1);
    const idleDesktop = await activity();
    assertIdleActivity(idleDesktop, "connected idle");
    await act(() => text("1"));
    holdNextFullRead = true;
    await key("j", "KeyJ");
    await until(async () => heldReads.length === 1 && (await session()).busy && (await activity()).busy,
      "held body read did not show request activity");
    const desktop = await activity();
    assertBusyActivity(desktop, "desktop body request");
    for (const edge of ["top", "bottom", "height", "width"]) assert(Math.abs(desktop.terminal[edge] - idleDesktop.terminal[edge]) <= 0.75,
      "request activity moved the terminal while its WASM stack was suspended");
    await screenshot("activity-desktop.png");
    await call("Emulation.setDeviceMetricsOverride", { width: 600, height: 700, deviceScaleFactor: 1, mobile: false });
    await evaluate("new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))");
    const narrow = await activity();
    assertBusyActivity(narrow, "narrow body request");
    await screenshot("activity-narrow.png");
    await call("Emulation.setEmulatedMedia", { features: [{ name: "prefers-reduced-motion", value: "reduce" }] });
    const reduced = await activity();
    assert(reduced.spinnerAnimation === "none" || reduced.spinnerDuration.split(",").every((duration) => parseFloat(duration) === 0),
      "reduced-motion preference did not stop the request spinner");
    await call("Emulation.setEmulatedMedia", { features: [{ name: "prefers-reduced-motion", value: "no-preference" }] });
    await call("Emulation.setDeviceMetricsOverride", { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
    await evaluate("new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))");
    heldReads[0].release();
    await until(async () => !(await session()).busy && !(await activity()).busy, "completed read did not clear busy status");
    await until(async () => (await screen()).includes("Literal HTML fixture"), "completed held read did not render its provider body");
    await until(async () => evaluate("document.querySelector('#runtime-message').hidden"), "completed read left the resizing cover over the terminal", 3000);
    assertIdleActivity(await activity(), "completed read");

    await call("Emulation.setDeviceMetricsOverride", { width: 360, height: 700, deviceScaleFactor: 1, mobile: false });
    await evaluate("new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))");
    const idleSmall = await activity();
    assertIdleActivity(idleSmall, "small viewport idle");
    await focus();
    await act(() => text("q"));
    await act(() => text("1"));
    holdNextFullRead = true;
    await key("j", "KeyJ");
    await until(async () => heldReads.length === 2 && (await session()).busy && (await activity()).busy,
      "second held body read did not enter busy state");
    const small = await activity();
    assertBusyActivity(small, "small request before keyboard cancellation");
    for (const edge of ["top", "bottom", "height", "width"]) assert(Math.abs(small.terminal[edge] - idleSmall.terminal[edge]) <= 0.75,
      "wrapped small-viewport pause guidance moved the terminal during a request");
    await screenshot("activity-small.png");
    canceledRequests.add(heldReads[1].requestId);
    const cancelMarker = events.length;
    await key("c", "KeyC", 2);
    await until(async () => events.slice(cancelMarker).some((event) => event.method === "Network.loadingFailed" &&
      event.params.requestId === heldReads[1].networkId && event.params.canceled === true),
      "Ctrl+C did not abort the held Google request promptly", 2000);
    heldReads[1].release();
    await until(async () => !(await session()).busy && !(await activity()).busy, "Ctrl+C did not cancel and clear the busy request");
    assertIdleActivity(await activity(), "cancelled read");
    assert.equal(await evaluate("window.omagmaDemo.error"), null, "cancelled read stopped the browser application");
    await screenshot("activity-after-cancel.png");
    await call("Emulation.setDeviceMetricsOverride", { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
    await evaluate("new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))");
    await disconnect();
    assertIdleActivity(await activity(), "disconnected sample");
    await importBundle(bundles.readonly);
    await connected(1);
    assertIdleActivity(await activity(), "reconnected idle");
    await disconnect();
    assert.equal(sends().length, 0, "activity acceptance attempted a Gmail mutation");
    assert.deepEqual(transportErrors, []); assert.deepEqual(unexpectedDestinations, []);
    const report = { synthetic: true, desktopUsed: false, browser: version.product, origin,
      realNativeServer: Boolean(suppliedOrigin), actualGoogleRequests: 0, googleSendRequests: 0,
      prominentTopStatus: true, pausedInputExplained: true, ariaBusy: true, reservedRowKeepsTerminalStable: true,
      desktop: { width: 1440, height: 1000, fontSize: desktop.fontSize, hintFontSize: desktop.hintFontSize,
        contrast: contrast(desktop.foreground, desktop.background), hintContrast: contrast(desktop.hintForeground, desktop.background) },
      narrow: { width: 600, height: 700, statusInViewport: true }, reducedMotion: true,
      small: { width: 360, height: 700, statusInViewport: true, terminalStableWhileHintWraps: true },
      clearedAfterCompletionAndCancellation: true, reconnectIdle: true, requestCount: requests.length, maximumActiveRequests };
    await writeFile(join(work, "activity-acceptance.json"), JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
    console.log(JSON.stringify(report));
  } else if (args.get("--native-connect") === "true") {
    assert((await evaluate("location.hash")) === "#omagma-session=" + localSessionNonce, "native launch capability is not retained in its intended fragment");
    const visibleURL = await evaluate("location.href");
    for (const secret of [clientSecret, ...refreshSecrets, ...accessSecrets]) assert(!visibleURL.includes(secret), "native URL contains OAuth credential material");
    assert.equal((await session()).mode, "demo", "native launch connected without the user's Connect action");
    assert.equal(requests.length, 0, "native launch contacted Google before Connect");
    await screenshot("native-server-sample.png");
    await click("#connect-open");
    await connected(2);
    assert.equal(await evaluate("document.querySelector('#credential-dialog').open"), false, "native server connection asked for credential files");
    const localRequests = events.filter((event) => event.method === "Network.requestWillBeSent" && event.params.request.url === origin + "/connection.json");
    assert.equal(localRequests.length, 1, "native Connect did not fetch one guarded in-memory connection bundle");
    const localAuthorization = Object.entries(localRequests[0].params.request.headers).find(([key]) => key.toLowerCase() === "authorization")?.[1];
    assert(localAuthorization === "Omagma-Session " + localSessionNonce, "native Connect did not authenticate its local credential request");
    assert.deepEqual((await session()).canSend, [true, true], "native bundle capability binding was lost");
    const ada = await act(() => text("1"));
    assert(ada.includes("Ada live mailbox") && ada.includes("Hello Ada,"), "native server connection did not render the first verified mailbox");
    const bea = await act(() => text("2"));
    assert(bea.includes("Bea live mailbox") && bea.includes("Hello Bea,"), "native server connection did not render the second verified mailbox");
    assert(!bea.includes("Ada live mailbox") && !bea.includes("Hello Ada,"), "native connection switched mail across account boundaries");
    const active = await evaluate("JSON.stringify({diagnostics:window.omagmaDemo,session:window.omagmaDemo.sessionInfo(),state:window.omagmaDemo.state()})");
    for (const secret of syntheticSecrets) assert(!active.includes(secret), "native connection exposed credentials or its local session secret in diagnostics");
    await screenshot("native-server-connected.png");
    const beforePageTransition = requests.length;
    await evaluate("window.dispatchEvent(new PageTransitionEvent('pagehide',{persisted:true}));window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}));true");
    await until(async () => (await evaluate("window.omagmaDemo?.ready === true")) && (await session()).mode === "demo" && (await session()).accountCount === 0,
      "persisted page transition did not erase the live connection and restore sample mode");
    assert.equal(requests.length, beforePageTransition, "persisted page transition automatically replayed Google authorization or mail requests");
    assert(!((await screen()).includes("Ada live mailbox") || (await screen()).includes("Bea live mailbox")), "persisted page transition retained live mailbox content");
    await disconnect();
    assert.equal(sends().length, 0, "native connection acceptance attempted a Gmail mutation");
    const beforeReload = requests.length;
    const marker = events.length;
    await call("Page.reload", { ignoreCache: true });
    await until(async () => events.slice(marker).some((event) => event.method === "Page.loadEventFired"), "native connection reload did not load a new document");
    await until(async () => evaluate("window.omagmaDemo?.ready === true"), "native connection reload did not restore sample mode");
    assert.equal((await session()).accountCount, 0, "native connection reload retained credentials");
    assert.equal(requests.length, beforeReload, "native connection reload automatically reused credentials");
    assert((await evaluate("location.hash")) === "#omagma-session=" + localSessionNonce, "refresh discarded the native Connect capability");
    await click("#connect-open");
    await connected(2);
    assert.equal(await evaluate("document.querySelector('#credential-dialog').open"), false, "refresh changed native Connect into a file chooser");
    await disconnect();
    const privacy = await evaluate(`(async()=>({
      diagnostics:JSON.stringify(window.omagmaDemo),html:document.documentElement.outerHTML,
      localStorage:Object.fromEntries(Object.keys(localStorage).map(key=>[key,localStorage.getItem(key)])),
      sessionStorage:Object.fromEntries(Object.keys(sessionStorage).map(key=>[key,sessionStorage.getItem(key)])),
      databases:await indexedDB.databases(),caches:await caches.keys(),cookies:document.cookie
    }))()`);
    privacy.indexedDBRows = await cacheRows();
    const exposed = JSON.stringify(privacy) + JSON.stringify(events.filter((event) => event.method === "Runtime.consoleAPICalled" || event.method === "Runtime.exceptionThrown"));
    for (const secret of syntheticSecrets) assert(!exposed.includes(secret), "native connection leaked credentials or its launch secret into persistence or logs");
    assert.deepEqual(privacy.localStorage, {}); assert.deepEqual(privacy.sessionStorage, {});
    assertCacheDatabases(privacy.databases); assert.deepEqual(privacy.caches, []); assert.equal(privacy.cookies, "");
    assert((await evaluate("location.hash")) === "#omagma-session=" + localSessionNonce, "native Connect changed its launch capability");
    assert.deepEqual(transportErrors, []); assert.deepEqual(unexpectedDestinations, []);
    const report = { synthetic: true, desktopUsed: false, browser: version.product, origin,
      realNativeServer: true, authenticatedNativeConnection: true, fileDialogRequired: false,
      accountCount: 2, verifiedReadsAndIsolation: true, credentialsInPersistenceOrLogs: 0,
      launchCapabilityInFragmentOnly: true, explicitConnectAfterRefresh: true, actualGoogleRequests: 0, googleSendRequests: sends().length,
      syntheticPersistedPageTransitionHandlers: true,
      requestCount: requests.length, maximumActiveRequests };
    await writeFile(join(work, "native-connect-acceptance.json"), JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
    console.log(JSON.stringify(report));
  } else if (args.get("--connect-only") === "true") {
    const sample = await evaluate("document.body.innerText");
    assert(/Sample inbox/i.test(sample), "default screen does not clearly identify the sample inbox");
    assert.match(await evaluate("document.querySelector('#connect-open').textContent"), /Connect Gmail/i);
    await screenshot("connect-sample-inbox.png");
    await click("#connect-open");
    await until(async () => evaluate("document.querySelector('#credential-dialog').open"), "primary connection dialog did not open");
    assert.equal(await evaluate("document.querySelector('#credential-separate').open"), false, "legacy separate-file controls are open by default");
    const chooser = await evaluate(`(()=>{
      const dialog=document.querySelector('#credential-dialog');
      const primary=document.querySelector('#credential-select');const bundle=document.querySelector('#credential-bundle');
      return {text:dialog.innerText,inputs:[...dialog.querySelectorAll('input[type=file]')].filter(input=>input.checkVisibility()).map(input=>input.id),
        singleBundle:bundle?.type==='file'&&!bundle.multiple,primaryVisible:primary?.checkVisibility(),primaryCaption:primary?.textContent};
    })()`);
    assert.deepEqual(chooser.inputs, [], "default dialog exposes legacy separate-file fields");
    assert(chooser.singleBundle && chooser.primaryVisible, "default dialog has no single-file connection chooser");
    assert.match(chooser.primaryCaption, /Select connection file/i);
    assert.match(chooser.text, /connection file/i, "primary chooser does not use the plain connection-file label");
    await screenshot("connect-single-file-dialog.png");
    await call("Page.setInterceptFileChooserDialog", { enabled: true });
    const chooserMarker = events.length;
    await click("#credential-select");
    let openedChooser;
    await until(async () => {
      openedChooser = events.slice(chooserMarker).find((event) => event.method === "Page.fileChooserOpened")?.params;
      return Boolean(openedChooser);
    }, "visible connection-file button did not open the native file chooser");
    assert.equal(openedChooser.mode, "selectSingle", "primary connection picker accepts multiple files");
    const description = await call("DOM.describeNode", { backendNodeId: openedChooser.backendNodeId });
    const attributes = Object.fromEntries(Array.from({ length: description.node.attributes.length / 2 }, (_, index) => description.node.attributes.slice(index * 2, index * 2 + 2)));
    assert.equal(attributes.id, "credential-bundle", "visible chooser button targets a legacy credential field");
    await call("DOM.setFileInputFiles", { backendNodeId: openedChooser.backendNodeId, files: [bundles.ada] });
    assert.equal(requests.length, 0, "choosing a connection file implicitly contacted Google");
    await screenshot("connect-selected-file-dialog.png");
    await choose("#credential-bundle", []);
    for (const [label, path] of bundles.invalid) {
      const before = requests.length;
      await importBundle(path);
      await until(async () => (await credentialError()).length > 0, `invalid ${label} connection file was not refused`);
      assert.equal(requests.length, before, `invalid ${label} connection file reached Google`);
      assert.equal((await session()).mode, "demo", `invalid ${label} changed the current session`);
      const exposed = (await credentialError()) + await evaluate("JSON.stringify(window.omagmaDemo)");
      for (const secret of syntheticSecrets) assert(!exposed.includes(secret), `invalid ${label} exposed credential contents`);
    }
    await disconnect();
    wrongProfile = true;
    const wrongStart = requests.length;
    await importBundle(bundles.ada);
    await until(async () => (await credentialError()).length > 0, "single-file wrong profile identity was not rejected", 30000);
    assert(requests.slice(wrongStart).some((request) => new URL(request.url).pathname.endsWith("/profile")), "single-file connection did not verify its Google profile");
    assert(!requests.slice(wrongStart).some((request) => new URL(request.url).pathname.endsWith("/messages")), "wrong single-file profile read mailbox rows");
    wrongProfile = false;
    await disconnect();

    scopeMode = "readonly";
    await importBundle(bundles.readonly);
    await connected(1);
    assert.deepEqual((await session()).canSend, [false], "read-only connection file enabled sending");
    assert((await screen()).includes("Ada live mailbox") && (await screen()).includes("Hello Ada,"), "single-file read-only connection did not read the verified mailbox");
    const denied = await act(() => text("c"));
    assert(/PermissionDenied|permission required|read.only|read only/i.test(denied), "single-file read-only account accepted compose");
    await disconnect();
    await importBundle(bundles.ada);
    await connected(1);
    assert.deepEqual((await session()).canSend, [false], "narrowed Google scope overrode single-file capability checks");
    await disconnect();

    scopeMode = "omitted";
    await importBundle(bundles.ada);
    await connected(1);
    assert.deepEqual((await session()).canSend, [true], "single-file send grant did not survive valid omitted-scope refresh");
    assert((await screen()).includes("Ada live mailbox"), "single-file send grant did not complete native mail loading");
    const diagnostics = await evaluate("JSON.stringify({diagnostics:window.omagmaDemo,session:window.omagmaDemo.sessionInfo(),state:window.omagmaDemo.state()})");
    for (const secret of syntheticSecrets) assert(!diagnostics.includes(secret), "single-file active diagnostics exposed credentials");
    await disconnect();

    scopeMode = "send";
    await importBundle(bundles.both);
    await connected(2);
    assert.deepEqual((await session()).canSend, [true, true]);
    const ada = await act(() => text("1"));
    assert(ada.includes("Ada live mailbox") && ada.includes("Hello Ada,"), "first bundled account rendered the wrong mailbox");
    const bea = await act(() => text("2"));
    assert(bea.includes("Bea live mailbox") && bea.includes("Hello Bea,"), "second bundled account rendered the wrong mailbox");
    assert(!bea.includes("Ada live mailbox") && !bea.includes("Hello Ada,"), "bundled account switch leaked mail");
    await screenshot("connect-two-account-inbox.png");
    await disconnect();

    scopeMode = "readonly";
    await importFiles(files.readonly);
    await connected(1);
    assert.deepEqual((await session()).canSend, [false], "legacy separate-file permissions changed");
    assert((await screen()).includes("Ada live mailbox"), "legacy separate-file import no longer reads its mailbox");
    await disconnect();
    assert.equal(sends().length, 0, "connection-only acceptance attempted a Gmail mutation");
    assert.equal(await evaluate("document.querySelector('#credential-bundle').files.length"), 0, "disconnect retained the selected connection file");
    const beforeReload = requests.length;
    const marker = events.length;
    await call("Page.reload", { ignoreCache: true });
    await until(async () => events.slice(marker).some((event) => event.method === "Page.loadEventFired"), "connection-only reload did not load a new document");
    await until(async () => evaluate("window.omagmaDemo?.ready === true"), "connection-only reload did not restore sample mode");
    assert.equal((await session()).accountCount, 0, "reload restored single-file credentials");
    assert.equal(requests.length, beforeReload, "reload automatically reused connection-file credentials");
    const privacy = await evaluate(`(async()=>({
      diagnostics:JSON.stringify(window.omagmaDemo),html:document.documentElement.outerHTML,
      localStorage:Object.fromEntries(Object.keys(localStorage).map(key=>[key,localStorage.getItem(key)])),
      sessionStorage:Object.fromEntries(Object.keys(sessionStorage).map(key=>[key,sessionStorage.getItem(key)])),
      databases:await indexedDB.databases(),caches:await caches.keys(),cookies:document.cookie
    }))()`);
    privacy.indexedDBRows = await cacheRows();
    const exposed = JSON.stringify(privacy) + JSON.stringify(events.filter((event) => event.method === "Runtime.consoleAPICalled" || event.method === "Runtime.exceptionThrown"));
    for (const secret of syntheticSecrets) assert(!exposed.includes(secret), "connection-file credentials leaked into persistence or logs");
    assert.deepEqual(privacy.localStorage, {});
    assert.deepEqual(privacy.sessionStorage, {});
    assertCacheDatabases(privacy.databases);
    assert.deepEqual(privacy.caches, []);
    assert.equal(privacy.cookies, "");
    assert.deepEqual(transportErrors, []);
    assert.deepEqual(unexpectedDestinations, []);
    const report = { synthetic: true, desktopUsed: false, browser: version.product, actualGoogleRequests: 0, origin, realNativeServer: Boolean(suppliedOrigin),
      primaryFileChooser: "credential-bundle", visibleChooserButton: chooser.primaryCaption.trim(), invalidBundlesRejectedBeforeNetwork: bundles.invalid.length,
      nativeChooserButtonVerified: true,
      profileIdentityVerified: true, readonlyAndNarrowedScopes: true, omittedScopeRefresh: true,
      twoAccountsReadAndIsolated: true, legacySeparateFiles: true, selectedFilesCleared: true,
      credentialsInPersistenceOrLogs: 0, googleSendRequests: sends().length,
      requestCount: requests.length, maximumActiveRequests };
    await writeFile(join(work, "connect-acceptance.json"), JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
    console.log(JSON.stringify(report));
  } else {
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
    await input(encoder.encode('c'));
    await input(new Uint8Array([0x14]));
    await input(encoder.encode('irecipient@example.test\t\t\tBuffered review regression\tPlain packet body'));
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
  await connected(1);
  const failedFirstList = await screen();
  assert(/PermissionDenied|permission required/i.test(failedFirstList), "first live list denial was not reported in the native mail status");
  assert(!failedFirstList.includes("Omagma, now in your browser") && !failedFirstList.includes("Hello Ada,"), "first live list failure displayed fictional or prior mail under a live account");
  listFailure = null;
  await disconnect();

  scopeMode = "readonly";
  await importFiles(files.readonly);
  await connected(1);
  assert.deepEqual((await session()).canSend, [false], "read-only grant enabled sending");
  const readonlyBefore = sends().length;
  const readonlyCompose = await act(() => text("c"));
  assert(/PermissionDenied|permission required|read.only|read only/i.test(readonlyCompose), "read-only compose did not explain its permission refusal");
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
  await act(() => click("#cache-clear"));
  listFailure = { accountIndex: 1, mode: "malformed" };
  await act(() => text("2"));
  const failedSwitch = await act(() => key("r", "KeyR", 2));
  assert(!failedSwitch.includes("Ada live mailbox") && !failedSwitch.includes("Hello Ada,"), "failed second-account list retained the first account's mail");
  const failedReply = await act(() => text("r"));
  assert(!failedReply.includes("Re: Ada live mailbox") && !failedReply.includes("> Hello Ada,"), "failed account switch retained another account's reply source");
  listFailure = null;
  const bea = await act(() => key("r", "KeyR", 2));
  assert(bea.includes("Bea live mailbox") && bea.includes("Hello Bea,"), "second account did not recover its own mailbox after a failed list");
  assert(!bea.includes("Ada live mailbox") && !bea.includes("Hello Ada,"), "second account leaked first-account content");
  await act(() => text("1"));
  await act(() => key("r", "KeyR", 2));
  await act(() => key("j", "KeyJ"));
  const html = await act(() => key("Enter", "Enter"));
  assert(html.includes("Literal HTML fixture") && html.includes("safe café"), "HTML-only provider body did not use the native semantic reader");
  assert(!html.includes("window.mailInjected") && !html.includes("javascript:"), "semantic HTML reader retained active source instructions");
  assert.equal(await evaluate("typeof window.mailInjected"), "undefined", "received HTML executed in the browser");
  await act(() => text("q"));
  await act(() => key("k", "KeyK"));
  await screenshot("live-inbox.png");

  const composeBody = "Hello synthetic recipient,\nPlain UTF-8 café 🚀.\n" + "界🚀 café ".repeat(260) + "\n";
  assert(Buffer.byteLength(composeBody) > 2048, "paste fixture does not cross multiple bridge input chunks");
  await act(() => text("c"));
  await editComposer({ plain: true });
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
  await until(async () => (await screen()).includes("Submitted; recipient delivery is not confirmed"), "successful synthetic send did not report native submission acceptance");
  const newMail = outgoingMessage(newSend);
  assert(newMail.headers.from.includes(accounts[0]) && newMail.headers.to.includes("recipient@example.test"));
  assert.equal(newMail.headers.subject, "Browser synthetic compose");
  assert.equal(newMail.body, composeBody, "plain MIME body changed pasted Unicode or line endings");
  assert.equal(newSend.threadId ?? null, null, "new compose unexpectedly joined an existing thread");

  await focus();
  await act(() => text("r"));
  await editComposer({ plain: true, body: true });
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
  await focus();
  await act(() => text("1"));
  await act(() => text("q"));
  holdNextFullRead = true;
  await key("G", "KeyG", 8); // The bounded last message has not been prefetched.
  await until(async () => heldReads.length === 1, "body request was not suspended by the synthetic transport");
  const heldRequestCount = requests.length;
  await text("jj");
  await call("Emulation.setDeviceMetricsOverride", { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false });
  await pause(100);
  assert.equal(requests.length, heldRequestCount, "WASM reentered the transport while another body request was suspended");
  await disconnectDecision(true);
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
  await editComposer({ plain: true });
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
  expectedDialog = { purpose: "intentional-reload-discards-session-draft", type: "beforeunload", accept: true };
  await call("Page.reload", { ignoreCache: true });
  await until(async () => events.slice(reloadMarker).some((event) => event.method === "Page.loadEventFired"), "reload did not create a new document");
  expectedDialog = null;
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
  privacy.indexedDBRows = await cacheRows();
  const privacyText = JSON.stringify(privacy) + JSON.stringify(events.filter((event) => event.method === "Runtime.consoleAPICalled" || event.method === "Runtime.exceptionThrown"));
  for (const secret of syntheticSecrets) assert(!privacyText.includes(secret), "credentials leaked into browser diagnostics, logs or persistence");
  assert.deepEqual(privacy.sessionStorage, {});
  assertCacheDatabases(privacy.databases);
  assert.deepEqual(privacy.caches, []);
  assert.equal(privacy.cookies, "");
  assert.deepEqual(Object.keys(privacy.localStorage), ["omagma-browser-pending-send-v1"]);
  assert(!JSON.stringify(receipt).includes("Protected uncertain body") && !JSON.stringify(receipt).includes(accounts[0]), "uncertain receipt retained mail content or account details");
  await click("#send-acknowledge");
  assert.equal(await evaluate("localStorage.getItem('omagma-browser-pending-send-v1')"), null, "explicit acknowledgement did not clear the generic receipt");
  assert.deepEqual(transportErrors, [], "synthetic transport handler failed");
  assert.deepEqual(unexpectedDestinations, [], "message content or host attempted an unapproved external destination");
  const report = { synthetic: true, desktopUsed: false, actualGoogleRequests: 0, browser: version.product,
    origin, realNativeServer: Boolean(suppliedOrigin),
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
  }
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
  if (server) await new Promise((accept) => server.close(accept));
}
