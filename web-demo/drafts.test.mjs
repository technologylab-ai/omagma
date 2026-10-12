import test from 'node:test';
import assert from 'node:assert/strict';
import { BrowserDraftError, DRAFT_LIMITS, validateDraftSnapshot, planDraftWrite, planDraftWrites, planDraftCleanup, createBrowserDrafts } from './drafts.mjs';
const binding = { account: 'ada@example.test', clientId: 'synthetic.apps.googleusercontent.com', grantId: 'a'.repeat(64) };
const draft = { id: 'synthetic-draft', subject: 'Retained draft', bodyText: 'Unsaved until the atomic commit', bodyFormat: 'markdown', to: [{ address: 'peer@example.test', name: 'Peer' }], attachments: [{ id: 'file', filename: 'note.txt', mimeType: 'text/plain', size: 3, data: 'YWJj' }], original: { bodyHtml: '<img src="cid:logo"><p>Literal source</p>', resources: [{ id: 'logo', filename: 'logo.png', mimeType: 'image/png', size: 3, data: 'YWJj', contentId: 'logo' }] } };
const snapshot = (actor = binding, extra = {}) => ({ version: 1, revision: 1, ...actor, drafts: [structuredClone(draft)], operations: [], ...extra });
const code = expected => error => error instanceof BrowserDraftError && error.code === expected;
const op = extra => ({ id: 'synthetic-operation', draftId: draft.id, hash: 'b'.repeat(64), phase: 'paused', outcome: 'unknown', errorCode: '', acknowledged: false, ...extra });

test('draft snapshots preserve literal originals, files, formats, and raw unfinished fields', () => {
  const original = snapshot();
  original.drafts[0].recoveryFields = ['unfinished <address', '', '', 'A raw subject', '**Edited note**\n雪'];
  const restored = validateDraftSnapshot(binding, new TextEncoder().encode(JSON.stringify(original)));
  assert.deepEqual(restored, original);
  assert.equal(restored.drafts[0].original.resources[0].data, 'YWJj');
  original.drafts[0].recoveryFields[0] = 'x'.repeat(64 * 1024);
  original.drafts[0].recoveryFields[3] = 's'.repeat(16 * 1024 + 16);
  assert.deepEqual(validateDraftSnapshot(binding, original), original);
});

test('every binding component is exact and metadata or credentials have no schema fields', () => {
  for (const extra of [{ account: 'Ada@example.test' }, { clientId: 'other.apps.googleusercontent.com' }, { grantId: 'f'.repeat(64) }]) assert.throws(() => validateDraftSnapshot({ ...binding, ...extra }, snapshot()), code('invalid'));
  for (const path of [[], ['drafts', 0], ['drafts', 0, 'original'], ['drafts', 0, 'attachments', 0]]) {
    const value = snapshot();
    const target = path.reduce((object, field) => object[field], value);
    target.accessToken = 'synthetic-secret';
    assert.throws(() => validateDraftSnapshot(binding, value), code('invalid'));
  }
  const withBlob = snapshot(); withBlob.drafts[0].attachments[0].blobId = 'c'.repeat(64);
  assert.throws(() => validateDraftSnapshot(binding, withBlob), code('invalid'));
});

test('invalid UTF-8, raw fields, duplicates, binary sizes, and whole-draft bounds refuse admission', () => {
  assert.throws(() => validateDraftSnapshot(binding, new Uint8Array([0xff])), code('invalid'));
  for (const mutate of [
    value => { value.drafts.push(value.drafts[0]); },
    value => { value.drafts[0].recoveryFields = ['only one']; },
    value => { value.drafts[0].bodyText = '\ud800'; },
    value => { value.drafts[0].attachments[0].size = 2; },
    value => { value.operations = [op({ draftId: 'missing' })]; },
    value => { value.operations = [op(), op()]; },
  ]) { const value = snapshot(); mutate(value); assert.throws(() => validateDraftSnapshot(binding, value), code('invalid')); }
  assert.throws(() => validateDraftSnapshot(binding, snapshot(binding, { drafts: Array.from({ length: 9 }, (_, index) => ({ ...draft, id: `draft-${index}` })) })), code('invalid'));
  const combined = snapshot(); combined.drafts[0].bodyText = 'a'.repeat(1600000); combined.drafts[0].original.bodyHtml = 'b'.repeat(1600000);
  assert.throws(() => validateDraftSnapshot(binding, combined), code('limit'));
});

