#!/usr/bin/env node
// Independent headless Chromium acceptance for the native preview artifact.
// The fixture writer must accept OUTPUT_DIRECTORY TRAP_URL and use the real
// preview_file.writePreview API. No desktop, real account or browser profile.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createServer } from "node:http";
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { resolve, join } from "node:path";
import { pathToFileURL } from "node:url";

const values = new Map();
for (let index = 2; index < process.argv.length; index += 2) values.set(process.argv[index], process.argv[index + 1]);
assert(values.get("--fixture-writer") && values.get("--work-dir"), "expected --fixture-writer and --work-dir");
const work = resolve(values.get("--work-dir"));
await mkdir(work, { recursive: true, mode: 0o700 });
const requests = [];
const trap = createServer((request, response) => {
  requests.push(request.url);
  if (request.url === "/positive-control") {
    response.writeHead(200, { "Content-Type": "text/html", "Cache-Control": "no-store" });
    response.end('<!doctype html><link rel="icon" href="data:,">Synthetic positive control.');
    return;
  }
  response.writeHead(200, { "Content-Type": "text/plain" });
  response.end("Synthetic resource trap. This must never be fetched.");
});
await new Promise((accept) => trap.listen(0, "127.0.0.1", accept));
const trapUrl = `http://127.0.0.1:${trap.address().port}`;
const account = join(work, "account");
await mkdir(account, { recursive: true, mode: 0o700 });
const written = spawnSync(resolve(values.get("--fixture-writer")), [account, trapUrl], { encoding: "utf8", timeout: 10000 });
assert.equal(written.status, 0, `native fixture writer failed: ${written.stderr}`);
const preview = join(account, "preview.html");
assert.equal((await stat(preview)).mode & 0o777, 0o600, "native preview is not private 0600");
const profile = join(work, "chrome-profile");
await mkdir(profile, { recursive: true, mode: 0o700 });
const browser = spawn(values.get("--chromium") || "/usr/bin/chromium", [
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
const pause = (milliseconds) => new Promise((accept) => setTimeout(accept, milliseconds));
async function until(condition, message, milliseconds = 10000) {
  const deadline = Date.now() + milliseconds;
  while (!(await condition())) {
    assert(Date.now() < deadline, `${message}; browser status ${browser.exitCode}; ${browserLog.slice(-1500)}`);
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
  socket.addEventListener("message", (event) => {
    const value = JSON.parse(event.data);
    if (value.id) {
      const waiter = pending.get(value.id);
      if (waiter) { pending.delete(value.id); clearTimeout(waiter.timer); value.error ? waiter.reject(new Error(JSON.stringify(value.error))) : waiter.accept(value.result); }
    } else events.push(value);
  });
  function call(method, params = {}, sessionId) {
    return new Promise((accept, reject) => {
      const id = ++sequence;
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP deadline: ${method}`)); }, 10000);
      pending.set(id, { accept, reject, timer });
      socket.send(JSON.stringify({ id, method, params, sessionId }));
    });
  }
  async function evaluate(expression, contextId, sessionId) {
    const response = await call("Runtime.evaluate", { expression, contextId, returnByValue: true, awaitPromise: true }, sessionId);
    assert(!response.exceptionDetails, JSON.stringify(response.exceptionDetails));
    return response.result.value;
  }
  await call("Page.enable");
  await call("Runtime.enable");
  await call("Network.enable");
  await call("Log.enable");
  // An opaque sandboxed srcdoc can live in a separate renderer. Attach to
  // that owned target instead of disabling site isolation to simplify tests.
  await call("Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: false, flatten: true });
  await call("Emulation.setDeviceMetricsOverride", { width: 1100, height: 1000, deviceScaleFactor: 1, mobile: false });
  const version = await call("Browser.getVersion");
  // Prove that the owned browser can reach the trap before the preview's
  // policy is applied; flags/DNS/test transport cannot make a false pass.
  const control = await call("Target.createTarget", { url: trapUrl + "/positive-control" });
  await until(async () => requests.includes("/positive-control"), "network positive control did not reach the trap");
  await pause(100);
  await call("Target.closeTarget", { targetId: control.targetId });
  requests.length = 0;
  await call("Page.navigate", { url: pathToFileURL(preview).href });
  await until(async () => evaluate("document.querySelector('iframe') !== null"), "preview shell not rendered");
  const shell = await evaluate("({frames:document.querySelectorAll('iframe').length,sandbox:document.querySelector('iframe').getAttribute('sandbox'),heading:document.querySelector('h1').textContent,sourceExecuted:typeof window.sourceExecuted})");
  assert.equal(shell.frames, 1, "mail created an extra outer frame");
  assert.equal(shell.sandbox, "", "preview grants source origin/script permissions");
  assert.equal(shell.heading, "Fictional launch planning preview");
  assert.equal(shell.sourceExecuted, "undefined");
  let childSession;
  await until(async () => {
    childSession = events.find((event) => event.method === "Target.attachedToTarget" && event.params.targetInfo.type === "iframe")?.params.sessionId;
    return childSession !== undefined;
  }, "opaque message renderer was not attached");
  await call("Page.enable", {}, childSession);
  await call("Runtime.enable", {}, childSession);
  await call("Log.enable", {}, childSession);
  await until(async () => (await call("Page.getFrameTree", {}, childSession)).frameTree.frame.url === "about:srcdoc", "message srcdoc not rendered");
  let context;
  await until(async () => {
    context = events.find((event) => event.method === "Runtime.executionContextCreated" && event.sessionId === childSession && event.params.context.auxData?.isDefault)?.params.context.id;
    return context !== undefined;
  }, "source's default execution world was not available");
  await until(async () => evaluate("document.querySelector('#original-table') !== null", context, childSession), "source table did not render");
  const content = await evaluate(`({
    text:document.body.textContent,
    color:getComputedStyle(document.querySelector('#original-table td')).color,
    tableWidth:document.querySelector('#original-table').getBoundingClientRect().width,
    cidImage:document.querySelector('#cid-image').naturalWidth,
    logo:document.querySelector('#trusted-logo').naturalWidth,
    background:getComputedStyle(document.querySelector('#cid-background')).backgroundImage.startsWith('url("data:image/png;base64,'),
    sourceExecuted:typeof window.sourceExecuted,
    remoteLink:document.querySelector('#remote-link').hasAttribute('href'),
    svgImage:document.querySelector('#bad-svg-image').hasAttribute('src'),
    parentAccess:(()=>{try{return parent.document.title}catch(error){return error.name}})()
  })`, context, childSession);
  assert(content.text.includes("Original planning table") && content.text.includes("Literal cid:picture@example.test stays prose."));
  assert.equal(content.color, "rgb(18, 52, 86)", "source table stylesheet was lost");
  assert(content.tableWidth > 500, "source table no longer renders its layout");
  assert(content.cidImage > 0 && content.logo > 0 && content.background, "verified CID/logo/background images are not visible");
  assert.equal(content.sourceExecuted, "undefined");
  assert.equal(content.remoteLink, false, "received link can navigate the preview frame");
  assert.equal(content.svgImage, false, "active SVG data image retained a source");
  assert.equal(content.parentAccess, "SecurityError", "source shares the trusted shell's origin");
  const screenshot = await call("Page.captureScreenshot", { format: "png", captureBeyondViewport: false });
  await writeFile(join(work, "browser-preview.png"), Buffer.from(screenshot.data, "base64"), { mode: 0o600 });
  await call("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: "dark" }] });
  const darkBackground = await evaluate("getComputedStyle(document.documentElement).backgroundColor");
  assert.notEqual(darkBackground, "rgb(255, 255, 255)", "preview shell does not follow dark appearance");
  const dark = await call("Page.captureScreenshot", { format: "png", captureBeyondViewport: false });
  await writeFile(join(work, "browser-preview-dark.png"), Buffer.from(dark.data, "base64"), { mode: 0o600 });
  // Exercise the browser's policy itself after native filtering. This prevents
  // a string-only sanitizer test from concealing a missing CSP/sandbox boundary.
  await evaluate(`(()=>{
    const trap=${JSON.stringify(trapUrl)};
    const script=document.createElement('script'); script.textContent="window.previewUnsafe=1;fetch('"+trap+"/injected-script')"; document.body.append(script);
    const image=document.createElement('img'); image.src=trap+'/injected-image'; image.setAttribute('onerror','window.previewUnsafe=2'); document.body.append(image);
    const style=document.createElement('style'); style.textContent="@import '"+trap+"/injected-import';body{background-image:url("+trap+"/injected-css)}"; document.head.append(style);
    const nested=document.createElement('iframe'); nested.src=trap+'/injected-frame'; document.body.append(nested);
    const form=document.createElement('form'); form.action=trap+'/injected-form'; document.body.append(form); form.requestSubmit();
    return true;
  })()`, context, childSession);
  await pause(1000);
  assert.equal(await evaluate("typeof window.previewUnsafe", context, childSession), "undefined", "source script/event execution escaped the policy");
  const stableFrame = (await call("Page.getFrameTree")).frameTree;
  assert.equal(stableFrame.frame.url, pathToFileURL(preview).href, "source changed the shell's navigation");
  assert.equal((await call("Page.getFrameTree", {}, childSession)).frameTree.frame.url, "about:srcdoc", "source navigated before the explicit policy probe");
  // A denied navigation may replace the child with an error document; it
  // must never fetch the URL or navigate the trusted outer shell.
  await evaluate(`(()=>{const refresh=document.createElement('meta');refresh.httpEquiv='refresh';refresh.content='0;url='+${JSON.stringify(trapUrl)}+'/injected-navigation';document.head.append(refresh);return true})()`, context, childSession);
  await pause(700);
  const after = (await call("Page.getFrameTree")).frameTree;
  assert.equal(after.frame.url, pathToFileURL(preview).href, "source navigated the trusted shell");
  assert.deepEqual(requests, [], `source fetched remote resources: ${requests}`);
  const blocked = events.filter((event) => event.method === "Log.entryAdded" && /blocked|refused|violates|sandbox/i.test(event.params.entry.text)).length;
  assert(blocked > 0, "browser did not report enforcing any injected policy boundary");
  const report = { synthetic: true, desktopUsed: false, browser: version.product, opaqueFrame: true,
    sourceStylesVisible: true, sourceTableVisible: true, verifiedImagesVisible: true,
    sourceScriptsBlocked: true, injectedNetworkBlocked: true, formsBlocked: true,
    sourceNavigationBlocked: true, trapRequests: requests.length, blockedPolicyMessages: blocked,
    networkPositiveControl: true, lightAndDarkAppearance: true, privateFileMode: "0600", screenshot: "browser-preview.png" };
  await writeFile(join(work, "browser-acceptance.json"), JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
  console.log(JSON.stringify(report));
} finally {
  socket?.close();
  try { process.kill(-browser.pid, "SIGTERM"); } catch (error) { if (error.code !== "ESRCH") throw error; }
  await Promise.race([new Promise((accept) => browser.once("exit", accept)), pause(3000)]);
  if (browser.exitCode === null && browser.signalCode === null) {
    try { process.kill(-browser.pid, "SIGKILL"); } catch (error) { if (error.code !== "ESRCH") throw error; }
  }
  await new Promise((accept) => trap.close(accept));
}
