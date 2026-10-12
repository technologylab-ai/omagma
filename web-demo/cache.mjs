// IndexedDB holds only current, bounded mail/contact snapshots. OAuth material,
// session handles, native paths, drafts and provider JSON have no schema fields.
export const CACHE_LIMITS = Object.freeze({ accounts: 3, messages: 300, contacts: 100, attachments: 49, snapshotBytes: 3 * 1024 * 1024, totalBytes: 8 * 1024 * 1024 });
const DATABASE = 'omagma-browser-cache-v1';
const STORE = 'actors';
const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });
const BAD_LITERAL = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/u;
const BAD_HEADER = /[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/u;

export class BrowserCacheError extends Error {
  constructor(code) {
    super({ invalid: 'The browser cache snapshot is invalid.', limit: 'The browser cache size limit was reached.', verified: 'Verify this account before loading or saving its cache.', unavailable: 'Browser cache storage is unavailable.' }[code]);
    this.name = 'BrowserCacheError';
    this.code = code;
  }
}
const invalid = () => { throw new BrowserCacheError('invalid'); };
const limited = () => { throw new BrowserCacheError('limit'); };
function record(value, allowed) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || (Object.getPrototypeOf(value) !== Object.prototype && Object.getPrototypeOf(value) !== null)) invalid();
  for (const key of Object.keys(value)) if (!allowed.includes(key)) invalid();
  return value;
}
function literalText(value, max) {
  if (typeof value !== 'string' || value.length > max) invalid();
  if (typeof value.isWellFormed === 'function' ? !value.isWellFormed() : /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(value)) invalid();
  if (encoder.encode(value).length > max) limited();
  return value;
}
function text(value, max, multiline = false) {
  literalText(value, max);
  if ((multiline ? BAD_LITERAL : BAD_HEADER).test(value)) invalid();
  return value;
}
function list(value, max, map) {
  if (!Array.isArray(value) || value.length > max) invalid();
  return value.map(map);
}
function integer(value, max = Number.MAX_SAFE_INTEGER, negative = false) {
  if (!Number.isSafeInteger(value) || (!negative && value < 0) || Math.abs(value) > max) invalid();
  return value;
}
function boolean(value) { if (typeof value !== 'boolean') invalid(); return value; }
function id(value, max = 128) {
  text(value, max);
  if (!/^[A-Za-z0-9._-]+$/.test(value)) invalid();
  return value;
}

export function cacheKey(binding) {
  record(binding, ['account', 'clientId', 'grantId']);
  const account = text(binding.account, 254);
  const clientId = text(binding.clientId, 256);
  const grantId = text(binding.grantId, 64);
  if (!/^[\x21-\x7e]+$/.test(account) || !/^[^@\s]+@[^@\s]+$/.test(account) || !/^[\x21-\x7e]+\.apps\.googleusercontent\.com$/.test(clientId) || !/^[a-f0-9]{64}$/.test(grantId)) invalid();
  // Case and every tuple component remain exact. No fallback to account-only
  // keys can expose a snapshot under a different registration or grant.
  return [account, clientId, grantId];
}

function address(value, contact = false) {
  record(value, ['address', 'name']);
  const address = text(value.address, 254);
  if (address && !address.includes('@')) invalid();
  if (contact && (!address || !/^[\x20-\x7e]+$/.test(address))) invalid();
  return { address, name: text(value.name ?? '', 4096) };
}
function attachment(value) {
  record(value, ['id', 'filename', 'mimeType', 'size', 'contentId', 'disposition', 'contentLocation']);
  const filename = text(value.filename, 4096);
  if (filename.includes('/') || filename.includes('\\') || /^[a-z]:/i.test(filename) || filename === '.' || filename === '..') invalid();
  return { id: text(value.id, 4096), filename, mimeType: text(value.mimeType ?? 'application/octet-stream', 256), size: integer(value.size, 50 * 1024 * 1024), contentId: value.contentId === null || value.contentId === undefined ? null : text(value.contentId, 1024), disposition: value.disposition === null || value.disposition === undefined ? null : text(value.disposition, 32), contentLocation: value.contentLocation === null || value.contentLocation === undefined ? null : text(value.contentLocation, 4096) };
}
function message(value) {
  record(value, ['id', 'threadId', 'from', 'replyTo', 'to', 'cc', 'subject', 'snippet', 'bodyText', 'bodyHtml', 'bodyHtmlAmbiguous', 'bodySource', 'messageId', 'references', 'inReplyTo', 'labels', 'receivedAt', 'sentDate', 'unread', 'bodyCached', 'bodyCacheError', 'attachments']);
  const bodySource = value.bodySource ?? 'unknown';
  if (!['unknown', 'plain', 'html'].includes(bodySource)) invalid();
  return {
    id: id(value.id), threadId: value.threadId === '' ? '' : id(value.threadId),
    from: address(value.from ?? { address: '', name: '' }),
    replyTo: list(value.replyTo ?? [], 1024, entry => address(entry)),
    to: list(value.to ?? [], 1024, entry => address(entry)), cc: list(value.cc ?? [], 1024, entry => address(entry)),
    subject: text(value.subject ?? '', 16 * 1024), snippet: text(value.snippet ?? '', 16 * 1024),
    bodyText: text(value.bodyText ?? '', 2 * 1024 * 1024, true),
    // Preserve formatting/control characters in passive HTML source. This is
    // never DOM HTML: only the bounded Zig semantic reader may interpret and
    // sanitize it after the verified native restore.
    bodyHtml: value.bodyHtml === null || value.bodyHtml === undefined ? null : literalText(value.bodyHtml, 2 * 1024 * 1024),
    bodyHtmlAmbiguous: boolean(value.bodyHtmlAmbiguous ?? false), bodySource,
    messageId: text(value.messageId ?? '', 4096), references: text(value.references ?? '', 64 * 1024), inReplyTo: text(value.inReplyTo ?? '', 4096),
    labels: list(value.labels ?? [], 128, label => id(label, 256)), receivedAt: integer(value.receivedAt ?? 0, 253402300800000, true),
    sentDate: value.sentDate === null || value.sentDate === undefined ? null : text(value.sentDate, 512),
    unread: boolean(value.unread ?? false), bodyCached: boolean(value.bodyCached ?? false), bodyCacheError: text(value.bodyCacheError ?? '', 512),
    attachments: list(value.attachments ?? [], CACHE_LIMITS.attachments, attachment),
  };
}
function contact(value) {
  record(value, ['resourceName', 'etag', 'name', 'emails']);
  const resourceName = text(value.resourceName, 256);
  if (!/^people\/[A-Za-z0-9._-]+$/.test(resourceName)) invalid();
  return { resourceName, etag: text(value.etag ?? '', 4096), name: text(value.name ?? '', 4096), emails: list(value.emails ?? [], 1024, entry => address(entry, true)) };
}

