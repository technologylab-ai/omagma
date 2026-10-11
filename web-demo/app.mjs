import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { Unicode11Addon } from '@xterm/addon-unicode11';
import { boundedSize, BrowserWasmBridge } from './bridge.mjs';
import { importCredentialFiles } from './credentials.mjs';
import { SessionTransport, pendingSend, acknowledgePendingSend } from './transport.mjs';

const select = selector => document.querySelector(selector);
const terminalElement = select('#terminal');
const message = select('#runtime-message');
const messageText = select('#runtime-message-text');
const runtimeStatus = select('#runtime-status');
const modeStatus = select('#session-status');
const sizeLabel = select('#terminal-size');
const resetButton = select('#demo-reset');
const focusButton = select('#terminal-focus');
const connectButton = select('#connect-open');
const disconnectButton = select('#disconnect-session');
const dialog = select('#credential-dialog');
const form = select('#credential-form');
const credentialError = select('#credential-error');
const credentialSubmit = select('#credential-connect');
const encoder = new TextEncoder();
const hasJSPI = typeof WebAssembly.Suspending === 'function' && typeof WebAssembly.promising === 'function';
const terminal = new Terminal({
  cols: 100, rows: 30,
  fontFamily: '"Cascadia Code", "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace',
  fontSize: 13, lineHeight: 1.15, letterSpacing: 0, scrollback: 0,
  cursorBlink: false, cursorStyle: 'block', allowProposedApi: true,
  convertEol: false, overviewRuler: { width: 0 }, logLevel: 'off',
  theme: { background: '#0d1219', foreground: '#d1d9e6', cursor: '#b5cc90', selectionBackground: '#364258' },
});
const fit = new FitAddon();
terminal.loadAddon(fit);
terminal.loadAddon(new Unicode11Addon());
terminal.unicode.activeVersion = '11';
terminal.open(terminalElement);
let bridge = null;
let transport = null;
let module = null;
let ready = false;
let error = null;
let mode = 'demo';
let frameCount = 0;
let generation = 0;
let connectAttempt = 0;
let activeJob = null;
let lifecycleBusy = false;
let credentialBusy = false;
let resizeScheduled = false;
let inputScheduled = false;
let wasmCols = 0;
let wasmRows = 0;
const pendingInput = new Uint8Array(64 * 1024);
let pendingLength = 0;

function screenText() {
  const buffer = terminal.buffer.active;
  return Array.from({ length: terminal.rows }, (_, row) => buffer.getLine(buffer.viewportY + row)?.translateToString(true) ?? '').join('\n');
}
function cellStyle(col, row) {
  const cell = terminal.buffer.active.getLine(terminal.buffer.active.viewportY + row)?.getCell(col);
  return cell ? { fg: cell.getFgColor(), bg: cell.getBgColor(), fgRGB: cell.isFgRGB(), bgRGB: cell.isBgRGB() } : null;
}
function cell(col, row) {
  const cell = terminal.buffer.active.getLine(terminal.buffer.active.viewportY + row)?.getCell(col);
  return cell ? { chars: cell.getChars(), width: cell.getWidth() } : null;
}
function geometry() {
  const rect = element => {
    if (!element) return null;
    const { x, y, top, right, bottom, left, width, height } = element.getBoundingClientRect();
    return { x, y, top, right, bottom, left, width, height };
  };
  return { stage: rect(select('.terminal-stage')), terminal: rect(terminalElement), screen: rect(terminalElement.querySelector('.xterm-screen')) };
}
function sessionInfo() {
  return { mode, generation, jspi: hasJSPI, ...(transport?.info() ?? { accountCount: 0, canSend: [], busy: false, sendPhase: null, sendRemaining: 0 }) };
}