test('atomic plans preserve previous and other actors on quota, corruption and stale revisions', () => {
  const initial = planDraftWrite([], binding, snapshot()).record;
  const replacement = snapshot(binding, { revision: 2, drafts: [] });
  assert.equal(planDraftWrite([initial], binding, replacement).rows[0].snapshot.drafts.length, 0);
  assert.equal(initial.snapshot.drafts.length, 1);
  assert.throws(() => planDraftWrite([initial], binding, snapshot()), code('conflict'));
  const rows = ['ada', 'bea', 'cam'].map(name => {
    const actor = { ...binding, account: `${name}@example.test` };
    return planDraftWrite([], actor, snapshot(actor)).record;
  });
  const fourth = { ...binding, account: 'dee@example.test' };
  assert.throws(() => planDraftWrite(rows, fourth, snapshot(fourth)), code('limit'));
  const corrupted = { ...initial, byteLength: 1 };
  assert.throws(() => planDraftWrite([corrupted], binding, replacement), code('invalid'));
  assert.equal(corrupted.byteLength, 1);
  const quotaRows = ['ada', 'bea'].map(name => {
    const actor = { ...binding, account: `${name}@example.test` };
    return planDraftWrite([], actor, snapshot(actor, { drafts: [0, 1].map(index => ({ id: `draft-${index}`, bodyText: 'a'.repeat(2 * 1024 * 1024 - 100) })) })).record;
  });
  const three = { ...binding, account: 'cam@example.test' };
  assert.throws(() => planDraftWrite(quotaRows, three, snapshot(three, { drafts: [{ id: 'extra', bodyText: 'a'.repeat(1024) }] })), code('limit'));
});

test('submitted unknown records cannot regress to a countdown through a stale tab', () => {
  const initial = planDraftWrite([], binding, snapshot(binding, { operations: [op({ phase: 'submitted' })] })).record;
  const stale = snapshot(binding, { revision: 2, operations: [op({ outcome: 'rejected' })] });
  assert.throws(() => planDraftWrite([initial], binding, stale), code('conflict'));
  const acknowledged = snapshot(binding, { revision: 2, operations: [op({ phase: 'submitted', acknowledged: true })] });
  assert.equal(planDraftWrite([initial], binding, acknowledged).record.snapshot.operations[0].acknowledged, true);
});

// An independent transaction model implements atomic commit/abort and request
// turn boundaries, so async saves cannot claim success on put() alone.
function memoryDatabase(initial = []) {
  let rows = structuredClone(initial), failCommit = false;
  const db = {
    close() {},
    transaction(_name, mode, options) {
      assert(mode === 'readonly' || options.durability === 'strict');
      const tx = { oncomplete: null, onabort: null, onerror: null };
      let staged = structuredClone(rows), aborted = false, pending = 0, timer;
      const finish = () => {
        clearTimeout(timer); timer = setTimeout(() => {
          if (aborted || pending) return;
          if (mode === 'readwrite' && failCommit) { aborted = true; tx.onabort?.(); return; }
          if (mode === 'readwrite') rows = staged;
          tx.oncomplete?.();
        }, 0);
      };
      const request = action => { pending++; const result = {}; queueMicrotask(() => { if (aborted) return; try { result.result = action(); result.onsuccess?.(); } catch { result.onerror?.(); } finally { pending--; finish(); } }); return result; };
      const key = value => JSON.stringify(value);
      tx.abort = () => { aborted = true; clearTimeout(timer); queueMicrotask(() => tx.onabort?.()); };
      tx.objectStore = () => ({
        get: identity => request(() => structuredClone(staged.find(row => key(row.key) === key(identity)))),
        getAll: (_query, limit) => request(() => structuredClone(staged.slice(0, limit))),
        put: row => request(() => { staged = staged.filter(item => key(item.key) !== key(row.key)); staged.push(structuredClone(row)); }),
        delete: identity => request(() => { staged = staged.filter(item => key(item.key) !== key(identity)); }),
      });
      finish(); return tx;
    },
  };
  return { indexedDB: { open() { const request = {}; queueMicrotask(() => { request.result = db; request.onsuccess(); }); return request; } }, rows: () => structuredClone(rows), failCommit(value) { failCommit = value; } };
}

