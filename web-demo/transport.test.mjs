import assert from 'node:assert/strict';
import test from 'node:test';
import { SessionTransport, allowedGmailRequest, pendingSend, acknowledgePendingSend, capturePendingSendAcknowledgement } from './transport.mjs';
import { scopesFor } from './credentials.mjs';

test('Google endpoint policy rejects redirects, credentials in URLs and unrelated writes', () => {
  assert.equal(allowedGmailRequest('https://gmail.googleapis.com/gmail/v1/users/me/profile', 'GET'), true);
  assert.equal(allowedGmailRequest('https://gmail.googleapis.com/gmail/v1/users/me/messages/send', 'POST'), true);
  for (const url of ['https://attacker.invalid/gmail/v1/users/me/profile', 'http://gmail.googleapis.com/gmail/v1/users/me/profile', 'https://gmail.googleapis.com/gmail/v1/users/other/profile', 'https://gmail.googleapis.com/gmail/v1/users/me/profile?access_token=synthetic']) assert.equal(allowedGmailRequest(url, 'GET'), false);
  assert.equal(allowedGmailRequest('https://gmail.googleapis.com/gmail/v1/users/me/messages/fictional', 'DELETE'), false);
  const root = 'https://gmail.googleapis.com/gmail/v1/users/me/';
  for (const [path, method] of [['messages/fictional/modify?fields=id,labelIds', 'POST'], ['messages/fictional/trash', 'POST'], ['messages/fictional/untrash', 'POST'], ['labels', 'POST'], ['labels/Label_fictional', 'PATCH'], ['labels/Label_fictional', 'DELETE']]) assert.equal(allowedGmailRequest(root + path, method), true, `${method} ${path}`);
  for (const [path, method] of [['messages/batchDelete', 'POST'], ['messages/import', 'POST'], ['messages/fictional/modify?access_token=secret', 'POST'], ['labels/Label_fictional?fields=id', 'DELETE'], ['settings/sendAs', 'PATCH'], ['settings/forwardingAddresses', 'GET'], ['messages?unexpected=value', 'GET'], ['messages/fictional?format=anything', 'GET']]) assert.equal(allowedGmailRequest(root + path, method), false, `${method} ${path}`);
});

test('mailbox writes use verified modify scope and bypass only the send grace and send uncertainty fence', async () => {
  const previousFetch = globalThis.fetch;
  const previousStorage = Object.getOwnPropertyDescriptor(globalThis, 'localStorage');
  const marker = JSON.stringify({ id: 'fictional-unresolved-send', startedAt: 1 });
  const stored = new Map([['omagma-browser-pending-send-v1', marker]]);
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: { getItem: key => stored.get(key) ?? null, setItem: (key, value) => stored.set(key, value), removeItem: key => stored.delete(key) } });
  const calls = [];
  let failNext = false;
  let beforeSendCalls = 0;
  globalThis.fetch = async (url, init) => {
    calls.push({ url, method: init.method });
    if (url === 'https://oauth2.googleapis.com/token') return new Response(JSON.stringify({ access_token: 'synthetic-access', expires_in: 3600, token_type: 'Bearer' }));
    if (failNext) { failNext = false; throw new Error('synthetic lost mailbox response'); }
    return init.method === 'DELETE' ? new Response(null, { status: 204 }) : new Response('{"id":"m1","labelIds":["INBOX"]}');
  };
  const memory = new WebAssembly.Memory({ initial: 64 });
  const transport = new SessionTransport(() => memory, () => {}, () => {}, async () => { beforeSendCalls++; });
  try {
    const caps = ['mail-read', 'mail-modify'];
    const [metadata] = await transport.prepare([{ account: 'ada@example.test', clientId: 'synthetic.apps.googleusercontent.com', clientSecret: 'synthetic-secret', refreshToken: 'synthetic-refresh', capabilities: caps, scopes: scopesFor(caps), grantId: '0'.repeat(64) }]);
    const encode = (offset, text) => { const bytes = new TextEncoder().encode(text); new Uint8Array(memory.buffer, offset, bytes.length).set(bytes); return bytes.length; };
    const request = async (method, path, body = '') => {
      const methodLength = encode(128, method), urlLength = encode(256, `https://gmail.googleapis.com/gmail/v1/users/me/${path}`), bodyLength = encode(1024, body);
      transport.beginJob();
      return transport.wasmRequest(metadata.session, 128, methodLength, 256, urlLength, 1024, bodyLength, 16384, 3 * 1024 * 1024, 8);
    };
    assert.deepEqual(transport.info().canModify, [true]);
    assert.equal(await request('GET', 'messages/m1?format=minimal&fields=id,labelIds'), 0);
    assert.equal(await request('POST', 'messages/m1/modify?fields=id,labelIds', '{"removeLabelIds":["INBOX"]}'), 0);
    assert.equal(await request('PATCH', 'labels/Label_synthetic', '{"name":"Renamed"}'), 0);
    assert.equal(await request('DELETE', 'labels/Label_synthetic'), 0);
    assert.equal(await request('POST', 'messages/send', '{"raw":"synthetic"}'), 3);
    failNext = true;
    assert.equal(await request('POST', 'messages/m1/modify?fields=id,labelIds', '{"addLabelIds":["STARRED"]}'), 1);
    assert.equal(await request('GET', 'messages/m1?format=minimal&fields=id,labelIds'), 0);
    assert.equal(beforeSendCalls, 0);
    assert.equal(stored.get('omagma-browser-pending-send-v1'), marker);
    assert.equal(calls.length, 7);
  } finally { transport.close(); globalThis.fetch = previousFetch; if (previousStorage) Object.defineProperty(globalThis, 'localStorage', previousStorage); else delete globalThis.localStorage; }
});

