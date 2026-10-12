import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { boundedSize, BrowserWasmBridge, terminalUnicode, alignTerminalRows } from './bridge.mjs';
import { importCredentialFiles, importConnectionFile } from './credentials.mjs';
import { SessionTransport, pendingSend, acknowledgePendingSend, capturePendingSendAcknowledgement } from './transport.mjs';
import { createBrowserCache } from './cache.mjs';
import { createBrowserDrafts, DRAFT_LIMITS } from './drafts.mjs';

const select = selector => document.querySelector(selector);
const terminalElement = select('#terminal');
const message = select('#runtime-message');
const messageText = select('#runtime-message-text');
const runtimeStatus = select('#runtime-status');
const requestStatus = select('#request-status');
const requestHint = select('#request-status-hint');
const requestSpinner = select('#request-status-spinner');
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
const fileConnectButton = select('#connect-file-open');
const cacheClearButton = select('#cache-clear');
const draftStorageButton = select('#draft-storage-open');
const draftStorageDialog = select('#draft-storage-dialog');
const browserCache = createBrowserCache();
const browserDrafts = createBrowserDrafts();
const sessionParameter = new URLSearchParams(location.hash.slice(1)).get('omagma-session');
const serverSession = location.protocol === 'http:' && location.hostname === '127.0.0.1' && /^[a-f0-9]{64}$/.test(sessionParameter ?? '') ? sessionParameter : null;
const encoder = new TextEncoder();
const hasJSPI = typeof WebAssembly.Suspending === 'function' && typeof WebAssembly.promising === 'function';
const terminal = new Terminal({
  cols: 100, rows: 30,
  fontFamily: '"Cascadia Code", "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace',
  fontSize: 13, lineHeight: 1.15, letterSpacing: 0, scrollback: 0,
  cursorBlink: false, cursorStyle: 'block', allowProposedApi: true, screenReaderMode: true,
  convertEol: false, overviewRuler: { width: 0 }, logLevel: 'off',
  theme: { background: '#0d1219', foreground: '#d1d9e6', cursor: '#b5cc90', selectionBackground: '#364258' },
});
const fit = new FitAddon();
terminal.loadAddon(fit);
terminal.open(terminalElement);
let bridge = null;
let terminalWidths = null;
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
let credentialRequest = null;
let cacheBusy = false;
let cacheError = '';
let draftError = '';
let draftRestoreWarning = '';
let draftBusy = false;
let draftInputQueued = false;
let draftCleanupBusy = false;
let storageNotice = '';
let autosaveTimer = null;
let cacheRevisions = [];
let deferredFit = false;
let resizeCover = false;
let resizeScheduled = false;
let inputScheduled = false;
let wasmCols = 0;
let wasmRows = 0;
const pendingInput = new Uint8Array(64 * 1024);
let pendingLength = 0;
let inputNotice = '';
const draftDirty = () => Boolean(bridge?.exports.draft_dirty?.());
const unsavedDraftRisk = () => draftDirty() || (Boolean(draftError) && (bridge?.exports.draft_count?.() ?? 0) > 0);
const terminalRows = terminalElement.querySelector('.xterm-rows');
terminal.onRender(({ start, end }) => alignTerminalRows(terminalRows, terminal.cols, terminalWidths, start, end));
// Selection, focus and link hover can replace DOM rows outside onRender.
// Observe only child lists, so our own geometry attributes cannot feed back.
new MutationObserver(() => alignTerminalRows(terminalRows, terminal.cols, terminalWidths))
  .observe(terminalRows, { childList: true, subtree: true });

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
  get inputNotice() { return inputNotice; },
  screenText, cellStyle, cell, geometry, sessionInfo,
  exports() { return bridge ? Object.keys(bridge.exports).sort() : []; },
  state() { return mode === 'demo' ? bridge?.state() ?? null : null; },
}), writable: false, configurable: false });

