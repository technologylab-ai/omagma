import assert from 'node:assert/strict';
import test from 'node:test';
import { boundedSize, BrowserWasmBridge, terminalUnicode, alignTerminalRows } from './bridge.mjs';

function fixture(capacity = 3) {
  const memory = new WebAssembly.Memory({ initial: 1 });
  const inputs = [];
  const calls = [];
  const exports = {
    memory,
    init: (...args) => { calls.push(['init', ...args]); return 0; },
    resize: (...args) => { calls.push(['resize', ...args]); return 0; },
    input_ptr: () => 0,
    input_capacity: () => capacity,
    input: len => { inputs.push(new Uint8Array(memory.buffer, 0, len).slice()); return 0; },
    output_ptr: () => 128,
    output_len: () => 0,
    codepoint_width: () => 1,
  };
  return { exports, memory, inputs, calls };
}

test('terminal width provider uses the WASM policy and preserves combining cell properties', () => {
  const called = [];
  const provider = terminalUnicode({ codepoint_width: codepoint => {
    called.push(codepoint);
    return codepoint === 0x301 ? 0 : codepoint === 0x1fa84 ? 2 : 1;
  } });
  assert.equal(provider.wcwidth(0x1fa84), 2);
  assert.equal(provider.wcwidth(0x2063), 1);
  // xterm's public property word carries the preceding cell's width and join.
  assert.equal(provider.charProperties(0x301, 4), 5);
  assert.equal(provider.charProperties(0x301, 2), 3);
  assert.equal(provider.charProperties(0x301, 0), 0);
  assert.equal(provider.charProperties(0x301, 1), 0);
  assert.deepEqual(called, [0x1fa84, 0x2063, 0x301, 0x301, 0x301, 0x301]);
});

test('missing or invalid WASM width capability stops the host instead of selecting different Unicode tables', () => {
  assert.throws(() => terminalUnicode({}), /missing codepoint_width/);
  const instance = fixture();
  delete instance.exports.codepoint_width;
  assert.throws(() => new BrowserWasmBridge(instance, () => {}), /missing codepoint_width/);
  assert.throws(() => terminalUnicode({ codepoint_width: () => 3 }).wcwidth(0x1fa84), /invalid character width/);
});

test('DOM placement preserves merged Unicode text and styles while allocating the declared columns', () => {
  const unicode = terminalUnicode({ codepoint_width: codepoint => codepoint === 0x301 ? 0 : [0x1fa84, 0x754c].includes(codepoint) ? 2 : 1 });
  const texts = ['A🪄B', '\u2063', 'X\u0301界'];
  const spans = texts.map(textContent => ({ textContent, style: { color: '#e8ebf1', letterSpacing: '3px' } }));
  const row = { style: { width: '100px' }, children: spans };
  alignTerminalRows({ children: [row] }, 10, unicode);
  assert.deepEqual(spans.map(span => [span.style.left, span.style.width]), [['0px', '40px'], ['40px', '10px'], ['50px', '30px']]);
  assert.deepEqual(spans.map(span => span.textContent), texts);
  assert(spans.every(span => span.style.color === '#e8ebf1' && span.style.letterSpacing === '3px'));
});

test('DOM placement waits for usable dimensions and the current WASM width policy', () => {
  const row = { style: { width: '0px' }, children: [{ textContent: 'A', style: {} }] };
  const rows = { children: [row] };
  alignTerminalRows(rows, 10, null);
  alignTerminalRows(rows, 10, { wcwidth: () => { throw new Error('zero-sized rows must wait'); } });
  assert.deepEqual(row.children[0].style, {});
});