test('a narrowed refreshed scope rejects mailbox mutation before provider entry while reads keep working', async () => {
  const previousFetch = globalThis.fetch;
  const previousNow = Date.now;
  let clock = previousNow();
  Date.now = () => clock;
  let refreshes = 0, writes = 0;
  globalThis.fetch = async (url, init) => {
    if (url === 'https://oauth2.googleapis.com/token') return new Response(JSON.stringify({ access_token: 'synthetic-access', expires_in: 3600, token_type: 'Bearer', scope: refreshes++ === 0 ? scopesFor(['mail-read', 'mail-modify'])[0] : scopesFor(['mail-read'])[0] }));
    if (init.method !== 'GET') writes++;
    return new Response('{}');
  };
  const memory = new WebAssembly.Memory({ initial: 64 });
  const transport = new SessionTransport(() => memory);
  try {
    const caps = ['mail-read', 'mail-modify'];
    const [metadata] = await transport.prepare([{ account: 'ada@example.test', clientId: 'synthetic.apps.googleusercontent.com', clientSecret: 'synthetic-secret', refreshToken: 'synthetic-refresh', capabilities: caps, scopes: scopesFor(caps), grantId: '0'.repeat(64) }]);
    const encode = (offset, text) => { const bytes = new TextEncoder().encode(text); new Uint8Array(memory.buffer, offset, bytes.length).set(bytes); return bytes.length; };
    const methodLength = encode(128, 'POST'), urlLength = encode(256, 'https://gmail.googleapis.com/gmail/v1/users/me/messages/m1/modify?fields=id,labelIds'), bodyLength = encode(1024, '{}');
    clock += 3600000;
    transport.beginJob();
    assert.equal(await transport.wasmRequest(metadata.session, 128, methodLength, 256, urlLength, 1024, bodyLength, 16384, 3 * 1024 * 1024, 8), 3);
    assert.equal(writes, 0);
    assert.equal(refreshes, 2);
    assert.deepEqual(transport.info().canModify, [false]);
  } finally { transport.close(); globalThis.fetch = previousFetch; Date.now = previousNow; }
});