function updateControls() {
  const info = sessionInfo();
  const canConnect = hasJSPI && typeof bridge?.exports.connect === 'function';
  terminal.options.disableStdin = !ready || lifecycleBusy || info.busy || draftCleanupBusy || (draftBusy && !draftInputQueued);
  focusButton.disabled = !ready;
  resetButton.disabled = !ready || lifecycleBusy || mode !== 'demo';
  connectButton.hidden = mode !== 'demo';
  connectButton.disabled = !ready || lifecycleBusy || credentialBusy || !canConnect;
  connectButton.title = canConnect ? 'Load your existing Omagma accounts' : 'Live mail requires a JSPI-capable browser and the live browser build';
  fileConnectButton.hidden = !serverSession || mode !== 'demo';
  fileConnectButton.disabled = connectButton.disabled;
  disconnectButton.hidden = mode === 'demo';
  disconnectButton.disabled = mode === 'demo' || draftCleanupBusy;
  credentialSubmit.disabled = credentialBusy || lifecycleBusy;
  cacheClearButton.hidden = mode !== 'live';
  cacheClearButton.disabled = !ready || Boolean(activeJob) || info.busy || cacheBusy || lifecycleBusy || credentialBusy;
  draftStorageButton.hidden = mode !== 'live';
  draftStorageButton.disabled = !ready || Boolean(activeJob) || info.busy || cacheBusy || lifecycleBusy || credentialBusy || draftCleanupBusy;
  select('#send-grace').hidden = !info.sendPhase;
  select('#send-grace-text').textContent = info.sendPhase === 'grace' ? `Sending in ${info.sendRemaining}s · Esc / Ctrl+C cancels` : 'Submitting to Google…';
  select('#send-grace-cancel').disabled = info.sendPhase !== 'grace';
  const unknownAccount = mode === 'live' ? bridge?.unknownAccount?.() || '' : '';
  select('#send-uncertainty-text').textContent = unknownAccount ? `An unconfirmed send for ${unknownAccount} is protected. Check this account's Sent before acknowledging.` : 'A previous send has no confirmation. Check Sent in every account used here before clearing this notice.';
  select('#send-acknowledge').textContent = unknownAccount ? `I checked ${unknownAccount}'s Sent` : 'I checked Sent for all accounts used here';
  select('#send-uncertainty').hidden = !(pendingSend() || unknownAccount || (mode === 'live' && bridge?.exports.send_status?.() === 2)) || Boolean(info.sendPhase);
  select('#send-acknowledge').disabled = info.busy || Boolean(activeJob) || cacheBusy || !(unknownAccount ? bridge?.draftActorReady?.(bridge.exports.unknown_target_index()) : mode === 'live' && bridge?.exports.live_accounts?.() > 0);
  const active = !error && (info.busy || mode === 'connecting' || credentialBusy || cacheBusy || draftBusy || lifecycleBusy || !ready);
  requestStatus.classList.toggle('is-busy', active);
  requestStatus.classList.toggle('is-error', Boolean(error));
  requestSpinner.hidden = !active;
  terminalElement.setAttribute('aria-busy', String(!error && (Boolean(activeJob) || info.busy || draftBusy || draftCleanupBusy || lifecycleBusy || !ready)));
  requestHint.textContent = '';
  if (!error) {
    if (info.sendPhase === 'grace') {
      runtimeStatus.textContent = `Sending in ${info.sendRemaining}s…`;
      requestHint.textContent = 'Esc / Ctrl+C cancels before submission.';
    } else if (info.sendPhase === 'sending') {
      runtimeStatus.textContent = 'Sending mail to Google…';
      requestHint.textContent = 'Waiting for Google to confirm the send.';
    } else if (info.mailboxWriting) {
      runtimeStatus.textContent = 'Waiting for Google to confirm mailbox change…';
      requestHint.textContent = 'Keyboard input is paused. The change has been submitted; waiting for confirmation.';
    } else if (info.busy) {
      runtimeStatus.textContent = mode === 'connecting' ? 'Connecting to Gmail…' : 'Google request in progress…';
      requestHint.textContent = 'Keyboard input is paused. Ctrl+C cancels the request.';
    } else if (draftBusy) {
      runtimeStatus.textContent = 'Saving browser drafts…';
      requestHint.textContent = draftInputQueued ? 'Typing is queued while your draft saves.' : 'Keyboard input is paused until this change is saved.';
    }
    else if (cacheBusy) runtimeStatus.textContent = 'Updating browser cache…';
    else if (credentialBusy) runtimeStatus.textContent = 'Loading your Omagma connection…';
    else if (mode === 'connecting') runtimeStatus.textContent = 'Connecting to Gmail…';
    else if (!ready || lifecycleBusy) runtimeStatus.textContent = 'Loading WebAssembly…';
    else if (draftError) { runtimeStatus.textContent = 'Browser drafts could not be saved'; requestHint.textContent = draftError; }
    else if (draftRestoreWarning) { runtimeStatus.textContent = 'Some browser drafts could not be loaded'; requestHint.textContent = draftRestoreWarning; }
    else if (cacheError) { runtimeStatus.textContent = 'Browser cache could not be saved'; requestHint.textContent = cacheError; }
    else if (storageNotice) { runtimeStatus.textContent = 'Saved browser drafts cleared'; requestHint.textContent = storageNotice; }
    else runtimeStatus.textContent = 'Running locally in WebAssembly';
  }
  if (!error && inputNotice && !active) {
    runtimeStatus.textContent = inputNotice;
    requestHint.textContent = 'Your session is kept. Paste smaller chunks, up to 64 KiB.';
  }
  modeStatus.textContent = mode === 'demo' ? 'Sample mode · no Gmail connection' : (mode === 'connecting' ? 'Connecting · credentials in session memory' : 'Live Gmail · bounded cache · live queries show up to 30 messages');
  select('.window-subtitle').textContent = mode === 'demo' ? '/ sample inbox' : '/ live Gmail';
  select('#sample-notice').hidden = mode !== 'demo';
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
  if (activeJob && (cols !== terminal.cols || rows !== terminal.rows)) {
    deferredFit = true;
    if (!error && ready) { resizeCover = true; message.hidden = false; messageText.textContent = 'Resizing terminal… waiting for the current request. Ctrl+C cancels a read.'; }
    return;
  }
  deferredFit = false;
  if (cols !== terminal.cols || rows !== terminal.rows) terminal.resize(cols, rows);
  if (resizeCover && !error && ready) { resizeCover = false; message.hidden = true; }
  sizeLabel.textContent = `${cols} × ${rows}`;
}