// Diagnostics expose rendered cells and non-sensitive session metadata only.
Object.defineProperty(window, 'omagmaDemo', { value: Object.freeze({
  get ready() { return ready; }, get error() { return error; },
  get cols() { return terminal.cols; }, get rows() { return terminal.rows; },
  get frameCount() { return frameCount; }, get unicodeVersion() { return terminal.unicode.activeVersion; },
  screenText, cellStyle, cell, geometry, sessionInfo,
  exports() { return bridge ? Object.keys(bridge.exports).sort() : []; },
  state() { return mode === 'demo' ? bridge?.state() ?? null : null; },
}), writable: false, configurable: false });

function updateControls() {
  const info = sessionInfo();
  const canConnect = hasJSPI && typeof bridge?.exports.connect === 'function';
  terminal.options.disableStdin = !ready || lifecycleBusy || info.busy;
  focusButton.disabled = !ready;
  resetButton.disabled = !ready || lifecycleBusy || mode !== 'demo';
  connectButton.hidden = mode !== 'demo';
  connectButton.disabled = !ready || lifecycleBusy || credentialBusy || !canConnect;
  connectButton.title = canConnect ? 'Select existing Omagma file credentials' : 'Live mail requires a JSPI-capable browser and the live browser build';
  disconnectButton.hidden = mode === 'demo';
  disconnectButton.disabled = mode === 'demo';
  credentialSubmit.disabled = credentialBusy || lifecycleBusy;
  select('#send-grace').hidden = !info.sendPhase;
  select('#send-grace-text').textContent = info.sendPhase === 'grace' ? `Sending in ${info.sendRemaining}s · Esc / Ctrl+C cancels` : 'Submitting to Google…';
  select('#send-grace-cancel').disabled = info.sendPhase !== 'grace';
  select('#send-uncertainty').hidden = !pendingSend() || info.sendPhase === 'sending';
  select('#send-acknowledge').disabled = info.busy;
  if (ready && !error) runtimeStatus.textContent = mode === 'connecting' ? 'Verifying accounts with Google…' : (info.busy ? 'Google request in progress…' : 'Running locally in WebAssembly');
  modeStatus.textContent = mode === 'demo' ? 'Fictional mail · in memory only' : (mode === 'connecting' ? 'Connecting · session memory only' : 'Live Gmail · session memory only');
  select('.window-subtitle').textContent = mode === 'demo' ? '/ fictional inboxes' : '/ live Gmail';
}

function fail(reason) {
  ready = false;
  error = reason instanceof Error ? reason.message : 'The browser experiment stopped.';
  transport?.cancelSend();
  transport?.abort();
  message.hidden = false;
  message.classList.add('failed');
  messageText.textContent = error;
  runtimeStatus.textContent = 'The experiment stopped';
  updateControls();
  resetButton.disabled = !module || mode !== 'demo';
}

function fitTerminal() {
  const proposed = fit.proposeDimensions();
  if (!proposed) return;
  const { cols, rows } = boundedSize(proposed.cols, proposed.rows);
  if (cols !== terminal.cols || rows !== terminal.rows) terminal.resize(cols, rows);
  sizeLabel.textContent = `${cols} × ${rows}`;
}

function runJob(action) {
  if (activeJob) return Promise.reject(new Error('Another terminal operation is running.'));
  const currentBridge = bridge;
  const currentTransport = transport;
  currentTransport?.beginJob();
  const job = (async () => {
    try { return await action(currentBridge, currentTransport); }
    finally { currentTransport?.finishSend(currentBridge?.exports.send_status?.() ?? 0); }
  })();
  activeJob = job;
  void job.finally(() => {
    if (activeJob === job) activeJob = null;
    updateControls();
    drain();
  }).catch(() => {});
  return job;
}

