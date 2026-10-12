import assert from 'node:assert/strict';
import test from 'node:test';
import { CACHE_LIMITS, BrowserCacheError, cacheKey, validateMailPolicy, validateCacheSnapshot as validateSnapshot, scopeCacheSnapshot as scopeSnapshot, planCacheWrite as planWrite, createBrowserCache as createCache } from './cache.mjs';
import { decoderRevisionFixture, mailPolicyFixture as mailPolicy } from './mail-policy.fixture.mjs';

const validateCacheSnapshot = (binding, raw) => validateSnapshot(binding, raw, { mailPolicy });
const scopeCacheSnapshot = (binding, raw, options) => scopeSnapshot(binding, raw, { ...options, mailPolicy });
const planCacheWrite = (rows, binding, raw, savedAt) => planWrite(rows, binding, raw, savedAt, { mailPolicy });
const createBrowserCache = options => createCache({ ...options, mailPolicy });

const binding = { account: 'ada@example.test', clientId: 'synthetic.apps.googleusercontent.com', grantId: 'a'.repeat(64) };
const message = { id: 'mail-1', threadId: 'thread-1', subject: 'Synthetic cached mail', bodyText: 'A literal cached body.', bodyCached: true };
const contact = { resourceName: 'people/c1', etag: 'synthetic-etag', name: 'Morgan', emails: [{ address: 'morgan@example.test', name: 'Morgan' }] };
function snapshot(actor = binding, overrides = {}) { return { version: 1, decoderRevision: decoderRevisionFixture, ...actor, updatedAt: 1791730000000, messages: [structuredClone(message)], contacts: [structuredClone(contact)], contactsLoaded: true, ...overrides }; }
function stored(actor, size = 0, savedAt = 1) {
  const data = snapshot(actor, { messages: [{ ...message, bodyText: 'x'.repeat(size), bodyHtml: size ? 'h'.repeat(Math.floor(size / 2)) : null }] });
  return planCacheWrite([], actor, data, savedAt).record;
}
function code(expected) { return error => error instanceof BrowserCacheError && error.code === expected; }

// Literal transport DTO, kept independent of the JavaScript normalizer. WASM
// emits every warning count even for a mail-only or complete contact snapshot.
const wasmSnapshot = `{"version":1,"decoderRevision":4,"account":"ada@example.test","clientId":"synthetic.apps.googleusercontent.com","grantId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","updatedAt":1791730000000,"messages":[{"id":"mail-1","threadId":"thread-1","from":{"address":"morgan@example.test","name":"Morgan"},"replyTo":[],"to":[],"cc":[],"subject":"Synthetic cached mail","snippet":"","bodyText":"A literal cached body.","bodyHtml":null,"bodyHtmlAmbiguous":false,"bodySource":"plain","messageId":"","references":"","inReplyTo":"","labels":["INBOX"],"receivedAt":0,"sentDate":null,"unread":false,"bodyCached":true,"bodyCacheError":"","decodeWarning":"","metadataPartial":false,"labelsVerified":true,"attachments":[]}],"contacts":[{"resourceName":"people/c1","etag":"synthetic-etag","name":"Morgan","emails":[{"address":"morgan@example.test","name":""}],"readWarnings":{"omittedContacts":0,"partialContacts":0,"omittedEmails":0,"omittedNames":0,"sanitizedNames":0,"omittedMetadata":0,"invalidFields":0}}],"contactsLoaded":true,"contactWarnings":{"omittedContacts":0,"partialContacts":0,"omittedEmails":0,"omittedNames":0,"sanitizedNames":0,"omittedMetadata":0,"invalidFields":0}}`;
const zeroContactWarnings = { omittedContacts: 0, partialContacts: 0, omittedEmails: 0, omittedNames: 0, sanitizedNames: 0, omittedMetadata: 0, invalidFields: 0 };

