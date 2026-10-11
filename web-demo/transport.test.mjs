import assert from 'node:assert/strict';
import test from 'node:test';
import { SessionTransport, allowedGmailRequest } from './transport.mjs';
import { scopesFor } from './credentials.mjs';

test('Google endpoint policy rejects redirects, credentials in URLs and unrelated writes', () => {
  assert.equal(allowedGmailRequest('https://gmail.googleapis.com/gmail/v1/users/me/profile', 'GET'), true);
  assert.equal(allowedGmailRequest('https://gmail.googleapis.com/gmail/v1/users/me/messages/send', 'POST'), true);
  for (const url of ['https://attacker.invalid/gmail/v1/users/me/profile', 'http://gmail.googleapis.com/gmail/v1/users/me/profile', 'https://gmail.googleapis.com/gmail/v1/users/other/profile', 'https://gmail.googleapis.com/gmail/v1/users/me/profile?access_token=synthetic']) assert.equal(allowedGmailRequest(url, 'GET'), false);
  assert.equal(allowedGmailRequest('https://gmail.googleapis.com/gmail/v1/users/me/messages/fictional', 'DELETE'), false);
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