test('IndexedDB commit precedes success; failed save and discard keep the prior disk row', async () => {
  const memory = memoryDatabase(), store = createBrowserDrafts(memory);
  await assert.rejects(() => store.save(binding, snapshot()), code('verified'));
  await assert.rejects(() => store.load(binding), code('verified'));
  assert.equal(await store.stage(binding), null);
  await store.save(binding, snapshot(), { verified: true });
  assert.equal(memory.rows().length, 1);
  memory.failCommit(true);
  await assert.rejects(() => store.save(binding, snapshot(binding, { revision: 2, drafts: [] }), { verified: true }), code('unavailable'));
  assert.equal(memory.rows()[0].snapshot.drafts.length, 1);
  memory.failCommit(false);
  await store.save(binding, snapshot(binding, { revision: 2, drafts: [] }), { verified: true });
  assert.equal((await store.load(binding, { verified: true })).drafts.length, 0);
});

test('send boundary commit is durable, isolated and aborts without changing the paused recovery', async () => {
  const memory = memoryDatabase(), store = createBrowserDrafts(memory);
  await store.save(binding, snapshot(binding, { operations: [op()] }), { verified: true });
  memory.failCommit(true);
  await assert.rejects(() => store.markSubmitting(binding, { verified: true, expected: { revision: 1, id: op().id, draftId: op().draftId, hash: op().hash } }), code('unavailable'));
  assert.equal(memory.rows()[0].snapshot.operations[0].phase, 'paused');
  memory.failCommit(false);
  await store.markSubmitting(binding, { verified: true, expected: { revision: 1, id: op().id, draftId: op().draftId, hash: op().hash } });
  assert.equal((await store.stage(binding)).operations[0].phase, 'submitted');
  const other = { ...binding, grantId: 'c'.repeat(64) };
  await assert.rejects(() => store.markSubmitting(other, { verified: true }), code('invalid'));
  await assert.rejects(() => store.markSubmitting(binding, { verified: true, expected: { revision: 1, id: op().id, draftId: op().draftId, hash: op().hash } }), code('conflict'));
  await store.save(binding, snapshot(binding, { revision: 2, drafts: [], operations: [op({ phase: 'submitted', outcome: 'applied' })] }), { verified: true });
  assert.deepEqual((await store.stage(binding)).drafts, []);
});

test('storage open errors remain retryable and never erase data', async () => {
  let calls = 0;
  const store = createBrowserDrafts({ indexedDB: { open() { calls++; throw new Error('Synthetic unavailable'); } } });
  await assert.rejects(() => store.stage(binding), code('unavailable'));
  await assert.rejects(() => store.stage(binding), code('unavailable'));
  assert.equal(calls, 2);
  assert.equal(DRAFT_LIMITS.totalBytes, 8 * 1024 * 1024);
});

test('stale countdown identity cannot mark or submit a replacement operation from another tab', async () => {
  const memory = memoryDatabase(), store = createBrowserDrafts(memory);
  const expectedA = await store.saveChanges(binding, snapshot(binding, { operations: [op()] }), { verified: true, bindings: [binding] });
  const replacement = op({ id: 'new-tab-operation', hash: 'c'.repeat(64) });
  await store.save(binding, snapshot(binding, { revision: 2, operations: [op({ outcome: 'rejected', errorCode: 'SendPausedForReview' }), replacement] }), { verified: true });
  await assert.rejects(() => store.markSubmitting(binding, { verified: true, expected: expectedA }), code('conflict'));
  assert.equal((await store.stage(binding)).operations[1].phase, 'paused');
  assert.equal((await store.stage(binding)).revision, 2);
  for (const changed of [{ id: 'wrong' }, { draftId: 'wrong' }, { hash: 'd'.repeat(64) }, { revision: 1 }]) {
    await assert.rejects(() => store.markSubmitting(binding, { verified: true, expected: { revision: 2, id: replacement.id, draftId: replacement.draftId, hash: replacement.hash, ...changed } }), code('conflict'));
  }
});