function drain() {
  if (!ready || activeJob || lifecycleBusy || credentialBusy) return;
  const thisGeneration = generation;
  if (wasmCols !== terminal.cols || wasmRows !== terminal.rows) {
    const cols = terminal.cols, rows = terminal.rows;
    void runJob(async current => { await current.resize(cols, rows); wasmCols = cols; wasmRows = rows; }).catch(reason => { if (generation === thisGeneration) fail(reason); });
    return;
  }
  if (pendingLength === 0) return;
  const bytes = pendingInput.slice(0, pendingLength);
  pendingInput.fill(0, 0, pendingLength);
  pendingLength = 0;
  void runJob(async current => { try { await current.input(bytes); } finally { bytes.fill(0); } }).catch(reason => { if (generation === thisGeneration) fail(reason); });
}

function resize() {
  if (resizeScheduled) return;
  resizeScheduled = true;
  requestAnimationFrame(() => {
    resizeScheduled = false;
    try { fitTerminal(); drain(); } catch (reason) { fail(reason); }
  });
}
new ResizeObserver(resize).observe(terminalElement);

function queueInput(bytes) {
  if (!ready) return;
  if (bytes.length > pendingInput.length - pendingLength) { fail(new Error('This experiment accepts up to 64 KiB of input at a time.')); return; }
  pendingInput.set(bytes, pendingLength);
  pendingLength += bytes.length;
  if (!inputScheduled) {
    inputScheduled = true;
    queueMicrotask(() => { inputScheduled = false; drain(); });
  }
}
function queueText(data, binary = false) {
  if (data.length > pendingInput.length) { fail(new Error('This experiment accepts up to 64 KiB of input at a time.')); return; }
  queueInput(binary ? Uint8Array.from(data, character => character.charCodeAt(0)) : encoder.encode(data));
}
terminal.onData(data => queueText(data));
terminal.onBinary(data => queueText(data, true));
terminal.attachCustomKeyEventHandler(event => {
  if (event.key === 'F6') {
    event.preventDefault(); event.stopPropagation();
    if (event.type === 'keydown') focusButton.focus();
    return false;
  }
  if (transport?.info().sendPhase === 'grace' && (event.key === 'Escape' || (event.ctrlKey && event.key.toLowerCase() === 'c'))) {
    event.preventDefault(); event.stopPropagation();
    if (event.type === 'keydown') transport.cancelSend();
    return false;
  }
  if (transport?.info().busy && event.ctrlKey && event.key.toLowerCase() === 'c') {
    event.preventDefault();
    if (event.type === 'keydown') transport.abort();
    return false;
  }
  return true;
});

async function start(nextMode = 'demo') {
  const thisGeneration = ++generation;
  const oldBridge = bridge;
  const oldTransport = transport;
  const oldJob = activeJob;
  oldTransport?.close();
  bridge = null; transport = null; ready = false; error = null;
  mode = nextMode; lifecycleBusy = true;
  pendingInput.fill(0); pendingLength = 0;
  message.hidden = false; message.classList.remove('failed');
  messageText.textContent = 'Loading WebAssembly…';
  runtimeStatus.textContent = 'Starting the TUI';
  updateControls();
  try {
    if (oldJob) { try { await oldJob; } catch {} }
    oldBridge?.wipe();
    if (thisGeneration !== generation) return;
    terminal.reset();
    fitTerminal();
    if (!module) {
      if (location.protocol === 'file:') throw new Error('Serve this folder over HTTP to load WebAssembly. See the browser experiment README.');
      const response = await fetch(new URL('./omagma.wasm', import.meta.url));
      if (!response.ok) throw new Error(`Could not load omagma.wasm (HTTP ${response.status}). Build and package the browser experiment first.`);
      module = await WebAssembly.compile(await response.arrayBuffer());
      for (const entry of WebAssembly.Module.imports(module)) if (entry.module !== 'env' || !['http_request', 'now_ms'].includes(entry.name) || entry.kind !== 'function') throw new Error('This browser module requests an unsupported host capability.');
    }
    let instance;
    const currentTransport = new SessionTransport(() => instance?.exports.memory, () => { if (thisGeneration === generation) updateControls(); }, () => { if (thisGeneration === generation) updateControls(); });
    const http = (...args) => currentTransport.wasmRequest(...args);
    instance = await WebAssembly.instantiate(module, { env: { http_request: hasJSPI ? new WebAssembly.Suspending(http) : () => 3, now_ms: () => Date.now() } });
    if (thisGeneration !== generation) { currentTransport.close(); new Uint8Array(instance.exports.memory.buffer).fill(0); return; }
    transport = currentTransport;
    let firstFrame;
    const displayed = new Promise(resolve => { firstFrame = resolve; });
    bridge = new BrowserWasmBridge(instance, bytes => {
      terminal.write(bytes, () => {
        firstFrame();
        if (thisGeneration !== generation) return;
        frameCount++;
      });
    }, hasJSPI ? fn => WebAssembly.promising(fn) : null);
    wasmCols = terminal.cols; wasmRows = terminal.rows;
    await runJob(current => current.init(wasmCols, wasmRows));
    await displayed;
    if (thisGeneration !== generation) return;
    ready = true; lifecycleBusy = false;
    message.hidden = true;
    updateControls();
    terminal.focus();
    drain();
  } catch (reason) {
    if (thisGeneration === generation) { lifecycleBusy = false; fail(reason); }
    throw reason;
  }
}

