import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { boundedSize, BrowserWasmBridge } from './bridge.mjs';

const terminalElement = document.querySelector('#terminal');
const message = document.querySelector('#runtime-message');
const messageText = document.querySelector('#runtime-message-text');
const runtimeStatus = document.querySelector('#runtime-status');
const sizeLabel = document.querySelector('#terminal-size');
const resetButton = document.querySelector('#demo-reset');
const focusButton = document.querySelector('#terminal-focus');
const encoder = new TextEncoder();
const terminal = new Terminal({
  cols: 100,
  rows: 30,
  fontFamily: '"Cascadia Code", "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace',
  fontSize: 13,
  lineHeight: 1.15,
  letterSpacing: 0,
  scrollback: 0,
  cursorBlink: false,
  cursorStyle: 'block',
  allowProposedApi: false,
  convertEol: false,
  overviewRuler: { width: 0 },
  theme: { background: '#0d1219', foreground: '#d1d9e6', cursor: '#b5cc90', selectionBackground: '#364258' },
});
const fit = new FitAddon();
terminal.loadAddon(fit);
terminal.open(terminalElement);
let bridge = null;
let module = null;
let ready = false;
let error = null;
let frameCount = 0;
let generation = 0;
let resizeScheduled = false;
let queuedInput = '';
let inputScheduled = false;
let wasmCols = 0;
let wasmRows = 0;

function screenText() {
  const buffer = terminal.buffer.active;
  const lines = [];
  for (let row = 0; row < terminal.rows; row++) lines.push(buffer.getLine(buffer.viewportY + row)?.translateToString(true) ?? '');
  return lines.join('\n');
}

function cellStyle(col, row) {
  const buffer = terminal.buffer.active;
  const cell = buffer.getLine(buffer.viewportY + row)?.getCell(col);
  return cell ? { fg: cell.getFgColor(), bg: cell.getBgColor(), fgRGB: cell.isFgRGB(), bgRGB: cell.isBgRGB() } : null;
}

// Read-only diagnostics for the synthetic experiment and browser regression
// checks. All UI behavior and state come from the compiled Zig module.
Object.defineProperty(window, 'omagmaDemo', { value: Object.freeze({
  get ready() { return ready; },
  get error() { return error; },
  get cols() { return terminal.cols; },
  get rows() { return terminal.rows; },
  get frameCount() { return frameCount; },
  screenText,
  cellStyle,
  exports() { return bridge ? Object.keys(bridge.exports).sort() : []; },
  state() { return bridge?.state() ?? null; },
}), writable: false, configurable: false });

function fail(reason) {
  ready = false;
  error = reason instanceof Error ? reason.message : String(reason);
  terminal.options.disableStdin = true;
  message.hidden = false;
  message.classList.add('failed');
  messageText.textContent = error;
  runtimeStatus.textContent = 'The experiment stopped';
  focusButton.disabled = true;
  resetButton.disabled = !module;
}

function attempt(action) {
  try { action(); } catch (reason) { fail(reason); }
}

function fitTerminal() {
  const proposed = fit.proposeDimensions();
  if (!proposed) return false;
  const { cols, rows } = boundedSize(proposed.cols, proposed.rows);
  const changed = cols !== terminal.cols || rows !== terminal.rows;
  if (changed) terminal.resize(cols, rows);
  sizeLabel.textContent = `${cols} × ${rows}`;
  return changed;
}

function synchronizeSize() {
  if (wasmCols === terminal.cols && wasmRows === terminal.rows) return;
  bridge.resize(terminal.cols, terminal.rows);
  wasmCols = terminal.cols;
  wasmRows = terminal.rows;
}

function resize() {
  if (resizeScheduled) return;
  resizeScheduled = true;
  requestAnimationFrame(() => {
    resizeScheduled = false;
    attempt(() => {
      fitTerminal();
      if (ready) synchronizeSize();
    });
  });
}
new ResizeObserver(resize).observe(terminalElement);

function send(data) {
  if (!ready) return;
  queuedInput += data;
  if (inputScheduled) return;
  inputScheduled = true;
  queueMicrotask(() => {
    inputScheduled = false;
    const input = queuedInput;
    queuedInput = '';
    if (ready) attempt(() => bridge.input(encoder.encode(input)));
  });
}
terminal.onData(send);
terminal.onBinary(data => {
  if (ready) attempt(() => bridge.input(Uint8Array.from(data, character => character.charCodeAt(0))));
});

terminal.attachCustomKeyEventHandler(event => {
  // Tab and Shift+Tab remain native TUI pane keys. F6 moves focus to the
  // page controls so keyboard users can leave the terminal interaction.
  if (event.key === 'F6') {
    event.preventDefault();
    event.stopPropagation();
    if (event.type === 'keydown') focusButton.focus();
    return false;
  }
  return true;
});

async function start() {
  const thisGeneration = ++generation;
  ready = false;
  error = null;
  queuedInput = '';
  focusButton.disabled = true;
  resetButton.disabled = true;
  terminal.options.disableStdin = true;
  message.hidden = false;
  message.classList.remove('failed');
  messageText.textContent = 'Loading WebAssembly…';
  runtimeStatus.textContent = 'Starting the TUI';
  terminal.reset();
  fitTerminal();
  try {
    if (!module) {
      if (location.protocol === 'file:') throw new Error('Serve this folder over HTTP to load WebAssembly. See the browser experiment README.');
      const response = await fetch(new URL('./omagma.wasm', import.meta.url));
      if (!response.ok) throw new Error(`Could not load omagma.wasm (HTTP ${response.status}). Build the browser target and package the demo first.`);
      module = await WebAssembly.compile(await response.arrayBuffer());
      if (WebAssembly.Module.imports(module).length) throw new Error('This experiment requires an import-free WebAssembly module.');
    }
    const instance = await WebAssembly.instantiate(module, {});
    if (thisGeneration !== generation) return;
    bridge = new BrowserWasmBridge(instance, bytes => {
      // Pass bytes directly to xterm's streaming UTF-8 decoder. Split Unicode
      // code points in successive frames remain intact.
      terminal.write(bytes, () => {
        if (thisGeneration !== generation) return;
        frameCount++;
        if (!ready && !error) {
          ready = true;
          terminal.options.disableStdin = false;
          message.hidden = true;
          runtimeStatus.textContent = 'Running locally in WebAssembly';
          focusButton.disabled = false;
          resetButton.disabled = false;
          terminal.focus();
          attempt(synchronizeSize);
        }
      });
    });
    wasmCols = terminal.cols;
    wasmRows = terminal.rows;
    bridge.init(wasmCols, wasmRows);
  } catch (reason) {
    if (thisGeneration === generation) fail(reason);
  }
}

focusButton.addEventListener('click', () => terminal.focus());
resetButton.addEventListener('click', () => { void start(); });
void start();