test('settled receipt history rotates across exact verified actors in one transaction while unknowns stay protected', async () => {
  const memory = memoryDatabase(), store = createBrowserDrafts(memory);
  const other = { ...binding, account: 'bea@example.test' };
  const settled = Array.from({ length: 63 }, (_, index) => op({ id: `old-${index}`, phase: 'submitted', outcome: 'applied' }));
  const protectedOp = op({ id: 'uncertain-old', phase: 'submitted' });
  const previous = snapshot(binding, { operations: [...settled, protectedOp] });
  await store.save(binding, previous, { verified: true });
  const nextOther = snapshot(other, { operations: [op({ id: 'new-other' })] });
  const nextFirst = snapshot(binding, { revision: 2, operations: [...settled.slice(1), protectedOp] });
  const updates = { version: 1, updates: [nextOther, nextFirst] };
  await assert.rejects(() => store.saveChanges(other, updates, { verified: true, bindings: [other] }), code('verified'));
  assert.equal(memory.rows().length, 1);
  memory.failCommit(true);
  await assert.rejects(() => store.saveChanges(other, updates, { verified: true, bindings: [binding, other] }), code('unavailable'));
  assert.equal(memory.rows()[0].snapshot.operations.length, 64);
  memory.failCommit(false);
  const expected = await store.saveChanges(other, updates, { verified: true, bindings: [binding, other] });
  assert.equal(expected.id, 'new-other');
  assert.equal(memory.rows().reduce((sum, row) => sum + row.snapshot.operations.length, 0), 64);
  assert.equal((await store.stage(binding)).operations.at(-1).id, protectedOp.id);
  const illegal = snapshot(binding, { revision: 3, operations: settled.slice(1) });
  assert.throws(() => planDraftWrite(memory.rows(), binding, illegal), code('conflict'));
  const stalePair = { version: 1, updates: [snapshot(other, { revision: 2 }), nextFirst] };
  await assert.rejects(() => store.saveChanges(other, stalePair, { verified: true, bindings: [binding, other] }), code('conflict'));
  assert.equal((await store.stage(other)).operations.length, 1);
});

test('transport refuses stale durable countdown before any provider POST or generic send marker', async () => {
  const { SessionTransport } = await import('./transport.mjs');
  const { scopesFor } = await import('./credentials.mjs');
  const memoryDB = memoryDatabase(), store = createBrowserDrafts(memoryDB);
  const expected = await store.saveChanges(binding, snapshot(binding, { operations: [op()] }), { verified: true, bindings: [binding] });
  await store.save(binding, snapshot(binding, { revision: 2, operations: [op({ outcome: 'rejected' }), op({ id: 'replacement-op', hash: 'e'.repeat(64) })] }), { verified: true });
  const oldFetch = globalThis.fetch, oldTimer = globalThis.setTimeout;
  const oldStorage = Object.getOwnPropertyDescriptor(globalThis, 'localStorage');
  const markers = new Map();
  let posts = 0;
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: { getItem: key => markers.get(key) ?? null, setItem: (key, value) => markers.set(key, value), removeItem: key => markers.delete(key) } });
  globalThis.fetch = async (url, init) => {
    if (url === 'https://oauth2.googleapis.com/token') return new Response(JSON.stringify({ access_token: 'synthetic-access', expires_in: 3600, token_type: 'Bearer' }));
    if (init.method === 'POST') posts++;
    return new Response('{}');
  };
  const memory = new WebAssembly.Memory({ initial: 64 });
  const transport = new SessionTransport(() => memory, () => {}, () => {}, () => store.markSubmitting(binding, { verified: true, expected }));
  try {
    const capabilities = ['mail-read', 'mail-send'];
    const [metadata] = await transport.prepare([{ ...binding, capabilities, scopes: scopesFor(capabilities), refreshToken: 'synthetic-refresh', clientSecret: 'synthetic-secret' }]);
    globalThis.setTimeout = (callback, delay, ...args) => oldTimer(callback, delay === 10000 ? 0 : delay, ...args);
    const encode = (offset, value) => { const bytes = new TextEncoder().encode(value); new Uint8Array(memory.buffer, offset, bytes.length).set(bytes); return bytes.length; };
    const method = encode(128, 'POST'), url = encode(256, 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send'), body = encode(1024, '{"raw":"synthetic"}');
    transport.beginJob();
    assert.equal(await transport.wasmRequest(metadata.session, 128, method, 256, url, 1024, body, 16384, 3 * 1024 * 1024, 8), 3);
    assert.equal(posts, 0);
    assert.equal(markers.size, 0);
    assert.equal((await store.stage(binding)).operations[1].phase, 'paused');
  } finally {
    transport.close(); globalThis.fetch = oldFetch; globalThis.setTimeout = oldTimer;
    if (oldStorage) Object.defineProperty(globalThis, 'localStorage', oldStorage); else delete globalThis.localStorage;
  }
});