const bindingOf = record => ({ account: record.account, clientId: record.clientId, grantId: record.grantId });
async function persistCaches(current, currentTransport, epoch) {
  if (epoch !== generation || !current || !currentTransport || typeof current.exports.cache_revision !== 'function') return;
  const records = currentTransport.cacheBindings();
  let failed = '';
  let attempted = false;
  for (let index = 0; index < Math.min(records.length, current.exports.live_accounts?.() ?? 0); index++) {
    if (epoch !== generation) return;
    if (!records[index].canContacts && typeof current.exports.contacts_permission === 'function' && (!current.exports.can_contacts || current.exports.can_contacts(index))) await current.restrictContacts(index, false);
    const revision = current.exports.cache_revision(index);
    if (cacheRevisions[index] === revision) continue;
    attempted = true;
    cacheBusy = true; updateControls();
    try {
      const snapshot = current.cacheSnapshot(index);
      if (snapshot) await browserCache.save(bindingOf(records[index]), snapshot, { verified: true });
      else await browserCache.clear(bindingOf(records[index]));
    } catch { failed = 'The current tab keeps its mail. Local cache storage is unavailable or this snapshot exceeds its limits.'; }
    finally { if (epoch === generation) cacheRevisions[index] = revision; }
  }
  if (epoch === generation) { cacheBusy = false; if (attempted) cacheError = failed; updateControls(); }
}

function scheduleAutosave() {
  clearTimeout(autosaveTimer); autosaveTimer = null;
  if (!ready || activeJob || lifecycleBusy || credentialBusy || !bridge?.exports.autosave_pending?.()) return;
  const epoch = generation;
  autosaveTimer = setTimeout(() => {
    autosaveTimer = null;
    if (epoch !== generation || !ready || activeJob || lifecycleBusy || credentialBusy) return;
    void runJob(current => current.idle()).catch(reason => { if (epoch === generation) fail(reason); });
  }, Math.max(25, Math.min(1500, bridge.exports.autosave_delay?.() ?? 1500)));
}

function runJob(action) {
  if (activeJob) return Promise.reject(new Error('Another terminal operation is running.'));
  const currentBridge = bridge;
  const currentTransport = transport;
  const epoch = generation;
  currentTransport?.beginJob();
  const job = (async () => {
    try { const result = await action(currentBridge, currentTransport); await persistCaches(currentBridge, currentTransport, epoch); return result; }
    finally { currentTransport?.finishSend(currentBridge?.exports.send_status?.() ?? 0); }
  })();
  activeJob = job;
  updateControls();
  void job.finally(() => {
    if (activeJob === job) activeJob = null;
    if (deferredFit && epoch === generation) fitTerminal();
    updateControls();
    drain();
    scheduleAutosave();
  }).catch(() => {});
  return job;
}

