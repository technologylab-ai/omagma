#!/usr/bin/env node
// Acceptance for the real Zig `omagma server` binary. Run under the repository's
// cooperative host lock. This harness never reads a real account configuration
// or credential store, and browser subchecks intercept all Google traffic.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { request } from "node:http";
import { createServer, connect } from "node:net";
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const args = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  assert(process.argv[index].startsWith("--") && process.argv[index + 1], `invalid argument ${process.argv[index]}`);
  args.set(process.argv[index], process.argv[index + 1]);
}
assert(args.has("--binary"), "expected --binary /path/to/native/omagma");
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const binary = resolve(args.get("--binary"));
const site = resolve(args.get("--site-dir") || join(root, "web-demo/dist"));
const work = resolve(args.get("--work-dir") || `/tmp/omagma-browser-server-${process.pid}`);
const browserChecks = args.get("--browser-checks") || "none";
assert(["none", "demo", "connect", "both"].includes(browserChecks), "--browser-checks must be none, demo, connect, or both");
await mkdir(work, { recursive: true, mode: 0o700 });
const empty = join(work, `empty-cwd-${process.pid}`);
await mkdir(empty, { recursive: true, mode: 0o700 });
assert.deepEqual(await readdir(empty), [], "server launch directory is not empty");
const environment = { PATH: process.env.PATH, LANG: "C.UTF-8", HOME: join(work, "home"),
  XDG_CONFIG_HOME: join(work, "config"), XDG_CACHE_HOME: join(work, "cache"), XDG_DATA_HOME: join(work, "data") };
const scopes = ["https://www.googleapis.com/auth/gmail.readonly", "https://www.googleapis.com/auth/gmail.send"];
const clientId = "synthetic-browser-test.apps.googleusercontent.com";
const clientSecret = "synthetic-client-secret-never-valid";
const addresses = ["ada.browser@example.test", "bea.browser@example.test"];
const refreshTokens = addresses.map((_, index) => `synthetic-refresh-${index}-never-valid`);
const tupleHash = (parts) => createHash("sha256").update(parts.map((part) => part + "\0").join("")).digest("hex");
const configDirectory = join(environment.XDG_CONFIG_HOME, "omagma");
const credentialDirectory = join(work, "private-credentials");
await mkdir(configDirectory, { recursive: true, mode: 0o700 });
await mkdir(credentialDirectory, { recursive: true, mode: 0o700 });
const clientFile = join(configDirectory, "synthetic-oauth-client.json");
const grants = addresses.map((account) => ({ account, clientFile, clientId,
  grantId: tupleHash(["omagma-terminal-grant-v1", ...scopes]), capabilities: ["mail-read", "mail-send"], scopes, enabled: true }));
await writeFile(clientFile, JSON.stringify({ installed: { client_id: clientId, client_secret: clientSecret,
  project_id: "synthetic-browser-project", auth_uri: "https://accounts.google.com/o/oauth2/auth",
  token_uri: "https://oauth2.googleapis.com/token", redirect_uris: ["http://localhost"] } }) + "\n", { mode: 0o600 });
await writeFile(join(configDirectory, "config.json"), JSON.stringify({ oauthClientFile: clientFile,
  credentialStore: "file", credentialDirectory, accounts: addresses.map((address, index) => ({ address,
    profile: `Profile ${index + 1}`, enabled: true, required: true })) }) + "\n", { mode: 0o600 });
await writeFile(join(configDirectory, "terminal-grants.json"), JSON.stringify({ version: 1, accounts: grants }) + "\n", { mode: 0o600 });
for (const [index, grant] of grants.entries()) {
  const accountDirectory = join(credentialDirectory, tupleHash(["omagma-credential-account-v1", grant.account]));
  await mkdir(accountDirectory, { recursive: true, mode: 0o700 });
  const name = `terminal-${tupleHash(["omagma-credential-value-v1", "terminal", grant.account, grant.clientId, grant.grantId])}.token`;
  await writeFile(join(accountDirectory, name), refreshTokens[index], { mode: 0o600 });
}
const expectedRecords = grants.map((grant, index) => ({ account: grant.account, clientId, clientSecret,
  grantId: grant.grantId, capabilities: grant.capabilities, scopes: grant.scopes, refreshToken: refreshTokens[index] }));