test('proven local cancellation after durable boundary retains an editable rejection without a provider POST', async () => {
  const { SessionTransport } = await import('./transport.mjs');
  const { scopesFor } = await import('./credentials.mjs');
  const memoryDB = memoryDatabase(), store = createBrowserDrafts(memoryDB);
  const expected = await store.saveChanges(binding, snapshot(binding, { operations: [op()] }), { verified: true, bindings: [binding] });
  const oldFetch = globalThis.fetch, oldTimer = globalThis.setTimeout;
  const oldStorage = Object.getOwnPropertyDescriptor(globalThis, 'localStorage');
  let posts = 0;
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: { getItem: () => null, setItem() { throw new Error('Synthetic localStorage failure'); }, removeItem() {} } });
  globalThis.fetch = async (url, init) => {
    if (url === 'https://oauth2.googleapis.com/token') return new Response(JSON.stringify({ access_token: 'synthetic-access', expires_in: 3600, token_type: 'Bearer' }));
    if (init.method === 'POST') posts++;
    return new Response('{}');
  };
  const memory = new WebAssembly.Memory({ initial: 64 });
  const transport = new SessionTransport(() => memory, () => {}, () => {}, () => store.markSubmitting(binding, { verified: true, expected }));
  try {
    const capabilities = ['mail-read', 'mail-send'];
    const [metadata] = await transport.prepare([{ ...binding, capabilities, scopes: scopesFor(capabilities), refreshToken: 'synthetic-refresh', clientSecret: 'synthetic-secret' }]);
    globalThis.setTimeout = (callback, delay, ...args) => oldTimer(callback, delay === 10000 ? 0 : delay, ...args);
    const encode = (offset, value) => { const bytes = new TextEncoder().encode(value); new Uint8Array(memory.buffer, offset, bytes.length).set(bytes); return bytes.length; };
    const method = encode(128, 'POST'), url = encode(256, 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send'), body = encode(1024, '{"raw":"synthetic"}');
    transport.beginJob();
    assert.equal(await transport.wasmRequest(metadata.session, 128, method, 256, url, 1024, body, 16384, 3 * 1024 * 1024, 8), 5);
    assert.equal(posts, 0);
    assert.equal((await store.stage(binding)).operations[0].phase, 'submitted');
    // The provider's definite-no-POST receipt keeps phase monotonic while the
    // outcome, rather than the boundary name, establishes an editable draft.
    await store.save(binding, snapshot(binding, { revision: 2, operations: [op({ phase: 'submitted', outcome: 'rejected', errorCode: 'SendCanceledBeforeSubmission' })] }), { verified: true });
    assert.equal((await store.stage(binding)).operations[0].outcome, 'rejected');
    assert.equal((await store.stage(binding)).drafts.length, 1);
  } finally {
    transport.close(); globalThis.fetch = oldFetch; globalThis.setTimeout = oldTimer;
    if (oldStorage) Object.defineProperty(globalThis, 'localStorage', oldStorage); else delete globalThis.localStorage;
  }
});


