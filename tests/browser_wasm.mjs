#!/usr/bin/env node
// Synthetic WASM browser acceptance. Uses an owned headless Chromium profile;
// never maps a desktop window, connects Gmail, or reads credential files.
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
const work = resolve(args.get("--work-dir") || "/tmp/omagma-wasm-browser");
let suppliedOrigin = null;
if (args.has("--origin")) {
  const url = new URL(args.get("--origin"));
  assert(url.protocol === "http:" && ["127.0.0.1", "localhost", "[::1]"].includes(url.hostname) && !url.username && !url.password && url.pathname === "/" && !url.search && !url.hash, "--origin must be an owned loopback HTTP origin");
  suppliedOrigin = url.origin;
}
assert(work !== site && !site.startsWith(work + sep), "browser scratch directory must not contain the site");
await mkdir(work, { recursive: true, mode: 0o700 });
const wasmBytes = suppliedOrigin ? Buffer.from(await (await fetch(suppliedOrigin + "/omagma.wasm")).arrayBuffer()) : await readFile(join(site, "omagma.wasm"));
assert.deepEqual(wasmBytes.subarray(0, 8), Buffer.from([0, 97, 115, 109, 1, 0, 0, 0]), "site does not contain a real WebAssembly module");
const staticRequests = [];
const mime = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".wasm": "application/wasm", ".svg": "image/svg+xml", ".png": "image/png", ".woff2": "font/woff2" };
const server = suppliedOrigin ? null : createServer(async (request, response) => {
  staticRequests.push(request.url);
  try {
    const pathname = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
    const path = resolve(site, "." + (pathname === "/" ? "/index.html" : pathname));
    assert(path.startsWith(site + sep), "request escaped site directory");
    const bytes = await readFile(path);
    response.writeHead(200, { "Content-Type": mime[extname(path)] || "application/octet-stream", "Cache-Control": "no-store" });
    response.end(bytes);
  } catch {
    response.writeHead(404, { "Content-Type": "text/plain" });
    response.end("Not found");
  }
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
  function call(method, params = {}) {
    return new Promise((accept, reject) => {
      const id = ++sequence;
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP deadline: ${method}`)); }, 10000);
      pending.set(id, { accept, reject, timer });
      socket.send(JSON.stringify({ id, method, params }));
    });
  }
  async function evaluate(expression) {
    const response = await call("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
    assert(!response.exceptionDetails, JSON.stringify(response.exceptionDetails));
    return response.result.value;
  }
  const screen = () => evaluate("window.omagmaDemo.screenText()");
  async function frameAfter(action) {
    const before = await evaluate("window.omagmaDemo.frameCount");
    await action();
    await until(async () => (await evaluate("window.omagmaDemo.frameCount")) > before, "input did not produce a parsed terminal frame");
    return screen();
  }
  async function key(key, code, modifiers = 0) {
    const virtual = { Enter: 13, Escape: 27, Backspace: 8, Tab: 9, ArrowDown: 40,
      ArrowUp: 38, ArrowLeft: 37, ArrowRight: 39, Home: 36, End: 35,
      PageDown: 34, PageUp: 33, Delete: 46, F6: 117 }[key] || (key.length === 1 ? key.toUpperCase().charCodeAt(0) : 0);
    const params = { key, code, modifiers, windowsVirtualKeyCode: virtual, nativeVirtualKeyCode: virtual };
    await call("Input.dispatchKeyEvent", { ...params, type: "keyDown", ...(key === "Enter" ? { text: "\r", unmodifiedText: "\r" } : {}) });
    await call("Input.dispatchKeyEvent", { ...params, type: "keyUp" });
  }
  async function text(value) { await call("Input.insertText", { text: value }); }
  async function focus() { await evaluate("document.querySelector('.xterm-helper-textarea').focus();true"); }
  async function click(selector) {
    const rect = await evaluate(`(()=>{const r=document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()`);
    await call("Input.dispatchMouseEvent", { type: "mousePressed", ...rect, button: "left", clickCount: 1 });
    await call("Input.dispatchMouseEvent", { type: "mouseReleased", ...rect, button: "left", clickCount: 1 });
  }
  async function screenshot(name) {
    const capture = await call("Page.captureScreenshot", { format: "png", captureBeyondViewport: false });
    await writeFile(join(work, name), Buffer.from(capture.data, "base64"), { mode: 0o600 });
  }
  async function viewport(width, height, deviceScaleFactor = 1, zoom = 1) {
    await call("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor, mobile: false });
    await evaluate(`document.documentElement.style.zoom=${JSON.stringify(String(zoom))};true`);
    await evaluate("new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))");
    await pause(100);
    assert.equal(await evaluate("window.omagmaDemo.error"), null, "viewport change stopped the WASM terminal");
  }
  async function geometry() {
    // Read DOM directly so an older shell with no new diagnostics can be the
    // negative control. The screen must fit the actual padded content area,
    // rather than merely fit the document or its clipping ancestor.
    return evaluate(`(()=>{
      const element=document.querySelector('#terminal');const css=getComputedStyle(element);
      const rect=value=>{const r=value.getBoundingClientRect();return {left:r.left,right:r.right,top:r.top,bottom:r.bottom,width:r.width,height:r.height}};
      const host=rect(element),screen=rect(element.querySelector('.xterm-screen'));
      const scaleX=host.width/parseFloat(css.width),scaleY=host.height/parseFloat(css.height);
      const content={left:host.left+(parseFloat(css.paddingLeft)+parseFloat(css.borderLeftWidth))*scaleX,
        right:host.right-(parseFloat(css.paddingRight)+parseFloat(css.borderRightWidth))*scaleX,
        top:host.top+(parseFloat(css.paddingTop)+parseFloat(css.borderTopWidth))*scaleY,
        bottom:host.bottom-(parseFloat(css.paddingBottom)+parseFloat(css.borderBottomWidth))*scaleY};
      return {host,content,screen,stage:rect(document.querySelector('.terminal-stage')),
        cols:window.omagmaDemo.cols,rows:window.omagmaDemo.rows,
        documentWidth:document.documentElement.clientWidth,documentScrollWidth:document.documentElement.scrollWidth};
    })()`);
  }
  function assertGeometry(value, label) {
    const tolerance = 0.75;
    assert(value.screen.right <= value.content.right + tolerance, `${label}: rightmost terminal cell is clipped (${value.screen.right} > padded content ${value.content.right})`);
    assert(value.screen.bottom <= value.content.bottom + tolerance, `${label}: bottom terminal row is clipped (${value.screen.bottom} > padded content ${value.content.bottom})`);
    assert(value.screen.left >= value.content.left - tolerance && value.screen.top >= value.content.top - tolerance, `${label}: terminal begins outside its content area`);
    assert(value.documentScrollWidth <= value.documentWidth, `${label}: shell overflows the document horizontally`);
  }
  async function grid() {
    return evaluate(`(()=>{
      const api=window.omagmaDemo;
      const rows=Array.from({length:api.rows},(_,row)=>Array.from({length:api.cols},(_,col)=>api.cell(col,row)));
      const lines=rows.map(row=>row.map(cell=>cell.chars).join(''));
      const top=rows.findIndex(row=>row.some(cell=>cell.chars==='╭'));
      let bottom=-1;for(let row=top+1;row<rows.length;row++)if(rows[row].some(cell=>cell.chars==='╰'))bottom=row;
      const right=top<0?[]:rows[top].flatMap((cell,col)=>cell.chars==='╮'?[col]:[]);
      const left=top<0?[]:rows[top].flatMap((cell,col)=>cell.chars==='╭'?[col]:[]);
      const shifted=[];for(let row=top+1;row<bottom;row++)for(const col of [...left,...right]){
        const chars=rows[row][col].chars;if(chars!=='│')shifted.push({row,col,chars});
      }
      const glyphs=[];for(let row=0;row<rows.length;row++)for(let col=0;col<api.cols;col++){
        if(['⭐','🚀','こ','ん','に','ち','は','日','本','語'].includes(rows[row][col].chars))
          glyphs.push({row,col,...rows[row][col],next:rows[row][col+1],readerStatus:lines[row].includes('Starred')});
      }
      return {top,bottom,left,right,shifted,glyphs,unicodeVersion:api.unicodeVersion};
    })()`);
  }
  function assertGrid(value, label, readerVisible) {
    assert(value.top >= 0 && value.bottom > value.top && value.right.length > 0, `${label}: pane border corners are missing`);
    assert.deepEqual(value.shifted, [], `${label}: pane dividers shifted between native rows`);
    const stars = value.glyphs.filter((glyph) => glyph.chars === "⭐");
    assert(stars.length > 0, `${label}: starred-row width regression has no fixture coverage`);
    assertGlyphWidths(value.glyphs, label);
    if (readerVisible) {
      assert(stars.some((glyph) => glyph.readerStatus), `${label}: reader Starred status has no width coverage`);
    }
  }
  function assertGlyphWidths(glyphs, label) {
    for (const glyph of glyphs) {
      assert.equal(glyph.width, 2, `${label}: ${glyph.chars} occupies the wrong number of terminal columns`);
      assert.equal(glyph.next?.width, 0, `${label}: ${glyph.chars} has no wide-cell continuation`);
      assert.equal(glyph.next?.chars, "", `${label}: ${glyph.chars} overwrote its continuation cell`);
    }
  }
  await call("Page.enable");
  await call("Runtime.enable");
  await call("Network.enable");
  await call("Log.enable");
  await call("Emulation.setDeviceMetricsOverride", { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
  const version = await call("Browser.getVersion");
  await call("Page.navigate", { url: origin + "/" });
  await until(async () => evaluate("window.omagmaDemo?.ready === true || Boolean(window.omagmaDemo?.error)"), "WASM terminal did not finish loading");
  assert.equal(await evaluate("window.omagmaDemo.error"), null, "WASM terminal reported an error");
  assert(events.some((event) => event.method === "Network.requestWillBeSent" && event.params.request.url === origin + "/omagma.wasm"), "browser did not load the site's WebAssembly bytes");
  if (args.get("--geometry-only") === "true") {
    await viewport(1920, 1300);
    const before = await geometry();
    await screenshot("wasm-geometry-1920.png");
    await writeFile(join(work, "geometry-control.json"), JSON.stringify(before, null, 2) + "\n", { mode: 0o600 });
    assertGeometry(before, "1920x1300 baseline control");
    console.log(JSON.stringify({ geometry: before, clipped: false }));
  } else {
  const exports = await evaluate("window.omagmaDemo.exports()");
  assert(exports.includes("memory"), "loaded module did not expose linear memory");
  const abi = await evaluate(`(async()=>{
    const module=await WebAssembly.compile(await (await fetch('./omagma.wasm')).arrayBuffer());
    const imports=WebAssembly.Module.imports(module);
    let hostHttpCalls=0;
    const {exports:e}=await WebAssembly.instantiate(module,{env:{
      http_request(){hostHttpCalls++;return 1},now_ms(){return Date.now()}
    }});
    const init=e.init(100,30);
    const cap=e.input_capacity();
    const before=e.output_len();
    const tooLarge=e.input(cap+1);
    const unchanged=before===e.output_len();
    const outOfRange=e.input(0xffffffff);
    const memory=e.memory.buffer.byteLength;
    return {imports,hostHttpCalls,init,inputCapacity:cap,tooLarge,outOfRange,unchanged,memory,
      outputBytes:e.output_len(),outputPointer:e.output_ptr(),inputPointer:e.input_ptr()};
  })()`);
  assert.deepEqual(abi.imports.map(({module,name,kind})=>({module,name,kind})).sort((a,b)=>a.name.localeCompare(b.name)), [
    {module:"env",name:"http_request",kind:"function"},{module:"env",name:"now_ms",kind:"function"},
  ], "WASM imports services outside its explicit HTTP and clock host adapters");
  assert.equal(abi.hostHttpCalls, 0, "standalone fictional demo called the HTTP adapter");
  assert.equal(abi.init, 0, "standalone browser module did not initialize");
  assert(abi.inputCapacity > 0 && abi.inputCapacity <= 65536, "WASM input buffer is not bounded");
  assert.notEqual(abi.tooLarge, 0, "WASM accepted input exceeding its exported capacity");
  assert.notEqual(abi.outOfRange, 0, "WASM accepted an out-of-range input length");
  assert(abi.unchanged, "rejected input changed the terminal output");
  assert(abi.outputBytes > 0 && abi.outputPointer + abi.outputBytes <= abi.memory, "WASM output points outside linear memory");
  assert(abi.inputPointer + abi.inputCapacity <= abi.memory, "WASM input points outside linear memory");
  const initial = await screen();
  assert(initial.length > 100 && /omagma/i.test(initial), "WASM terminal frame is empty or missing its title");
  const palette = await evaluate(String.raw`(()=>{
    const lines=window.omagmaDemo.screenText().split('\n');
    function at(text){const row=lines.findIndex(line=>line.includes(text));if(row<0)return null;return window.omagmaDemo.cellStyle(lines[row].indexOf(text),row)}
    return {body:at('Hello Alex,'),accent:at('omagma ·')};
  })()`);
  assert(palette.body && palette.accent, "palette reference text is missing from the real terminal buffer");
  assert.equal(palette.body.fg, 0xe8ebf1, "xterm changed the native body's RGB foreground");
  assert.equal(palette.body.bg, 0x111620, "xterm changed the native body's RGB background");
  assert.equal(palette.accent.fg, 0xff9e61, "xterm changed the native orange accent");
  assert(palette.body.fgRGB && palette.body.bgRGB && palette.accent.fgRGB, "native palette no longer uses explicit RGB terminal cells");
  const rendering = [];
  for (const size of [
    { label: "1440", width: 1440, height: 1000, dpr: 1, zoom: 1 },
    { label: "1920", width: 1920, height: 1300, dpr: 1, zoom: 1 },
    { label: "1920-dpr125", width: 1920, height: 1300, dpr: 1.25, zoom: 1 },
    { label: "1536-browser125", width: 1536, height: 1040, dpr: 1.25, zoom: 1 },
    { label: "1920-zoom110", width: 1920, height: 1300, dpr: 1.25, zoom: 1.1 },
    { label: "1920-zoom125", width: 1920, height: 1300, dpr: 1, zoom: 1.25 },
    { label: "600", width: 600, height: 700, dpr: 1, zoom: 1 },
    { label: "600-zoom125", width: 600, height: 700, dpr: 1.25, zoom: 1.25 },
  ]) {
    await viewport(size.width, size.height, size.dpr, size.zoom);
    const bounds = await geometry();
    const cells = await grid();
    const entry = { ...size, bounds, cells };
    rendering.push(entry);
    await screenshot(`wasm-rendering-${size.label}.png`);
    await writeFile(join(work, "rendering-acceptance.json"), JSON.stringify(rendering, null, 2) + "\n", { mode: 0o600 });
    assertGeometry(bounds, size.label);
    assertGrid(cells, size.label, size.width >= 1440);
    // CSS document zoom is a separate layout stress case. Chrome's native
    // page zoom changes the CSS viewport and DPR, represented above by the
    // 1536x1040 / DPR1.25 case for a 1920x1300 physical viewport.
    if (size.zoom !== 1) continue;
    const target = await evaluate(`(()=>{
      const api=window.omagmaDemo;
      for(let row=0;row<api.rows;row++)for(let col=0;col<api.cols;col++){
        if(api.cell(col,row).chars!=='D')continue;
        let rest='';for(let cursor=col;cursor<api.cols;cursor++)rest+=api.cell(cursor,row).chars;
        if(rest.startsWith('Design review'))return {row,col};
      }return null;
    })()`);
    assert(target, `${size.label}: pointer fixture subject is not visible`);
    const pointer = { x: bounds.screen.left + (target.col + 3.5) * bounds.screen.width / bounds.cols,
      y: bounds.screen.top + (target.row + 0.5) * bounds.screen.height / bounds.rows };
    const picked = await frameAfter(async () => {
      await call("Input.dispatchMouseEvent", { type: "mousePressed", ...pointer, button: "left", clickCount: 1 });
      await call("Input.dispatchMouseEvent", { type: "mouseReleased", ...pointer, button: "left", clickCount: 1 });
    });
    entry.pointerHit = { row: target.row, col: target.col, ...pointer,
      selectionLine: picked.split("\n").find((line) => line.includes("Mail")) };
    await writeFile(join(work, "rendering-acceptance.json"), JSON.stringify(rendering, null, 2) + "\n", { mode: 0o600 });
    await screenshot(`wasm-pointer-${size.label}.png`);
    assert(/Mail[^\n]*2\/12/.test(picked), `${size.label}: pointer coordinates did not select the intended native row`);
    if (size.width >= 1440) assert(picked.includes("A warm orange accent"), `${size.label}: pointer selection did not update the reader`);
    entry.pointerHit.selectedMessage = 2;
    await focus();
    await frameAfter(() => text("1"));
    await writeFile(join(work, "rendering-acceptance.json"), JSON.stringify(rendering, null, 2) + "\n", { mode: 0o600 });
  }
  await viewport(1440, 1000);
  await focus();
  assert(initial.includes("Omagma, now in your browser"), "initial fictional message missing");
  assert(initial.includes("actual Zig TUI renderer"), "initial body was not rendered by the terminal");
  const second = await frameAfter(() => key("ArrowDown", "ArrowDown"));
  assert(second.includes("A warm orange accent"), "ArrowDown did not select the next message body");
  const third = await frameAfter(() => key("j", "KeyJ"));
  assert(third.includes("For Friday:"), "j letter navigation did not select the next message body");
  const studio = await frameAfter(() => text("2"));
  assert(/To[^\n]*studio@example\.test/.test(studio), "account switch did not render the second account's recipient");
  const team = await frameAfter(() => text("3"));
  assert(/To[^\n]*team@example\.test/.test(team), "third account did not render its own recipient");
  const alex = await frameAfter(() => text("1"));
  assert(/To[^\n]*alex@example\.test/.test(alex), "first account did not restore its own recipient");

  await frameAfter(() => text("/"));
  const searchInput = await frameAfter(() => text("Final rehearsal"));
  assert(searchInput.includes("Final rehearsal"), "search did not accept actual browser input");
  const filtered = await frameAfter(() => key("Enter", "Enter"));
  assert(filtered.includes("Final rehearsal notes"), "local search did not retain the matching message");
  assert(!filtered.includes("Friday demo checklist"), "local search retained a nonmatching message");
  const restored = await frameAfter(() => text("q"));
  assert(restored.includes("Friday demo checklist") && restored.includes("Omagma, now in your browser"), "q did not clear search and restore the inbox");

  await frameAfter(() => text("/"));
  const unicodeInput = await frameAfter(() => text("こんにちは"));
  assert(unicodeInput.includes("こんにちは"), "browser/WASM input corrupted Japanese text");
  const unicodeMatch = await frameAfter(() => key("Enter", "Enter"));
  assert(unicodeMatch.includes("Unicode postcard") && unicodeMatch.includes("こんにちは"), "Unicode search did not match the fictional postcard");
  assert(!unicodeMatch.includes("Omagma, now in your browser"), "Unicode search did not filter the inbox");
  const unicodeSearchCells = (await grid()).glyphs.filter((glyph) => "こんにちは".includes(glyph.chars));
  assert([..."こんにちは"].every((char) => unicodeSearchCells.some((glyph) => glyph.chars === char)), "explicit Japanese search result has no complete CJK cell coverage");
  assertGlyphWidths(unicodeSearchCells, "explicit Japanese search result");
  await frameAfter(() => text("q"));

  const below = await frameAfter(() => text("v"));
  assert(below.includes("Reader below"), "v did not toggle the native pane layout");
  const right = await frameAfter(() => text("v"));
  assert(right.includes("Reader right"), "v did not restore the native pane layout");
  const expanded = await frameAfter(() => text("z"));
  assert(expanded.includes("Reader expanded"), "z did not expand the reader");
  await frameAfter(() => text("q"));
  const help = await frameAfter(() => text("?"));
  assert(help.includes("Search help"), "native searchable help did not open");
  await frameAfter(() => text("q"));
  const theme = await frameAfter(() => text("T"));
  assert(/theme/i.test(theme) && /Omagma/.test(theme), "native theme picker did not open");
  await frameAfter(() => key("ArrowDown", "ArrowDown"));
  await frameAfter(() => key("Enter", "Enter"));

  // Buttons use real pointer input. Keyboard-only users can leave the xterm
  // input using F6 and activate the reachable host control with Enter.
  await key("F6", "F6");
  assert.equal(await evaluate("document.activeElement.id"), "terminal-focus", "F6 did not leave the terminal for its host focus control");
  await key("Enter", "Enter");
  await until(async () => evaluate("document.activeElement.classList.contains('xterm-helper-textarea')"), "Enter on the host focus control did not focus the terminal", 1500);
  await frameAfter(() => text("j"));
  await frameAfter(() => click("#demo-reset"));
  await until(async () => evaluate("window.omagmaDemo.ready"), "Reset did not restart WASM");
  assert((await screen()).includes("actual Zig TUI renderer"), "Reset did not restore fictional initial state");

  const report = { synthetic: true, desktopUsed: false, browser: version.product,
    wasmBytes: wasmBytes.length, wasmSha256: createHash("sha256").update(wasmBytes).digest("hex"),
    exports, abi, palette, rendering, unicodeSearchCells, staticRequests, origin, realNativeServer: Boolean(suppliedOrigin), initialCols: await evaluate("window.omagmaDemo.cols"),
    initialRows: await evaluate("window.omagmaDemo.rows"), arrowAndLetterNavigation: true,
    accountSeparation: true, localSearchAndReset: true, unicodeInputAndSearch: true,
    nativePaneLayout: true, expandedReader: true, nativeHelp: true, nativeThemePicker: true,
    accessibleHostControls: true, resetButton: true };
  await screenshot("wasm-terminal.png");
  await frameAfter(() => call("Emulation.setDeviceMetricsOverride", { width: 600, height: 700, deviceScaleFactor: 1, mobile: false }));
  const narrow = await evaluate("({cols:window.omagmaDemo.cols,rows:window.omagmaDemo.rows,width:document.documentElement.clientWidth,scrollWidth:document.documentElement.scrollWidth})");
  assert(narrow.cols < report.initialCols && narrow.rows < report.initialRows, "viewport resize did not resize the WASM terminal");
  assert(narrow.scrollWidth <= narrow.width, "narrow shell overflows horizontally");
  await focus();
  const narrowSecond = await frameAfter(() => text("j"));
  assert(narrowSecond.includes("A warm orange") || narrowSecond.includes("Design review"), "narrow terminal lost keyboard message navigation");
  await screenshot("wasm-terminal-narrow.png");
  report.narrowViewport = { width: 600, height: 700, ...narrow, keyboardNavigation: true };
  report.narrowScreenshot = join(work, "wasm-terminal-narrow.png");
  await frameAfter(() => text("j"));
  await frameAfter(() => text("j"));
  await frameAfter(() => key("Enter", "Enter"));
  const narrowReader = await frameAfter(() => text("z"));
  assert(narrowReader.includes("Montréal"), "narrow reader did not open the selected Unicode message");
  const readerGlyphs = (await grid()).glyphs;
  assert(readerGlyphs.some((glyph) => glyph.chars === "🚀"), "reader rocket fixture has no terminal-cell coverage");
  assert(readerGlyphs.some((glyph) => glyph.chars === "日"), "reader Japanese fixture has no terminal-cell coverage");
  assertGlyphWidths(readerGlyphs, "narrow Unicode reader");
  report.readerUnicodeCells = readerGlyphs;
  const scrolled = await frameAfter(() => key("PageDown", "PageDown"));
  assert.notEqual(scrolled, narrowReader, "narrow reader did not scroll with PageDown");
  assert(scrolled.includes("Montréal"), "scrolling changed the selected message");
  await screenshot("wasm-reader-narrow.png");
  report.narrowViewport.readerScroll = true;

  // The bridge rejects an oversized event before copying it into linear
  // memory. Reset must remain available after that controlled refusal.
  await text("x".repeat(65537));
  await until(async () => evaluate("Boolean(window.omagmaDemo.error)"), "oversized browser input was not refused");
  assert.match(await evaluate("window.omagmaDemo.error"), /64 KiB/, "oversized input did not explain its bound");
  await frameAfter(() => click("#demo-reset"));
  await until(async () => evaluate("window.omagmaDemo.ready"), "Reset did not recover after oversized input");
  report.inputEventLimit = 65536;
  report.oversizedInputRefusedAndReset = true;
  const reloadMarker = events.length;
  await call("Page.reload", { ignoreCache: true });
  await until(async () => events.slice(reloadMarker).some((event) => event.method === "Page.loadEventFired"), "reload did not load a new document");
  await until(async () => evaluate("window.omagmaDemo?.ready === true"), "reload did not recreate the WASM terminal");
  assert((await screen()).includes("Omagma"), "reload did not restore the synthetic terminal");
  report.reload = true;
  const externalRequests = events.filter((event) => event.method === "Network.requestWillBeSent")
    .map((event) => event.params.request.url)
    .filter((url) => !url.startsWith(origin + "/") && !url.startsWith("data:") && !url.startsWith("blob:"));
  assert.deepEqual(externalRequests, [], `page attempted external network: ${externalRequests.join(", ")}`);
  const exceptions = events.filter((event) => event.method === "Runtime.exceptionThrown");
  assert.deepEqual(exceptions, [], "page raised uncaught exceptions");
  report.externalRequests = 0;
  report.screenshot = join(work, "wasm-terminal.png");
  await writeFile(join(work, "browser-acceptance.json"), JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
  console.log(JSON.stringify(report));
  }
} finally {
  socket?.close();
  try { process.kill(-browser.pid, "SIGTERM"); } catch (error) { if (error.code !== "ESRCH") throw error; }
  await Promise.race([new Promise((accept) => browser.once("exit", accept)), pause(3000)]);
  if (browser.exitCode === null && browser.signalCode === null) {
    try { process.kill(-browser.pid, "SIGKILL"); } catch (error) { if (error.code !== "ESRCH") throw error; }
  }
  if (server) await new Promise((accept) => server.close(accept));
}
