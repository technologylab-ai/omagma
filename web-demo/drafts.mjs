// Private, bounded passive draft data. The shared WASM draft codec validates
// restored mail after fresh PROFILE verification; nothing here renders HTML.
import { cacheKey } from './cache.mjs';
import { pendingSend } from './transport.mjs';
export const DRAFT_LIMITS = Object.freeze({ actors: 3, drafts: 8, operations: 64, totalBytes: 8 * 1024 * 1024, draftBytes: 3 * 1024 * 1024 - 16 * 1024, snapshotBytes: 8 * 1024 * 1024 + 128 * 1024 });
const DATABASE = 'omagma-browser-drafts-v1';
const STORE = 'actors';
const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });
export class BrowserDraftError extends Error {
  constructor(code) {
    super({ invalid: 'The saved browser drafts are invalid; the stored copy was kept.', limit: 'Browser draft storage is full; discard a saved draft to free space.', operations: 'The browser send receipt history is full; settled receipts must be retired before another send.', unavailable: 'Browser draft storage is unavailable; your current editor contents are kept.', verified: 'Verify this account before saving or reading its drafts.', conflict: 'These drafts changed in another tab; this tab keeps its editor contents. Reconnect before saving.', protected: 'An unconfirmed send is protected; check Sent and acknowledge it before clearing saved drafts.', review: 'Review clearing all saved browser drafts before continuing.' }[code]);
    this.name = 'BrowserDraftError'; this.code = code;
  }
}
const invalid = () => { throw new BrowserDraftError('invalid'); };
const limited = () => { throw new BrowserDraftError('limit'); };
function record(value, fields) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || (Object.getPrototypeOf(value) !== Object.prototype && Object.getPrototypeOf(value) !== null)) invalid();
  for (const key of Object.keys(value)) if (!fields.includes(key)) invalid();
  return value;
}
function text(value, max) {
  if (typeof value !== 'string' || value.length > max || /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(value)) invalid();
  if (encoder.encode(value).length > max) limited();
  return value;
}
function integer(value, max) { if (!Number.isSafeInteger(value) || value < 0 || value > max) invalid(); return value; }
function list(value, max, check) { if (!Array.isArray(value) || value.length > max) invalid(); for (const item of value) check(item); return value; }
function address(value) { record(value, ['address', 'name']); text(value.address, 4096); text(value.name ?? '', 16 * 1024); }
function file(value) {
  record(value, ['id', 'filename', 'mimeType', 'size', 'data', 'blobId', 'contentId', 'disposition', 'contentLocation']);
  text(value.id, 4096); text(value.filename, 4096); text(value.mimeType ?? 'application/octet-stream', 128);
  if (value.blobId !== undefined && value.blobId !== null) invalid();
  const bytes = integer(value.size ?? 0, 2 * 1024 * 1024);
  const data = text(value.data ?? '', 3 * 1024 * 1024);
  if (!/^[A-Za-z0-9_-]*$/.test(data) || data.length % 4 === 1 || Math.floor(data.length * 3 / 4) !== bytes) invalid();
  for (const key of ['contentId', 'disposition', 'contentLocation']) if (value[key] !== undefined && value[key] !== null) text(value[key], 4096);
}
function original(value) {
  record(value, ['version', 'sourceMessageId', 'from', 'to', 'cc', 'subject', 'date', 'bodyText', 'bodyHtml', 'resources']);
  if ((value.version ?? 1) !== 1) invalid();
  text(value.sourceMessageId ?? '', 4096); address(value.from ?? { address: '' });
  for (const key of ['to', 'cc']) list(value[key] ?? [], 1024, address);
  text(value.subject ?? '', 64 * 1024); text(value.date ?? '', 64 * 1024);
  text(value.bodyText ?? '', 2 * 1024 * 1024); text(value.bodyHtml ?? '', 2 * 1024 * 1024);
  list(value.resources ?? [], 32, file);
}
function draft(value) {
  record(value, ['id', 'from', 'recoveryFields', 'to', 'cc', 'bcc', 'subject', 'bodyText', 'bodyFormat', 'threadId', 'inReplyTo', 'references', 'attachments', 'original', 'omittedAttachments']);
  if (!text(value.id, 128)) invalid();
  if (value.from !== undefined && value.from !== null) address(value.from);
  for (const key of ['to', 'cc', 'bcc']) list(value[key] ?? [], 32, address);
  if (value.recoveryFields !== undefined && value.recoveryFields !== null) {
    if (!Array.isArray(value.recoveryFields) || value.recoveryFields.length !== 5) invalid();
    value.recoveryFields.forEach((field, index) => text(field, index === 4 ? 2 * 1024 * 1024 : 64 * 1024));
  }
  text(value.subject ?? '', 64 * 1024); text(value.bodyText ?? '', 2 * 1024 * 1024);
  if (!['plain', 'markdown'].includes(value.bodyFormat ?? 'plain')) invalid();
  for (const key of ['threadId', 'inReplyTo', 'references']) text(value[key] ?? '', 64 * 1024);
  list(value.attachments ?? [], 16, file);
  if (value.original !== undefined && value.original !== null) original(value.original);
  integer(value.omittedAttachments ?? 0, 64);
  const files = [...(value.attachments ?? []), ...(value.original?.resources ?? [])];
  if (files.reduce((sum, entry) => sum + entry.size, 0) > 2 * 1024 * 1024) limited();
  if (encodedSize(value) > DRAFT_LIMITS.draftBytes) limited();
}
function operation(value) {
  record(value, ['id', 'draftId', 'hash', 'phase', 'outcome', 'errorCode', 'acknowledged']);
  if (!text(value.id, 256) || !text(value.draftId, 128) || !/^[a-f0-9]{64}$/.test(value.hash)) invalid();
  if (!['paused', 'submitted'].includes(value.phase) || !['unknown', 'applied', 'rejected'].includes(value.outcome)) invalid();
  text(value.errorCode ?? '', 64);
  if (typeof value.acknowledged !== 'boolean' || (value.acknowledged && value.outcome !== 'unknown')) invalid();
}
function encodedSize(value) { return encoder.encode(JSON.stringify(value)).length; }
function parse(raw) {
  try {
    if (raw instanceof Uint8Array) { if (raw.length > DRAFT_LIMITS.snapshotBytes) limited(); return JSON.parse(decoder.decode(raw)); }
    if (typeof raw === 'string') { if (raw.length > DRAFT_LIMITS.snapshotBytes || encoder.encode(raw).length > DRAFT_LIMITS.snapshotBytes) limited(); return JSON.parse(raw); }
    return raw;
  } catch (error) { if (error instanceof BrowserDraftError) throw error; invalid(); }
}
export function validateDraftSnapshot(binding, raw) {
  let key;
  try { key = cacheKey(binding); } catch { invalid(); }
  const value = record(parse(raw), ['version', 'revision', 'account', 'clientId', 'grantId', 'drafts', 'operations']);
  if (value.version !== 1 || value.account !== key[0] || value.clientId !== key[1] || value.grantId !== key[2] || !integer(value.revision, 0xffffffff)) invalid();
  list(value.drafts, DRAFT_LIMITS.drafts, draft); list(value.operations, DRAFT_LIMITS.operations, operation);
  if (new Set(value.drafts.map(item => item.id)).size !== value.drafts.length || new Set(value.operations.map(item => item.id)).size !== value.operations.length) invalid();
  for (const op of value.operations) if (op.outcome === 'unknown' && !op.acknowledged && !value.drafts.some(item => item.id === op.draftId)) invalid();
  if (encodedSize(value) > DRAFT_LIMITS.snapshotBytes || value.drafts.reduce((sum, item) => sum + encodedSize(item), 0) > DRAFT_LIMITS.totalBytes) limited();
  return value;
}
const sameKey = (left, right) => Array.isArray(left) && left.length === 3 && left.every((item, index) => item === right[index]);
function validatedRow(row) {
  record(row, ['key', 'snapshot', 'byteLength', 'draftBytes']);
  if (!Array.isArray(row.key) || row.key.length !== 3) invalid();
  const snapshot = validateDraftSnapshot({ account: row.key[0], clientId: row.key[1], grantId: row.key[2] }, row.snapshot);
  if (row.byteLength !== encodedSize(snapshot) || row.draftBytes !== snapshot.drafts.reduce((sum, item) => sum + encodedSize(item), 0)) invalid();
  return { ...row, snapshot };
}
function transition(previous, next) {
  if (previous?.revision !== next.revision - 1 && !(previous === null && next.revision === 1)) throw new BrowserDraftError('conflict');
  // A tab restored during a countdown cannot overwrite a subsequent submitted
  // marker, even though the boundary marker shares that operation's revision.
  for (const op of previous?.operations ?? []) if (op.phase === 'submitted') {
    const replacement = next.operations.find(item => item.id === op.id);
    if ((!replacement && op.outcome === 'unknown' && !op.acknowledged) || (replacement && replacement.phase !== 'submitted')) throw new BrowserDraftError('conflict');
  }
}
// A damaged row belonging to another actor must stay untouched. Count its
// actual passive contents and declared reservation conservatively, without
// parsing/rendering them or allocating an unbounded JSON copy.
function passiveSize(value, limit) {
  let bytes = 0, nodes = 0;
  const seen = new Set();
  const add = length => { bytes = Math.min(limit + 1, bytes + length); };
  function string(value) {
    if (value.length > limit - bytes) { bytes = limit + 1; return; }
    add(2);
    for (let index = 0; index < value.length && bytes <= limit; index++) {
      const point = value.codePointAt(index);
      if (point > 0xffff) index++;
      add(point < 0x20 || (point >= 0xd800 && point <= 0xdfff) ? 6 : point === 0x22 || point === 0x5c ? 2 : point < 0x80 ? 1 : point < 0x800 ? 2 : point < 0x10000 ? 3 : 4);
    }
  }
  function visit(item, depth) {
    if (bytes > limit) return;
    if (++nodes > 32768 || depth > 32) { bytes = limit + 1; return; }
    if (typeof item === 'string') return string(item);
    if (item === null || typeof item === 'boolean' || typeof item === 'number') { add(32); return; }
    if (!item || typeof item !== 'object' || seen.has(item)) { bytes = limit + 1; return; }
    seen.add(item);
    if (Array.isArray(item)) {
      if (item.length > 32768 - nodes) { bytes = limit + 1; return; }
      add(2 + item.length);
      for (const child of item) visit(child, depth + 1);
    } else if (Object.getPrototypeOf(item) === Object.prototype || Object.getPrototypeOf(item) === null) {
      add(2);
      for (const key in item) if (Object.hasOwn(item, key)) {
        string(key); add(2); visit(item[key], depth + 1);
        if (bytes > limit) break;
      }
    } else bytes = limit + 1;
    seen.delete(item);
  }
  visit(value, 0);
  return bytes;
}
function retainedRow(row) {
  try {
    const valid = validatedRow(row);
    return { row: valid, valid: true, draftBytes: valid.draftBytes, operations: valid.snapshot.operations.length };
  } catch {
    let draftBytes = passiveSize(row, DRAFT_LIMITS.totalBytes);
    for (const field of ['draftBytes', 'byteLength']) if (Number.isSafeInteger(row?.[field]) && row[field] > 0) draftBytes = Math.max(draftBytes, Math.min(DRAFT_LIMITS.totalBytes + 1, row[field]));
    const operations = Array.isArray(row?.snapshot?.operations) ? Math.min(DRAFT_LIMITS.operations + 1, row.snapshot.operations.length) : DRAFT_LIMITS.operations;
    return { row, valid: false, draftBytes, operations };
  }
}
function emptySettled(row) {
  return row.valid && row.row.snapshot.drafts.length === 0 && row.row.snapshot.operations.every(op => op.outcome !== 'unknown' || op.acknowledged);
}
// undefined means no pending marker; null means an unreadable/unattributed
// marker. The pure plan accepts only its opaque identity, never account data.
export function planDraftCleanup(rows, { protectedOperationId } = {}) {
  if (!Array.isArray(rows) || rows.length > DRAFT_LIMITS.actors) limited();
  const retained = rows.map(retainedRow), clearable = [];
  const markerPresent = protectedOperationId !== undefined;
  const identified = typeof protectedOperationId === 'string' && retained.some(entry => entry.valid && entry.row.snapshot.operations.some(op => op.id === protectedOperationId));
  let protectedActors = 0, unreadable = 0, drafts = 0, clearableDrafts = 0;
  for (const entry of retained) {
    if (!entry.valid) { unreadable++; continue; }
    const snapshot = entry.row.snapshot;
    drafts += snapshot.drafts.length;
    // A provider rejection can still await the other tab's UI consumption.
    // Its matching host marker protects the whole actor, as does an applied
    // recovery. Unattributed markers conservatively protect submitted drafts.
    if (snapshot.operations.some(op => (markerPresent && op.id === protectedOperationId) || (op.outcome === 'unknown' && !op.acknowledged) || (op.phase === 'submitted' && (op.outcome === 'applied' || (markerPresent && !identified)) && snapshot.drafts.some(draft => draft.id === op.draftId)))) protectedActors++;
    else { clearable.push(entry.row.key); clearableDrafts += snapshot.drafts.length; }
  }
  return { clearable, summary: { actors: retained.length, drafts, protected: protectedActors, unrestorable: unreadable, clearableActors: clearable.length, clearableDrafts } };
}
function cleanupMarker() {
  const marker = pendingSend();
  return marker ? { protectedOperationId: marker.id ?? null } : {};
}
export function planDraftWrites(rows, updates, options = {}) {
  if (!Array.isArray(rows) || rows.length > DRAFT_LIMITS.actors || !Array.isArray(updates) || !updates.length || updates.length > DRAFT_LIMITS.actors) limited();
  const activeBindings = options.bindings ?? updates.map(update => update.binding);
  if (!Array.isArray(activeBindings) || activeBindings.length > DRAFT_LIMITS.actors) invalid();
  const activeKeys = activeBindings.map(cacheKey);
  const result = rows.map(retainedRow);
  const changed = [], deletions = [];
  for (const { binding, snapshot: raw } of updates) {
    const snapshot = validateDraftSnapshot(binding, raw);
    const key = cacheKey(binding);
    if (changed.some(row => sameKey(row.key, key))) invalid();
    const index = result.findIndex(entry => sameKey(entry.row?.key, key));
    // Never replace a corrupt current actor with an empty or partial recovery.
    const previous = index < 0 ? null : validatedRow(result[index].row).snapshot;
    transition(previous, snapshot);
    const next = { key, snapshot, byteLength: encodedSize(snapshot), draftBytes: snapshot.drafts.reduce((sum, item) => sum + encodedSize(item), 0) };
    const retained = { row: next, valid: true, draftBytes: next.draftBytes, operations: snapshot.operations.length };
    if (index < 0) result.push(retained); else result[index] = retained;
    changed.push(next);
  }
  // Empty settled histories can release superseded account/grant slots and
  // receipt capacity held by unconnected actors. A still-open tab retaining
  // the old revision will fail CAS and must reload.
  let operationCount = result.reduce((sum, row) => sum + row.operations, 0);
  for (let index = 0; (result.length > DRAFT_LIMITS.actors || operationCount > DRAFT_LIMITS.operations) && index < result.length;) {
    const entry = result[index];
    if (emptySettled(entry) && (result.length > DRAFT_LIMITS.actors || entry.operations > 0) && !activeKeys.some(key => sameKey(key, entry.row.key)) && !changed.some(row => sameKey(row.key, entry.row.key))) { deletions.push(entry.row.key); operationCount -= entry.operations; result.splice(index, 1); }
    else index++;
  }
  if (result.length > DRAFT_LIMITS.actors || result.reduce((sum, row) => sum + row.draftBytes, 0) > DRAFT_LIMITS.totalBytes) limited();
  if (operationCount > DRAFT_LIMITS.operations) throw new BrowserDraftError('operations');
  // Every affected actor is compared and committed in one transaction. Receipt
  // rotation can free another verified actor's settled history without a lost
  // update, half-commit, or changing its protected drafts.
  return { records: changed, deletions, rows: result.map(entry => entry.row) };
}
export function planDraftWrite(rows, binding, raw) {
  const plan = planDraftWrites(rows, [{ binding, snapshot: raw }]);
  return { ...plan, record: plan.records[0] };
}
function verifiedUpdates(primary, raw, bindings) {
  const value = parse(raw);
  let documents;
  if (value && Object.hasOwn(value, 'updates')) {
    record(value, ['version', 'updates']);
    if (value.version !== 1 || !Array.isArray(value.updates) || !value.updates.length || value.updates.length > DRAFT_LIMITS.actors || encodedSize(value) > DRAFT_LIMITS.snapshotBytes) invalid();
    documents = value.updates;
  } else documents = [value];
  if (!Array.isArray(bindings) || bindings.length > DRAFT_LIMITS.actors) invalid();
  const updates = documents.map(snapshot => {
    const binding = bindings.find(actor => snapshot?.account === actor.account && snapshot?.clientId === actor.clientId && snapshot?.grantId === actor.grantId);
    if (!binding) throw new BrowserDraftError('verified');
    return { binding, snapshot: validateDraftSnapshot(binding, snapshot) };
  });
  if (!updates.some(item => sameKey(cacheKey(item.binding), cacheKey(primary)))) throw new BrowserDraftError('verified');
  return updates;
}
export function createBrowserDrafts({ indexedDB = globalThis.indexedDB, databaseName = DATABASE } = {}) {
  let opening = null, connection = null, generation = 0;
  const unavailable = () => new BrowserDraftError('unavailable');
  function open() {
    if (opening) return opening;
    if (!indexedDB || typeof databaseName !== 'string' || !databaseName.startsWith('omagma-browser-drafts-') || databaseName.length > 128) return Promise.reject(unavailable());
    const epoch = generation;
    const promise = new Promise((resolve, reject) => {
      let request, done = false;
      const fail = () => { if (!done) { done = true; reject(unavailable()); } };
      try { request = indexedDB.open(databaseName, 1); } catch { fail(); return; }
      request.onupgradeneeded = () => { try { if (!request.result.objectStoreNames.contains(STORE)) request.result.createObjectStore(STORE, { keyPath: 'key' }); } catch { fail(); } };
      request.onerror = fail; request.onblocked = fail;
      request.onsuccess = () => {
        if (done || generation !== epoch) { request.result.close(); fail(); return; }
        done = true; connection = request.result;
        const current = connection;
        current.onversionchange = () => { current.close(); if (current === connection) { connection = null; opening = null; } };
        resolve(current);
      };
    });
    opening = promise;
    promise.catch(() => { if (opening === promise) opening = null; });
    return promise;
  }
  async function transaction(mode, action) {
    const db = await open();
    return new Promise((resolve, reject) => {
      let tx, result, failure;
      try { tx = db.transaction(STORE, mode, mode === 'readwrite' ? { durability: 'strict' } : undefined); } catch { reject(unavailable()); return; }
      tx.oncomplete = () => resolve(result);
      tx.onabort = () => reject(failure ?? unavailable());
      tx.onerror = () => { failure ??= unavailable(); };
      const fail = error => { failure = error instanceof BrowserDraftError ? error : unavailable(); try { tx.abort(); } catch { reject(failure); } };
      try { action(tx.objectStore(STORE), value => { result = value; }, fail); } catch (error) { fail(error); }
    });
  }
  async function read(binding) {
    const key = cacheKey(binding);
    return transaction('readonly', (store, finish, fail) => {
      const request = store.get(key);
      request.onerror = () => fail(unavailable());
      request.onsuccess = () => {
        try { if (request.result === undefined) { finish(null); return; } const row = validatedRow(request.result); if (!sameKey(row.key, key)) invalid(); finish(row.snapshot); }
        catch (error) { fail(error); }
      };
    });
  }
  function commit(updates, bindings) {
    return transaction('readwrite', (store, finish, fail) => {
      const request = store.getAll(undefined, DRAFT_LIMITS.actors + 1);
      request.onerror = () => fail(unavailable());
      request.onsuccess = () => {
        try { const plan = planDraftWrites(request.result, updates, { bindings }); for (const key of plan.deletions) store.delete(key); for (const row of plan.records) store.put(row); finish({ stored: true }); }
        catch (error) { fail(error); }
      };
    });
  }
  return Object.freeze({
    // Staged content is private and unverified: it may only enter WASM's pending
    // restore buffer. No UI/debug exposure before matching fresh PROFILE.
    stage: read,
    load(binding, options = {}) { return options.verified === true ? read(binding) : Promise.reject(new BrowserDraftError('verified')); },
    async save(binding, raw, options = {}) {
      if (options.verified !== true) throw new BrowserDraftError('verified');
      return commit([{ binding, snapshot: validateDraftSnapshot(binding, raw) }]);
    },
    async saveChanges(primary, raw, options = {}) {
      if (options.verified !== true) throw new BrowserDraftError('verified');
      const updates = verifiedUpdates(primary, raw, options.bindings);
      const snapshot = updates.find(item => sameKey(cacheKey(item.binding), cacheKey(primary))).snapshot;
      const paused = snapshot.operations.filter(op => op.phase === 'paused' && op.outcome === 'unknown' && !op.acknowledged);
      if (paused.length > 1) invalid();
      await commit(updates, options.bindings);
      return paused.length ? { revision: snapshot.revision, id: paused[0].id, draftId: paused[0].draftId, hash: paused[0].hash } : null;
    },
    async markSubmitting(binding, options = {}) {
      if (options.verified !== true) throw new BrowserDraftError('verified');
      const key = cacheKey(binding);
      return transaction('readwrite', (store, finish, fail) => {
        const request = store.get(key);
        request.onerror = () => fail(unavailable());
        request.onsuccess = () => {
          try {
            const row = validatedRow(request.result);
            if (!sameKey(row.key, key)) invalid();
            const pending = row.snapshot.operations.filter(op => op.phase === 'paused' && op.outcome === 'unknown' && !op.acknowledged);
            const expected = options.expected;
            if (pending.length !== 1 || !expected || row.snapshot.revision !== expected.revision || pending[0].id !== expected.id || pending[0].draftId !== expected.draftId || pending[0].hash !== expected.hash) throw new BrowserDraftError('conflict');
            pending[0].phase = 'submitted';
            row.byteLength = encodedSize(row.snapshot);
            store.put(row); finish();
          } catch (error) { fail(error); }
        };
      });
    },
    async savedDraftsSummary() {
      return transaction('readonly', (store, finish, fail) => {
        const request = store.getAll(undefined, DRAFT_LIMITS.actors + 1);
        request.onerror = () => fail(unavailable());
        request.onsuccess = () => {
          try {
            finish(planDraftCleanup(request.result, cleanupMarker()).summary);
          } catch (error) { fail(error); }
        };
      });
    },
    async clearKnownSavedDrafts(options = {}) {
      if (options.reviewed !== true) throw new BrowserDraftError('review');
      return transaction('readwrite', (store, finish, fail) => {
        const request = store.getAll(undefined, DRAFT_LIMITS.actors + 1);
        request.onerror = () => fail(unavailable());
        request.onsuccess = () => {
          try {
            const plan = planDraftCleanup(request.result, cleanupMarker());
            for (const key of plan.clearable) store.delete(key);
            finish({ clearedActors: plan.clearable.length, remainingProtected: plan.summary.protected, remainingUnreadable: plan.summary.unrestorable });
          } catch (error) { fail(error); }
        };
      });
    },
    close() { generation++; connection?.close(); connection = null; opening = null; },
  });
}
