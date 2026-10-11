import assert from 'node:assert/strict';
import test from 'node:test';
import { identityHash, tokenFilename, importCredentialFiles, scopesFor, parseRefreshedToken, permissions } from './credentials.mjs';

export async function fixture(capabilities = ['mail-read', 'mail-send']) {
  const grant = { account: 'ada@example.test', clientFile: '/private/OAuth client.json', clientId: 'synthetic.apps.googleusercontent.com', capabilities, scopes: scopesFor(capabilities) };
  grant.grantId = await identityHash(['omagma-terminal-grant-v1', ...grant.scopes]);
  const registration = { installed: { client_id: grant.clientId, client_secret: 'synthetic-secret', token_uri: 'https://oauth2.googleapis.com/token', auth_uri: 'https://accounts.google.com/o/oauth2/v2/auth' } };
  return {
    grant,
    clients: [new File([JSON.stringify(registration)], 'client.json')],
    registry: new File([JSON.stringify({ version: 1, accounts: [grant] })], 'terminal-grants.json'),
    tokens: [new File(['synthetic-refresh'], await tokenFilename(grant))],
  };
}

test('native scope identity and exact token basename connect matching files', async () => {
  const files = await fixture();
  const records = await importCredentialFiles(files.clients, files.registry, files.tokens);
  assert.equal(records.length, 1);
  assert.equal(records[0].account, files.grant.account);
  assert.equal(records[0].refreshToken, 'synthetic-refresh');
});

test('a renamed or unmatched terminal token cannot supply another grant', async () => {
  const files = await fixture();
  await assert.rejects(() => importCredentialFiles(files.clients, files.registry, [new File(['synthetic-refresh'], 'terminal-unmatched.token')]), /No selected terminal token matches/);
});

test('changed grant scopes invalidate the identity before connecting', async () => {
  const files = await fixture();
  const changed = { ...files.grant, grantId: '0'.repeat(64) };
  await assert.rejects(() => importCredentialFiles(files.clients, new File([JSON.stringify({ version: 1, accounts: [changed] })], 'terminal-grants.json'), files.tokens), /identity does not match/);
});

test('registration endpoint policy rejects credential exfiltration', async () => {
  const files = await fixture();
  const malicious = new File([JSON.stringify({ installed: { client_id: files.grant.clientId, client_secret: 'synthetic-secret', token_uri: 'https://attacker.invalid/token' } })], 'client.json');
  await assert.rejects(() => importCredentialFiles([malicious], files.registry, files.tokens), /unsupported token endpoint/);
});

test('reported narrower scopes disable send; omitted scopes preserve the original grant', () => {
  const original = scopesFor(['mail-read', 'mail-send']);
  const base = { access_token: 'synthetic-access', expires_in: 3600, token_type: 'Bearer' };
  const narrowed = parseRefreshedToken({ ...base, scope: original[0] }, original);
  assert.deepEqual(permissions(['mail-read', 'mail-send'], narrowed.actualScopes), { canRead: true, canSend: false });
  const unchanged = parseRefreshedToken(base, original);
  assert.deepEqual(permissions(['mail-read', 'mail-send'], unchanged.actualScopes), { canRead: true, canSend: true });
  assert.deepEqual(permissions(['mail-read'], unchanged.actualScopes), { canRead: true, canSend: false });
});