test('Ctrl+C preserves submitted mailbox requests while reads remain cancelable and send state stays separate', async () => {
  const previousFetch = globalThis.fetch;
  const previousStorage = Object.getOwnPropertyDescriptor(globalThis, 'localStorage');
  const marker = JSON.stringify({ id: 'separate-unknown-send', startedAt: 1 });
  const markers = new Map([['omagma-browser-pending-send-v1', marker]]);
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: { getItem: key => markers.get(key) ?? null, setItem: (key, value) => markers.set(key, value), removeItem: key => markers.delete(key) } });
  let held, entered;
  let providerCalls = 0;
  globalThis.fetch = (url, init) => {
    if (url === 'https://oauth2.googleapis.com/token') return Promise.resolve(new Response(JSON.stringify({ access_token: 'synthetic-access', expires_in: 3600, token_type: 'Bearer' })));
    providerCalls++;
    return new Promise((resolve, reject) => {
      held = { signal: init.signal, finish: () => resolve(init.method === 'DELETE' ? new Response(null, { status: 204 }) : new Response('{"id":"synthetic","labelIds":["INBOX"]}')) };
      init.signal.addEventListener('abort', () => reject(new Error('Synthetic canceled request')), { once: true });
      entered();
    });
  };
  const memory = new WebAssembly.Memory({ initial: 64 });
  const transport = new SessionTransport(() => memory);
  try {
    const capabilities = ['mail-read', 'mail-modify'];
    const [metadata] = await transport.prepare([{ account: 'ada@example.test', clientId: 'synthetic.apps.googleusercontent.com', clientSecret: 'synthetic-secret', refreshToken: 'synthetic-refresh', capabilities, scopes: scopesFor(capabilities), grantId: '0'.repeat(64) }]);
    const encode = (offset, text) => { const bytes = new TextEncoder().encode(text); new Uint8Array(memory.buffer, offset, bytes.length).set(bytes); return bytes.length; };
    for (const [method, path, body] of [['POST', 'messages/m1/modify?fields=id,labelIds', '{"removeLabelIds":["INBOX"]}'], ['PATCH', 'labels/Label_synthetic', '{"name":"Renamed"}'], ['DELETE', 'labels/Label_synthetic', ''], ['GET', 'messages/m1?format=minimal&fields=id,labelIds', '']]) {
      const started = new Promise(resolve => { entered = resolve; });
      const methodLength = encode(128, method), urlLength = encode(256, `https://gmail.googleapis.com/gmail/v1/users/me/${path}`), bodyLength = encode(1024, body);
      transport.beginJob();
      const request = transport.wasmRequest(metadata.session, 128, methodLength, 256, urlLength, 1024, bodyLength, 16384, 3 * 1024 * 1024, 8);
      await started;
      const writing = method !== 'GET';
      assert.equal(transport.info().busy, true);
      assert.equal(transport.info().mailboxWriting, writing);
      assert.equal(transport.info().sendPhase, null);
      assert.equal(transport.abort(), !writing);
      assert.equal(held.signal.aborted, !writing);
      if (writing) held.finish();
      assert.equal(await request, writing ? 0 : 1);
      assert.equal(transport.info().mailboxWriting, false);
      assert.equal(transport.info().busy, false);
      assert.equal(markers.get('omagma-browser-pending-send-v1'), marker);
    }
    assert.equal(providerCalls, 4);
  } finally { transport.close(); globalThis.fetch = previousFetch; if (previousStorage) Object.defineProperty(globalThis, 'localStorage', previousStorage); else delete globalThis.localStorage; }
});

test('mailbox request deadline and disconnect remain uncertain after dispatch without an automatic retry', async () => {
  const previousFetch = globalThis.fetch, previousTimer = globalThis.setTimeout;
  let held, entered;
  let writes = 0;
  globalThis.fetch = (url, init) => {
    if (url === 'https://oauth2.googleapis.com/token') return Promise.resolve(new Response(JSON.stringify({ access_token: 'synthetic-access', expires_in: 3600, token_type: 'Bearer' })));
    writes++;
    return new Promise((_, reject) => {
      held = init.signal;
      init.signal.addEventListener('abort', () => reject(new Error('Synthetic interrupted mailbox write')), { once: true });
      entered();
    });
  };
  try {
    for (const interruptedBy of ['disconnect', 'deadline']) {
      const memory = new WebAssembly.Memory({ initial: 64 });
      const transport = new SessionTransport(() => memory);
      try {
        const capabilities = ['mail-read', 'mail-modify'];
        const [metadata] = await transport.prepare([{ account: 'ada@example.test', clientId: 'synthetic.apps.googleusercontent.com', clientSecret: 'synthetic-secret', refreshToken: 'synthetic-refresh', capabilities, scopes: scopesFor(capabilities), grantId: '0'.repeat(64) }]);
        const encode = (offset, text) => { const bytes = new TextEncoder().encode(text); new Uint8Array(memory.buffer, offset, bytes.length).set(bytes); return bytes.length; };
        const methodLength = encode(128, 'POST'), urlLength = encode(256, 'https://gmail.googleapis.com/gmail/v1/users/me/messages/m1/modify?fields=id,labelIds'), bodyLength = encode(1024, '{"addLabelIds":["STARRED"]}');
        const started = new Promise(resolve => { entered = resolve; });
        if (interruptedBy === 'deadline') globalThis.setTimeout = (callback, delay, ...args) => previousTimer(callback, delay === 10000 ? 5 : delay, ...args);
        transport.beginJob();
        const request = transport.wasmRequest(metadata.session, 128, methodLength, 256, urlLength, 1024, bodyLength, 16384, 3 * 1024 * 1024, 8);
        await started;
        assert.equal(transport.info().mailboxWriting, true);
        if (interruptedBy === 'disconnect') transport.close();
        assert.equal(await request, 1);
        assert.equal(held.aborted, true);
        assert.equal(transport.info().mailboxWriting, false);
      } finally { transport.close(); globalThis.setTimeout = previousTimer; }
    }
    assert.equal(writes, 2);
  } finally { globalThis.fetch = previousFetch; globalThis.setTimeout = previousTimer; }
});