test('global receipt quota reports its cause while a disconnected actor remains unchanged', async () => {
  const memory = memoryDatabase(), store = createBrowserDrafts(memory);
  const other = { ...binding, account: 'disconnected@example.test' };
  const settled = (count, prefix) => Array.from({ length: count }, (_, index) => op({ id: `${prefix}-${index}`, draftId: `old-${index}`, phase: 'submitted', outcome: 'applied' }));
  const oldA = settled(39, 'a'), oldB = settled(23, 'b');
  const protectedA = op({ id: 'protected-a', phase: 'submitted' }), protectedB = op({ id: 'protected-b', phase: 'submitted' });
  await store.save(binding, snapshot(binding, { operations: [...oldA, protectedA] }), { verified: true });
  await store.save(other, snapshot(other, { operations: [...oldB, protectedB] }), { verified: true });
  const before = memory.rows(), pending = op({ id: 'next-a' });
  await assert.rejects(() => store.saveChanges(binding, snapshot(binding, { revision: 2, operations: [...oldA, protectedA, pending] }), { verified: true, bindings: [binding] }), code('operations'));
  assert.deepEqual(memory.rows(), before);
  const expected = await store.saveChanges(binding, snapshot(binding, { revision: 2, operations: [...oldA.slice(1), protectedA, pending] }), { verified: true, bindings: [binding] });
  assert.equal(expected.id, pending.id);
  assert.deepEqual(memory.rows().find(row => row.key[0] === other.account), before.find(row => row.key[0] === other.account));
  assert.equal(memory.rows().reduce((sum, row) => sum + row.snapshot.operations.length, 0), 64);
  assert.equal((await store.load(binding, { verified: true })).operations.find(op => op.id === protectedA.id).acknowledged, false);
});

test('superseded empty settled rows free a grant slot atomically without pruning protected or active drafts', async () => {
  const actors = [binding, { ...binding, grantId: 'c'.repeat(64) }, { ...binding, account: 'retained@example.test' }];
  const empty = snapshot(binding, { drafts: [], operations: [op({ phase: 'submitted', outcome: 'applied' })] });
  const protectedOld = snapshot(actors[1], { operations: [op({ phase: 'submitted' })] });
  const rows = [planDraftWrite([], actors[0], empty).record, planDraftWrite([], actors[1], protectedOld).record, planDraftWrite([], actors[2], snapshot(actors[2])).record];
  const memory = memoryDatabase(rows), store = createBrowserDrafts(memory);
  const nextGrant = { ...binding, grantId: 'd'.repeat(64) };
  memory.failCommit(true);
  await assert.rejects(() => store.save(nextGrant, snapshot(nextGrant), { verified: true }), code('unavailable'));
  assert.deepEqual(memory.rows(), rows);
  memory.failCommit(false);
  await store.save(nextGrant, snapshot(nextGrant), { verified: true });
  assert.equal(memory.rows().length, 3);
  assert.equal(await store.stage(binding), null);
  assert.deepEqual(await store.stage(actors[1]), protectedOld);
  assert.deepEqual(await store.stage(actors[2]), snapshot(actors[2]));
  await assert.rejects(() => store.save(binding, { ...empty, revision: 2 }, { verified: true }), code('conflict'));
});

test('another actor damaged row stays intact without poisoning a healthy save and still counts toward quotas', async () => {
  const other = { ...binding, account: 'damaged@example.test' };
  const good = planDraftWrite([], binding, snapshot()).record;
  const damaged = planDraftWrite([], other, snapshot(other, { operations: [op({ phase: 'submitted' })] })).record;
  damaged.snapshot.drafts = []; // Missing protected recovery must never be overwritten or cleared.
  const memory = memoryDatabase([good, damaged]), store = createBrowserDrafts(memory);
  await store.save(binding, snapshot(binding, { revision: 2 }), { verified: true });
  assert.deepEqual(memory.rows().find(row => row.key[0] === other.account), damaged);
  await assert.rejects(() => store.load(other, { verified: true }), code('invalid'));
  await assert.rejects(() => store.save(other, snapshot(other, { revision: 2 }), { verified: true }), code('invalid'));
  const reserved = { ...damaged, draftBytes: DRAFT_LIMITS.totalBytes };
  assert.throws(() => planDraftWrite([good, reserved], binding, snapshot(binding, { revision: 2 })), code('limit'));
  const receiptReservation = structuredClone(damaged);
  receiptReservation.snapshot.operations = Array.from({ length: 64 }, (_, index) => op({ id: `unknown-${index}`, phase: 'submitted' }));
  assert.throws(() => planDraftWrite([good, receiptReservation], binding, snapshot(binding, { revision: 2, operations: [op()] })), code('operations'));
  const summary = await store.savedDraftsSummary();
  assert.deepEqual(summary, { actors: 2, drafts: 1, protected: 0, unrestorable: 1, clearableActors: 1, clearableDrafts: 1 });
  const rawKeys = Object.keys(summary);
  assert(!rawKeys.includes('bodyText') && !rawKeys.includes('accounts'));
});

