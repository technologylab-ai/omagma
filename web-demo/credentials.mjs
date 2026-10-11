const encoder = new TextEncoder();
const READ = 'https://www.googleapis.com/auth/gmail.readonly';
const SEND = 'https://www.googleapis.com/auth/gmail.send';
const MODIFY = 'https://www.googleapis.com/auth/gmail.modify';
const CONTACTS = 'https://www.googleapis.com/auth/contacts';
const CONTACTS_READ = 'https://www.googleapis.com/auth/contacts.readonly';
const capabilities = new Set(['mail-read', 'mail-send', 'mail-modify', 'contacts-read', 'contacts-write', 'calendar-rsvp']);
const scopes = new Set([READ, SEND, MODIFY, CONTACTS, CONTACTS_READ]);

function reject(message) { throw new Error(message); }
function printable(value, max = 4096) {
  return typeof value === 'string' && value.length > 0 && value.length <= max && /^[\x21-\x7e]+$/.test(value);
}
function uniqueStrings(values, allowed, max) {
  return Array.isArray(values) && values.length > 0 && values.length <= max && values.every(value => allowed.has(value)) && new Set(values).size === values.length;
}

export function scopesFor(caps) {
  if (!uniqueStrings(caps, capabilities, 6) || !caps.includes('mail-read')) reject('A terminal grant must include a valid mail-read capability.');
  const result = [caps.includes('mail-modify') ? MODIFY : READ];
  if ((caps.includes('mail-send') || caps.includes('calendar-rsvp')) && !caps.includes('mail-modify')) result.push(SEND);
  if (caps.includes('contacts-write')) result.push(CONTACTS);
  else if (caps.includes('contacts-read')) result.push(CONTACTS_READ);
  return result;
}

export async function identityHash(parts) {
  const bytes = encoder.encode(parts.map(part => `${part}\0`).join(''));
  try {
    const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
    return Array.from(digest, byte => byte.toString(16).padStart(2, '0')).join('');
  } finally { bytes.fill(0); }
}

export async function tokenFilename(grant) {
  return `terminal-${await identityHash(['omagma-credential-value-v1', 'terminal', grant.account, grant.clientId, grant.grantId])}.token`;
}

async function jsonFile(file, limit, label) {
  if (!file || file.size === 0 || file.size > limit) reject(`Choose a ${label} file within the supported size limit.`);
  let parsed;
  try { parsed = JSON.parse(await file.text()); }
  catch { reject(`The selected ${label} file is not valid JSON.`); }
  return parsed;
}

function client(data) {
  const value = data?.installed;
  if (!value || !printable(value.client_id) || !value.client_id.endsWith('.apps.googleusercontent.com') || !printable(value.client_secret)) reject('Choose the original downloaded Google Desktop OAuth client JSON.');
  if (value.token_uri !== undefined && value.token_uri !== 'https://oauth2.googleapis.com/token') reject('The OAuth registration uses an unsupported token endpoint.');
  if (value.auth_uri !== undefined && !['https://accounts.google.com/o/oauth2/auth', 'https://accounts.google.com/o/oauth2/v2/auth'].includes(value.auth_uri)) reject('The OAuth registration uses an unsupported authorization endpoint.');
  return { clientId: value.client_id, clientSecret: value.client_secret };
}

export async function importCredentialFiles(clientFiles, grantFile, tokenFiles) {
  if (clientFiles.length === 0 || clientFiles.length > 3) reject('Choose one to three OAuth client JSON files.');
  if (tokenFiles.length === 0 || tokenFiles.length > 128) reject('Choose token files, or a credential folder containing at most 128 files.');
  const registrations = new Map();
  for (const file of clientFiles) {
    const registration = client(await jsonFile(file, 16 * 1024, 'OAuth client'));
    if (registrations.has(registration.clientId)) reject('Choose one registration file per OAuth client.');
    registrations.set(registration.clientId, registration);
  }
  const registry = await jsonFile(grantFile, 64 * 1024, 'terminal grants');
  if (registry?.version !== 1 || !Array.isArray(registry.accounts) || registry.accounts.length === 0 || registry.accounts.length > 3) reject('The terminal grant registry must contain one to three accounts.');
  const seen = new Set();
  const result = [];
  for (const grant of registry.accounts) {
    if (!printable(grant.account, 254) || !grant.account.includes('@') || seen.has(grant.account.toLowerCase())) reject('The terminal grant registry has an invalid or duplicate account.');
    seen.add(grant.account.toLowerCase());
    if (!printable(grant.clientId) || !grant.clientId.endsWith('.apps.googleusercontent.com') || typeof grant.clientFile !== 'string' || grant.clientFile.length === 0 || grant.clientFile.length > 4096 || !uniqueStrings(grant.scopes, scopes, 5)) reject('The terminal grant registry has an invalid registration or scope set.');
    if (grant.enabled !== undefined && typeof grant.enabled !== 'boolean') reject('The terminal grant registry has an invalid enabled flag.');
    const expectedScopes = scopesFor(grant.capabilities);
    if (expectedScopes.length !== grant.scopes.length || expectedScopes.some((scope, index) => scope !== grant.scopes[index])) reject('The terminal grant capabilities and recorded scopes do not match.');
    const identity = await identityHash(['omagma-terminal-grant-v1', ...grant.scopes]);
    if (grant.grantId !== identity) reject('The terminal grant identity does not match its recorded scopes.');
    if (grant.enabled === false || !registrations.has(grant.clientId)) continue;
    const filename = await tokenFilename(grant);
    const matching = tokenFiles.filter(file => file.name === filename);
    if (matching.length > 1) reject('The selected files contain duplicate tokens for one grant.');
    if (matching.length === 0) continue;
    const file = matching[0];
    if (file.size === 0 || file.size > 4096) reject('A matched token file exceeds the supported size.');
    const refreshToken = await file.text();
    if (!printable(refreshToken)) reject('A matched token file must contain the unmodified refresh token.');
    result.push({ account: grant.account, ...registrations.get(grant.clientId), grantId: grant.grantId, capabilities: [...grant.capabilities], scopes: [...grant.scopes], refreshToken });
  }
  registrations.clear();
  if (result.length === 0) reject('No selected terminal token matches an enabled grant and OAuth client. Choose the matching client, grants and token files.');
  return result;
}

export function permissions(caps, actualScopes) {
  const readScope = actualScopes.includes(READ) || actualScopes.includes(MODIFY);
  const sendScope = actualScopes.includes(SEND) || actualScopes.includes(MODIFY);
  return { canRead: caps.includes('mail-read') && readScope, canSend: caps.includes('mail-send') && sendScope };
}

export function parseRefreshedToken(data, originalScopes) {
  if (!data || !printable(data.access_token) || typeof data.token_type !== 'string' || data.token_type.toLowerCase() !== 'bearer' || !Number.isInteger(data.expires_in) || data.expires_in <= 0 || data.expires_in > 86400) reject('Google returned an invalid access-token response.');
  // RFC 6749 permits omission when the original scopes have not changed.
  const actualScopes = data.scope === undefined ? [...originalScopes] : (typeof data.scope === 'string' ? data.scope.split(/\s+/).filter(Boolean) : []);
  if (!uniqueStrings(actualScopes, scopes, 5)) reject('Google returned an unsupported access-token scope set.');
  return { accessToken: data.access_token, actualScopes, expiresAt: Date.now() + data.expires_in * 1000 };
}