function parseSnapshot(value) {
  try {
    if (value instanceof Uint8Array) {
      if (value.length > CACHE_LIMITS.snapshotBytes) limited();
      return JSON.parse(decoder.decode(value));
    }
    if (typeof value === 'string') {
      if (value.length > CACHE_LIMITS.snapshotBytes || encoder.encode(value).length > CACHE_LIMITS.snapshotBytes) limited();
      return JSON.parse(value);
    }
    return value;
  } catch (error) { if (error instanceof BrowserCacheError) throw error; invalid(); }
}

function encodedSize(snapshot) {
  const json = JSON.stringify(snapshot);
  if (json.length > CACHE_LIMITS.snapshotBytes) limited();
  const size = encoder.encode(json).length;
  if (size > CACHE_LIMITS.snapshotBytes) limited();
  return size;
}

export function validateCacheSnapshot(binding, raw) {
  const key = cacheKey(binding);
  const value = record(parseSnapshot(raw), ['version', 'account', 'clientId', 'grantId', 'updatedAt', 'messages', 'contacts', 'contactsLoaded']);
  if (value.version !== 1 || value.account !== key[0] || value.clientId !== key[1] || value.grantId !== key[2]) invalid();
  const messages = list(value.messages, CACHE_LIMITS.messages, message);
  if (new Set(messages.map(entry => entry.id)).size !== messages.length) invalid();
  const contacts = list(value.contacts, CACHE_LIMITS.contacts, contact);
  if (new Set(contacts.map(entry => entry.resourceName)).size !== contacts.length) invalid();
  const contactsLoaded = boolean(value.contactsLoaded);
  if (!contactsLoaded && contacts.length) invalid();
  const snapshot = { version: 1, account: key[0], clientId: key[1], grantId: key[2], updatedAt: integer(value.updatedAt, 253402300800000), messages, contacts, contactsLoaded };
  encodedSize(snapshot);
  return snapshot;
}

export function scopeCacheSnapshot(binding, raw, { contactsGranted = false } = {}) {
  const snapshot = validateCacheSnapshot(binding, raw);
  if (contactsGranted !== true) { snapshot.contacts = []; snapshot.contactsLoaded = false; }
  return snapshot;
}

function sameKey(left, right) { return Array.isArray(left) && left.length === 3 && left.every((value, index) => value === right[index]); }
function validatedRecord(row) {
  record(row, ['key', 'snapshot', 'byteLength', 'savedAt']);
  if (!Array.isArray(row.key) || row.key.length !== 3) invalid();
  const binding = { account: row.key[0], clientId: row.key[1], grantId: row.key[2] };
  const snapshot = validateCacheSnapshot(binding, row.snapshot);
  const byteLength = encodedSize(snapshot);
  if (byteLength !== row.byteLength) invalid();
  return { key: cacheKey(binding), snapshot, byteLength, savedAt: integer(row.savedAt, 253402300800000) };
}