test('reviewed cleanup deletes only whole eligible rows and rechecks protected receipts atomically', async () => {
  const ordinary = planDraftWrite([], binding, snapshot()).record;
  const protectedActor = { ...binding, account: 'protected@example.test' };
  const protectedRow = planDraftWrite([], protectedActor, snapshot(protectedActor, { operations: [op({ phase: 'submitted' })] })).record;
  const damagedActor = { ...binding, account: 'unreadable@example.test' };
  const damaged = planDraftWrite([], damagedActor, snapshot(damagedActor)).record;
  damaged.byteLength = 0;
  const memory = memoryDatabase([ordinary, protectedRow, damaged]), store = createBrowserDrafts(memory);
  await assert.rejects(() => store.clearKnownSavedDrafts(), code('review'));
  assert.deepEqual(await store.savedDraftsSummary(), { actors: 3, drafts: 2, protected: 1, unrestorable: 1, clearableActors: 1, clearableDrafts: 1 });
  memory.failCommit(true);
  await assert.rejects(() => store.clearKnownSavedDrafts({ reviewed: true }), code('unavailable'));
  assert.equal(memory.rows().length, 3);
  memory.failCommit(false);
  assert.deepEqual(await store.clearKnownSavedDrafts({ reviewed: true }), { clearedActors: 1, remainingProtected: 1, remainingUnreadable: 1 });
  assert.deepEqual(memory.rows(), [protectedRow, damaged]);
  const appliedWithRecovery = planDraftWrite([], binding, snapshot(binding, { operations: [op({ phase: 'submitted', outcome: 'applied' })] })).record;
  const unconsumedStore = createBrowserDrafts(memoryDatabase([appliedWithRecovery]));
  assert.equal((await unconsumedStore.savedDraftsSummary()).clearableActors, 0);
  assert.deepEqual(await unconsumedStore.clearKnownSavedDrafts({ reviewed: true }), { clearedActors: 0, remainingProtected: 1, remainingUnreadable: 0 });
  // Review is a summary only. A send begun after review must be rechecked by
  // the final transaction and retained, never deleted from stale UI counts.
  const changedMemory = memoryDatabase([ordinary]), changedStore = createBrowserDrafts(changedMemory);
  assert.equal((await changedStore.savedDraftsSummary()).clearableActors, 1);
  await changedStore.save(binding, snapshot(binding, { revision: 2, operations: [op()] }), { verified: true });
  assert.deepEqual(await changedStore.clearKnownSavedDrafts({ reviewed: true }), { clearedActors: 0, remainingProtected: 1, remainingUnreadable: 0 });
  assert.equal(changedMemory.rows().length, 1);
});


test('an inactive empty settled history releases the global receipt budget for a new actor', async () => {
  const other = { ...binding, account: 'inactive@example.test' };
  const history = Array.from({ length: 64 }, (_, index) => op({ id: `old-${index}`, draftId: `sent-${index}`, phase: 'submitted', outcome: 'applied' }));
  const inactive = planDraftWrite([], other, snapshot(other, { drafts: [], operations: history })).record;
  const memory = memoryDatabase([inactive]), store = createBrowserDrafts(memory);
  const pending = snapshot(binding, { operations: [op()] });
  // A row already loaded into this WASM must be retired by a coordinated
  // provider snapshot, not silently deleted behind its native revision.
  await assert.rejects(() => store.saveChanges(binding, pending, { verified: true, bindings: [binding, other] }), code('operations'));
  assert.deepEqual(memory.rows(), [inactive]);
  memory.failCommit(true);
  await assert.rejects(() => store.saveChanges(binding, pending, { verified: true, bindings: [binding] }), code('unavailable'));
  assert.deepEqual(memory.rows(), [inactive]);
  memory.failCommit(false);
  const expected = await store.saveChanges(binding, pending, { verified: true, bindings: [binding] });
  assert.equal(expected.id, op().id);
  assert.equal(memory.rows().length, 1);
  assert.deepEqual(await store.stage(binding), pending);
  assert.equal(await store.stage(other), null);
  const protectedOld = planDraftWrite([], other, snapshot(other, { operations: [...history.slice(1), op({ id: 'protected-old', phase: 'submitted' })] })).record;
  assert.throws(() => planDraftWrite([protectedOld], binding, pending), code('operations'));
  const ordinaryDraft = planDraftWrite([], other, snapshot(other, { operations: history })).record;
  assert.throws(() => planDraftWrite([ordinaryDraft], binding, pending), code('operations'));
});


