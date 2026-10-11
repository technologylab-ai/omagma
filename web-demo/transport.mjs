import { parseRefreshedToken, permissions } from './credentials.mjs';

const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const GMAIL_ROOT = 'https://gmail.googleapis.com/gmail/v1/users/me/';
const RECEIPT_KEY = 'omagma-browser-pending-send-v1';
const MAX_RESPONSE = 3 * 1024 * 1024;
const MAX_REQUEST = 3 * 1024 * 1024;
const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });
class LocalCanceled extends Error {}

export function pendingSend() {
  try {
    const text = localStorage.getItem(RECEIPT_KEY);
    if (!text) return null;
    if (text.length > 512) return { uncertain: true };
    const receipt = JSON.parse(text);
    return receipt && typeof receipt.id === 'string' && receipt.id.length <= 64 && Number.isFinite(receipt.startedAt) ? { uncertain: true } : { uncertain: true };
  } catch { return { uncertain: true }; }
}

export function acknowledgePendingSend() {
  try { localStorage.removeItem(RECEIPT_KEY); return true; }
  catch { return false; }
}

export function allowedGmailRequest(url, method) {
  let parsed;
  try { parsed = new URL(url); } catch { return false; }
  if (!url.startsWith(GMAIL_ROOT) || parsed.origin !== 'https://gmail.googleapis.com' || !parsed.pathname.startsWith('/gmail/v1/users/me/') || parsed.username || parsed.password || parsed.hash) return false;
  for (const name of parsed.searchParams.keys()) if (/^(access_token|refresh_token|client_secret|token)$/i.test(name)) return false;
  return method === 'GET' || (method === 'POST' && parsed.pathname === '/gmail/v1/users/me/messages/send' && !parsed.search);
}

export class SessionTransport {
  #sessions = new Map();
  #controller = null;
  #closed = false;
  #deadline = 0;
  #active = false;
  #jobPendingId = null;
  #activity;
  #receiptChanged;
  #memory;
  #grace = null;
  #sendPhase = null;
  #remaining = 0;

  constructor(getMemory, activity = () => {}, receiptChanged = () => {}) {
    this.#memory = getMemory;
    this.#activity = activity;
    this.#receiptChanged = receiptChanged;
  }