const pause = (milliseconds) => new Promise((accept) => setTimeout(accept, milliseconds));
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const reservations = [];
const idleSockets = [];
let child;
let stdout = "";
let stderr = "";
let sessionNonce = "";
const redacted = (text) => [sessionNonce, clientSecret, ...refreshTokens].filter(Boolean)
  .reduce((value, secret) => value.replaceAll(secret, "[private fixture value]"), text)
  .replace(/#omagma-session=[A-Za-z0-9]+/g, "#omagma-session=[private fixture value]");

async function reserve(port) {
  const listener = createServer((socket) => socket.destroy());
  const status = await new Promise((accept, reject) => {
    listener.once("error", (error) => error.code === "EADDRINUSE" ? accept("already occupied") : reject(error));
    listener.listen(port, "127.0.0.1", () => accept("owned reservation"));
  });
  if (status === "owned reservation") reservations.push(listener);
  return { port, status };
}
async function firstFree(start) {
  for (let port = start; port < start + 100; port++) {
    const probe = createServer();
    const free = await new Promise((accept, reject) => {
      probe.once("error", (error) => error.code === "EADDRINUSE" ? accept(false) : reject(error));
      probe.listen(port, "127.0.0.1", () => accept(true));
    });
    if (free) { await new Promise((accept) => probe.close(accept)); return port; }
  }
  throw new Error("no free test port after the occupied default ports");
}
function http(port, path, method = "GET", body = null, extraHeaders = {}) {
  return new Promise((accept, reject) => {
    const connection = request({ hostname: "127.0.0.1", port, path, method,
      headers: { Connection: "close", ...(body === null ? {} : { "Content-Length": Buffer.byteLength(body) }), ...extraHeaders },
      agent: false, timeout: 10000 }, (response) => {
      const chunks = [];
      response.on("data", (bytes) => chunks.push(bytes));
      response.once("error", reject);
      response.once("end", () => accept({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks) }));
    });
    connection.once("timeout", () => connection.destroy(new Error(`HTTP deadline: ${method} ${path}`)));
    connection.once("error", reject);
    connection.end(body);
  });
}
async function browser(script, origin, name, extra = [], launchURL = null) {
  const output = join(work, name);
  await mkdir(output, { recursive: true, mode: 0o700 });
  const browserProcess = spawn(process.execPath, [join(root, "tests", script), "--origin", origin,
    "--work-dir", output, ...extra], { cwd: root, env: { ...environment,
      ...(launchURL ? { OMAGMA_TEST_LAUNCH_URL: launchURL } : {}) }, stdio: ["ignore", "pipe", "pipe"] });
  let out = "", err = "";
  browserProcess.stdout.on("data", (bytes) => { out += bytes; });
  browserProcess.stderr.on("data", (bytes) => { err += bytes; });
  const status = await new Promise((accept, reject) => { browserProcess.once("error", reject); browserProcess.once("exit", accept); });
  await writeFile(join(output, "suite.stdout"), redacted(out), { mode: 0o600 });
  await writeFile(join(output, "suite.stderr"), redacted(err), { mode: 0o600 });
  assert.equal(status, 0, `${script} failed against the real Zig server: ${redacted(err)}`);
  return JSON.parse(out);
}

