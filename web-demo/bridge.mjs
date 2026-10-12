const requiredFunctions = ['init', 'resize', 'input_ptr', 'input_capacity', 'input', 'output_ptr', 'output_len', 'codepoint_width', 'policy_ptr', 'policy_len'];
const MAX_INPUT_EVENT = 64 * 1024;
const MAX_OUTPUT_FRAME = 2 * 1024 * 1024;

export function boundedSize(cols, rows) {
  return { cols: Math.min(240, Math.max(2, Math.floor(cols) || 2)), rows: Math.min(80, Math.max(2, Math.floor(rows) || 2)) };
}

// xterm consumes additive scalar widths, just like the browser Vaxis adapter.
// The Unicode tables and width policy live only in the Zig renderer.
export function terminalUnicode(exports) {
  if (typeof exports.codepoint_width !== 'function') throw new Error('The browser module is missing codepoint_width().');
  const width = codepoint => {
    const columns = exports.codepoint_width(codepoint);
    if (columns !== 0 && columns !== 1 && columns !== 2) throw new Error('The WebAssembly TUI returned an invalid character width.');
    return columns;
  };
  return {
    version: 'omagma-wcwidth',
    wcwidth: width,
    charProperties(codepoint, preceding) {
      let columns = width(codepoint);
      const previousColumns = (preceding >> 1) & 3;
      const joins = columns === 0 && preceding !== 0 && previousColumns > 0;
      if (joins) columns = previousColumns;
      // Public xterm 6 Unicode provider properties: width bits 1–2, join bit 0.
      return (columns << 1) | Number(joins);
    },
  };
}

function borderParts(text, unicode) {
  const parts = [];
  let current = '', border = false;
  for (const character of text) {
    const codepoint = character.codePointAt(0);
    const width = unicode.wcwidth(codepoint);
    const nextBorder = codepoint >= 0x2500 && codepoint <= 0x257f;
    if (current && (nextBorder || (border && width > 0))) {
      parts.push(current);
      current = '';
    }
    current += character;
    if (width > 0) border = nextBorder;
  }
  if (current) parts.push(current);
  return parts;
}

// The pinned DOM renderer relies on letter-spacing for cell geometry, which
// some invisible/shaping characters ignore. Position styled spans by declared
// columns; split border glyphs to avoid accumulated internal spacing error.
// Normal text stays merged, retaining its existing shaping and Unicode data.
export function alignTerminalRows(rows, columns, unicode, start = 0, end = rows.children.length - 1) {
  if (!unicode || !Number.isInteger(columns) || columns < 2 || columns > 240) return;
  for (let index = Math.max(0, start); index <= end && index < rows.children.length && index < 80; index++) {
    const row = rows.children[index];
    const cellWidth = Number.parseFloat(row.style.width) / columns;
    if (!Number.isFinite(cellWidth) || cellWidth <= 0) continue;
    row.style.position = 'relative';
    const spans = [];
    for (const span of Array.from(row.children)) {
      const text = span.textContent ?? '';
      if (text.length > 1 && /[\u2500-\u257f]/u.test(text)) {
        const parts = borderParts(text, unicode);
        if (parts.length > 1) {
          const cells = parts.map(part => {
            const cell = span.cloneNode(false);
            cell.textContent = part;
            return cell;
          });
          span.replaceWith(...cells);
          spans.push(...cells);
          continue;
        }
      }
      spans.push(span);
    }
    let column = 0;
    for (const span of spans) {
      let width = 0;
      for (const character of span.textContent ?? '') width += unicode.wcwidth(character.codePointAt(0));
      span.style.position = 'absolute';
      span.style.top = '0px';
      span.style.left = `${column * cellWidth}px`;
      span.style.width = `${width * cellWidth}px`;
      column += width;
    }
  }
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
    for (const name of ['init', 'resize', 'input', 'connect', 'cache_clear', 'acknowledge_unknown', 'contacts_permission']) if (typeof this.exports[name] === 'function') this.calls[name] = promising ? promising(this.exports[name]) : this.exports[name];
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

  readMailPolicy() {
    const bytes = this.view(this.exports.policy_ptr(), this.exports.policy_len(), 4096, 'mail policy');
    try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
    catch (cause) { throw new Error('The WebAssembly mail policy is invalid.', { cause }); }
  }

  cacheSnapshot(index) {
    if (typeof this.exports.cache_export !== 'function' || this.exports.cache_export(index) !== 0) return null;
    const bytes = this.view(this.exports.cache_ptr(), this.exports.cache_len(), 3 * 1024 * 1024, 'cache');
    try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
    finally { bytes.fill(0); }
  }
  clearCache(index = 0xffffffff) { return this.invoke('cache_clear', index); }
  acknowledgeUnknown() { return this.invoke('acknowledge_unknown'); }
  restrictContacts(index, allowed) { return this.invoke('contacts_permission', index, Number(Boolean(allowed))); }

  wipe() { new Uint8Array(this.exports.memory.buffer).fill(0); }

  state() {
    if (typeof this.exports.state_ptr !== 'function' || typeof this.exports.state_len !== 'function') return null;
    const bytes = this.view(this.exports.state_ptr(), this.exports.state_len(), MAX_OUTPUT_FRAME, 'state');
    return JSON.parse(new TextDecoder().decode(bytes));
  }
}
