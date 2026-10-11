import assert from 'node:assert/strict';
import test from 'node:test';
import { boundedSize, BrowserWasmBridge } from './bridge.mjs';

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
  };
  return { exports, memory, inputs, calls };
}

test('terminal dimensions remain inside the WASM layout limits', () => {
  assert.deepEqual(boundedSize(500, 100), { cols: 240, rows: 80 });
  assert.deepEqual(boundedSize(0, NaN), { cols: 2, rows: 2 });
  const instance = fixture();
  const bridge = new BrowserWasmBridge(instance, () => {});
  bridge.init(300, 100);
  bridge.resize(41.9, 18.9);
  assert.deepEqual(instance.calls, [['init', 240, 80], ['resize', 41, 18]]);
});

test('UTF-8 input and ANSI sequences survive byte boundaries', () => {
  const instance = fixture(2);
  const bridge = new BrowserWasmBridge(instance, () => {});
  const input = new TextEncoder().encode('café 📨\x1b[A');
  bridge.input(input);
  assert.equal(instance.inputs.every(chunk => chunk.length <= 2), true);
  assert.deepEqual(Uint8Array.from(instance.inputs.flatMap(chunk => [...chunk])), input);
});

test('output is copied before WASM overwrites or grows its memory', () => {
  const instance = fixture();
  instance.exports.output_len = () => 4;
  new Uint8Array(instance.memory.buffer, 128, 4).set([1, 2, 3, 4]);
  const frames = [];
  const bridge = new BrowserWasmBridge(instance, frame => frames.push(frame));
  bridge.init(80, 24);
  new Uint8Array(instance.memory.buffer, 128, 4).fill(0);
  instance.memory.grow(1);
  assert.deepEqual(frames[0], Uint8Array.of(1, 2, 3, 4));
  assert.equal(frames[0].buffer.byteLength, 4);
});

test('invalid pointers and oversized buffers stop at the host boundary', () => {
  const instance = fixture();
  instance.exports.output_len = () => 100000;
  const bridge = new BrowserWasmBridge(instance, () => assert.fail('Invalid frame was emitted'));
  assert.throws(() => bridge.init(80, 24), /invalid output buffer/);
  instance.exports.output_len = () => 0;
  instance.exports.input_ptr = () => -1;
  assert.throws(() => bridge.input(Uint8Array.of(1)), /invalid input buffer/);
  assert.throws(() => bridge.input(new Uint8Array(65537)), /64 KiB/);
});

test('WASM traps become a readable error with the stopped operation', () => {
  const instance = fixture();
  instance.exports.input = () => { throw new WebAssembly.RuntimeError('unreachable'); };
  const bridge = new BrowserWasmBridge(instance, () => {});
  assert.throws(() => bridge.input(Uint8Array.of(1)), /stopped while running input\(\): unreachable/);
});
