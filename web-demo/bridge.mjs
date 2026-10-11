const requiredFunctions = ['init', 'resize', 'input_ptr', 'input_capacity', 'input', 'output_ptr', 'output_len'];
const MAX_INPUT_EVENT = 64 * 1024;
const MAX_OUTPUT_FRAME = 2 * 1024 * 1024;

export function boundedSize(cols, rows) {
  return { cols: Math.min(240, Math.max(2, Math.floor(cols) || 2)), rows: Math.min(80, Math.max(2, Math.floor(rows) || 2)) };
}

export class BrowserWasmBridge {
  constructor(instance, onFrame, promising = null) {
    this.exports = instance.exports;
    this.onFrame = onFrame;
    if (!(this.exports.memory instanceof WebAssembly.Memory)) {
      throw new Error('The browser module does not export WebAssembly memory.');
    }
    for (const name of requiredFunctions) {
      if (typeof this.exports[name] !== 'function') throw new Error(`The browser module is missing ${name}().`);
    }
    this.calls = {};
    for (const name of ['init', 'resize', 'input', 'connect', 'cache_clear', 'acknowledge_unknown']) if (typeof this.exports[name] === 'function') this.calls[name] = promising ? promising(this.exports[name]) : this.exports[name];
  }

  async invoke(name, ...args) {
    try {
      const status = await this.calls[name](...args);
      if (status !== 0) throw new Error(name === 'connect' ? 'Google could not verify or load this account. Check the matching grants and token files.' : `The WebAssembly TUI returned status ${status} from ${name}().`);
      this.frame();
    } catch (error) {
      if (error instanceof WebAssembly.RuntimeError) {
        throw new Error(`The WebAssembly TUI stopped while running ${name}(): ${error.message}`, { cause: error });
      }
      throw error;
    }
  }

  init(cols, rows) {
    const size = boundedSize(cols, rows);
    return this.invoke('init', size.cols, size.rows);
  }

  resize(cols, rows) {
    const size = boundedSize(cols, rows);
    return this.invoke('resize', size.cols, size.rows);
  }

  view(ptr, len, limit, label) {
    const memory = this.exports.memory.buffer;
    if (!Number.isInteger(ptr) || !Number.isInteger(len) || ptr < 0 || len < 0 || len > limit || ptr > memory.byteLength - len) {
      throw new Error(`The WebAssembly TUI returned an invalid ${label} buffer.`);
    }
    return new Uint8Array(memory, ptr, len);
  }

  frame() {
    const ptr = this.exports.output_ptr();
    const len = this.exports.output_len();
    if (len === 0) return;
    // xterm parses asynchronously. Never retain a view that WASM may overwrite
    // or invalidate by growing memory before that parse completes.
    this.onFrame(this.view(ptr, len, MAX_OUTPUT_FRAME, 'output').slice());
  }

  async input(bytes) {
    if (!(bytes instanceof Uint8Array)) throw new TypeError('Terminal input must be UTF-8 bytes.');
    if (bytes.length > MAX_INPUT_EVENT) throw new Error('This experiment accepts up to 64 KiB of input at a time.');
    let offset = 0;
    while (offset < bytes.length) {
      const capacity = this.exports.input_capacity();
      if (capacity === 0) throw new Error('The WebAssembly TUI has no input capacity.');
      const buffer = this.view(this.exports.input_ptr(), capacity, MAX_INPUT_EVENT, 'input');
      const len = Math.min(capacity, bytes.length - offset);
      // Raw byte chunks preserve decoder state across boundaries, including
      // a UTF-8 character or ANSI keyboard sequence split between calls.
      buffer.set(bytes.subarray(offset, offset + len));
      await this.invoke('input', len);
      offset += len;
    }
  }

  async connect(metadata, cached = null) {
    if (typeof this.exports.connect_ptr !== 'function' || typeof this.exports.connect_capacity !== 'function' || !this.calls.connect) throw new Error('This browser build does not include live mail support.');
    const bytes = new TextEncoder().encode(JSON.stringify(metadata));
    const capacity = this.exports.connect_capacity();
    if (bytes.length > capacity) throw new Error('The selected account metadata exceeds the browser limit.');
    const ptr = this.exports.connect_ptr();
    const buffer = this.view(ptr, capacity, MAX_INPUT_EVENT, 'connection');
    buffer.fill(0);
    buffer.set(bytes);
    let cacheBytes;
    if (typeof this.exports.cache_stage === 'function') {
      cacheBytes = new TextEncoder().encode(cached ? JSON.stringify(cached) : '');
      const cacheCapacity = this.exports.cache_input_capacity();
      if (cacheBytes.length > cacheCapacity) throw new Error('The saved cache exceeds its bounded restore capacity.');
      this.view(this.exports.cache_input_ptr(), cacheCapacity, 3 * 1024 * 1024, 'cache').set(cacheBytes);
      if (this.exports.cache_stage(cacheBytes.length) !== 0) throw new Error('The saved cache cannot be staged while another operation is running.');
    }
    try { await this.invoke('connect', bytes.length); }
    finally { this.view(ptr, capacity, MAX_INPUT_EVENT, 'connection').fill(0); bytes.fill(0); cacheBytes?.fill(0); }
  }

  cacheSnapshot(index) {
    if (typeof this.exports.cache_export !== 'function' || this.exports.cache_export(index) !== 0) return null;
    const bytes = this.view(this.exports.cache_ptr(), this.exports.cache_len(), 3 * 1024 * 1024, 'cache');
    try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
    finally { bytes.fill(0); }
  }
  clearCache(index = 0xffffffff) { return this.invoke('cache_clear', index); }
  acknowledgeUnknown() { return this.invoke('acknowledge_unknown'); }

  wipe() { new Uint8Array(this.exports.memory.buffer).fill(0); }

  state() {
    if (typeof this.exports.state_ptr !== 'function' || typeof this.exports.state_len !== 'function') return null;
    const bytes = this.view(this.exports.state_ptr(), this.exports.state_len(), MAX_OUTPUT_FRAME, 'state');
    return JSON.parse(new TextDecoder().decode(bytes));
  }
}
