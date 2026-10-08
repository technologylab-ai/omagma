// Presentation-only normalization. The Zig child remains the provider and
// authority for account identity, bounded fetches and browser destinations.
export const PLUGIN_ID = "io.github.technologylab_ai.omagma";
export const TUI_APP_ID = "TUI.float.omagma";

export function tuiArgv(binary, account, fixtures) {
  const argv = ["omarchy", "launch", "tui", "--app-id=" + TUI_APP_ID, binary, "tui"];
  if (account) argv.push("--account", account);
  if (fixtures) argv.push("--fixtures");
  return argv;
}
export const MAX_ROWS = 30;
export const MAX_FRAME_BYTES = 512 * 1024;
export const MAX_PENDING = 64;
export const STATES = ["never", "loading", "current", "stale", "disconnected", "unavailable"];

export function utf8Length(text) {
  let n = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c < 0x80) n++;
    else if (c < 0x800) n += 2;
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < text.length
             && text.charCodeAt(i + 1) >= 0xdc00 && text.charCodeAt(i + 1) <= 0xdfff) { n += 4; i++; }
    else n += 3;
  }
  return n;
}

export function displayText(value, limit) {
  if (typeof value !== "string") return "";
  const source = value.replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, " ");
  // Scan a UTF-16 prefix without per-character strings or array storage.
  // The output uses one substring; only malformed surrogates need replacing.
  let bytes = 0, end = 0, hasUnpaired = false;
  while (end < source.length) {
    const code = source.charCodeAt(end);
    let size = code < 0x80 ? 1 : code < 0x800 ? 2 : 3;
    let step = 1, unpaired = false;
    if (code >= 0xd800 && code <= 0xdbff && end + 1 < source.length
        && source.charCodeAt(end + 1) >= 0xdc00 && source.charCodeAt(end + 1) <= 0xdfff) {
      size = 4; step = 2;
    } else if (code >= 0xd800 && code <= 0xdfff) unpaired = true;
    if (bytes + size > limit) break;
    bytes += size; end += step;
    hasUnpaired = hasUnpaired || unpaired;
  }
  const prefix = end === source.length ? source : source.slice(0, end);
  return hasUnpaired ? prefix.replace(/[\ud800-\udbff][\udc00-\udfff]|[\ud800-\udfff]/g,
      pair => pair.length === 2 ? pair : "\ufffd") : prefix;
}

export function safeInteger(value, max) {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= max;
}

export function opaqueId(value) {
  return typeof value === "string" && value.length > 0 && utf8Length(value) <= 128
    && !/[\u0000-\u0020\u007f-\u009f\ud800-\udfff]/u.test(value);
}

export function emptyAccounts() {
  return [];
}

