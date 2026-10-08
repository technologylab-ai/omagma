import assert from "node:assert/strict";
import * as Model from "../Model.mjs";

const ADDRESSES = ["acct@other.example", "work@business.example", "optional@third.example"];

function snapshot(account, generation = 1, extra = {}) {
  return { account, enabled: account !== ADDRESSES[2], required: account !== ADDRESSES[2],
    generation, state: "current", checkedAt: 100, unread: 71, partial: false, error: "", retryAt: 0,
    messages: [{ id: "same-id", threadId: "same-thread", sender: account,
      subject: "<img src=x onerror=alert(1)>", snippet: "<b>Literal HTML</b>", receivedAt: 100000, unread: false }], ...extra };
}

const init = Model.handshakeAccounts(ADDRESSES.map(a => snapshot(a)));
assert.equal(Model.initialAccount(init, ""), ADDRESSES[0]);
assert.equal(Model.initialAccount(init.map((a, i) => ({ ...a, enabled: i === 1 })), ""), ADDRESSES[1]);
assert.equal(Model.initialAccount(init, ADDRESSES[1]), ADDRESSES[1]);
const oneAccount = Model.handshakeAccounts([snapshot(ADDRESSES[1])]);
assert.equal(Model.initialAccount(oneAccount, ""), ADDRESSES[1]);
assert.equal(oneAccount.length, 1);
assert.equal(oneAccount[0].account, ADDRESSES[1]);
assert.equal(oneAccount[0].enabled, true);
assert.equal(Model.initialAccount(oneAccount, ADDRESSES[0]), ADDRESSES[1]);
assert.equal(Model.replaceSnapshot(oneAccount, snapshot(ADDRESSES[0], 2)), null);
assert.deepEqual(Model.emptyAccounts(), []);
assert.equal(Model.selectedAccount([], "").messages.length, 0);
assert.equal(Model.initialAccount([], ""), "");
assert.equal(Model.handshakeAccounts(ADDRESSES.map(a => snapshot(a)).concat(snapshot("fourth@example.com"))), null);
assert.equal(Model.handshakeAccounts([snapshot("Case@example.com"), snapshot("case@example.com")]), null);
for (const address of ["", "@domain", "local@", "a@b@c", "has space@example.com", "bad\n@example.com", "a/b@example.com", "a?b@example.com", "é@example.com", "a".repeat(254) + "@b"])
  assert.equal(Model.handshakeAccounts([snapshot(address)]), null);