  beginJob() { this.#deadline = Date.now() + 30000; this.#jobPendingId = null; }
  info() { return { accountCount: this.#sessions.size, canSend: Array.from(this.#sessions.values(), record => record.canSend), busy: this.#active, sendPhase: this.#sendPhase, sendRemaining: this.#remaining }; }

  close() {
    this.#closed = true;
    this.cancelSend();
    this.#controller?.abort();
    for (const record of this.#sessions.values()) {
      record.refreshToken = '';
      record.clientSecret = '';
      record.accessToken = '';
    }
    this.#sessions.clear();
  }

  abort() { this.#controller?.abort(); }
  cancelSend() { this.#grace?.cancel(); }

  async prepare(records) {
    const metadata = [];
    for (const record of records) {
      if (this.#closed) throw new Error('Connection cancelled.');
      let session;
      do { session = crypto.getRandomValues(new Uint32Array(1))[0]; } while (session === 0 || this.#sessions.has(session));
      const privateRecord = { ...record, accessToken: '', expiresAt: 0, canRead: false, canSend: false };
      this.#sessions.set(session, privateRecord);
      this.beginJob();
      await this.#operation(() => this.#refresh(privateRecord));
      metadata.push({ session, nonce: crypto.randomUUID(), account: record.account, clientId: record.clientId, grantId: record.grantId, capabilities: [...record.capabilities], scopes: [...record.scopes], actualScopes: [...privateRecord.actualScopes] });
      record.refreshToken = '';
      record.clientSecret = '';
    }
    return metadata;
  }

  async #operation(action) {
    if (this.#closed) throw new Error('Connection cancelled.');
    if (this.#active) throw new Error('Another Google request is already running.');
    this.#active = true;
    this.#activity(true);
    try { return await action(); }
    finally { this.#active = false; this.#sendPhase = null; this.#remaining = 0; this.#activity(false); }
  }

  async #fetch(url, init, limit) {
    const remaining = this.#deadline - Date.now();
    if (this.#closed) throw new LocalCanceled('Connection cancelled before the request started.');
    if (remaining <= 0) throw new LocalCanceled('The operation timed out before the request started.');
    const controller = new AbortController();
    this.#controller = controller;
    const timeout = setTimeout(() => controller.abort(), Math.min(10000, remaining));
    let reader;
    try {
      const response = await fetch(url, { ...init, signal: controller.signal, redirect: 'error', credentials: 'omit', cache: 'no-store', referrerPolicy: 'no-referrer' });
      if (this.#closed) throw new Error('Connection cancelled.');
      const length = response.headers.get('content-length');
      if (length && /^\d+$/.test(length) && Number(length) > limit) throw new RangeError('Google returned a response larger than this experiment supports.');
      const bytes = new Uint8Array(limit);
      let used = 0;
      if (response.body) {
        reader = response.body.getReader();
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          if (this.#closed) throw new Error('Connection cancelled.');
          if (used + value.byteLength > limit) throw new RangeError('Google returned a response larger than this experiment supports.');
          bytes.set(value, used);
          used += value.byteLength;
        }
      }
      return { status: response.status, bytes: bytes.subarray(0, used) };
    } catch (reason) {
      if (reason instanceof RangeError) throw reason;
      if (this.#closed) throw new Error('Connection cancelled.');
      if (controller.signal.aborted) throw new Error('The Google request was cancelled or timed out.');
      throw new Error('The Google request could not complete. Check your connection and browser access.');
    } finally {
      clearTimeout(timeout);
      controller.abort();
      if (reader) { try { void reader.cancel().catch(() => {}); } catch {} }
      if (this.#controller === controller) this.#controller = null;
    }
  }

  async #refresh(record) {
    const form = new URLSearchParams({ client_id: record.clientId, client_secret: record.clientSecret, refresh_token: record.refreshToken, grant_type: 'refresh_token' });
    const result = await this.#fetch(TOKEN_URL, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' }, body: form.toString() }, 16 * 1024);
    let data;
    try {
      if (result.status !== 200) throw new Error('Google could not refresh this grant. Reauthorize it in Omagma, then select the updated files.');
      try { data = JSON.parse(decoder.decode(result.bytes)); } catch { throw new Error('Google returned an invalid access-token response.'); }
      const refreshed = parseRefreshedToken(data, record.scopes);
      const allowed = permissions(record.capabilities, refreshed.actualScopes);
      if (!allowed.canRead) throw new Error('The refreshed grant does not permit reading Gmail.');
      Object.assign(record, refreshed, allowed);
    } finally { result.bytes.fill(0); data = null; }
  }

  #view(ptr, length, max) {
    const memory = this.#memory()?.buffer;
    if (!memory || !Number.isInteger(ptr) || !Number.isInteger(length) || ptr < 0 || length < 0 || length > max || ptr > memory.byteLength - length) throw new Error('Invalid WebAssembly transport buffer.');
    return new Uint8Array(memory, ptr, length);
  }

  #meta(ptr, status, length) {
    const bytes = this.#view(ptr, 8, 8);
    const meta = new DataView(bytes.buffer, bytes.byteOffset, 8);
    meta.setUint32(0, status, true);
    meta.setUint32(4, length, true);
  }

  #startSend() {
    if (pendingSend()) throw new LocalCanceled('Check Sent and acknowledge the previous send before submitting another message.');
    const receipt = { id: crypto.randomUUID(), startedAt: Date.now() };
    try { localStorage.setItem(RECEIPT_KEY, JSON.stringify(receipt)); }
    catch { throw new LocalCanceled('This browser cannot retain send confirmation state. Sending is disabled.'); }
    this.#jobPendingId = receipt.id;
    this.#receiptChanged();
  }

  async #sendGrace() {
    if (pendingSend()) throw new LocalCanceled('Check Sent and acknowledge the previous send before submitting another message.');
    this.#sendPhase = 'grace';
    const until = Date.now() + 10000;
    const tick = () => {
      this.#remaining = Math.max(0, Math.ceil((until - Date.now()) / 1000));
      this.#activity(true);
    };
    tick();
    try {
      await new Promise((resolve, reject) => {
        const timer = setTimeout(resolve, 10000);
        const interval = setInterval(tick, 250);
        this.#grace = {
          cancel: () => { clearTimeout(timer); reject(new LocalCanceled('Send cancelled before submission.')); },
          cleanup: () => { clearTimeout(timer); clearInterval(interval); },
        };
      });
    } finally { this.#grace?.cleanup(); this.#grace = null; }
    if (this.#closed) throw new LocalCanceled('Send cancelled before submission.');
    if (Date.now() >= this.#deadline) throw new LocalCanceled('Send timed out before submission.');
    this.#sendPhase = 'sending';
    this.#remaining = 0;
    this.#activity(true);
  }

  finishSend(status) {
    const owned = this.#jobPendingId;
    this.#jobPendingId = null;
    if (!owned || (status !== 1 && status !== 3)) return;
    try {
      const stored = JSON.parse(localStorage.getItem(RECEIPT_KEY) || 'null');
      if (stored?.id === owned) localStorage.removeItem(RECEIPT_KEY);
    } catch {}
    this.#receiptChanged();
  }

  async wasmRequest(session, methodPtr, methodLength, urlPtr, urlLength, bodyPtr, bodyLength, responsePtr, responseCapacity, metaPtr) {
    let body;
    let method;
    let submissionStarted = false;
    try {
      this.#meta(metaPtr, 0, 0);
      // WASM i32 imports arrive as signed JS numbers; opaque handles are u32.
      const record = this.#sessions.get(session >>> 0);
      if (this.#closed || !record || !record.canRead) return 3;
      method = decoder.decode(this.#view(methodPtr, methodLength, 8));
      const url = decoder.decode(this.#view(urlPtr, urlLength, 16384));
      if (!allowedGmailRequest(url, method) || (method === 'POST' && !record.canSend)) return 3;
      this.#view(responsePtr, responseCapacity, MAX_RESPONSE);
      body = this.#view(bodyPtr, bodyLength, MAX_REQUEST).slice();
      if ((method === 'GET' && bodyLength !== 0) || (method === 'POST' && bodyLength === 0)) return 3;
      return await this.#operation(async () => {
        if (record.expiresAt - Date.now() < 60000) await this.#refresh(record);
        if (method === 'POST' && !record.canSend) return 3;
        if (method === 'POST') { await this.#sendGrace(); this.#startSend(); }
        submissionStarted = method === 'POST';
        const response = await this.#fetch(url, { method, headers: { Authorization: `Bearer ${record.accessToken}`, Accept: 'application/json', ...(method === 'POST' ? { 'Content-Type': 'application/json' } : {}) }, ...(method === 'POST' ? { body } : {}) }, responseCapacity);
        try {
          if (this.#closed) return 1;
          this.#view(responsePtr, response.bytes.length, MAX_RESPONSE).set(response.bytes);
          this.#meta(metaPtr, response.status, response.bytes.length);
          return 0;
        } finally { response.bytes.fill(0); }
      });
    } catch (reason) {
      if (reason instanceof LocalCanceled) return 4;
      if (method === 'POST' && !submissionStarted) return 3;
      return reason instanceof RangeError ? 2 : 1;
    }
    finally { body?.fill(0); }
  }
}