try {
  const inspected = spawnSync(binary, ["build-info"], { cwd: empty, env: environment, encoding: "utf8", timeout: 10000 });
  assert.equal(inspected.status, 0, `native build-info failed: ${redacted(inspected.stderr || "")}`);
  const buildInfo = JSON.parse(inspected.stdout);
  assert.equal(buildInfo.zigVersion, "0.17.0", "native binary uses a compiler outside the declared pin");
  assert(typeof buildInfo.optimizeMode === "string" && buildInfo.optimizeMode.length > 0, "native binary did not report its optimization mode");
  const occupied = [await reserve(8766), await reserve(8767)];
  const expectedPort = await firstFree(8768);
  child = spawn(binary, ["server"], { cwd: empty, env: environment, detached: true, stdio: ["ignore", "pipe", "pipe"] });
  child.stdout.on("data", (bytes) => { stdout = (stdout + bytes).slice(-32768); });
  child.stderr.on("data", (bytes) => { stderr = (stderr + bytes).slice(-32768); });
  let launchError;
  child.once("error", (error) => { launchError = error; });
  let origin, launchURL;
  const deadline = Date.now() + 15000;
  while (!origin) {
    if (launchError) throw launchError;
    const url = stdout.match(/http:\/\/127\.0\.0\.1:\d+\/#omagma-session=([a-f0-9]{64})/);
    if (url) { launchURL = url[0]; sessionNonce = url[1]; origin = new URL(launchURL).origin; }
    else {
      assert(child.exitCode === null && child.signalCode === null, `native server exited before printing its URL: ${redacted(stdout)} ${redacted(stderr)}`);
      assert(Date.now() < deadline, `native server did not print a guarded loopback launch URL on stdout: ${redacted(stdout)} ${redacted(stderr)}`);
      await pause(30);
    }
  }
  const port = Number(new URL(origin).port);
  assert.equal(port, expectedPort, "native server did not select the next free port after occupied 8766/8767");
  const assetTypes = { "index.html": "text/html", "app.mjs": "text/javascript", "style.css": "text/css", "omagma-logo.png": "image/png", "xterm.css": "text/css", "omagma.wasm": "application/wasm" };
  const assets = [];
  for (const [name, mime] of Object.entries(assetTypes)) {
    const expected = await readFile(join(site, name));
    const path = name === "index.html" ? "/" : "/" + name;
    const got = await http(port, path);
    assert.equal(got.status, 200, `${path}: native embedded asset missing`);
    assert.equal(got.headers["content-type"]?.split(";")[0], mime, `${path}: wrong native MIME type`);
    assert.equal(Number(got.headers["content-length"]), expected.length, `${path}: wrong asset length`);
    assert.equal(digest(got.body), digest(expected), `${path}: embedded asset differs from the qualified site`);
    const head = await http(port, path, "HEAD");
    assert.equal(head.status, 200);
    assert.equal(head.body.length, 0, `${path}: HEAD sent a body`);
    assert.equal(Number(head.headers["content-length"]), expected.length, `${path}: HEAD lost the GET representation length`);
    assert.equal(head.headers["content-type"], got.headers["content-type"]);
    assets.push({ path, bytes: expected.length, mime, sha256: digest(expected) });
  }
  assert.deepEqual(await readdir(empty), [], "native static server requires or writes runtime files in its launch directory");
  const authorization = `Omagma-Session ${sessionNonce}`;
  const rejected = [
    {}, { Authorization: "Omagma-Session " + "0".repeat(64) },
    { Authorization: authorization, Origin: "https://attacker.example.test" },
    { Authorization: authorization, Host: `attacker.example.test:${port}` },
    { Authorization: authorization, Host: `127.0.0.1:${port + 1}` },
  ];
  for (const headers of rejected) {
    const denied = await http(port, "/connection.json", "GET", null, headers);
    assert.equal(denied.status, 403, "native connection endpoint accepted an unauthenticated, cross-origin or wrong-host request");
    assert.equal(denied.headers["access-control-allow-origin"], undefined, "private connection response grants CORS access");
    assert(!denied.body.includes(clientSecret) && !refreshTokens.some((token) => denied.body.includes(token)), "rejected connection request exposed fixture credentials");
  }
  const connection = await http(port, "/connection.json", "GET", null, { Authorization: authorization, Origin: origin });
  assert.equal(connection.status, 200, "guarded native connection endpoint did not load synthetic file-store grants");
  assert.equal(connection.headers["content-type"]?.split(";")[0], "application/json");
  assert.equal(connection.headers["cache-control"], "no-store");
  assert.equal(connection.headers["access-control-allow-origin"], undefined);
  const bundle = JSON.parse(connection.body);
  assert.equal(bundle.format, "omagma-browser-connection");
  assert.equal(bundle.version, 1);
  assert.equal(bundle.accounts.length, 2);
  const canonicalRecords = (records) => records.map((record) => Object.fromEntries(Object.keys(record).sort().map((key) => [key, record[key]])));
  assert(JSON.stringify(canonicalRecords(bundle.accounts)) === JSON.stringify(canonicalRecords(expectedRecords)), "guarded connection bundle differs from the synthetic source records");
  assert.deepEqual(await readdir(empty), [], "connection endpoint wrote an export file into the launch directory");
  assert.deepEqual((await readdir(configDirectory)).sort(), ["config.json", "synthetic-oauth-client.json", "terminal-grants.json"], "connection endpoint created an unexpected disk export");
  const unknown = ["/not-an-asset", "/.git/config", "/../private-sentinel.txt", "/%2e%2e/private-sentinel.txt",
    "/%2e%2e%2fprivate-sentinel.txt", "/app.mjs/../private-sentinel.txt", "/..\\private-sentinel.txt"];
  await writeFile(join(work, "private-sentinel.txt"), "synthetic server traversal sentinel", { mode: 0o600 });
  for (const path of unknown) {
    const got = await http(port, path);
    assert.equal(got.status, 404, `${path}: unexpected/traversal route did not return 404`);
    assert(!got.body.includes("synthetic server traversal sentinel"), `${path}: server read a file outside its embedded site`);
  }
  const post = await http(port, "/", "POST", "ignored synthetic body");
  assert.equal(post.status, 405, "native static server accepted POST");
  assert.match(post.headers.allow || "", /GET/);
  assert.match(post.headers.allow || "", /HEAD/);
  const concurrent = await Promise.all(Array.from({ length: 8 }, (_, index) => http(port, index % 2 ? "/style.css" : "/app.mjs")));
  assert(concurrent.every((response) => response.status === 200), "native server dropped ordinary concurrent asset requests");
  // A peer that sends no request must not monopolize the local server. Keep a
  // few idle peers while a normal GET completes, then inspect deadline cleanup.
  for (let index = 0; index < 2; index++) {
    const socket = connect({ host: "127.0.0.1", port });
    socket.on("error", () => {});
    socket.on("end", () => socket.destroy());
    socket.resume();
    await new Promise((accept, reject) => { socket.once("connect", accept); socket.once("error", reject); });
    idleSockets.push(socket);
  }
  const idleStarted = Date.now();
  assert.equal((await http(port, "/style.css")).status, 200, "idle clients prevented a real request");
  const requestDuringIdleMs = Date.now() - idleStarted;
  const idleDeadline = Date.now() + 15000;
  while (idleSockets.some((socket) => !socket.destroyed) && Date.now() < idleDeadline) await pause(30);
  assert(idleSockets.every((socket) => socket.destroyed), "native server retained idle connections past its bounded deadline");
  const report = { synthetic: true, nativeBinary: true, buildInfo, emptyLaunchDirectory: true, origin, occupied, selectedPort: port,
    assets, getAndHead: true, traversalAndUnknown404: unknown.length, post405: true,
    concurrentRequests: concurrent.length, idleConnectionsClosed: idleSockets.length, requestDuringIdleMs,
    actualGoogleRequests: 0, privateConnection: { rejectedRequests: rejected.length, validatedSyntheticAccounts: 2,
      authorizationRequired: true, exactHostAndOrigin: true, noCors: true, noStore: true, noDiskExport: true } };
  if (["demo", "both"].includes(browserChecks)) {
    const result = await browser("browser_wasm.mjs", origin, "demo-browser");
    report.demoBrowser = { browser: result.browser, realNativeServer: result.realNativeServer,
      renderingCases: result.rendering.length, externalRequests: result.externalRequests };
  }
  if (["connect", "both"].includes(browserChecks)) {
    const direct = await browser("browser_wasm_live.mjs", origin, "native-connect-browser", ["--native-connect", "true"], launchURL);
    report.nativeConnectBrowser = { browser: direct.browser, realNativeServer: direct.realNativeServer,
      syntheticProviderRequests: direct.requestCount, googleSendRequests: direct.googleSendRequests, actualGoogleRequests: direct.actualGoogleRequests };
    const result = await browser("browser_wasm_live.mjs", origin, "connect-browser", ["--connect-only", "true"]);
    report.connectBrowser = { browser: result.browser, realNativeServer: result.realNativeServer,
      syntheticProviderRequests: result.requestCount, googleSendRequests: result.googleSendRequests, actualGoogleRequests: result.actualGoogleRequests };
  }
  await writeFile(join(work, "server-acceptance.json"), JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
  console.log(JSON.stringify(report));
} catch (error) {
  if (typeof error.message === "string") error.message = redacted(error.message);
  throw error;
} finally {
  for (const socket of idleSockets) socket.destroy();
  if (child?.pid) {
    try { process.kill(-child.pid, "SIGTERM"); } catch (error) { if (error.code !== "ESRCH") throw error; }
    await Promise.race([new Promise((accept) => child.once("exit", accept)), pause(3000)]);
    if (child.exitCode === null && child.signalCode === null) {
      try { process.kill(-child.pid, "SIGKILL"); } catch (error) { if (error.code !== "ESRCH") throw error; }
    }
  }
  for (const listener of reservations) await new Promise((accept) => listener.close(accept));
}