assert.equal(Model.canonicalAddress("Mixed.Case+tag@other.example"), "Mixed.Case+tag@other.example");
assert.equal(init[2].enabled, false);
assert.equal(init[2].required, false);
assert.equal(Model.initialAccount(init, ADDRESSES[2]), ADDRESSES[2]);
assert.equal(Model.initialAccount(init, "removed@example.com"), ADDRESSES[0]);
assert.equal(Model.handshakeAccounts([]), null);
assert.equal(init[0].messages[0].subject, "<img src=x onerror=alert(1)>");
assert.equal(Model.selectedAccount(init, ADDRESSES[1]).messages[0].sender, ADDRESSES[1]);
assert.equal(Model.replaceSnapshot(init, snapshot(ADDRESSES[0], 0)), init);
assert.equal(Model.replaceSnapshot(init, snapshot(ADDRESSES[0], 1)), init);
assert.equal(Model.replaceSnapshot(init, snapshot("intruder@example.org")), null);
assert.equal(Model.handshakeAccounts([snapshot(ADDRESSES[0]), snapshot(ADDRESSES[0]), snapshot(ADDRESSES[2])]), null);
assert.equal(Model.normalizeSnapshot(snapshot(ADDRESSES[0], 2, { messages: new Array(31).fill(init[0].messages[0]) })), null);
assert.equal(Model.normalizeSnapshot(snapshot(ADDRESSES[0], 2, { unread: -1 })), null);
assert.equal(Model.normalizeSnapshot(snapshot(ADDRESSES[0], 2, { generation: 9007199254740992 })), null);
assert.equal(Model.normalizeSnapshot(snapshot(ADDRESSES[0], 2, { messages: [{ ...init[0].messages[0], id: "x".repeat(129) }] })), null);
assert.equal(Model.displayText("😀😀x", 8), "😀😀");
assert.equal(Model.displayText("a\u0000b\n<c>\u202e", 100), "a b <c> ");
assert.equal(Model.displayText("\ud800", 3), "�");
assert.equal(Model.utf8Length("😀äx"), 7);
// Compare valid UTF-8 prefix selection to an independent byte-count reference,
// including adjacent valid/unpaired surrogates, control characters and BMP text.
function referenceDisplay(value, limit) {
  const sanitized = value.replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, " ");
  const chunks = [];
  let used = 0;
  for (const character of sanitized) {
    const code = character.codePointAt(0);
    const safe = code >= 0xd800 && code <= 0xdfff ? "�" : character;
    const size = Buffer.byteLength(safe, "utf8");
    if (used + size > limit) break;
    used += size;
    chunks.push(safe);
  }
  return chunks.join("");
}
const characters = ["x", "ä", "中", "😀", "\ud800", "\udc00", "\u0000", "\u202e"];
for (const first of characters) for (const second of characters) for (const third of characters) {
  const value = first + second + third;
  for (let limit = 0; limit <= 12; limit++) assert.equal(Model.displayText(value, limit), referenceDisplay(value, limit));
}
assert.equal(Model.emptyLabel(snapshot(ADDRESSES[0], 1, { messages: [] }), 100000), "Inbox is empty");
for (const state of ["never", "loading", "stale", "disconnected", "unavailable"])
  assert.notEqual(Model.emptyLabel(snapshot(ADDRESSES[0], 1, { state, messages: [] }), 100000), "Inbox is empty");
assert.equal(Model.effectiveState(init[0], 161000), "stale");
assert.equal(Model.stateLabel(init[0], 161000), "Cached");
assert.equal(Model.hasAccountWarning(init[0], 161000), false);
assert.equal(Model.hasAccountWarning({ ...init[0], state: "stale", error: "" }, 161000), false);
assert.equal(Model.hasAccountWarning({ ...init[0], state: "stale", error: "TransportFailed" }, 161000), true);
assert.equal(Model.hasAccountWarning({ ...init[0], state: "disconnected", error: "" }, 161000), true);
assert.equal(Model.parseLine("x".repeat(524289)), null);
assert.equal(Model.parseLine("garbage"), null);
assert.throws(() => Model.requestLine(9007199254740992, "hello"));
assert.deepEqual(Model.daemonArgv("/binary path", "/config path", true, true),
  ["/binary path", "daemon", "--config", "/config path", "--fixtures", "--dry-run-open"]);
assert.deepEqual(Model.tuiArgv("/plugin with spaces/bin/omagma", "work@example.test", false),
  ["omarchy", "launch", "tui", "--app-id=TUI.float.omagma", "/plugin with spaces/bin/omagma", "tui", "--account", "work@example.test"]);
assert.deepEqual(Model.tuiArgv("/binary", "", true),
  ["omarchy", "launch", "tui", "--app-id=TUI.float.omagma", "/binary", "tui", "--fixtures"]);

let accounts = init;
for (let generation = 2; generation <= 1001; generation++) {
  for (const address of ADDRESSES) accounts = Model.replaceSnapshot(accounts, snapshot(address, generation));
  assert.equal(accounts.length, 3);
  assert.equal(accounts.reduce((sum, a) => sum + a.messages.length, 0), 3);
  for (const account of accounts) assert.equal(account.messages[0].sender, account.account);
}
assert.equal(accounts[0].generation, 1001);
console.log("UI model: validation, plain text, state/empty distinction, account isolation, stale generations and 1000 replacements passed.");