// Pure transaction plan used by IndexedDB writes and quota/replace regression
// tests. An actor gets one current row; saving never appends mail history.
export function planCacheWrite(rows, binding, raw, savedAt = Date.now()) {
  if (!Array.isArray(rows) || rows.length > 4) invalid();
  const snapshot = validateCacheSnapshot(binding, raw);
  const next = { key: cacheKey(binding), snapshot, byteLength: encodedSize(snapshot), savedAt: integer(savedAt, 253402300800000) };
  const remove = [];
  const retained = [];
  for (const row of rows) {
    let previous;
    try { previous = validatedRecord(row); } catch { if (row?.key !== undefined) remove.push(row.key); continue; }
    if (!sameKey(previous.key, next.key)) retained.push(previous);
  }
  retained.sort((left, right) => left.savedAt - right.savedAt);
  let bytes = next.byteLength + retained.reduce((sum, row) => sum + row.byteLength, 0);
  while (retained.length + 1 > CACHE_LIMITS.accounts || bytes > CACHE_LIMITS.totalBytes) {
    const evicted = retained.shift();
    if (!evicted) limited();
    remove.push(evicted.key); bytes -= evicted.byteLength;
  }
  return { record: next, remove, rows: [...retained, next], bytes };
}

export function createBrowserCache({ indexedDB = globalThis.indexedDB, databaseName = DATABASE } = {}) {
  let opening = null;
  let connection = null;
  let generation = 0;
  const unavailable = () => new BrowserCacheError('unavailable');
  function open() {
    if (opening) return opening;
    if (!indexedDB || typeof databaseName !== 'string' || !databaseName.startsWith('omagma-browser-cache-') || databaseName.length > 128) return Promise.reject(unavailable());
    const expectedGeneration = generation;
    const pending = new Promise((resolve, reject) => {
      let settled = false;
      let request;
      const fail = () => { if (!settled) { settled = true; reject(unavailable()); } };
      try { request = indexedDB.open(databaseName, 1); } catch { fail(); return; }
      request.onupgradeneeded = () => {
        try { if (!request.result.objectStoreNames.contains(STORE)) request.result.createObjectStore(STORE, { keyPath: 'key' }); }
        catch { fail(); }
      };
      request.onerror = fail;
      request.onblocked = fail;
      request.onsuccess = () => {
        if (settled || expectedGeneration !== generation) { request.result.close(); fail(); return; }
        settled = true; connection = request.result;
        const current = connection;
        current.onversionchange = () => { current.close(); if (connection === current) { connection = null; opening = null; } };
        resolve(connection);
      };
    });
    opening = pending;
    pending.catch(() => { if (opening === pending) opening = null; });
    return pending;
  }
  async function transaction(mode, action) {
    const db = await open();
    return new Promise((resolve, reject) => {
      let result, failure;
      let tx;
      try { tx = db.transaction(STORE, mode); } catch { reject(unavailable()); return; }
      tx.oncomplete = () => resolve(result);
      tx.onabort = () => reject(failure ?? unavailable());
      tx.onerror = () => { failure ??= unavailable(); };
      const fail = error => { failure = error instanceof BrowserCacheError ? error : unavailable(); try { tx.abort(); } catch { reject(failure); } };
      try { action(tx.objectStore(STORE), value => { result = value; }, fail); } catch (error) { fail(error); }
    });
  }
  async function read(binding, options) {
    const key = cacheKey(binding);
    return transaction('readwrite', (store, finish, fail) => {
      const request = store.get(key);
      request.onerror = () => fail(unavailable());
      request.onsuccess = () => {
        if (request.result === undefined) { finish(null); return; }
        let row;
        try { row = validatedRecord(request.result); if (!sameKey(row.key, key)) invalid(); }
        catch { store.delete(key); finish(null); return; }
        finish(scopeCacheSnapshot(binding, row.snapshot, options));
      };
    });
  }
  return Object.freeze({
    // PRE-verification staging only. The caller must send these untrusted
    // bytes solely to native pending-cache input; no DOM, diagnostic or UI use
    // is permitted until Gmail PROFILE and the exact native actor binding pass.
    stage(binding, options = {}) { return read(binding, options); },
    load(binding, options = {}) {
      if (options.verified !== true) return Promise.reject(new BrowserCacheError('verified'));
      return read(binding, options);
    },
    async save(binding, snapshot, options = {}) {
      if (options.verified !== true) throw new BrowserCacheError('verified');
      const validated = validateCacheSnapshot(binding, snapshot);
      return transaction('readwrite', (store, finish, fail) => {
        // Count-limited retrieval bounds corrupted/old database contents too.
        const request = store.getAll(undefined, 4);
        request.onerror = () => fail(unavailable());
        request.onsuccess = () => {
          try {
            const rows = request.result;
            const oversized = rows.length > CACHE_LIMITS.accounts;
            const plan = planCacheWrite(oversized ? [] : rows, binding, validated);
            if (oversized) store.clear();
            else for (const key of plan.remove) store.delete(key);
            store.put(plan.record);
            finish({ stored: true, accounts: plan.rows.length, bytes: plan.bytes });
          } catch (error) { fail(error); }
        };
      });
    },
    async clear(binding = null) {
      const key = binding === null ? null : cacheKey(binding);
      return transaction('readwrite', (store, finish) => { if (key === null) store.clear(); else store.delete(key); finish(); });
    },
    close() { generation++; connection?.close(); connection = null; opening = null; },
  });
}