function selectedFiles(selector, limit) {
  const files = select(selector).files;
  if (files.length > limit) throw new Error('Too many credential files were selected.');
  return Array.from(files);
}
function clearSelectedFiles() { form.reset(); }
function stopConnection() {
  connectAttempt++;
  credentialBusy = false;
  clearSelectedFiles();
  if (dialog.open) dialog.close();
  void start().catch(() => {});
}

form.addEventListener('submit', event => {
  event.preventDefault();
  if (credentialBusy) return;
  const attempt = ++connectAttempt;
  credentialBusy = true;
  credentialError.textContent = '';
  updateControls();
  void (async () => {
    let records = [];
    let connectingGeneration = null;
    try {
      const clients = selectedFiles('#credential-clients', 3);
      const grants = selectedFiles('#credential-grants', 1)[0];
      const tokens = [...selectedFiles('#credential-tokens', 128), ...selectedFiles('#credential-folder', 128)];
      records = await importCredentialFiles(clients, grants, tokens);
      if (attempt !== connectAttempt) return;
      await start('connecting');
      connectingGeneration = generation;
      if (attempt !== connectAttempt) return;
      await runJob(async (current, currentTransport) => {
        for (const record of records) {
          const [metadata] = await currentTransport.prepare([record]);
          await current.connect(metadata);
        }
      });
      if (attempt !== connectAttempt || generation !== connectingGeneration) return;
      mode = 'live'; credentialBusy = false;
      clearSelectedFiles(); dialog.close(); updateControls(); terminal.focus();
    } catch (reason) {
      if (attempt !== connectAttempt) return;
      const detail = reason instanceof Error ? reason.message : 'The selected credentials could not connect.';
      if (connectingGeneration !== null) { try { await start(); } catch {} }
      credentialError.textContent = detail;
      credentialBusy = false;
      updateControls();
    } finally {
      for (const record of records) { record.refreshToken = ''; record.clientSecret = ''; }
      records = [];
    }
  })();
});

connectButton.addEventListener('click', () => { credentialError.textContent = ''; dialog.showModal(); });
select('#credential-cancel').addEventListener('click', stopConnection);
dialog.addEventListener('cancel', event => { event.preventDefault(); stopConnection(); });
disconnectButton.addEventListener('click', stopConnection);
focusButton.addEventListener('click', () => terminal.focus());
resetButton.addEventListener('click', () => { void start().catch(() => {}); });
select('#send-grace-cancel').addEventListener('click', () => transport?.cancelSend());
select('#send-acknowledge').addEventListener('click', () => { acknowledgePendingSend(); updateControls(); });
window.addEventListener('pagehide', () => { transport?.close(); pendingInput.fill(0); });
void start().catch(() => {});
