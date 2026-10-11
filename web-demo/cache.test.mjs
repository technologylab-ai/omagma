import assert from 'node:assert/strict';
import test from 'node:test';
import { CACHE_LIMITS, BrowserCacheError, cacheKey, validateCacheSnapshot, scopeCacheSnapshot, planCacheWrite, createBrowserCache } from './cache.mjs';

const binding = { account: 'ada@example.test', clientId: 'synthetic.apps.googleusercontent.com', grantId: 'a'.repeat(64) };
const message = { id: 'mail-1', threadId: 'thread-1', subject: 'Synthetic cached mail', bodyText: 'A literal cached body.', bodyCached: true };
const contact = { resourceName: 'people/c1', etag: 'synthetic-etag', name: 'Morgan', emails: [{ address: 'morgan@example.test', name: 'Morgan' }] };
function snapshot(actor = binding, overrides = {}) { return { version: 1, ...actor, updatedAt: 1791730000000, messages: [structuredClone(message)], contacts: [structuredClone(contact)], contactsLoaded: true, ...overrides }; }
function stored(actor, size = 0, savedAt = 1) {
  const data = snapshot(actor, { messages: [{ ...message, bodyText: 'x'.repeat(size), bodyHtml: size ? 'h'.repeat(Math.floor(size / 2)) : null }] });
  return planCacheWrite([], actor, data, savedAt).record;
}
function code(expected) { return error => error instanceof BrowserCacheError && error.code === expected; }

test('snapshot binding requires every exact actor and grant component', () => {
  assert.deepEqual(cacheKey(binding), [binding.account, binding.clientId, binding.grantId]);
  for (const changed of [{ account: 'bea@example.test' }, { clientId: 'other.apps.googleusercontent.com' }, { grantId: 'b'.repeat(64) }, { account: 'Ada@example.test' }]) assert.throws(() => validateCacheSnapshot({ ...binding, ...changed }, snapshot()), code('invalid'));
  assert.throws(() => cacheKey({ ...binding, account: 'ada@other@example.test' }), code('invalid'));
});

test('canonical mail bodies, passive HTML and attachment metadata survive validation', () => {
  const data = snapshot();
  data.messages[0].bodyHtml = '<p>Literal <b>markup</b><img src="https://remote.invalid/image"></p>';
  data.messages[0].attachments = [{ id: 'attachment-1', filename: 'report.pdf', mimeType: 'application/pdf', size: 12, contentId: null, disposition: 'attachment' }];
  const result = validateCacheSnapshot(binding, data);
  assert.equal(result.messages[0].bodyHtml, data.messages[0].bodyHtml);
  assert.equal(result.messages[0].bodyText, message.bodyText);
  assert.equal(result.contacts[0].emails[0].address, contact.emails[0].address);
  assert.equal(result.messages[0].attachments[0].filename, 'report.pdf');
});

test('passive HTML preserves RTL formatting and controls but requires valid bounded UTF-8', () => {
  const bodyHtml = '<p dir="rtl">\u200fשלום\u202e\u2066\u2069\u202c</p>\u0000\x1b[31m<img src="https://remote.invalid/image">';
  const data = snapshot(binding, { messages: [{ ...message, bodyHtml }] });
  assert.equal(validateCacheSnapshot(binding, data).messages[0].bodyHtml, bodyHtml);
  assert.equal(validateCacheSnapshot(binding, new TextEncoder().encode(JSON.stringify(data))).messages[0].bodyHtml, bodyHtml);
  assert.throws(() => validateCacheSnapshot(binding, snapshot(binding, { messages: [{ ...message, bodyHtml: '\ud800' }] })), code('invalid'));
  assert.throws(() => validateCacheSnapshot(binding, new Uint8Array([0xff])), code('invalid'));
  assert.throws(() => validateCacheSnapshot(binding, snapshot(binding, { messages: [{ ...message, bodyHtml: 'x'.repeat(2 * 1024 * 1024 + 1) }] })), code('invalid'));
});