test('cleanup preserves matching unconsumed rejections and unattributed submitted recoveries', () => {
  const other = { ...binding, account: 'other@example.test' };
  const rejectedA = planDraftWrite([], binding, snapshot(binding, { operations: [op({ id: 'operation-a', phase: 'submitted', outcome: 'rejected' })] })).record;
  const rejectedB = planDraftWrite([], other, snapshot(other, { operations: [op({ id: 'operation-b', phase: 'submitted', outcome: 'rejected' })] })).record;
  assert.equal(planDraftCleanup([rejectedA, rejectedB]).summary.clearableActors, 2);
  const pinned = planDraftCleanup([rejectedA, rejectedB], { protectedOperationId: 'operation-b' });
  assert.deepEqual(pinned.clearable, [rejectedA.key]);
  assert.equal(pinned.summary.protected, 1);
  for (const protectedOperationId of [null, 'legacy-unattributed-marker']) {
    assert.equal(planDraftCleanup([rejectedA, rejectedB], { protectedOperationId }).summary.clearableActors, 0);
  }
  const ordinary = planDraftWrite([], other, snapshot(other)).record;
  assert.deepEqual(planDraftCleanup([rejectedA, ordinary], { protectedOperationId: null }).clearable, [ordinary.key]);
  // The exact id pins a whole row even if its draft was already removed.
  const withoutRecovery = planDraftWrite([], binding, snapshot(binding, { drafts: [], operations: [op({ id: 'operation-a', phase: 'submitted', outcome: 'rejected' })] })).record;
  assert.equal(planDraftCleanup([withoutRecovery], { protectedOperationId: 'operation-a' }).summary.clearableActors, 0);
});

test('cleanup rereads the global pending-send identity inside the final transaction after review', async () => {
  const oldStorage = Object.getOwnPropertyDescriptor(globalThis, 'localStorage');
  const key = 'omagma-browser-pending-send-v1', markers = new Map();
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: { getItem: key => markers.get(key) ?? null, setItem: (key, value) => markers.set(key, value), removeItem: key => markers.delete(key) } });
  const operation = 'browser-12345678-1234-4234-8234-123456789abc-42';
  const other = { ...binding, account: 'sending@example.test' };
  const ordinary = planDraftWrite([], binding, snapshot()).record;
  const unconsumed = planDraftWrite([], other, snapshot(other, { operations: [op({ id: operation, phase: 'submitted', outcome: 'rejected', errorCode: 'InvalidRequest' })] })).record;
  const memory = memoryDatabase([ordinary, unconsumed]), store = createBrowserDrafts(memory);
  try {
    assert.equal((await store.savedDraftsSummary()).clearableActors, 2);
    const deleting = store.clearKnownSavedDrafts({ reviewed: true });
    // Another tab's known rejection still has an outstanding UI consumer.
    // This marker appears after the call started, before its IDB recheck.
    markers.set(key, JSON.stringify({ id: operation, startedAt: Date.now() }));
    assert.deepEqual(await deleting, { clearedActors: 1, remainingProtected: 1, remainingUnreadable: 0 });
    assert.deepEqual(memory.rows(), [unconsumed]);
    assert.equal((await store.savedDraftsSummary()).clearableActors, 0);
    for (const raw of ['not-json', JSON.stringify({ id: 'invalid-private-text', startedAt: 1 }), JSON.stringify({ id: '12345678-1234-4234-8234-123456789abc', startedAt: 1 })]) {
      markers.set(key, raw);
      assert.equal((await store.savedDraftsSummary()).clearableActors, 0);
      assert.deepEqual(await store.clearKnownSavedDrafts({ reviewed: true }), { clearedActors: 0, remainingProtected: 1, remainingUnreadable: 0 });
    }
    markers.delete(key);
    assert.deepEqual(await store.clearKnownSavedDrafts({ reviewed: true }), { clearedActors: 1, remainingProtected: 0, remainingUnreadable: 0 });
    assert.equal(memory.rows().length, 0);
  } finally {
    store.close();
    if (oldStorage) Object.defineProperty(globalThis, 'localStorage', oldStorage); else delete globalThis.localStorage;
  }
});