test('border cells keep grid positions while ordinary Unicode shaping runs remain intact', () => {
  const unicode = terminalUnicode({ codepoint_width: codepoint => codepoint === 0x301 ? 0 : codepoint === 0x6587 ? 2 : 1 });
  const row = { style: { width: '100px' }, children: [] };
  const span = textContent => ({
    textContent, className: 'xterm-bold', style: { color: '#e8ebf1', letterSpacing: '0px' },
    cloneNode() { const next = span(this.textContent); next.style = { ...this.style }; return next; },
    replaceWith(...cells) { row.children.splice(row.children.indexOf(this), 1, ...cells); },
  });
  const original = '╭─文e\u0301─╮';
  row.children.push(span(original));
  alignTerminalRows({ children: [row] }, 10, unicode);
  assert.deepEqual(row.children.map(cell => cell.textContent), ['╭', '─', '文e\u0301', '─', '╮']);
  assert.deepEqual(row.children.map(cell => [cell.style.left, cell.style.width]), [['0px', '10px'], ['10px', '10px'], ['20px', '30px'], ['50px', '10px'], ['60px', '10px']]);
  assert.equal(row.children.map(cell => cell.textContent).join(''), original);
  assert(row.children.every(cell => cell.className === 'xterm-bold' && cell.style.color === '#e8ebf1'));
  const before = [...row.children];
  alignTerminalRows({ children: [row] }, 10, unicode);
  assert.equal(row.children.length, before.length);
  row.children.forEach((cell, index) => assert.equal(cell, before[index], 'repeated row alignment must retain each node'));
});

test('terminal dimensions remain inside the WASM layout limits', async () => {
  assert.deepEqual(boundedSize(500, 100), { cols: 240, rows: 80 });
  assert.deepEqual(boundedSize(0, NaN), { cols: 2, rows: 2 });
  const instance = fixture();
  const bridge = new BrowserWasmBridge(instance, () => {});
  await bridge.init(300, 100);
  await bridge.resize(41.9, 18.9);
  assert.deepEqual(instance.calls, [['init', 240, 80], ['resize', 41, 18]]);
});

test('UTF-8 input and ANSI sequences survive byte boundaries', async () => {
  const instance = fixture(2);
  const bridge = new BrowserWasmBridge(instance, () => {});
  const input = new TextEncoder().encode('café 📨\x1b[A');
  await bridge.input(input);
  assert.equal(instance.inputs.every(chunk => chunk.length <= 2), true);
  assert.deepEqual(Uint8Array.from(instance.inputs.flatMap(chunk => [...chunk])), input);
});

test('output is copied before WASM overwrites or grows its memory', async () => {
  const instance = fixture();
  instance.exports.output_len = () => 4;
  new Uint8Array(instance.memory.buffer, 128, 4).set([1, 2, 3, 4]);
  const frames = [];
  const bridge = new BrowserWasmBridge(instance, frame => frames.push(frame));
  await bridge.init(80, 24);
  new Uint8Array(instance.memory.buffer, 128, 4).fill(0);
  instance.memory.grow(1);
  assert.deepEqual(frames[0], Uint8Array.of(1, 2, 3, 4));
  assert.equal(frames[0].buffer.byteLength, 4);
});

test('invalid pointers and oversized buffers stop at the host boundary', async () => {
  const instance = fixture();
  instance.exports.output_len = () => 100000;
  const bridge = new BrowserWasmBridge(instance, () => assert.fail('Invalid frame was emitted'));
  await assert.rejects(() => bridge.init(80, 24), /invalid output buffer/);
  instance.exports.output_len = () => 0;
  instance.exports.input_ptr = () => -1;
  await assert.rejects(() => bridge.input(Uint8Array.of(1)), /invalid input buffer/);
  await assert.rejects(() => bridge.input(new Uint8Array(65537)), /64 KiB/);
});

test('WASM traps become a readable error with the stopped operation', async () => {
  const instance = fixture();
  instance.exports.input = () => { throw new WebAssembly.RuntimeError('unreachable'); };
  const bridge = new BrowserWasmBridge(instance, () => {});
  await assert.rejects(() => bridge.input(Uint8Array.of(1)), /stopped while running input\(\): unreachable/);
});