test('current inventory holds up to 300 distinct messages and 49 attachment metadata entries', () => {
  const messages = Array.from({ length: 300 }, (_, index) => ({ ...message, id: `mail-${index}` }));
  messages[0].attachments = Array.from({ length: 49 }, (_, index) => ({ id: `attachment-${index}`, filename: `inline-${index}.png`, mimeType: 'image/png', size: 12 }));
  const result = validateCacheSnapshot(binding, snapshot(binding, { messages }));
  assert.equal(result.messages.length, CACHE_LIMITS.messages);
  assert.equal(result.messages[0].attachments.length, CACHE_LIMITS.attachments);
  messages[0].attachments.push({ id: 'attachment-50', filename: 'last.png', mimeType: 'image/png', size: 12 });
  assert.throws(() => validateCacheSnapshot(binding, snapshot(binding, { messages })), code('invalid'));
});

test('cached contacts require an explicit current granted flag while mail stays available', () => {
  const data = snapshot();
  for (const contactsGranted of [undefined, false, 'true']) {
    const result = scopeCacheSnapshot(binding, data, { contactsGranted });
    assert.deepEqual(result.contacts, []);
    assert.equal(result.contactsLoaded, false);
    assert.equal(result.messages[0].bodyText, message.bodyText);
  }
  assert.equal(scopeCacheSnapshot(binding, data, { contactsGranted: true }).contacts[0].name, 'Morgan');
  assert.equal(data.contacts.length, 1);
});

test('canonical native name and label limits remain cacheable', () => {
  const data = snapshot();
  data.messages[0].from = { address: 'morgan@example.test', name: 'm'.repeat(4096) };
  data.messages[0].labels = ['l'.repeat(256)];
  data.contacts[0].name = 'c'.repeat(4096);
  data.contacts[0].emails = Array.from({ length: 33 }, (_, index) => ({ address: `morgan${index}@example.test`, name: 'n'.repeat(4096) }));
  const result = validateCacheSnapshot(binding, data);
  assert.equal(result.messages[0].from.name.length, 4096);
  assert.equal(result.messages[0].labels[0].length, 256);
  assert.equal(result.contacts[0].emails.length, 33);
});

test('credentials, paths, provider JSON, sessions and send state have no cache fields', () => {
  for (const key of ['refreshToken', 'access_token', 'clientSecret', 'session', 'nonce', 'path', 'drafts', 'operationId']) assert.throws(() => validateCacheSnapshot(binding, { ...snapshot(), [key]: 'synthetic-private' }), code('invalid'));
  for (const key of ['provider', 'fixtureRaw', 'invitation', 'path']) {
    const data = snapshot(); data.messages[0][key] = null;
    assert.throws(() => validateCacheSnapshot(binding, data), code('invalid'));
  }
  const data = snapshot(); data.contacts[0].provider = { metadata: 'synthetic' };
  assert.throws(() => validateCacheSnapshot(binding, data), code('invalid'));
  data.contacts[0] = structuredClone(contact);
  data.messages[0].attachments = [{ id: 'attachment-1', filename: 'report.pdf', mimeType: 'application/pdf', size: 12, data: 'synthetic-raw' }];
  assert.throws(() => validateCacheSnapshot(binding, data), code('invalid'));
  data.messages[0].attachments = [{ id: 'attachment-1', filename: '../private.pdf', mimeType: 'application/pdf', size: 12 }];
  assert.throws(() => validateCacheSnapshot(binding, data), code('invalid'));
});

test('row, contact, duplicate and literal-control bounds reject malformed snapshots', () => {
  assert.throws(() => validateCacheSnapshot(binding, snapshot(binding, { messages: Array.from({ length: 301 }, (_, index) => ({ ...message, id: `mail-${index}` })) })), code('invalid'));
  assert.throws(() => validateCacheSnapshot(binding, snapshot(binding, { contacts: Array.from({ length: 101 }, (_, index) => ({ ...contact, resourceName: `people/c${index}` })) })), code('invalid'));
  assert.throws(() => validateCacheSnapshot(binding, snapshot(binding, { messages: [message, message] })), code('invalid'));
  assert.throws(() => validateCacheSnapshot(binding, snapshot(binding, { contactsLoaded: false })), code('invalid'));
  for (const bodyText of ['ESC\x1b[31m', 'NUL\0', 'Bidi\u202e']) assert.throws(() => validateCacheSnapshot(binding, snapshot(binding, { messages: [{ ...message, bodyText }] })), code('invalid'));
});