test('transport accepts the core 3 MiB slab, injects auth only into Google headers and bounds streamed responses', async () => {
  const previousFetch = globalThis.fetch;
  const requests = [];
  let oversized = false;
  globalThis.fetch = async (url, init) => {
    requests.push({ url, init });
    assert.equal(init.redirect, 'error');
    assert.equal(init.credentials, 'omit');
    if (url === 'https://oauth2.googleapis.com/token') return new Response(JSON.stringify({ access_token: 'synthetic-access', expires_in: 3600, token_type: 'Bearer', scope: scopesFor(['mail-read'])[0] }));
    assert.equal(init.headers.Authorization, 'Bearer synthetic-access');
    return oversized ? new Response('x', { headers: { 'Content-Length': String(4 * 1024 * 1024) } }) : new Response('{"emailAddress":"ada@example.test"}');
  };
  const memory = new WebAssembly.Memory({ initial: 64 });
  const transport = new SessionTransport(() => memory);
  try {
    const [metadata] = await transport.prepare([{ account: 'ada@example.test', clientId: 'synthetic.apps.googleusercontent.com', clientSecret: 'synthetic-secret', refreshToken: 'synthetic-refresh', capabilities: ['mail-read'], scopes: scopesFor(['mail-read']), grantId: '0'.repeat(64) }]);
    const encode = (offset, text) => { const bytes = new TextEncoder().encode(text); new Uint8Array(memory.buffer, offset, bytes.length).set(bytes); return bytes.length; };
    const methodLength = encode(128, 'GET');
    const urlLength = encode(256, 'https://gmail.googleapis.com/gmail/v1/users/me/profile');
    transport.beginJob();
    assert.equal(await transport.wasmRequest(metadata.session, 128, methodLength, 256, urlLength, 0, 0, 16384, 3 * 1024 * 1024, 8), 0);
    const meta = new DataView(memory.buffer, 8, 8);
    assert.equal(meta.getUint32(0, true), 200);
    const body = new TextDecoder().decode(new Uint8Array(memory.buffer, 16384, meta.getUint32(4, true)));
    assert.equal(body, '{"emailAddress":"ada@example.test"}');
    assert.equal(new TextDecoder().decode(new Uint8Array(memory.buffer)).includes('synthetic-access'), false);
    oversized = true;
    transport.beginJob();
    assert.equal(await transport.wasmRequest(metadata.session, 128, methodLength, 256, urlLength, 0, 0, 16384, 3 * 1024 * 1024, 8), 2);
    assert.equal(meta.getUint32(4, true), 0);
    assert.equal(requests.length, 3);
  } finally { transport.close(); globalThis.fetch = previousFetch; }
});