function drain() {
  if (!ready || activeJob || lifecycleBusy || credentialBusy) return;
  const thisGeneration = generation;
  if (wasmCols !== terminal.cols || wasmRows !== terminal.rows) {
    const cols = terminal.cols, rows = terminal.rows;
    void runJob(async current => { await current.resize(cols, rows); wasmCols = cols; wasmRows = rows; if (generation === thisGeneration && ready && !error) message.hidden = true; }).catch(reason => { if (generation === thisGeneration) fail(reason); });
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
  if (bytes.length > pendingInput.length - pendingLength) { inputNotice = 'Input too large · paste was skipped'; updateControls(); return; }
  inputNotice = '';
  pendingInput.set(bytes, pendingLength);
  pendingLength += bytes.length;
  if (!inputScheduled) {
    inputScheduled = true;
    queueMicrotask(() => { inputScheduled = false; drain(); });
  }
}
function queueText(data, binary = false) {
  if (data.length > pendingInput.length) { inputNotice = 'Input too large · paste was skipped'; updateControls(); return; }
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
    if (event.type === 'keydown' && transport.info().sendPhase !== 'sending' && !transport.info().mailboxWriting) transport.abort();
    return false;
  }
  return true;
});

async function start(nextMode = 'demo') {
  const thisGeneration = ++generation;
  clearTimeout(autosaveTimer); autosaveTimer = null;
  const oldBridge = bridge;
  const oldTransport = transport;
  const oldJob = activeJob;
  oldTransport?.close();
  bridge = null; transport = null; ready = false; error = null;
  mode = nextMode; lifecycleBusy = true;
  cacheRevisions = []; cacheBusy = false; cacheError = ''; draftBusy = false; draftInputQueued = false; draftError = ''; draftRestoreWarning = ''; storageNotice = ''; deferredFit = false;
  pendingInput.fill(0); pendingLength = 0;
  message.hidden = false; message.classList.remove('failed');
  messageText.textContent = 'Loading WebAssembly…';
  runtimeStatus.textContent = 'Starting the TUI';
  updateControls();
  try {
    if (oldJob) { try { await oldJob; } catch {} }
    // Pending old output must never query a width export after its memory wipe.
    // The next instance installs its own provider before emitting any frame.
    terminal.unicode.activeVersion = '6';
    terminalWidths = null;
    oldBridge?.wipe();
    if (thisGeneration !== generation) return;
    terminal.reset();
    fitTerminal();
    if (!module) {
      if (location.protocol === 'file:') throw new Error('Serve this folder over HTTP to load WebAssembly. See the browser experiment README.');
      const response = await fetch(new URL('./omagma.wasm', import.meta.url));
      if (!response.ok) throw new Error(`Could not load omagma.wasm (HTTP ${response.status}). Build and package the browser experiment first.`);
      module = await WebAssembly.compile(await response.arrayBuffer());
      for (const entry of WebAssembly.Module.imports(module)) if (entry.module !== 'env' || !['http_request', 'now_ms', 'drafts_store'].includes(entry.name) || entry.kind !== 'function') throw new Error('This browser module requests an unsupported host capability.');
    }
    let instance;
    const verifiedActors = new Map();
    const pendingDraftSends = new Map();
    const restoreProblems = new Map();
    const currentTransport = new SessionTransport(() => instance?.exports.memory, () => { if (thisGeneration === generation) updateControls(); }, () => { if (thisGeneration === generation) updateControls(); }, async session => {
      const actor = verifiedActors.get(session);
      if (thisGeneration !== generation || !actor) throw new Error('Draft account verification expired.');
      const expected = pendingDraftSends.get(session);
      await browserDrafts.markSubmitting(actor, { verified: true, expected });
      pendingDraftSends.delete(session);
      return expected.id;
    });
    const http = (...args) => currentTransport.wasmRequest(...args);
    const saveDrafts = async (session, pointer, length) => {
      const actor = verifiedActors.get(session >>> 0);
      if (thisGeneration !== generation || !actor) return 1;
      let bytes;
      draftBusy = true;
      draftInputQueued = Boolean(instance.exports.autosave_accepts_input?.());
      updateControls();
      try {
        const memory = instance.exports.memory.buffer;
        if (!Number.isInteger(pointer) || !Number.isInteger(length) || pointer < 0 || length < 0 || length > DRAFT_LIMITS.snapshotBytes || pointer > memory.byteLength - length) throw new Error();
        bytes = new Uint8Array(memory, pointer, length).slice();
        const expected = await browserDrafts.saveChanges(actor, bytes, { verified: true, bindings: Array.from(verifiedActors.values()) });
        if (expected) pendingDraftSends.set(session >>> 0, expected); else pendingDraftSends.delete(session >>> 0);
        if (thisGeneration === generation) draftError = '';
        return 0;
      } catch (reason) {
        if (thisGeneration === generation) draftError = reason?.code === 'operations' ? 'Browser send history is full. Reconnect its accounts or review saved-draft cleanup before retrying.' : reason?.code === 'limit' ? 'Draft storage is full. Your current edits and the previous saved copy are kept.' : reason?.code === 'conflict' ? 'Another tab changed these drafts. Your current edits are kept; reconnect before saving.' : 'Local draft storage is unavailable. Your current edits and the previous saved copy are kept.';
        return reason?.code === 'operations' ? 4 : reason?.code === 'limit' ? 2 : reason?.code === 'conflict' ? 3 : 1;
      } finally { bytes?.fill(0); if (thisGeneration === generation) { draftBusy = false; draftInputQueued = false; updateControls(); } }
    };
    instance = await WebAssembly.instantiate(module, { env: { http_request: hasJSPI ? new WebAssembly.Suspending(http) : () => 3, drafts_store: hasJSPI ? new WebAssembly.Suspending(saveDrafts) : () => 1, now_ms: () => Date.now() } });
    if (thisGeneration !== generation) { currentTransport.close(); new Uint8Array(instance.exports.memory.buffer).fill(0); return; }
    transport = currentTransport;
    const unicode = terminalUnicode(instance.exports);
    terminal.unicode.register(unicode);
    terminal.unicode.activeVersion = unicode.version;
    terminalWidths = unicode;
    let firstFrame;
    const displayed = new Promise(resolve => { firstFrame = resolve; });
    bridge = new BrowserWasmBridge(instance, bytes => {
      terminal.write(bytes, () => {
        firstFrame();
        if (thisGeneration !== generation) return;
        frameCount++;
      });
    }, hasJSPI ? fn => WebAssembly.promising(fn) : null);
    bridge.verifyDraftActor = (session, actor) => {
      restoreProblems.delete(session >>> 0); draftRestoreWarning = Array.from(restoreProblems.values()).join(' · ');
      return verifiedActors.set(session >>> 0, Object.freeze(bindingOf(actor)));
    };
    bridge.blockDraftActor = (session, actor) => {
      restoreProblems.set(session >>> 0, `Saved drafts for ${actor.account} could not be loaded. Reading works; drafting and sending need a successful reconnect.`);
      draftRestoreWarning = Array.from(restoreProblems.values()).join(' · ');
    };
    bridge.draftActorReady = index => {
      const actor = currentTransport.cacheBindings()[index];
      return Boolean(actor && Array.from(verifiedActors.values()).some(value => value.account === actor.account && value.clientId === actor.clientId && value.grantId === actor.grantId));
    };
    bridge.draftStorageReady = () => verifiedActors.size > 0 && verifiedActors.size === instance.exports.live_accounts();
    browserCache.configure(bridge.readMailPolicy());
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
function updateConnectionSelection() { select('#credential-selection').textContent = select('#credential-bundle').files.length ? 'Connection file selected' : 'No connection file selected'; }
function clearSelectedFiles() { form.reset(); select('#credential-separate').open = false; updateConnectionSelection(); }
function stopConnection() {
  connectAttempt++;
  credentialRequest?.abort(); credentialRequest = null;
  credentialBusy = false;
  clearSelectedFiles();
  if (dialog.open) dialog.close();
  void start().catch(() => {});
}

async function localConnection() {
  const controller = new AbortController();
  credentialRequest = controller;
  const timer = setTimeout(() => controller.abort(), 30000);
  const bytes = new Uint8Array(64 * 1024);
  let length = 0;
  let reader;
  try {
    const response = await fetch(new URL('./connection.json', import.meta.url), {
      headers: { Authorization: `Omagma-Session ${serverSession}` },
      credentials: 'omit', cache: 'no-store', redirect: 'error', mode: 'same-origin',
      referrerPolicy: 'no-referrer', signal: controller.signal,
    });
    if (!response.ok || response.headers.get('content-type')?.split(';')[0] !== 'application/json') throw new Error('Could not load local Omagma accounts. You can select an exported connection file instead.');
    reader = response.body.getReader();
    for (;;) {
      const chunk = await reader.read();
      if (chunk.done) break;
      if (length + chunk.value.length > bytes.length) throw new Error('The local connection exceeds its supported size.');
      bytes.set(chunk.value, length); length += chunk.value.length;
    }
    return await importConnectionFile({ size: length, text: async () => new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, length)) });
  } finally {
    clearTimeout(timer);
    try { await reader?.cancel(); } catch {}
    bytes.fill(0);
    if (credentialRequest === controller) credentialRequest = null;
  }
}