test('each current snapshot replaces the prior rows and cached bodies without history', () => {
  const previous = stored(binding);
  const next = snapshot(binding, { messages: [{ ...message, id: 'mail-new', bodyText: 'New current body.' }] });
  const plan = planCacheWrite([previous], binding, next, 2);
  assert.equal(plan.rows.length, 1);
  assert.equal(plan.record.snapshot.messages.length, 1);
  assert.equal(plan.record.snapshot.messages[0].id, 'mail-new');
  assert.equal(JSON.stringify(plan.rows).includes(message.bodyText), false);
});

test('fourth actor and total quota evict the oldest other current snapshot', () => {
  const actors = ['ada', 'bea', 'cam', 'dee'].map(name => ({ ...binding, account: `${name}@example.test` }));
  const rows = actors.slice(0, 3).map((actor, index) => stored(actor, 0, index + 1));
  const plan = planCacheWrite(rows, actors[3], snapshot(actors[3]), 4);
  assert.equal(plan.rows.length, CACHE_LIMITS.accounts);
  assert.deepEqual(plan.remove, [cacheKey(actors[0])]);
  const almostThreeMiB = 1950000;
  const large = actors.slice(0, 2).map((actor, index) => stored(actor, almostThreeMiB, index + 1));
  const total = planCacheWrite(large, actors[2], snapshot(actors[2], { messages: [{ ...message, bodyText: 'x'.repeat(almostThreeMiB), bodyHtml: 'h'.repeat(Math.floor(almostThreeMiB / 2)) }] }), 3);
  assert(total.bytes <= CACHE_LIMITS.totalBytes);
  assert.equal(total.rows.length, 2);
  assert.deepEqual(total.remove, [cacheKey(actors[0])]);
});

test('per-snapshot quota rejects oversized bodies before persistence', () => {
  const data = snapshot(binding, { messages: [{ ...message, bodyText: 'x'.repeat(2 * 1024 * 1024), bodyHtml: 'h'.repeat(2 * 1024 * 1024) }] });
  assert.throws(() => planCacheWrite([], binding, data), code('limit'));
});

test('cache APIs require verification for loaded views and never fall back to network', async () => {
  const cache = createBrowserCache({ indexedDB: undefined });
  await assert.rejects(() => cache.load(binding), code('verified'));
  await assert.rejects(() => cache.save(binding, snapshot()), code('verified'));
  await assert.rejects(() => cache.stage(binding, { contactsGranted: true }), code('unavailable'));
  await assert.rejects(() => cache.clear(binding), code('unavailable'));
  cache.close();
});

test('temporary IndexedDB open failures allow a later attempt', async () => {
  let attempts = 0;
  const cache = createBrowserCache({ indexedDB: { open() { attempts++; throw new Error('Synthetic open failure'); } } });
  await assert.rejects(() => cache.stage(binding), code('unavailable'));
  await assert.rejects(() => cache.stage(binding), code('unavailable'));
  assert.equal(attempts, 2);
});

test('closing during IndexedDB opening closes the late connection', async () => {
  const request = {};
  let closed = 0;
  const cache = createBrowserCache({ indexedDB: { open() { return request; } } });
  const pending = cache.stage(binding);
  cache.close();
  request.result = { close() { closed++; } };
  request.onsuccess();
  await assert.rejects(() => pending, code('unavailable'));
  assert.equal(closed, 1);
});

test('invalid stored rows are discarded by the transaction plan', () => {
  const malformed = { ...stored(binding), clientSecret: 'synthetic-private' };
  const other = { ...binding, account: 'bea@example.test' };
  const plan = planCacheWrite([malformed], other, snapshot(other), 2);
  assert.equal(plan.rows.length, 1);
  assert.deepEqual(plan.remove, [cacheKey(binding)]);
  assert.equal(JSON.stringify(plan.rows).includes('synthetic-private'), false);
});