test('a previous uncertain send rejects locally and survives a later preflight cancellation', async () => {
  const previousFetch = globalThis.fetch;
  const previousStorage = Object.getOwnPropertyDescriptor(globalThis, 'localStorage');
  const stored = new Map([['omagma-browser-pending-send-v1', JSON.stringify({ id: 'fictional-pending-operation', startedAt: 1 })]]);
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: { getItem: key => stored.get(key) ?? null, setItem: (key, value) => stored.set(key, value), removeItem: key => stored.delete(key) } });
  let requests = 0;
  globalThis.fetch = async url => {
    requests++;
    assert.equal(url, 'https://oauth2.googleapis.com/token');
    return new Response(JSON.stringify({ access_token: 'synthetic-access', expires_in: 3600, token_type: 'Bearer' }));
  };
  const memory = new WebAssembly.Memory({ initial: 64 });
  const transport = new SessionTransport(() => memory);
  try {
    const caps = ['mail-read', 'mail-send'];
    const [metadata] = await transport.prepare([{ account: 'ada@example.test', clientId: 'synthetic.apps.googleusercontent.com', clientSecret: 'synthetic-secret', refreshToken: 'synthetic-refresh', capabilities: caps, scopes: scopesFor(caps), grantId: '0'.repeat(64) }]);
    const encode = (offset, text) => { const bytes = new TextEncoder().encode(text); new Uint8Array(memory.buffer, offset, bytes.length).set(bytes); return bytes.length; };
    const methodLength = encode(128, 'POST');
    const urlLength = encode(256, 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send');
    const bodyLength = encode(1024, '{"raw":"synthetic"}');
    transport.beginJob();
    assert.equal(await transport.wasmRequest(metadata.session, 128, methodLength, 256, urlLength, 1024, bodyLength, 16384, 3 * 1024 * 1024, 8), 4);
    transport.finishSend(3);
    assert.equal(requests, 1);
    assert.equal(stored.has('omagma-browser-pending-send-v1'), true);
  } finally { transport.close(); globalThis.fetch = previousFetch; if (previousStorage) Object.defineProperty(globalThis, 'localStorage', previousStorage); else delete globalThis.localStorage; }
});

test('generic send markers expose only validated opaque identities and named acknowledgement preserves other operations', () => {
  const previousStorage = Object.getOwnPropertyDescriptor(globalThis, 'localStorage');
  const stored = new Map();
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: { getItem: key => stored.get(key) ?? null, setItem: (key, value) => stored.set(key, value), removeItem: key => stored.delete(key) } });
  const key = 'omagma-browser-pending-send-v1';
  const operation = 'browser-12345678-1234-4234-8234-123456789abc-18446744073709551615';
  try {
    stored.set(key, JSON.stringify({ id: operation, startedAt: 1 }));
    assert.deepEqual(pendingSend(), { uncertain: true, id: operation });
    assert.equal(acknowledgePendingSend(), false);
    assert.equal(acknowledgePendingSend('browser-12345678-1234-4234-8234-123456789abc-2'), false);
    assert.equal(pendingSend().id, operation);
    assert.equal(acknowledgePendingSend(operation), true);
    assert.equal(pendingSend(), null);
    const legacy = '12345678-1234-4234-8234-123456789abc';
    stored.set(key, JSON.stringify({ id: legacy, startedAt: 1 }));
    assert.equal(pendingSend().id, legacy);
    for (const id of ['unrecognized-old-marker', 'private@example.test', 'browser-12345678-1234-4234-8234-123456789abc-123456789012345678901']) {
      stored.set(key, JSON.stringify({ id, startedAt: 1 }));
      assert.deepEqual(pendingSend(), { uncertain: true });
      assert.equal(acknowledgePendingSend(operation), false);
    }
  } finally { if (previousStorage) Object.defineProperty(globalThis, 'localStorage', previousStorage); else delete globalThis.localStorage; }
});

test('generic notice acknowledgement pins the exact captured marker across an awaited operation', () => {
  const previousStorage = Object.getOwnPropertyDescriptor(globalThis, 'localStorage');
  const stored = new Map(), key = 'omagma-browser-pending-send-v1';
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: { getItem: key => stored.get(key) ?? null, removeItem: key => stored.delete(key) } });
  try {
    const absent = capturePendingSendAcknowledgement();
    stored.set(key, 'old opaque marker');
    assert.equal(absent(), false);
    const old = capturePendingSendAcknowledgement();
    const replacement = JSON.stringify({ id: 'browser-12345678-1234-4234-8234-123456789abc-2', startedAt: 2 });
    stored.set(key, replacement);
    assert.equal(old(), false);
    assert.equal(stored.get(key), replacement);
    assert.equal(capturePendingSendAcknowledgement()(), true);
    stored.set(key, 'old opaque marker');
    assert.equal(capturePendingSendAcknowledgement()(), true);
    assert.equal(stored.has(key), false);
  } finally { if (previousStorage) Object.defineProperty(globalThis, 'localStorage', previousStorage); else delete globalThis.localStorage; }
});