function memoryCacheDatabase() {
  let rows = [];
  const database = {
    close() {},
    transaction() {
      let staged = structuredClone(rows), pending = 0, aborted = false, timer;
      const tx = {};
      const finish = () => {
        clearTimeout(timer);
        timer = setTimeout(() => { if (!aborted && pending === 0) { rows = staged; tx.oncomplete?.(); } }, 0);
      };
      const request = action => {
        pending++;
        const result = {};
        queueMicrotask(() => {
          if (aborted) return;
          try { result.result = action(); result.onsuccess?.(); }
          catch { result.onerror?.(); }
          finally { pending--; finish(); }
        });
        return result;
      };
      const key = value => JSON.stringify(value);
      tx.abort = () => { aborted = true; clearTimeout(timer); queueMicrotask(() => tx.onabort?.()); };
      tx.objectStore = () => ({
        get: identity => request(() => structuredClone(staged.find(row => key(row.key) === key(identity)))),
        getAll: (_query, limit) => request(() => structuredClone(staged.slice(0, limit))),
        put: row => request(() => { staged = staged.filter(item => key(item.key) !== key(row.key)); staged.push(structuredClone(row)); }),
        delete: identity => request(() => { staged = staged.filter(row => key(row.key) !== key(identity)); }),
        clear: () => request(() => { staged = []; }),
      });
      finish();
      return tx;
    },
  };
  return { indexedDB: { open() { const request = {}; queueMicrotask(() => { request.result = database; request.onsuccess(); }); return request; } }, rows: () => structuredClone(rows) };
}

test('literal WASM cache snapshots retain zero contact warning objects including mail-only snapshots', () => {
  const complete = validateCacheSnapshot(binding, new TextEncoder().encode(wasmSnapshot));
  assert.deepEqual(complete, JSON.parse(wasmSnapshot));
  const mailOnly = { ...JSON.parse(wasmSnapshot), contacts: [], contactsLoaded: false };
  const planned = planCacheWrite([], binding, mailOnly, 1);
  assert.deepEqual(planned.record.snapshot.contactWarnings, zeroContactWarnings);
  assert.deepEqual(scopeCacheSnapshot(binding, JSON.stringify(planned.record.snapshot), { contactsGranted: true }), mailOnly);
  const legacy = validateCacheSnapshot(binding, snapshot());
  assert.deepEqual(legacy.contactWarnings, zeroContactWarnings);
  assert.deepEqual(legacy.contacts[0].readWarnings, zeroContactWarnings);
});

test('contact warning pages survive IndexedDB save reopen and scoped restore without losing all-omitted warnings', async () => {
  const memory = memoryCacheDatabase();
  let cache = createBrowserCache(memory);
  const partial = JSON.parse(wasmSnapshot);
  partial.contacts[0].readWarnings = { omittedContacts: 0, partialContacts: 1, omittedEmails: 2, omittedNames: 1, sanitizedNames: 1, omittedMetadata: 1, invalidFields: 1 };
  partial.contactWarnings = { ...partial.contacts[0].readWarnings, omittedContacts: 2 };
  const empty = { ...JSON.parse(wasmSnapshot), contacts: [], contactWarnings: { ...zeroContactWarnings, omittedContacts: 100 } };
  for (const value of [JSON.parse(wasmSnapshot), partial, empty]) {
    await cache.save(binding, new TextEncoder().encode(JSON.stringify(value)), { verified: true });
    assert.equal(memory.rows().length, 1);
    assert.deepEqual(memory.rows()[0].snapshot, value);
    cache.close();
    cache = createBrowserCache(memory);
    assert.deepEqual(await cache.stage(binding, { contactsGranted: true }), value);
    assert.deepEqual(await cache.load(binding, { verified: true, contactsGranted: true }), value);
    const narrowed = await cache.load(binding, { verified: true, contactsGranted: false });
    assert.deepEqual(narrowed.contacts, []);
    assert.equal(narrowed.contactsLoaded, false);
    assert.deepEqual(narrowed.contactWarnings, zeroContactWarnings);
    assert.deepEqual(narrowed.messages, value.messages);
  }
  const before = memory.rows();
  await assert.rejects(() => cache.save(binding, { ...empty, contactWarnings: { omittedContacts: 101 } }, { verified: true }), code('invalid'));
  assert.deepEqual(memory.rows(), before);
  cache.close();
});

test('contact warning counters default only absent fields and reject malformed or unbounded counts', () => {
  const pageLimits = { omittedContacts: 100, partialContacts: 100, omittedEmails: 1572864, omittedNames: 1572864, sanitizedNames: 3200, omittedMetadata: 100, invalidFields: 300 };
  const rowLimits = { omittedContacts: 0, partialContacts: 1, omittedEmails: 1572864, omittedNames: 1572864, sanitizedNames: 32, omittedMetadata: 1, invalidFields: 3 };
  for (const [field, limits] of [['contactWarnings', pageLimits], ['readWarnings', rowLimits]]) {
    const value = JSON.parse(wasmSnapshot);
    const target = field === 'contactWarnings' ? value : value.contacts[0];
    target[field] = {};
    const defaults = validateCacheSnapshot(binding, value);
    assert.deepEqual(field === 'contactWarnings' ? defaults[field] : defaults.contacts[0][field], zeroContactWarnings);
    for (const [count, max] of Object.entries(limits)) {
      target[field] = { [count]: max };
      const exact = validateCacheSnapshot(binding, value);
      assert.equal(field === 'contactWarnings' ? exact[field][count] : exact.contacts[0][field][count], max);
      for (const bad of [-1, max + 1, 0xffffffff, 1.5, Infinity, '1', null, true]) {
        target[field] = { [count]: bad };
        assert.throws(() => validateCacheSnapshot(binding, value), code('invalid'));
      }
    }
    for (const malformed of [null, [], 'warning', 0, { provider: 'private data' }]) {
      target[field] = malformed;
      assert.throws(() => validateCacheSnapshot(binding, value), code('invalid'));
    }
  }
});