function beginConnection(local = false) {
  if (credentialBusy) return;
  const attempt = ++connectAttempt;
  credentialBusy = true;
  credentialError.textContent = '';
  updateControls();
  void (async () => {
    let records = [];
    let connectingGeneration = null;
    try {
      const bundle = selectedFiles('#credential-bundle', 1)[0];
      if (local) records = await localConnection();
      else if (bundle) records = await importConnectionFile(bundle);
      else if (select('#credential-separate').open) {
        const clients = selectedFiles('#credential-clients', 3);
        const grants = selectedFiles('#credential-grants', 1)[0];
        const tokens = [...selectedFiles('#credential-tokens', 128), ...selectedFiles('#credential-folder', 128)];
        records = await importCredentialFiles(clients, grants, tokens);
      } else throw new Error('Select an Omagma connection file first.');
      if (attempt !== connectAttempt) return;
      await start('connecting');
      connectingGeneration = generation;
      if (attempt !== connectAttempt) return;
      await runJob(async (current, currentTransport) => {
        for (const record of records) {
          const [metadata] = await currentTransport.prepare([record]);
          const index = currentTransport.cacheBindings().length - 1;
          const actor = currentTransport.cacheBindings()[index];
          let cached = null;
          try { cached = await browserCache.stage(bindingOf(actor), { contactsGranted: actor.canContacts }); }
          catch { cacheError = 'A saved snapshot was refused. Gmail will load a fresh view.'; }
          // Staging is private until connect's fresh PROFILE and exact native
          // binding succeed. Refusal keeps disk records and stops restoration.
          let drafts = null, draftStorageReady = false;
          try { drafts = await browserDrafts.stage(bindingOf(actor)); draftStorageReady = true; }
          catch { /* Its verified actor will receive a separate restore warning below. */ }
          const restoration = await current.connect(metadata, cached, drafts);
          if (draftStorageReady && restoration.draftsStaged && current.exports.drafts_restored?.(index)) current.verifyDraftActor(metadata.session, actor);
          else current.blockDraftActor(metadata.session, actor);
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
      if (!dialog.open) dialog.showModal();
    } finally {
      for (const record of records) { record.refreshToken = ''; record.clientSecret = ''; }
      records = [];
      if (attempt === connectAttempt) { select('#credential-bundle').value = ''; updateConnectionSelection(); }
    }
  })();
}

form.addEventListener('submit', event => { event.preventDefault(); beginConnection(); });
connectButton.addEventListener('click', () => { credentialError.textContent = ''; if (serverSession) beginConnection(true); else dialog.showModal(); });
fileConnectButton.addEventListener('click', () => { credentialError.textContent = ''; dialog.showModal(); });
select('#credential-select').addEventListener('click', () => select('#credential-bundle').click());
select('#credential-bundle').addEventListener('change', () => {
  for (const selector of ['#credential-clients', '#credential-grants', '#credential-tokens', '#credential-folder']) select(selector).value = '';
  select('#credential-separate').open = false;
  updateConnectionSelection();
});
for (const selector of ['#credential-clients', '#credential-grants', '#credential-tokens', '#credential-folder']) select(selector).addEventListener('change', () => { select('#credential-bundle').value = ''; updateConnectionSelection(); });
select('#credential-cancel').addEventListener('click', stopConnection);
dialog.addEventListener('cancel', event => { event.preventDefault(); stopConnection(); });
disconnectButton.addEventListener('click', () => {
  if ((unsavedDraftRisk() || pendingLength || activeJob) && !window.confirm('Disconnect with unsaved changes? Previously saved drafts remain in this browser.')) return;
  void stopConnection();
});
focusButton.addEventListener('click', () => terminal.focus());
resetButton.addEventListener('click', stopConnection);
select('#send-grace-cancel').addEventListener('click', () => transport?.cancelSend());
select('#send-acknowledge').addEventListener('click', () => {
  const namedTarget = bridge?.unknownAccount?.();
  if (activeJob || !bridge || (namedTarget ? !bridge.draftActorReady(bridge.exports.unknown_target_index()) : mode !== 'live')) return;
  const marker = pendingSend();
  const clearGenericNotice = namedTarget ? null : capturePendingSendAcknowledgement();
  void runJob(async current => {
    const acknowledged = await current.acknowledgeUnknown();
    if (!current.unknownAccount()) {
      if (acknowledged.operationId && marker?.id === acknowledged.operationId) acknowledgePendingSend(acknowledged.operationId);
      else clearGenericNotice?.();
    }
  }).catch(() => { draftError = 'The acknowledgment could not be saved. The recovery draft remains protected.'; updateControls(); });
});
cacheClearButton.addEventListener('click', () => {
  if (activeJob || !bridge) return;
  void runJob(async current => { await current.clearCache(); await browserCache.clear(); cacheError = ''; }).catch(fail);
});
draftStorageButton.addEventListener('click', async () => {
  if (mode !== 'live' || activeJob || draftCleanupBusy) return;
  const epoch = generation;
  select('#draft-storage-error').textContent = '';
  select('#draft-storage-clear').disabled = true;
  select('#draft-storage-summary').textContent = 'Loading saved draft counts…';
  draftStorageDialog.showModal(); select('#draft-storage-cancel').focus();
  try {
    const counts = await browserDrafts.savedDraftsSummary();
    if (epoch !== generation || !draftStorageDialog.open) return;
    select('#draft-storage-summary').textContent = `${counts.clearableDrafts} saved drafts and confirmed history from ${counts.clearableActors} saved connections can be cleared. ${counts.protected} connections with unconfirmed sends and ${counts.unrestorable} unreadable connections will be kept.`;
    select('#draft-storage-clear').disabled = counts.clearableActors === 0 || unsavedDraftRisk() || pendingLength > 0;
    if (unsavedDraftRisk() || pendingLength) select('#draft-storage-error').textContent = 'Save or discard your current changes before clearing saved drafts.';
  } catch { select('#draft-storage-error').textContent = 'Saved draft storage is unavailable. Existing data was kept.'; }
});
select('#draft-storage-cancel').addEventListener('click', () => { if (!draftCleanupBusy) { draftStorageDialog.close(); terminal.focus(); } });
draftStorageDialog.addEventListener('cancel', event => { if (draftCleanupBusy) event.preventDefault(); });
select('#draft-storage-clear').addEventListener('click', async () => {
  if (mode !== 'live' || activeJob || draftCleanupBusy || unsavedDraftRisk() || pendingLength) return;
  draftCleanupBusy = true; select('#draft-storage-clear').disabled = true; updateControls();
  try {
    const result = await browserDrafts.clearKnownSavedDrafts({ reviewed: true });
    if (result.clearedActors > 0) {
      draftStorageDialog.close(); await stopConnection();
      storageNotice = result.remainingProtected || result.remainingUnreadable ? 'Unconfirmed sends and unreadable saved data were kept. Connect again to continue.' : 'Connect again to continue. Your mailbox and mail cache were kept.';
    } else select('#draft-storage-error').textContent = 'No safe saved records could be cleared. Unconfirmed sends and unreadable data were kept.';
  } catch { select('#draft-storage-error').textContent = 'Draft cleanup could not be committed. Existing data was kept.'; }
  finally { draftCleanupBusy = false; updateControls(); }
});
window.addEventListener('pagehide', () => {
  connectAttempt++; generation++; ready = false;
  clearTimeout(autosaveTimer); autosaveTimer = null;
  credentialRequest?.abort(); transport?.close(); pendingInput.fill(0); pendingLength = 0;
});
window.addEventListener('beforeunload', event => {
  if (!unsavedDraftRisk() && !pendingLength && !activeJob && !draftCleanupBusy) return;
  event.preventDefault();
  event.returnValue = '';
});
window.addEventListener('pageshow', event => { if (event.persisted) stopConnection(); });
void start().catch(() => {});