test('the durable send identity becomes the generic marker and an invalid identity refuses before POST', async () => {
  const previousFetch = globalThis.fetch, previousTimer = globalThis.setTimeout;
  const previousStorage = Object.getOwnPropertyDescriptor(globalThis, 'localStorage');
  const stored = new Map();
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: { getItem: key => stored.get(key) ?? null, setItem: (key, value) => stored.set(key, value), removeItem: key => stored.delete(key) } });
  let posts = 0;
  let operation = 'browser-12345678-1234-4234-8234-123456789abc-7';
  globalThis.fetch = async (url, init) => {
    if (url === 'https://oauth2.googleapis.com/token') return new Response(JSON.stringify({ access_token: 'synthetic-access', expires_in: 3600, token_type: 'Bearer' }));
    assert.equal(init.method, 'POST');
    posts++;
    assert.equal(pendingSend()?.id, operation);
    return new Response('{"id":"synthetic-sent"}');
  };
  const memory = new WebAssembly.Memory({ initial: 64 });
  const transport = new SessionTransport(() => memory, () => {}, () => {}, async () => operation);
  try {
    const capabilities = ['mail-read', 'mail-send'];
    const [metadata] = await transport.prepare([{ account: 'ada@example.test', clientId: 'synthetic.apps.googleusercontent.com', clientSecret: 'synthetic-secret', refreshToken: 'synthetic-refresh', capabilities, scopes: scopesFor(capabilities), grantId: '0'.repeat(64) }]);
    globalThis.setTimeout = (callback, delay, ...args) => previousTimer(callback, delay === 10000 ? 0 : delay, ...args);
    const encode = (offset, text) => { const bytes = new TextEncoder().encode(text); new Uint8Array(memory.buffer, offset, bytes.length).set(bytes); return bytes.length; };
    const methodLength = encode(128, 'POST'), urlLength = encode(256, 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send'), bodyLength = encode(1024, '{"raw":"synthetic"}');
    const send = () => { transport.beginJob(); return transport.wasmRequest(metadata.session, 128, methodLength, 256, urlLength, 1024, bodyLength, 16384, 3 * 1024 * 1024, 8); };
    assert.equal(await send(), 0);
    assert.equal(pendingSend()?.id, operation);
    transport.finishSend(1);
    assert.equal(pendingSend(), null);
    operation = 'private@example.test';
    assert.equal(await send(), 5);
    assert.equal(posts, 1);
    assert.equal(pendingSend(), null);
  } finally { transport.close(); globalThis.fetch = previousFetch; globalThis.setTimeout = previousTimer; if (previousStorage) Object.defineProperty(globalThis, 'localStorage', previousStorage); else delete globalThis.localStorage; }
});

test('high-bit unsigned session handles survive signed WASM i32 imports', async () => {
  const previousFetch = globalThis.fetch;
  const previousRandom = Object.getOwnPropertyDescriptor(crypto, 'getRandomValues');
  const random = crypto.getRandomValues.bind(crypto);
  const handles = [0x80000001, 0xffffffff];
  Object.defineProperty(crypto, 'getRandomValues', { configurable: true, value: values => {
    if (values instanceof Uint32Array && values.length === 1 && handles.length) { values[0] = handles.shift(); return values; }
    return random(values);
  } });
  globalThis.fetch = async url => new Response(url === 'https://oauth2.googleapis.com/token' ? JSON.stringify({ access_token: 'synthetic-access', expires_in: 3600, token_type: 'Bearer' }) : '{}');
  const memory = new WebAssembly.Memory({ initial: 64 });
  const transport = new SessionTransport(() => memory);
  try {
    const records = ['ada@example.test', 'bea@example.test'].map(account => ({ account, clientId: 'synthetic.apps.googleusercontent.com', clientSecret: 'synthetic-secret', refreshToken: 'synthetic-refresh', capabilities: ['mail-read'], scopes: scopesFor(['mail-read']), grantId: '0'.repeat(64) }));
    const metadata = await transport.prepare(records);
    assert.deepEqual(metadata.map(record => record.session), [0x80000001, 0xffffffff]);
    const encode = (offset, text) => { const bytes = new TextEncoder().encode(text); new Uint8Array(memory.buffer, offset, bytes.length).set(bytes); return bytes.length; };
    const methodLength = encode(128, 'GET');
    const urlLength = encode(256, 'https://gmail.googleapis.com/gmail/v1/users/me/profile');
    for (const record of metadata) {
      transport.beginJob();
      assert.equal(await transport.wasmRequest(record.session | 0, 128, methodLength, 256, urlLength, 0, 0, 16384, 3 * 1024 * 1024, 8), 0);
    }
  } finally {
    transport.close(); globalThis.fetch = previousFetch;
    if (previousRandom) Object.defineProperty(crypto, 'getRandomValues', previousRandom); else delete crypto.getRandomValues;
  }
});