test('snapshot binding requires every exact actor and grant component', () => {
  assert.deepEqual(cacheKey(binding), [binding.account, binding.clientId, binding.grantId]);
  for (const changed of [{ account: 'bea@example.test' }, { clientId: 'other.apps.googleusercontent.com' }, { grantId: 'b'.repeat(64) }, { account: 'Ada@example.test' }]) assert.throws(() => validateCacheSnapshot({ ...binding, ...changed }, snapshot()), code('invalid'));
  assert.throws(() => cacheKey({ ...binding, account: 'ada@other@example.test' }), code('invalid'));
});

test('canonical mail bodies, passive HTML and attachment metadata survive validation', () => {
  const data = snapshot();
  data.messages[0].bodyHtml = '<p>Literal <b>markup</b><img src="https://remote.invalid/image"></p>';
  data.messages[0].attachments = [{ id: 'attachment-1', filename: 'report.pdf', mimeType: 'application/pdf', size: 12, contentId: null, disposition: 'attachment', contentLocation: 'https://example.test/report.pdf' }];
  const result = validateCacheSnapshot(binding, data);
  assert.equal(result.messages[0].bodyHtml, data.messages[0].bodyHtml);
  assert.equal(result.messages[0].bodyText, message.bodyText);
  assert.equal(result.contacts[0].emails[0].address, contact.emails[0].address);
  assert.equal(result.messages[0].attachments[0].filename, 'report.pdf');
  assert.equal(result.messages[0].attachments[0].contentLocation, 'https://example.test/report.pdf');
  assert(!('data' in result.messages[0].attachments[0]));
  assert(!('blobId' in result.messages[0].attachments[0]));
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

test('received protocol headers preserve literal CFWS and Unicode through persistence while retaining byte bounds', () => {
  const raw = {
    messageId: '\t(comment é\u200f) <source@example.test>\t',
    references: '(原文\u2066)\t<first@example.test>\t<second@example.test> (\u2069)',
    inReplyTo: '\t<parent@example.test> (é\u202e)\t',
    sentDate: 'Mon,\t12 Oct 2026 10:00:00 +0200 (é\u200f)',
  };
  const data = snapshot(binding, { messages: [{ ...message, ...raw }] });
  const stored = planCacheWrite([], binding, data).record.snapshot;
  const restored = scopeCacheSnapshot(binding, new TextEncoder().encode(JSON.stringify(stored)), { contactsGranted: false });
  for (const [field, value] of Object.entries(raw)) assert.equal(restored.messages[0][field], value);
  for (const field of Object.keys(raw)) {
    const max = field === 'references' ? mailPolicy.referencesBytes : mailPolicy.headerValueBytes;
    const exact = 'é'.repeat(max / 2);
    assert.equal(validateCacheSnapshot(binding, snapshot(binding, { messages: [{ ...message, [field]: exact }] })).messages[0][field], exact);
    assert.throws(() => validateCacheSnapshot(binding, snapshot(binding, { messages: [{ ...message, [field]: exact + 'é' }] })), code('limit'));
    assert.throws(() => validateCacheSnapshot(binding, snapshot(binding, { messages: [{ ...message, [field]: '\ud800' }] })), code('invalid'));
  }
  const malformed = new TextEncoder().encode(JSON.stringify(data));
  malformed[malformed.indexOf(0xc3)] = 0xff;
  assert.throws(() => validateCacheSnapshot(binding, malformed), code('invalid'));
  assert.throws(() => validateCacheSnapshot(binding, snapshot(binding, { messages: [{ ...message, id: 'mail\t1' }] })), code('invalid'));
  assert.throws(() => cacheKey({ ...binding, account: 'ada\t@example.test' }), code('invalid'));
  assert.throws(() => validateCacheSnapshot(binding, snapshot(binding, { messages: [{ ...message, subject: 'Display\ttext' }] })), code('invalid'));
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
  data.messages[0].from = { address: 'morgan@example.test', name: 'm'.repeat(mailPolicy.displayNameBytes) };
  data.messages[0].labels = ['l'.repeat(256)];
  data.contacts[0].name = 'c'.repeat(mailPolicy.displayNameBytes);
  data.contacts[0].emails = Array.from({ length: 33 }, (_, index) => ({ address: `morgan${index}@example.test`, name: 'n'.repeat(mailPolicy.displayNameBytes) }));
  const result = validateCacheSnapshot(binding, data);
  assert.equal(result.messages[0].from.name.length, mailPolicy.displayNameBytes);
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


test('compiled policy controls UTF-8 byte boundaries for received and outgoing metadata', () => {
  const mailbox = size => 'a'.repeat(size - '@example.test'.length) + '@example.test';
  const data = snapshot();
  data.messages[0].from = { address: mailbox(mailPolicy.incomingAddressBytes), name: 'é'.repeat(mailPolicy.displayNameBytes / 2) };
  data.messages[0].subject = 'é'.repeat(mailPolicy.subjectBytes / 2);
  data.messages[0].snippet = 'é'.repeat(mailPolicy.snippetBytes / 2);
  data.messages[0].references = 'r'.repeat(mailPolicy.referencesBytes);
  data.messages[0].messageId = 'i'.repeat(mailPolicy.headerValueBytes);
  data.messages[0].inReplyTo = 'i'.repeat(mailPolicy.headerValueBytes);
  data.messages[0].sentDate = 'd'.repeat(mailPolicy.headerValueBytes);
  data.messages[0].to = Array.from({ length: mailPolicy.incomingRecipients }, (_, index) => ({ address: `user${index}@例子.测试`, name: '中文' }));
  data.messages[0].attachments = [{ id: 'unicode', filename: 'é'.repeat((mailPolicy.filenameBytes - 4) / 2) + '.pdf', size: 0 }];
  data.contacts[0].emails = [{ address: mailbox(mailPolicy.outgoingAddressBytes), name: '中文' }, { address: '用户@例子.测试', name: 'Résumé' }];
  const result = validateCacheSnapshot(binding, data);
  assert.equal(result.messages[0].from.address, data.messages[0].from.address);
  assert.equal(result.messages[0].subject, data.messages[0].subject);
  assert.equal(result.messages[0].to.length, mailPolicy.incomingRecipients);
  assert.deepEqual(result.contacts[0].emails, data.contacts[0].emails);
  for (const change of [
    value => { value.messages[0].from.name += 'é'; },
    value => { value.messages[0].subject += 'é'; },
    value => { value.messages[0].snippet += 'é'; },
    value => { value.messages[0].attachments[0].filename += 'é'; },
  ]) {
    const oversized = structuredClone(data); change(oversized);
    assert.throws(() => validateCacheSnapshot(binding, oversized), code('limit'));
  }
  for (const change of [
    value => { value.messages[0].from.address += 'a'; },
    value => { value.contacts[0].emails[0].address += 'a'; },
    value => { value.messages[0].to.push({ address: 'extra@example.test' }); },
    value => { value.messages[0].references += 'r'; },
  ]) {
    const oversized = structuredClone(data); change(oversized);
    assert.throws(() => validateCacheSnapshot(binding, oversized), code('invalid'));
  }
});

test('warning rows with display-only sender and unverified labels survive persistence and scope changes', () => {
  const warning = { ...message, from: { address: '', name: 'Unsupported sender syntax' }, decodeWarning: 'HeaderTooLarge', metadataPartial: true, labelsVerified: false, labels: ['INBOX'], bodyCacheError: 'HeaderTooLarge' };
  const data = snapshot(binding, { messages: [warning] });
  const planned = planCacheWrite([], binding, data, 123);
  const restored = scopeCacheSnapshot(binding, JSON.stringify(planned.record.snapshot), { contactsGranted: false });
  for (const field of ['decodeWarning', 'metadataPartial', 'labelsVerified', 'bodyCacheError']) assert.equal(restored.messages[0][field], warning[field]);
  assert.deepEqual(restored.messages[0].from, warning.from);
  assert.deepEqual(restored.messages[0].labels, warning.labels);
  const legacy = validateCacheSnapshot(binding, snapshot());
  assert.equal(legacy.messages[0].decodeWarning, '');
  assert.equal(legacy.messages[0].metadataPartial, false);
  assert.equal(legacy.messages[0].labelsVerified, true);
  for (const [field, bad] of [['decodeWarning', false], ['metadataPartial', 'true'], ['labelsVerified', 1]]) {
    assert.throws(() => validateCacheSnapshot(binding, snapshot(binding, { messages: [{ ...warning, [field]: bad }] })), code('invalid'));
  }
});

test('cache requires explicit trusted policy and never reads it from mail or per-call options', async () => {
  assert.throws(() => validateSnapshot(binding, snapshot()), code('policy'));
  const cache = createCache({ indexedDB: undefined });
  await assert.rejects(() => cache.stage(binding, { mailPolicy }), code('policy'));
  for (const policy of [{}, { ...mailPolicy, displayNameBytes: 0 }, { ...mailPolicy, subjectBytes: 1 }, { ...mailPolicy, incomingRecipients: Infinity }, { ...mailPolicy, arbitrary: 1 }]) {
    assert.throws(() => validateMailPolicy(policy), code('policy'));
    assert.throws(() => cache.configure(policy), code('policy'));
  }
  const configured = { ...mailPolicy, displayNameBytes: 4 };
  cache.configure(configured);
  configured.displayNameBytes = 10000;
  const data = snapshot(binding, { contacts: [], contactsLoaded: false, messages: [{ ...message, from: { address: 'a@example.test', name: 'Short' } }] });
  await assert.rejects(() => cache.save(binding, data, { verified: true, mailPolicy }), code('invalid'));
  assert.throws(() => validateCacheSnapshot(binding, { ...snapshot(), mailPolicy }), code('invalid'));
  // An intentionally smaller synthetic policy proves validation is governed by
  // the supplied manifest, rather than an independently hard-coded JS cap.
  assert.throws(() => validateSnapshot(binding, data, { mailPolicy: { ...mailPolicy, displayNameBytes: 4 } }), code('invalid'));
});


test('legacy persisted byte receipts survive newly defaulted warning fields and decoder revision', () => {
  const legacy = snapshot();
  delete legacy.decoderRevision;
  const row = { key: cacheKey(binding), snapshot: legacy, byteLength: new TextEncoder().encode(JSON.stringify(legacy)).length, savedAt: 1 };
  const other = { ...binding, account: 'bea@example.test' };
  const plan = planCacheWrite([row], other, snapshot(other), 2);
  assert.deepEqual(plan.remove, []);
  assert.equal(plan.rows.length, 2);
  const normalized = plan.rows[0];
  assert.equal(normalized.snapshot.decoderRevision, 0);
  assert.equal(normalized.snapshot.messages[0].labelsVerified, true);
  assert.deepEqual(normalized.snapshot.contactWarnings, zeroContactWarnings);
  assert.deepEqual(normalized.snapshot.contacts[0].readWarnings, zeroContactWarnings);
  assert.equal(normalized.byteLength, new TextEncoder().encode(JSON.stringify(normalized.snapshot)).length);
  assert(normalized.byteLength > row.byteLength);
});

test('decoder revision is a bounded receipt and JavaScript preserves refusals for native migration', () => {
  const refused = { ...message, bodyText: '', bodyCached: false, bodyCacheError: 'UnsupportedCharset', decodeWarning: 'UnsupportedCharset', metadataPartial: true };
  for (const decoderRevision of [0, 3, decoderRevisionFixture, decoderRevisionFixture + 1, 0xffffffff]) {
    const data = snapshot(binding, { decoderRevision, messages: [refused] });
    const planned = planCacheWrite([], binding, data, 1);
    const restored = scopeCacheSnapshot(binding, JSON.stringify(planned.record.snapshot), { contactsGranted: false });
    assert.equal(restored.decoderRevision, decoderRevision);
    assert.equal(restored.messages[0].bodyCacheError, 'UnsupportedCharset');
    assert.equal(restored.messages[0].bodyCached, false);
    assert.equal(restored.messages[0].decodeWarning, 'UnsupportedCharset');
  }
  for (const decoderRevision of [-1, 0x100000000, 1.5, '4', null, true]) assert.throws(() => validateCacheSnapshot(binding, snapshot(binding, { decoderRevision })), code('invalid'));
  const legacy = snapshot();
  delete legacy.decoderRevision;
  const normalized = validateCacheSnapshot(binding, legacy);
  const wrongReceipt = { key: cacheKey(binding), snapshot: legacy, byteLength: new TextEncoder().encode(JSON.stringify(normalized)).length, savedAt: 1 };
  const other = { ...binding, account: 'bea@example.test' };
  assert.deepEqual(planCacheWrite([wrongReceipt], other, snapshot(other), 2).remove, [cacheKey(binding)]);
});