export function canonicalAddress(value) {
  if (typeof value !== "string" || value.length === 0 || value.length > 254
      || /[\u0000-\u0020\u007f-\uffff/\\?#"]/.test(value)) return null;
  const at = value.indexOf("@");
  return at > 0 && at < value.length - 1 && value.indexOf("@", at + 1) < 0 ? value : null;
}

export function normalizeSnapshot(value) {
  if (!value || !canonicalAddress(value.account) || STATES.indexOf(value.state) < 0
      || !safeInteger(value.generation, Number.MAX_SAFE_INTEGER)
      || !safeInteger(value.checkedAt, 8640000000000)
      || !safeInteger(value.retryAt, 8640000000000)
      || (value.unread !== null && !safeInteger(value.unread, Number.MAX_SAFE_INTEGER))
      || typeof value.enabled !== "boolean" || typeof value.required !== "boolean"
      || typeof value.partial !== "boolean" || !Array.isArray(value.messages)
      || value.messages.length > MAX_ROWS) return null;
  const rows = [], ids = new Set();
  for (const row of value.messages) {
    if (!row || !opaqueId(row.id) || !opaqueId(row.threadId) || ids.has(row.id)
        || !safeInteger(row.receivedAt, 8640000000000000) || typeof row.unread !== "boolean"
        || typeof row.sender !== "string" || typeof row.subject !== "string"
        || typeof row.snippet !== "string") return null;
    ids.add(row.id);
    rows.push({ id: row.id, threadId: row.threadId, sender: displayText(row.sender, 512),
      subject: displayText(row.subject, 512), snippet: displayText(row.snippet, 1024),
      receivedAt: row.receivedAt, unread: row.unread });
  }
  return { account: value.account, enabled: value.enabled, required: value.required,
    generation: value.generation, state: value.state, checkedAt: value.checkedAt,
    unread: value.unread, partial: value.partial, error: displayText(value.error, 256),
    retryAt: value.retryAt, messages: rows };
}

export function replaceSnapshot(accounts, value) {
  const next = normalizeSnapshot(value);
  if (!next) return null;
  const index = accounts.findIndex(a => a.account === next.account);
  if (index < 0) return null;
  if (next.generation <= accounts[index].generation) return accounts;
  const out = accounts.slice(); out[index] = next;
  return out;
}

export function handshakeAccounts(values) {
  if (!Array.isArray(values) || values.length < 1 || values.length > 3) return null;
  const accounts = [];
  const found = new Set();
  for (const value of values) {
    const account = normalizeSnapshot(value);
    if (!account || found.has(account.account.toLowerCase())) return null;
    found.add(account.account.toLowerCase());
    accounts.push(account);
  }
  return accounts;
}

export function selectedAccount(accounts, selected) {
  return accounts.find(a => a.account === selected) || accounts[0] || {
    account: "", enabled: false, required: false, generation: -1, state: "unavailable", checkedAt: 0,
    unread: null, partial: false, error: "", retryAt: 0, messages: [] };
}

export function initialAccount(accounts, previous) {
  if (accounts.some(a => a.account === previous)) return previous;
  const required = accounts.find(a => a.enabled && a.required);
  return required ? required.account : (accounts[0] ? accounts[0].account : "");
}

export function effectiveState(account, nowMs) {
  if (account.state === "current" && account.checkedAt > 0 && nowMs / 1000 - account.checkedAt > 60)
    return "stale";
  return account.state;
}

export function stateLabel(account, nowMs) {
  const labels = { never: "Never checked", loading: "Loading…", current: "Current",
    stale: "Cached", disconnected: "Disconnected", unavailable: "Unavailable" };
  return labels[effectiveState(account, nowMs)] + (account.partial ? " · Partial page" : "");
}

export function hasAccountWarning(account, nowMs) {
  return effectiveState(account, nowMs) === "disconnected" || account.error !== "";
}

export function emptyLabel(account, nowMs) {
  const state = effectiveState(account, nowMs);
  if (state === "current") return "Inbox is empty";
  if (state === "loading") return "Loading recent Inbox messages…";
  if (state === "never") return "Select Refresh to check this Inbox.";
  if (state === "disconnected") return "Connect this account with omagma auth, then refresh.";
  if (state === "unavailable") return "Mail access is unavailable. Open this account’s Inbox in Chrome.";
  return "Recent messages are unavailable. Refresh to try again.";
}

export function dateLabel(ms) {
  if (!ms) return "—";
  const date = new Date(ms);
  return date.toLocaleDateString(undefined, { month: "short", day: "numeric" }) + " "
    + date.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
}

export function checkedLabel(account) {
  return account.checkedAt ? "Last checked " + dateLabel(account.checkedAt * 1000) : "Not checked yet";
}

export function requestLine(id, cmd, fields) {
  if (!safeInteger(id, Number.MAX_SAFE_INTEGER)) throw new Error("invalid request id");
  const value = Object.assign({}, fields || {}, { id, cmd });
  const line = JSON.stringify(value) + "\n";
  if (utf8Length(line) > 16 * 1024) throw new Error("request too large");
  return line;
}

export function parseLine(line) {
  if (typeof line !== "string" || utf8Length(line) > MAX_FRAME_BYTES) return null;
  try { const value = JSON.parse(line); return value && typeof value === "object" ? value : null; }
  catch (_) { return null; }
}

export function daemonArgv(binary, config, fixtures, dryRunOpen) {
  const argv = [binary, "daemon"];
  if (config) argv.push("--config", config);
  if (fixtures) argv.push("--fixtures");
  if (dryRunOpen) argv.push("--dry-run-open");
  return argv;
}
