#!/usr/bin/env python3
"""Synthetic agent CLI behavior tests; run only with the cooperative host lock."""
from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import resource
import selectors
import subprocess
import stat
import tempfile
import threading
import time
import traceback
from urllib.parse import parse_qs, urlsplit

from build_info import build_mode, read_build_info

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests/fixtures/terminal"
MANIFEST = json.loads((FIXTURES / "manifest.json").read_text())
ACCOUNTS = MANIFEST["accounts"]
MAX_FRAME = 8 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def addresses(values):
    return [value if isinstance(value, str) else value["address"] for value in values]


def no_core_dump():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


class Client:
    def __init__(self, binary, directory, scenario=None, alias="cli", extra=(), fixtures=True):
        self.binary, self.scenario, self.alias, self.extra = binary, scenario, alias, tuple(extra)
        self.fixtures = fixtures
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ)
        env["HOME"] = str(self.directory / "home")
        for key in ["CONFIG", "CACHE", "DATA", "STATE"]:
            env[f"XDG_{key}_HOME"] = str(self.directory / key.lower())
        runtime = self.directory / "runtime"
        runtime.mkdir(mode=0o700, exist_ok=True)
        env["XDG_RUNTIME_DIR"] = str(runtime)
        for key in ["DISPLAY", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS"]:
            env.pop(key, None)
        self.environment = env
        argv = [str(binary), alias, "--cache-dir", str(self.directory / "cache")]
        if fixtures:
            argv += ["--fixtures", "--fixture-root", str(FIXTURES)]
        else:
            argv += ["--config", str(ROOT / "tests/fixtures/all-accounts.json"),
                     "--grant-file", str(self.directory / "synthetic-absent-grants.json")]
        if scenario:
            argv += ["--fixture-scenario", scenario]
        argv += list(extra)
        self.process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, env=env, cwd=self.directory, bufsize=0,
                                        preexec_fn=no_core_dump)
        self.selector = selectors.DefaultSelector()
        for stream in [self.process.stdout, self.process.stderr]:
            os.set_blocking(stream.fileno(), False)
            self.selector.register(stream, selectors.EVENT_READ)
        self.buffer = bytearray()
        self.stderr = bytearray()
        self.next_id = 0
        self.frame_count = 0
        self.max_frame_bytes = 0
        os.set_blocking(self.process.stdin.fileno(), False)

    def raw(self, data, seconds=8):
        view = memoryview(data)
        deadline = time.monotonic() + seconds
        while view:
            require(time.monotonic() < deadline, "CLI stdin write exceeded finite deadline")
            try:
                written = os.write(self.process.stdin.fileno(), view)
                view = view[written:]
            except BlockingIOError:
                time.sleep(.005)

    def restart(self):
        binary, directory, scenario, alias, extra = self.binary, self.directory, self.scenario, self.alias, self.extra
        frames, maximum, stderr = self.frame_count, self.max_frame_bytes, bytes(self.stderr)
        self.close()
        require(self.process.returncode == 0, "CLI did not exit cleanly before restart")
        self.__init__(binary, directory, scenario, alias, extra, self.fixtures)
        self.frame_count, self.max_frame_bytes = frames, maximum
        self.stderr.extend(stderr)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=3)
        # A write failure can precede receive(); retain bounded crash diagnostics.
        for _ in range(16):
            try:
                chunk = os.read(self.process.stderr.fileno(), 65536)
            except BlockingIOError:
                break
            if not chunk:
                break
            self.stderr.extend(chunk[:max(0, 65536 - len(self.stderr))])
        self.selector.close()
        for stream in [self.process.stdin, self.process.stdout, self.process.stderr]:
            if not stream.closed:
                stream.close()

    def receive(self, timeout=8):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            require(time.monotonic() < deadline, "CLI reply deadline exceeded")
            events = self.selector.select(min(.05, max(0, deadline - time.monotonic())))
            for key, _ in events:
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    self.selector.unregister(key.fileobj)
                    continue
                if key.fileobj is self.process.stderr:
                    self.stderr.extend(chunk)
                    require(len(self.stderr) <= 65536, "CLI stderr exceeded diagnostic cap")
                else:
                    self.buffer.extend(chunk)
                    require(len(self.buffer) <= MAX_FRAME, "CLI output exceeded frame cap")
            require(self.process.poll() is None or b"\n" in self.buffer, "CLI exited before replying")
        line, _, rest = self.buffer.partition(b"\n")
        self.buffer = bytearray(rest)
        self.max_frame_bytes = max(self.max_frame_bytes, len(line))
        self.frame_count += 1
        require(b"\x1b" not in line and b"\x00" not in line, "CLI emitted mail-derived raw terminal controls")
        value = json.loads(line)
        require(isinstance(value, dict) and value.get("version") == 1, "CLI reply omitted protocol version")
        return value

    def request(self, cmd, account=ACCOUNTS[0], ok=True, **params):
        self.next_id += 1
        request = {"id": f"test-{self.next_id}", "cmd": cmd, **params}
        if account is not None:
            request["account"] = account
        self.raw(json.dumps(request, ensure_ascii=False).encode() + b"\n")
        reply = self.receive()
        require(reply.get("id") == request["id"], "CLI response correlation failed")
        if account is not None:
            require(reply.get("account") == account, "CLI response lost explicit account identity")
        require(reply.get("ok") is ok, f"Unexpected outcome for {cmd}: {reply.get('error', {}).get('code', 'no error code')}")
        if not ok:
            error = reply.get("error", {})
            require(isinstance(error.get("code"), str) and bool(error["code"]), "failure omitted stable error code")
            require(isinstance(error.get("message"), str), "failure omitted error message")
            return error
        require("data" in reply, "successful command omitted data")
        return reply["data"]


def list_all(client, account, label=None):
    result, cursor, seen_cursors = [], "", set()
    for _ in range(20):
        page = client.request("mail.list", account, limit=12, cursor=cursor, **({"label": label} if label is not None else {}))
        messages = page["messages"]
        require(len(messages) <= 12, "provider ignored requested page limit")
        result += messages
        cursor = page.get("nextCursor") or ""
        if not cursor:
            break
        require(cursor not in seen_cursors, "pagination cursor cycle")
        seen_cursors.add(cursor)
    else:
        raise AssertionError("fixture pagination did not terminate")
    ids = [m["id"] for m in result]
    require(len(ids) == len(set(ids)) == 96, "pagination omitted or duplicated fixture messages")
    return result


def cache_limits(client, account):
    stats = client.request("cache.stats", account)
    for key in ["metadataEntries", "metadataLimit", "diskBytes", "diskLimitBytes", "bodyLimitBytes", "runtimeReservationBytes"]:
        require(type(stats.get(key)) is int and stats[key] >= 0, f"cache.stats omitted bounded metric {key}")
    require(stats["metadataEntries"] <= stats["metadataLimit"] <= 10000, "metadata cache exceeded configured hard limit")
    require(stats["diskBytes"] <= stats["diskLimitBytes"] <= 1024**3, "disk cache exceeded hard limit")
    require(stats["bodyLimitBytes"] <= 2 * 1024**2, "body cap exceeded published limit")
    require(stats["runtimeReservationBytes"] <= 64 * 1024**2, "terminal runtime reservation exceeded64MiB")
    require(stats.get("terminalHeapLimitBytes") == 64 * 1024**2, "terminal heap ceiling differs from64MiB")
    require(stats.get("fixedBackendReservationBytes") == 16 * 1024**2, "fixed backend reservation differs from16MiB")
    for key in ["allocatorUsedBytes", "allocatorPeakBytes", "rejectedAllocations"]:
        require(type(stats.get(key)) is int and stats[key] >= 0, f"cache.stats omitted actual allocation metric {key}")
    require(stats["allocatorUsedBytes"] <= stats["allocatorPeakBytes"] <= stats["terminalHeapLimitBytes"],
            "actual terminal heap allocations exceeded the configured cap")
    return stats


def pagination_and_isolation(client):
    results = {account: list_all(client, account) for account in ACCOUNTS}
    require([m["id"] for m in results[ACCOUNTS[0]]] == [m["id"] for m in results[ACCOUNTS[1]]], "fixture IDs did not collide")
    for account in ACCOUNTS:
        require(cache_limits(client, account)["metadataEntries"] > 30, "terminal cache still capped at bar-sized30rows")
        message = client.request("mail.read", account, messageId="shared-msg-012")
        require(account in message["bodyText"], "same-ID lookup leaked another account's body")


def accounts_and_search(client):
    listed = client.request("accounts.list", account=None)
    require({a["address"] for a in listed["accounts"]} == set(ACCOUNTS), "account discovery omitted or invented identities")
    for account in ACCOUNTS:
        found = client.request("mail.search", account, query="thread 003", limit=12)
        require({m["id"] for m in found["messages"]} == {"shared-msg-010", "shared-msg-011", "shared-msg-012"},
                "search did not filter the selected account's messages")
        target = client.request("mail.open", account, messageId="shared-msg-012")
        parsed = urlsplit(target["url"])
        require(target["opened"] is False and target["fixture"] is True, "fixture browser command launched a browser")
        require(parsed.scheme == "https" and parsed.netloc == "mail.google.com"
                and parse_qs(parsed.query).get("authuser") == [account], "browser target lost selected account identity")


def attachment_roundtrip(client):
    message = client.request("mail.read", messageId="shared-msg-003")
    require(len(message["attachments"]) == 1, "message omitted attachment metadata")
    attachment = message["attachments"][0]
    result = client.request("mail.attachment", messageId=message["id"], attachmentId=attachment["id"])
    encoded = result.get("base64") or result.get("data")
    require(isinstance(encoded, str), "attachment command omitted encoded binary data")
    data = base64.b64decode(encoded + "=" * (-len(encoded) % 4), altchars=b"-_", validate=True)
    oracle = MANIFEST["attachmentExpected"]
    require(len(data) == oracle["size"] and hashlib.sha256(data).hexdigest() == oracle["sha256"],
            "attachment bytes failed independent digest")
    require(result["filename"] == oracle["safeFilename"], "attachment filename retained path traversal")


def cursor_binding(client):
    first = client.request("mail.list", ACCOUNTS[0], limit=12)
    cursor = first["nextCursor"]
    client.request("mail.list", ACCOUNTS[1], ok=False, limit=12, cursor=cursor)
    client.request("mail.search", ACCOUNTS[0], ok=False, query="unmatched-fixture", limit=12, cursor=cursor)
    client.request("mail.list", ACCOUNTS[0], ok=False, limit=101)
    client.request("mail.read", "foreign@example.com", ok=False, messageId="shared-msg-001")
    client.request("mail.list", None, ok=False, limit=12)


def mime_and_readonly(client):
    for suffix, case in [(1, "quoted-printable"), (2, "base64"), (3, "alternative-attachment"), (10, "external-body"), (11, "latin1")]:
        message = client.request("mail.read", messageId=f"shared-msg-{suffix:03}")
        expected = MANIFEST["bodyExpected"][case]
        require(message["bodyText"].replace("\r\n", "\n") == expected, f"incorrect MIME/charset/body decoding for {case}")
    message = client.request("mail.read", messageId="shared-msg-001")
    require(message["unread"] is True, "read silently changed unread state")
    html = client.request("mail.read", messageId="shared-msg-004")
    require("Café" in html["bodyText"] and "tea" in html["bodyText"], "HTML-only body was not readable")
    require("alert(" not in html["bodyText"] and "display:none" not in html["bodyText"], "HTML active elements reached readable text")
    client.request("mail.read", messageId="shared-msg-007")
    named = client.request("mail.read", messageId=MANIFEST["displayNameExpected"]["messageId"])
    require(named["from"]["name"] == MANIFEST["displayNameExpected"]["name"], "From display name was not MIME-decoded")
    require(addresses(named["to"]) == MANIFEST["displayNameExpected"]["to"], "encoded comma changed recipient grammar")
    require(named["to"][0]["name"] == MANIFEST["displayNameExpected"]["name"], "recipient display name was not MIME-decoded")


def thread_and_reply(client):
    thread = client.request("mail.thread", threadId="shared-thread-001")
    require({m["id"] for m in thread["messages"]} == {"shared-msg-004", "shared-msg-005", "shared-msg-006"}, "thread omitted or mixed messages")
    for account in ACCOUNTS:
        draft = client.request("mail.reply", account, messageId="shared-msg-005", all=True)
        expected = MANIFEST["replyAllExpected"][account]
        require(addresses(draft["to"]) == expected["to"], "reply-all did not prefer Reply-To")
        require(addresses(draft["cc"]) == expected["cc"], "reply-all included self/duplicates or dropped other recipients")
        require(not draft.get("bcc"), "reply-all exposed Bcc")
        require(draft["threadId"] == "shared-thread-001", "reply lost account-specific thread context")
        require(draft["inReplyTo"] == f"<fixture-005-{account.split('@')[0]}@example.org>", "reply headers reference wrong account")
    client.request("mail.reply", messageId="shared-msg-006", all=True, ok=False)


def draft_and_send(client):
    draft = client.request("draft.create", draft={"to": [{"address": "recipient@example.org", "name": "Recipient Fixture"}],
                                                  "cc": [], "bcc": [], "subject": "Synthetic draft café 👋", "bodyText": "Fixture draft body."})
    draft_id = draft["id"]
    client.request("draft.read", ACCOUNTS[1], draftId=draft_id, ok=False)
    changed = client.request("draft.update", draftId=draft_id, draft={"to": [{"address": "recipient@example.org"}],
                                                                   "cc": [], "bcc": [], "subject": "Updated fixture", "bodyText": "Reviewed body."})
    require(changed["bodyText"] == "Reviewed body.", "draft update lost reviewed body")
    client.request("draft.send", draftId=draft_id, ok=False)
    before = cache_limits(client, ACCOUNTS[0])
    sent = client.request("draft.send", draftId=draft_id, operationId="fixture-known-send")
    replay = client.request("draft.send", draftId=draft_id, operationId="fixture-known-send")
    require(sent["outcome"] == "applied" and replay == sent, "send operation replay was not idempotent")
    after = cache_limits(client, ACCOUNTS[0])
    require(after["fixtureSends"] == before["fixtureSends"] + 1, "send replay made an additional provider send")
    client.request("mail.send", operationId="fixture-known-send", draft={"to": [{"address": "other@example.org"}],
                                                                         "subject": "Different operation content", "bodyText": "Different."}, ok=False)
    require(client.request("draft.discard", draftId=draft_id)["discarded"] is True,
            "completed local draft could not be discarded")
    client.request("draft.read", draftId=draft_id, ok=False)
    require(client.request("operation.read", operationId="fixture-known-send") == sent,
            "discarding a completed draft erased its operation receipt")


def header_injection(client):
    for draft in [{"to": ["fixture@example.org\r\nBcc: hidden@example.net"], "subject": "Fixture", "bodyText": "Body"},
                  {"to": ["fixture@example.org"], "subject": "Fixture\r\nX-Injected: true", "bodyText": "Body"}]:
        client.request("draft.create", draft=draft, ok=False)


def draft_wrong_type_rollback(client):
    original = {"to": ["recipient@example.org"], "subject": "Retain fixture subject", "bodyText": "Retain fixture body."}
    created = client.request("draft.create", draft=original)
    for value in [None, 123, [], {"unexpected": "object"}, True]:
        client.request("draft.update", draftId=created["id"], draft={**original, "bodyText": value}, ok=False)
        preserved = client.request("draft.read", draftId=created["id"])
        require(preserved["bodyText"] == original["bodyText"] and preserved["subject"] == original["subject"],
                "invalid draft type changed persisted content")
    client.request("draft.update", draftId=created["id"], draft={**original, "subject": 42}, ok=False)
    for value in [None, [], "not a draft"]:
        client.request("draft.create", draft=value, ok=False)


def invalid_message_id_reply(client):
    source = json.loads((FIXTURES / "accounts/personal.json").read_text())
    message = next(m for m in source["messages"] if m["id"] == "shared-msg-005")
    for header in message["payload"]["headers"]:
        if header["name"].lower() == "message-id":
            header["value"] = "not-a-valid-rfc-message-id"
    root = client.directory / "invalid-thread-fixture"
    (root / "accounts").mkdir(parents=True)
    (root / "accounts/personal.json").write_text(json.dumps(source))
    client.extra = ("--fixture-root", str(root))
    client.restart()
    before = client.request("draft.list")
    error = client.request("mail.reply", messageId=message["id"], all=True, ok=False)
    require(error["code"] == "MissingMessageId", "malformed nonempty Message-ID claimed a reply association")
    require(client.request("draft.list") == before, "invalid threading created an orphan reply draft")


def install_inbound_address_fixtures(client):
    """Override only two fictional delivered headers; preserve baseline workload."""
    fixture = json.loads((FIXTURES / "inbound-addresses.json").read_text())
    root = client.directory / "inbound-address-fixture"
    (root / "accounts").mkdir(parents=True)
    for account, cases in fixture["accounts"].items():
        source = json.loads((FIXTURES / f"accounts/{account.split('@')[0]}.json").read_text())
        for case in cases.values():
            message = next(m for m in source["messages"] if m["id"] == case["messageId"])
            headers = message["payload"]["headers"]
            headers[:] = [h for h in headers if h["name"].lower() != case["headerName"].lower()]
            headers.append({"name": case["headerName"], "value": case["headerValue"]})
        (root / f"accounts/{account.split('@')[0]}.json").write_text(json.dumps(source))
    client.extra = ("--fixture-root", str(root))
    client.restart()
    return fixture


def incoming_recipient_over32(client):
    fixture = install_inbound_address_fixtures(client)
    for account in ACCOUNTS:
        case = fixture["accounts"][account]["manyRecipients"]
        listed = client.request("mail.list", account, limit=100)["messages"]
        require(len(listed) == 96, "one delivered wide header aborted mailbox listing")
        metadata = next(m for m in listed if m["id"] == case["messageId"])
        require(addresses(metadata["to"]) == case["expectedAddresses"], "incoming metadata recipients were truncated or crossed accounts")
        full = client.request("mail.read", account, messageId=case["messageId"])
        require(addresses(full["to"]) == case["expectedAddresses"] and account in full["bodyText"],
                "full wide-header message lost participants or account-specific content")
        thread = client.request("mail.thread", account, threadId=full["threadId"])["messages"]
        received = next(m for m in thread if m["id"] == full["id"])
        require(addresses(received["to"]) == case["expectedAddresses"] and received["bodyText"] == full["bodyText"],
                "thread context changed wide-header participants or account body")
        reply = client.request("mail.reply", account, messageId=full["id"], all=False)
        require(addresses(reply["to"]) == [case["normalReplyRecipient"]] and addresses(reply["cc"]) == [],
                "ordinary reply unnecessarily copied the oversized incoming recipient list")
        before = client.request("draft.list", account)
        rejected = client.request("mail.reply", account, messageId=full["id"], all=True, ok=False)
        require(rejected["code"] == "TooManyRecipients", "reply-all silently truncated an oversized outgoing envelope")
        require(client.request("draft.list", account) == before, "failed wide reply-all created or modified a local draft")
        require(cache_limits(client, account)["fixtureSends"] == 0, "wide-header planning submitted mail")
    client.evidence = {"incomingRecipientsPerAccount": 34, "ordinaryReplyRecipients": 1,
                       "replyAllRefusedWithoutTruncation": True, "accountsChecked": 3}


def incoming_reply_to_local65(client):
    fixture = install_inbound_address_fixtures(client)
    for account in ACCOUNTS:
        case = fixture["accounts"][account]["longReplyTo"]
        listed = client.request("mail.list", account, limit=100)["messages"]
        metadata = next(m for m in listed if m["id"] == case["messageId"])
        require(addresses(metadata["replyTo"]) == case["expectedAddresses"], "delivered65-byte local-part blocked metadata or was changed")
        full = client.request("mail.read", account, messageId=case["messageId"])
        require(addresses(full["replyTo"]) == case["expectedAddresses"] and account in full["bodyText"],
                "long Reply-To full read was rejected, shortened, or routed to another account")
        thread = client.request("mail.thread", account, threadId=full["threadId"])["messages"]
        received = next(m for m in thread if m["id"] == full["id"])
        require(addresses(received["replyTo"]) == case["expectedAddresses"], "thread reading weakened delivered Reply-To identity")
        before = client.request("draft.list", account)
        for all_recipients in (False, True):
            rejected = client.request("mail.reply", account, messageId=full["id"], all=all_recipients, ok=False)
            require(rejected["code"] == "InvalidAddress", "reading a long Reply-To granted permission to send to it")
        require(client.request("draft.list", account) == before, "invalid outgoing Reply-To created an orphan draft")
        require(cache_limits(client, account)["fixtureSends"] == 0, "long Reply-To inspection submitted mail")
    client.evidence = {"incomingReplyToLocalBytes": 65, "outgoingReplyRefused": True, "accountsChecked": 3}


def outgoing_address_limits_unchanged(client):
    recipients32 = [f"boundary-{i:02}@example.org" for i in range(32)]
    local64 = "a" * 64 + "@example.org"
    local65 = "b" * 65 + "@example.org"
    for account in ACCOUNTS:
        boundary = client.request("draft.create", account, draft={"to": recipients32, "subject": "Fictional32-recipient boundary", "bodyText": "Synthetic draft only."})
        require(addresses(boundary["to"]) == recipients32, "valid32-recipient outgoing boundary was changed")
        address_boundary = client.request("draft.create", account, draft={"to": [local64], "subject": "Fictional64-byte local boundary", "bodyText": "Synthetic draft only."})
        require(addresses(address_boundary["to"]) == [local64], "valid64-byte local-part outgoing boundary was changed")
        drafts = client.request("draft.list", account)
        operations = client.request("operation.list", account)
        calls = cache_limits(client, account)["fixtureCalls"]
        for suffix, to, code in [("many", recipients32 + ["boundary-33@example.org"], "TooManyRecipients"),
                                  ("long", [local65], "InvalidAddress")]:
            draft = {"to": to, "subject": "Fictional invalid outgoing boundary", "bodyText": "Never dispatch."}
            rejected = client.request("draft.create", account, draft=draft, ok=False)
            require(rejected["code"] == code, "incoming compatibility loosened outgoing draft limits")
            rejected = client.request("mail.send", account, draft=draft, operationId=f"fixture-invalid-outgoing-{suffix}", ok=False)
            require(rejected["code"] == code, "incoming compatibility loosened outgoing send limits")
        require(client.request("draft.list", account) == drafts, "rejected outgoing boundary changed drafts")
        require(client.request("operation.list", account) == operations, "rejected outgoing boundary created a submission journal")
        metrics = cache_limits(client, account)
        require(metrics["fixtureCalls"] == calls and metrics["fixtureSends"] == 0, "invalid outgoing boundary reached the provider")
    client.evidence = {"outgoingRecipientLimit": 32, "outgoingLocalPartLimit": 64,
                       "invalidBoundaryHasNoProviderOrJournalSideEffect": True, "accountsChecked": 3}


def incoming_header_count_and_budget(client):
    spec = json.loads((FIXTURES / "inbound-headers.json").read_text())
    root = client.directory / "inbound-header-fixture"
    (root / "accounts").mkdir(parents=True, mode=0o700)
    sources = {}
    for account in ACCOUNTS:
        key = account.split("@")[0]
        source = json.loads((FIXTURES / "accounts" / f"{key}.json").read_text())
        target = next(m for m in source["messages"] if m["id"] == spec["validMessageId"])
        original_headers = copy.deepcopy(target["payload"]["headers"])
        target["payload"]["headers"] += [{"name": f"X-Fictional-{i:03}", "value": "Synthetic delivered header"}
                                          for i in range(spec["validHeaderCount"] - len(original_headers))]
        require(len(target["payload"]["headers"]) == 96, "valid incoming-header fixture not96 fields")
        require(sum(len(h["name"].encode()) + len(h["value"].encode()) for h in target["payload"]["headers"]) < 32768,
                "count fixture also exceeded byte budget")
        sources[account] = (source, copy.deepcopy(target), original_headers)
        (root / "accounts" / f"{key}.json").write_text(json.dumps(source, ensure_ascii=False))
    client.extra = ("--fixture-root", str(root))
    client.restart()
    cached_digests = {}
    for account in ACCOUNTS:
        full = client.request("mail.read", account, messageId=spec["validMessageId"])
        require(account in full["bodyText"] and "message 095" in full["bodyText"], "many-header incoming full read lost account/body")
        page = client.request("mail.search", account, query=f"subject:Synthetic {account.split('@')[0]} thread 031", limit=12)
        require(spec["validMessageId"] in {m["id"] for m in page["messages"]}, "many-header incoming message not searchable")
        account_dir = client.directory / "cache/fixtures" / hashlib.sha256(account.encode()).hexdigest()
        body_path = account_dir / ("mail-" + hashlib.sha256(spec["validMessageId"].encode()).hexdigest() + ".json")
        cached_digests[account] = (body_path, hashlib.sha256(body_path.read_bytes()).hexdigest())
    for vector in spec["vectors"]:
        for account in ACCOUNTS:
            source, template, original_headers = sources[account]
            bad = copy.deepcopy(template)
            bad["id"], bad["threadId"] = vector["id"], vector["id"] + "-thread"
            bad["payload"]["headers"] = copy.deepcopy(original_headers) + [
                {"name": f"X-Fictional-{i:03}", "value": "x" * vector["extraValueBytes"]}
                for i in range(vector["totalHeaders"] - len(original_headers))]
            require(len(bad["payload"]["headers"]) == vector["totalHeaders"], "header rejection fixture count wrong")
            aggregate = sum(len(h["name"].encode()) + len(h["value"].encode()) for h in bad["payload"]["headers"])
            require(all(len(h["value"].encode()) <= 8192 for h in bad["payload"]["headers"]), "rejection used single-field overflow")
            require((aggregate > 32768) == (vector["expectedError"] == "HeadersTooLarge"), "header count/byte vectors overlap")
            source["messages"].append(bad)
            (root / "accounts" / f"{account.split('@')[0]}.json").write_text(json.dumps(source, ensure_ascii=False))
            error = client.request("mail.read", account, messageId=vector["id"], ok=False)
            require(error["code"] == vector["expectedError"], "incoming header bound did not reject explicitly")
            good = client.request("mail.read", account, messageId=spec["validMessageId"], cacheOnly=True)
            require(account in good["bodyText"], "header refusal damaged valid cached account mail")
            path, before = cached_digests[account]
            require(hashlib.sha256(path.read_bytes()).hexdigest() == before, "header refusal rewrote valid body")
            require(cache_limits(client, account)["fixtureSends"] == 0, "incoming header tests submitted mail")
    client.evidence = {"incomingHeadersReadAndSearched": 96, "incomingHeaderCountLimit": 256,
                       "rejectedHeaderCount": 257, "aggregateByteLimit": 32768,
                       "independentCountAndByteRejections": True, "validBodyDigestsPreserved": True, "accountsChecked": 3}


def gmail_inline_underdeclared_text(client):
    spec = json.loads((FIXTURES / "inline-text-size.json").read_text())
    root = client.directory / "inline-size-fixture"
    (root / "accounts").mkdir(parents=True, mode=0o700)
    sources = {}

    def leaf(message, mime_type, data, declared):
        headers = [h for h in message["payload"]["headers"]
                   if h["name"].lower() not in {"content-type", "content-transfer-encoding", "content-disposition"}]
        headers.append({"name": "Content-Type", "value": mime_type + "; charset=utf-8"})
        message["payload"] = {"partId": "", "mimeType": mime_type, "filename": "", "headers": headers,
                              "body": {"size": declared, "data": base64.urlsafe_b64encode(data).decode().rstrip("=")}}

    def check_full(message, account, vector):
        text = vector["expectedTextTemplate"].format(account=account)
        literal = vector["literalTemplate"].format(account=account)
        require(message["id"] == vector["messageId"] and message["threadId"] == spec["threadId"],
                "inline text size compatibility changed message/thread identity")
        require(message["bodyText"] == text, "inline declared underestimate truncated or changed the full UTF-8 text")
        require(hashlib.sha256(message["bodyText"].encode()).digest() == hashlib.sha256(text.encode()).digest(),
                "inline text failed the independent literal digest")
        require(message.get("bodyHtml") == (literal if vector["mimeType"] == "text/html" else None),
                "inline HTML size compatibility changed the original full HTML")
        require(message["attachments"] == [], "inline text unexpectedly became an attachment")

    def cached_identity(account, vector):
        directory = client.directory / "cache/fixtures" / hashlib.sha256(account.encode()).hexdigest()
        state = json.loads((directory / "index.json").read_bytes())
        require(state["schema"] == 1 and state["account"] == account, "inline prefetch cache crossed accounts")
        entry = next(e for e in state["entries"] if e["message"]["id"] == vector["messageId"])
        path = directory / ("mail-" + hashlib.sha256(vector["messageId"].encode()).hexdigest() + ".json")
        raw = path.read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        record = json.loads(raw)
        require(entry["bytes"] == len(raw) and entry["bodyHash"] == digest and not entry.get("bodyError"),
                "inline prefetch left a refusal or invalid full-body reference")
        require(record["schema"] == 1 and record["account"] == account, "inline cached body has wrong account identity")
        check_full(record["message"], account, vector)
        return path, digest

    for account in ACCOUNTS:
        source = json.loads((FIXTURES / "accounts" / f"{account.split('@')[0]}.json").read_text())
        source["sync"] = {"historyId": spec["historyId"], "history": []}
        for vector in spec["positive"]:
            target = next(m for m in source["messages"] if m["id"] == vector["messageId"])
            data = vector["literalTemplate"].format(account=account).encode()
            require(len(data) > len(data.decode()), "size fixture did not exercise multibyte UTF-8")
            require(vector["declaredOffset"] == -1, "inline underestimate fixture is not exactly one byte")
            leaf(target, vector["mimeType"], data, len(data) - 1)
            target["historyId"] = spec["historyId"]
        sources[account] = source
        (root / "accounts" / f"{account.split('@')[0]}.json").write_text(json.dumps(source, ensure_ascii=False))
    client.extra = ("--fixture-root", str(root))
    client.restart()

    saved = {}
    for account in ACCOUNTS:
        for vector in spec["positive"]:
            check_full(client.request("mail.read", account, messageId=vector["messageId"]), account, vector)
        thread = client.request("mail.thread", account, threadId=spec["threadId"])["messages"]
        for vector in spec["positive"]:
            check_full(next(m for m in thread if m["id"] == vector["messageId"]), account, vector)
        client.request("cache.clear", account)
        before = cache_limits(client, account)
        refreshed = client.request("mail.refresh", account, limit=32)
        require(refreshed["refreshed"] is True and refreshed["refreshInProgress"] is False,
                "inline UTF-8 compatibility did not complete cache refresh")
        after = cache_limits(client, account)
        require(after["historyId"] == spec["historyId"], "inline prefetch did not establish the requested checkpoint")
        require(after["syncMetadataGets"] - before["syncMetadataGets"] == 32 and
                after["syncBodyGets"] - before["syncBodyGets"] == 32, "head refresh did not prefetch its full32-message head")
        page = client.request("mail.list", account, cacheOnly=True, limit=32)["messages"]
        expected_ids = [m["id"] for m in sorted(sources[account]["messages"], key=lambda m: -int(m["internalDate"]))[:32]]
        require([m["id"] for m in page] == expected_ids, "inline MIME refresh changed newest-head membership")
        for vector in spec["positive"]:
            check_full(client.request("mail.read", account, messageId=vector["messageId"], cacheOnly=True), account, vector)
            saved[(account, vector["messageId"])] = cached_identity(account, vector)
        thread = client.request("mail.thread", account, threadId=spec["threadId"], cacheOnly=True)["messages"]
        for vector in spec["positive"]:
            check_full(next(m for m in thread if m["id"] == vector["messageId"]), account, vector)
        read_metrics = cache_limits(client, account)
        require(read_metrics["fixtureCalls"] == after["fixtureCalls"], "cached full text/thread fetched the provider")
        client.request("mail.refresh", account, limit=32)
        unchanged = cache_limits(client, account)
        require(unchanged["historyId"] == spec["historyId"] and
                all(unchanged[k] == read_metrics[k] for k in ("syncListCalls", "syncMetadataGets", "syncBodyGets")),
                "unchanged inline UTF-8 history refetched mail or lost its checkpoint")

    # Refusal vectors have fresh IDs; none can be answered from a valid old body.
    # The literal rejection controls are independent of the runtime MIME decoder.
    account = ACCOUNTS[0]
    source = sources[account]
    template = next(m for m in source["messages"] if m["id"] == spec["positive"][0]["messageId"])
    for vector in spec["rejected"]:
        bad = copy.deepcopy(template)
        bad["id"], bad["threadId"] = vector["messageId"], vector["messageId"] + "-thread"
        data = ("Fictional refusal for " + account + ": café ∴.").encode()
        if vector["kind"] == "empty": data = b""
        if vector["kind"] == "actual-over-cap": data = b"x" * (spec["decodedLeafLimitBytes"] + 1)
        declared = len(data) + vector.get("declaredOffset", -1)
        if vector["kind"] == "declared-over-cap": declared = spec["decodedLeafLimitBytes"] + 1
        leaf(bad, vector["mimeType"], data, declared)
        if vector["kind"] == "named": bad["payload"]["filename"] = "fictional.txt"
        if vector["kind"] == "disposition":
            bad["payload"]["headers"].append({"name": "Content-Disposition", "value": "attachment"})
        if vector["kind"] == "external":
            encoded = bad["payload"]["body"].pop("data")
            external_id = "fictional-size-external"
            bad["payload"]["body"]["attachmentId"] = external_id
            source.setdefault("externalBodies", {})[external_id] = {"size": len(data), "data": encoded}
        source["messages"].append(bad)
        (root / "accounts/personal.json").write_text(json.dumps(source, ensure_ascii=False))
        error = client.request("mail.read", account, messageId=bad["id"], ok=False)
        require(error["code"] == vector["expectedError"], "inline compatibility weakened a strict MIME size/cap refusal")
        source["messages"].pop()
    client.restart()
    for account in ACCOUNTS:
        for vector in spec["positive"]:
            check_full(client.request("mail.read", account, messageId=vector["messageId"], cacheOnly=True), account, vector)
            path, digest = saved[(account, vector["messageId"])]
            require(hashlib.sha256(path.read_bytes()).hexdigest() == digest,
                    "size refusal or restart changed a valid prefetched body")
        metrics = cache_limits(client, account)
        require(metrics["historyId"] == spec["historyId"] and metrics["fixtureSends"] == 0,
                "MIME compatibility changed a checkpoint or dispatched mail")
    client.evidence = {"accountsChecked": 3, "inlineMimeTypes": ["text/plain", "text/html"],
                       "declaredUnderestimateBytes": 1, "fullUtf8LiteralDigestsMatch": True,
                       "refreshPrefetchedBodies": True, "checkpointPreserved": True,
                       "strictRefusalVectors": len(spec["rejected"]), "cachedBodyDigestsPreserved": True}


def set_private_fixture_body(client, data):
    """Keep large boundary inputs out of the public fixture corpus and receipts."""
    source = json.loads((FIXTURES / "accounts/personal.json").read_text())
    message = next(m for m in source["messages"] if m["id"] == "shared-msg-001")
    payload = message["payload"]
    payload["mimeType"] = "text/plain"
    payload["headers"] = [h for h in payload["headers"]
                          if h["name"].lower() not in {"content-type", "content-transfer-encoding"}]
    payload["headers"].append({"name": "Content-Type", "value": "text/plain; charset=utf-8"})
    payload.pop("parts", None)
    payload["body"] = {"size": len(data), "data": base64.urlsafe_b64encode(data).decode().rstrip("=")}
    root = client.directory / "boundary-fixture"
    (root / "accounts").mkdir(parents=True, exist_ok=True)
    (root / "accounts/personal.json").write_text(json.dumps(source))
    client.extra = ("--fixture-root", str(root))
    client.restart()


def quote_body_limit_rollback(client):
    data = b"\n" * 800000
    set_private_fixture_body(client, data)
    message = client.request("mail.read", messageId="shared-msg-001")
    require(message["bodyText"].encode() == data, "valid newline-heavy source body was truncated")
    before = client.request("draft.list")
    error = client.request("mail.reply", messageId="shared-msg-001", all=False, ok=False)
    require(error["code"] == "BodyTooLarge", "expanded reply did not report the decoded body limit")
    require(client.request("draft.list") == before, "failed reply persisted an oversized orphan draft")
    require(client.request("mail.read", messageId="shared-msg-001")["unread"] is True,
            "failed quote changed the original unread state")


def decoded_body_boundary(client):
    data = b"x" * (2 * 1024 * 1024)
    set_private_fixture_body(client, data)
    message = client.request("mail.read", messageId="shared-msg-001")
    require(len(message["bodyText"].encode()) == len(data) and message["bodyText"].encode() == data,
            "valid decoded body at2MiB was rejected or truncated by its larger base64url input")
    cache_limits(client, ACCOUNTS[0])


def mime_refusal_preserves_valid_cache(client):
    cached = client.request("mail.read", messageId="shared-msg-012")
    source = json.loads((FIXTURES / "accounts/personal.json").read_text())
    target = next(m for m in source["messages"] if m["id"] == "shared-msg-095")
    headers = [h for h in target["payload"]["headers"] if h["name"].lower()
               not in {"content-type", "content-transfer-encoding"}]
    root = client.directory / "invalid-mime-fixture"
    (root / "accounts").mkdir(parents=True)
    client.extra = ("--fixture-root", str(root))
    errors = {"declaredBodyOver2MiB": "BodyTooLarge", "sizeMismatch": "BodySizeMismatch",
              "unsupportedCharset": "UnsupportedCharset", "depth33": "MimeTooDeep", "parts513": "TooManyMimeParts"}
    for name, payload in json.loads((FIXTURES / "mime-limits.json").read_text())["cases"].items():
        target["payload"] = {**payload, "headers": headers + payload["headers"]}
        (root / "accounts/personal.json").write_text(json.dumps(source))
        client.restart()
        rejected = client.request("mail.read", messageId=target["id"], ok=False)
        require(rejected["code"] == errors[name], f"malformed MIME {name} omitted its bounded refusal")
        require(client.request("mail.read", messageId=cached["id"]) == cached,
                "malformed MIME corrupted another cached message")


def optional_field_type_rejection(client):
    before = cache_limits(client, ACCOUNTS[0])
    for key in ["cursor", "query", "label"]:
        for value in [None, 42, [], False]:
            error = client.request("mail.list", ok=False, **{key: value})
            require(error["code"] == "InvalidRequest", "invalid optional command field was silently ignored")
    client.request("mail.read", messageId=42, ok=False)
    client.request("mail.send", operationId=42, draft={"to": ["recipient@example.org"], "bodyText": "Synthetic"}, ok=False)
    after = cache_limits(client, ACCOUNTS[0])
    require(after["fixtureCalls"] == before["fixtureCalls"] and after["fixtureSends"] == before["fixtureSends"],
            "invalid command type reached the provider")
    contacts = client.request("contacts.list")
    original = contacts["contacts"][0]
    for key in ["name", "resourceName", "etag"]:
        client.request("contacts.upsert", contact={**original, key: 42}, expectedEtag=original["etag"], ok=False)
    require(client.request("contacts.list") == contacts, "invalid contact type overwrote persisted contact data")


def one_shot_cached_server_search(client):
    client.extra = ("--metadata-limit", "40")
    client.restart()
    client.request("mail.refresh", limit=40, label="INBOX")
    account = ACCOUNTS[0]
    common = ["--fixtures", "--fixture-root", str(FIXTURES), "--cache-dir", str(client.directory / "cache"),
              "--metadata-limit", "40", "--account", account]

    def run(family, verb, arguments, expected_error=None):
        argv = [str(client.binary), family, verb, *common, *arguments]
        result = subprocess.run(argv, input=b"", capture_output=True, cwd=client.directory,
                                env=client.environment, timeout=12, preexec_fn=no_core_dump)
        require(len(result.stdout) < MAX_FRAME and len(result.stderr) < 16384, "one-shot search output unbounded")
        if expected_error is not None:
            require(result.returncode != 0, "conflicting one-shot search flag accepted")
            if result.stdout:
                reply = json.loads(result.stdout)
                require(reply.get("ok") is False and reply.get("error", {}).get("code") == expected_error,
                        "one-shot flag error not explicit")
            else:
                require(expected_error.encode() in result.stderr, "parser flag failure omitted fixed code")
            require(not any(address.encode() in result.stderr for address in ACCOUNTS), "flag error disclosed account")
            return None
        require(result.returncode == 0 and not result.stderr, "one-shot search exit/stderr failed")
        reply = json.loads(result.stdout)
        require(reply.get("version") == 1 and reply.get("ok") is True and reply.get("account") == account,
                "one-shot search response lost version/account identity")
        return reply["data"]

    before = cache_limits(client, account)
    cached_ids, cursor = [], ""
    for _ in range(20):
        data = run("mail", "search", ["--cached", "--query", "subject:Synthetic personal", "--limit", "12",
                                      *( ["--cursor", cursor] if cursor else [])])
        require(data.get("searchMode") == "cache" and data.get("searchScope") == "metadata" and data.get("matchedCachedCount") == 40,
                "--cached did not identify retained metadata scope")
        cached_ids += [m["id"] for m in data["messages"]]
        cursor = data.get("nextCursor") or ""
        if not cursor: break
        require(cursor.startswith("K:"), "cached search used provider cursor namespace")
    else:
        raise AssertionError("one-shot cached pagination did not terminate")
    require(cached_ids == [f"shared-msg-{number:03}" for number in range(96, 56, -1)], "--cached searched outside newest40 or duplicated rows")
    after = cache_limits(client, account)
    for key in ("fixtureCalls", "syncCalls", "syncListCalls", "syncHistoryPages", "syncMetadataGets", "syncBodyGets"):
        require(after[key] == before[key], "--cached invoked provider")
    older = run("mail", "search", ["--server", "--query", "subject:Synthetic personal thread 010", "--limit", "12"])
    require({m["id"] for m in older["messages"]} == {"shared-msg-031", "shared-msg-032", "shared-msg-033"},
            "--server failed to reach older uncached mail")
    server_ids, cursor = [], ""
    for _ in range(20):
        data = run("mail", "search", ["--server", "--query", "subject:Synthetic personal", "--limit", "12",
                                      *( ["--cursor", cursor] if cursor else [])])
        server_ids += [m["id"] for m in data["messages"]]
        cursor = data.get("nextCursor") or ""
        if not cursor: break
        require(not cursor.startswith("K:"), "--server reused retained-cache cursor")
    else:
        raise AssertionError("one-shot server pagination did not terminate")
    require(server_ids == [f"shared-msg-{number:03}" for number in range(96, 0, -1)], "--server failed full distinct provider pagination")
    provider_after = cache_limits(client, account)
    require(provider_after["fixtureCalls"] > after["fixtureCalls"], "--server did not exercise provider boundary")
    for modes in (("--cached", "--server"), ("--server", "--cached")):
        run("mail", "search", [*modes, "--query", "Synthetic"], expected_error="ConflictingSearchMode")
    run("mail", "list", ["--server"], expected_error="ServerFlagRequiresSearch")
    final = cache_limits(client, account)
    require(final["fixtureCalls"] == provider_after["fixtureCalls"] and final["fixtureSends"] == 0,
            "invalid flags reached provider or submitted mail")
    client.evidence = {"cachedMessages": 40, "cachedProviderCalls": 0, "cachedCursorNamespace": "K",
                       "serverMessages": 96, "serverReachedUncachedOlder33": True, "serverCursorDistinct": True,
                       "flagConflictsRejected": 2, "serverNonSearchRejected": True, "mutationRequests": 0}


def one_shot_commands(client):
    def run(family, verb, arguments, stdin=b"", success=True):
        argv = [str(client.binary), family, verb, "--fixtures", "--fixture-root", str(FIXTURES),
                "--cache-dir", str(client.directory / "cache"), *arguments]
        result = subprocess.run(argv, input=stdin, capture_output=True, cwd=client.directory,
                                env=client.environment, timeout=8, preexec_fn=no_core_dump)
        require(len(result.stdout) < MAX_FRAME, "one-shot command exceeded output bound")
        require((result.returncode == 0) is success, "one-shot exit status disagreed with outcome")
        reply = json.loads(result.stdout)
        require(reply.get("version") == 1 and reply.get("ok") is success, "one-shot reply lost structured outcome")
        if success:
            require(not result.stderr, "successful one-shot command wrote stderr")
            return reply["data"]
        return reply["error"]
    account_args = ["--account", ACCOUNTS[0]]
    read = run("mail", "read", [*account_args, "--message-id", "shared-msg-001"])
    require(read == client.request("mail.read", messageId="shared-msg-001"), "one-shot read bypassed shared account behavior")
    text = "Synthetic one-shot stdin café 👋\n"
    draft = run("mail", "compose", [*account_args, "--to", '"Recipient, Fixture" <recipient@example.org>',
                                   "--subject", "Synthetic one-shot", "--body-stdin"], text.encode())
    require(draft["bodyText"] == text and addresses(draft["to"]) == ["recipient@example.org"],
            "one-shot compose lost stdin body or quoted recipient grammar")
    require(client.request("draft.read", draftId=draft["id"]) == draft, "one-shot draft was not persisted in shared cache")
    require(run("mail", "list", [], success=False)["code"] == "MissingField", "one-shot command implicitly chose an account")


def sent_outbox_persistence(client):
    body = "x" * 239 + "👋 café fixture body."
    draft = client.request("mail.reply", messageId="shared-msg-005", all=True)
    draft = client.request("draft.update", draftId=draft["id"], draft={**draft, "bodyText": body})
    operation = client.request("draft.send", draftId=draft["id"], operationId="fixture-outbox-send")
    require(operation["outcome"] == "applied", "mock outbox send was not applied")
    sent = client.request("mail.read", messageId=operation["messageId"])
    require("SENT" in sent["labels"] and sent["bodyText"] == body and sent["from"]["address"] == ACCOUNTS[0],
            "mock submission omitted readable sent mail")
    require(len(sent["snippet"].encode()) <= 240 and body.startswith(sent["snippet"]), "sent snippet broke its UTF-8 byte boundary")
    listed = client.request("mail.list", label="SENT", limit=12)["messages"]
    require(any(m["id"] == sent["id"] for m in listed), "sent folder omitted submitted message")
    require(any(m["id"] == sent["id"] for m in client.request("mail.thread", threadId=draft["threadId"])["messages"]),
            "reply did not appear with its original thread")
    client.restart()
    require(client.request("mail.read", messageId=sent["id"])["bodyText"] == body, "restart lost readable sent message")
    require(any(m["id"] == sent["id"] for m in client.request("mail.list", label="SENT", limit=12)["messages"]),
            "restart lost sent folder metadata")
    require(not any(m["id"] == sent["id"] for m in client.request("mail.list", ACCOUNTS[1], label="SENT", limit=12)["messages"]),
            "sent folder crossed accounts")
    client.extra = ("--metadata-limit", "48")
    client.restart()
    list_all(client, ACCOUNTS[0], label="INBOX")
    cache_limits(client, ACCOUNTS[0])
    require(client.request("mail.read", messageId=sent["id"])["bodyText"] == body, "ordinary metadata eviction erased mock provider sent mail")
    client.request("cache.clear")
    require(client.request("mail.read", messageId=sent["id"])["bodyText"] == body, "cache clear erased mock provider sent mail")
    require(any(m["id"] == sent["id"] for m in client.request("mail.list", label="SENT", limit=12)["messages"]),
            "cache clear erased mock provider sent folder")


def sent_mutations_persist(client):
    draft = client.request("mail.reply", messageId="shared-msg-005", all=True)
    body = "Synthetic sent-message mutation persistence."
    draft = client.request("draft.update", draftId=draft["id"], draft={**draft, "bodyText": body})
    receipt = client.request("draft.send", draftId=draft["id"], operationId="fixture-sent-mutations")
    require(receipt["outcome"] == "applied", "sent mutation fixture was not submitted")
    message_id = receipt["messageId"]
    client.request("mail.mark", messageId=message_id, unread=True, starred=True)
    client.request("mail.trash", messageId=message_id)

    def check_views(trashed):
        message = client.request("mail.read", messageId=message_id)
        require(message["bodyText"] == body, "sent mutation lost its readable body")
        require(message["unread"] is True and {"SENT", "UNREAD", "STARRED"} <= set(message["labels"]),
                "sent read lost unread/star labels")
        require(("TRASH" in message["labels"]) is trashed, "sent read reported stale trash state")
        for label in ["SENT", "STARRED", "TRASH"]:
            matches = [item for item in client.request("mail.list", label=label, limit=100)["messages"]
                       if item["id"] == message_id]
            require(bool(matches) is (trashed or label != "TRASH"), f"sent {label} view lost its mutation state")
            if matches:
                require(matches[0]["unread"] is True and set(matches[0]["labels"]) == set(message["labels"]),
                        f"sent {label} list disagreed with full read")
        thread = client.request("mail.thread", threadId=draft["threadId"])["messages"]
        matches = [item for item in thread if item["id"] == message_id]
        require(len(matches) == 1 and matches[0]["unread"] is True
                and set(matches[0]["labels"]) == set(message["labels"]),
                "sent thread disagreed with persisted mutation state")
        require(not client.request("mail.list", ACCOUNTS[1], label="SENT", limit=100)["messages"],
                "sent mutations leaked into another account")

    check_views(True)
    client.request("cache.clear")
    client.restart()
    check_views(True)
    client.request("mail.restore", messageId=message_id)
    check_views(False)
    client.request("cache.clear")
    client.restart()
    check_views(False)


def draft_attachment_bounds(client):
    original = client.request("mail.read", messageId="shared-msg-003")["attachments"][0]
    attachment = {**original, "id": "fixture-compose-attachment", "filename": "fixture.bin"}
    fields = {"to": ["recipient@example.org"], "subject": "Synthetic binary attachment",
              "bodyText": "Reviewed attachment body.", "attachments": [attachment]}
    draft = client.request("draft.create", draft=fields)
    require(draft["attachments"] == [attachment], "draft did not retain binary attachment metadata and bytes")
    for invalid in [{**attachment, "filename": "../../escape.txt"}, {**attachment, "mimeType": "text/plain\r\nX-Injected: yes"},
                    {**attachment, "size": attachment["size"] + 1}, {**attachment, "data": "***"}]:
        client.request("draft.update", draftId=draft["id"], draft={**fields, "attachments": [invalid]}, ok=False)
        require(client.request("draft.read", draftId=draft["id"])["attachments"] == [attachment],
                "invalid attachment changed the retained draft")
    operation = client.request("draft.send", draftId=draft["id"], operationId="fixture-attachment-send")
    require(operation["outcome"] == "applied", "bounded attachment send was not applied")
    recovered = client.request("mail.attachment", messageId=operation["messageId"], attachmentId=attachment["id"])
    data = base64.b64decode(recovered["data"] + "=" * (-len(recovered["data"]) % 4), altchars=b"-_", validate=True)
    require(hashlib.sha256(data).hexdigest() == MANIFEST["attachmentExpected"]["sha256"], "submitted attachment lost binary integrity")


def labels_and_trash(client):
    message_id = "shared-msg-001"
    other = client.request("mail.read", ACCOUNTS[1], messageId=message_id)
    client.request("mail.mark", messageId=message_id, unread=False, operationId="fixture-mark")
    require(client.request("mail.read", messageId=message_id)["unread"] is False, "mark unread mutation not reflected")
    client.request("mail.trash", messageId=message_id, operationId="fixture-trash")
    trashed = client.request("mail.read", messageId=message_id)
    require("TRASH" in trashed["labels"], "trash did not preserve readable message in trash")
    client.request("mail.restore", messageId=message_id, operationId="fixture-restore")
    require("TRASH" not in client.request("mail.read", messageId=message_id)["labels"], "restore left trash label")
    require(client.request("mail.read", ACCOUNTS[1], messageId=message_id) == other, "mutation affected another account")
    client.request("mail.delete", messageId=message_id, operationId="fixture-delete", ok=False)


def contacts_and_conflicts(client):
    listed = client.request("contacts.list")
    contacts = listed["contacts"]
    require(len(contacts) >= 2, "fixture contacts were omitted")
    original = next(c for c in contacts if c["resourceName"] == "people/shared-contact-001")
    other = client.request("contacts.list", ACCOUNTS[1])
    changed = client.request("contacts.upsert", contact={**original, "name": "Changed Fixture"},
                             expectedEtag=original["etag"], operationId="fixture-contact-change")
    require(changed["name"] == "Changed Fixture" and changed["etag"] != original["etag"], "contact update did not advance version")
    client.request("contacts.upsert", contact={**original, "name": "Stale Fixture"},
                   expectedEtag=original["etag"], operationId="fixture-contact-stale", ok=False)
    require(client.request("contacts.list", ACCOUNTS[1]) == other, "contact update crossed accounts")
    found = client.request("contacts.search", query="Changed")
    require(any(c["name"] == "Changed Fixture" for c in found["contacts"]), "updated contact not searchable")


def rsvp_semantics(client):
    before = cache_limits(client, ACCOUNTS[0])["fixtureSends"]
    inspected = client.request("invitation.inspect", messageId="shared-msg-009")
    require(inspected["uid"] == "fixture-meeting@example.org" and inspected["organizer"] == "organizer@example.org"
            and inspected["attendee"] == ACCOUNTS[0] and inspected["recurrenceId"] == "20261107T100000Z",
            "invitation inspection lost recipient or recurring identity")
    require(cache_limits(client, ACCOUNTS[0])["fixtureSends"] == before, "invitation inspection sent an RSVP")
    for status in ["accepted", "tentative", "declined"]:
        result = client.request("invitation.reply", messageId="shared-msg-009", status=status,
                                operationId=f"fixture-rsvp-{status}")
        require(result["outcome"] == "applied", "RSVP outcome not explicit")
        calendar = result["icalendar"].replace("\r\n", "\n")
        for value in ["METHOD:REPLY", "UID:fixture-meeting@example.org", "SEQUENCE:4",
                      "RECURRENCE-ID:20261107T100000Z", "ORGANIZER:mailto:organizer@example.org",
                      f"PARTSTAT={status.upper()}:mailto:{ACCOUNTS[0]}"]:
            require(value in calendar, "RSVP lost invitation identity/status")
        require(calendar.count("ATTENDEE;") == 1, "RSVP included other attendees")
    client.request("invitation.reply", messageId="shared-msg-009", status="cancelled", operationId="fixture-bad-rsvp", ok=False)


def cache_clear_isolation(client):
    list_all(client, ACCOUNTS[1])
    other = cache_limits(client, ACCOUNTS[1])
    client.request("cache.clear", operationId="fixture-clear")
    require(cache_limits(client, ACCOUNTS[0])["metadataEntries"] == 0, "clear retained target metadata")
    require(cache_limits(client, ACCOUNTS[1])["metadataEntries"] == other["metadataEntries"], "cache clear affected other account")


def malformed_recovery(client):
    client.raw(b'{"id":\n')
    bad = client.receive()
    require(bad.get("ok") is False, "malformed JSON was accepted")
    cache_limits(client, ACCOUNTS[0])


def oversized_request_recovery(client):
    payload = {"id": "oversized", "account": ACCOUNTS[0], "cmd": "draft.create",
               "draft": {"to": ["recipient@example.org"], "subject": "Over cap", "bodyText": "x" * (3 * 1024**2 + 1024)}}
    client.raw(json.dumps(payload).encode() + b"\n")
    rejected = client.receive()
    require(rejected.get("ok") is False, "oversized request was accepted")
    require(rejected.get("error", {}).get("code") == "InvalidRequest", "oversized request omitted documented bounded error")
    cache_limits(client, ACCOUNTS[0])


def stdout_backpressure(client):
    total = 256
    frames = [{"id": f"backpressure-{i}", "account": ACCOUNTS[0], "cmd": "cache.stats"} for i in range(total)]
    payload = b"".join(json.dumps(frame).encode() + b"\n" for frame in frames)
    offset = 0
    # Fill input until the synchronous writer pauses behind undrained stdout.
    deadline = time.monotonic() + 3
    while offset < len(payload) and time.monotonic() < deadline:
        try:
            written = os.write(client.process.stdin.fileno(), payload[offset:])
            offset += written
        except BlockingIOError:
            break
    time.sleep(.25)
    require(client.process.poll() is None, "CLI stopped while stdout was undrained")
    for expected in frames:
        if offset < len(payload):
            try:
                offset += os.write(client.process.stdin.fileno(), payload[offset:])
            except BlockingIOError:
                pass
        reply = client.receive()
        require(reply.get("id") == expected["id"] and reply.get("account") == ACCOUNTS[0] and reply.get("ok") is True,
                "backpressure lost, reordered or corrupted a command reply")
    require(offset == len(payload), "backpressure test did not finish writing all requests")
    cache_limits(client, ACCOUNTS[0])


def agent_alias(client):
    client.alias = "agent"
    client.restart()
    accounts_and_search(client)


def cache_eviction_bounds(client):
    client.extra = ("--metadata-limit", "48", "--disk-limit-bytes", "131072")
    client.restart()
    list_all(client, ACCOUNTS[0])
    stats = cache_limits(client, ACCOUNTS[0])
    require(stats["metadataLimit"] == 48 and stats["metadataEntries"] == 48, "configured metadata eviction was not enforced")
    require(stats["diskLimitBytes"] == 131072, "configured disk quota was ignored")
    for suffix in [13, 14, 15]:
        message = client.request("mail.read", messageId=f"shared-msg-{suffix:03}")
        require(len(message["bodyText"].encode()) > 64 * 1024, "fixture did not exercise disk-pressure bodies")
        cache_limits(client, ACCOUNTS[0])
    before = cache_limits(client, ACCOUNTS[0])["fixtureCalls"]
    for suffix in [13, 14, 15]:
        require("Synthetic" in client.request("mail.read", messageId=f"shared-msg-{suffix:03}")["bodyText"], "evicted body was not recoverable")
    require(cache_limits(client, ACCOUNTS[0])["fixtureCalls"] > before, "disk-pressure test did not evict a fetched body")
    client.restart()
    require(cache_limits(client, ACCOUNTS[0])["metadataEntries"] <= 48, "restart discarded configured metadata limit")


def mutation_survives_body_eviction(client):
    client.extra = ("--metadata-limit", "48", "--disk-limit-bytes", "131072")
    client.restart()
    list_all(client, ACCOUNTS[0])
    client.request("mail.mark", messageId="shared-msg-013", unread=False, operationId="fixture-pressure-mark")
    client.request("mail.trash", messageId="shared-msg-013", operationId="fixture-pressure-trash")
    for suffix in [14, 15]:
        client.request("mail.read", messageId=f"shared-msg-{suffix:03}")
    recovered = client.request("mail.read", messageId="shared-msg-013")
    require(recovered["unread"] is False and "TRASH" in recovered["labels"] and "INBOX" not in recovered["labels"],
            "body eviction restored old provider fixture labels")


def reopening_lower_limits(client):
    list_all(client, ACCOUNTS[0])
    for suffix in [13, 14, 15]:
        client.request("mail.read", messageId=f"shared-msg-{suffix:03}")
    require(cache_limits(client, ACCOUNTS[0])["diskBytes"] > 131072, "fixture did not populate a cache above the lower quota")
    client.extra = ("--metadata-limit", "48", "--disk-limit-bytes", "131072")
    client.restart()
    stats = cache_limits(client, ACCOUNTS[0])
    require(stats["metadataEntries"] <= 48 and stats["diskBytes"] <= 131072, "reopen did not enforce lowered limits")
    client.restart()
    stats = cache_limits(client, ACCOUNTS[0])
    require(stats["metadataEntries"] <= 48 and stats["diskBytes"] <= 131072, "lower-limit enforcement was not persisted")


def rsvp_replay_persistence(client):
    params = {"messageId": "shared-msg-009", "status": "accepted", "operationId": "fixture-rsvp-replay"}
    first = client.request("invitation.reply", **params)
    before = cache_limits(client, ACCOUNTS[0])["fixtureSends"]
    # A regenerated reply has a different creation timestamp; operation meaning stays identical.
    time.sleep(1.1)
    require(client.request("invitation.reply", **params) == first, "RSVP replay regenerated or resent a completed operation")
    client.restart()
    require(client.request("invitation.reply", **params) == first, "RSVP replay changed across restart")
    require(cache_limits(client, ACCOUNTS[0])["fixtureSends"] == before, "RSVP replay dispatched again")
    client.request("invitation.reply", **{**params, "status": "declined"}, ok=False)


def cached_body_identity(client):
    client.request("mail.read", messageId="shared-msg-012")
    candidates = []
    for path in (client.directory / "cache").rglob("*.json"):
        value = json.loads(path.read_text())
        message = value.get("message", value)
        if message.get("id") == "shared-msg-012" and "bodyText" in message:
            candidates.append((path, value, message))
    require(len(candidates) == 1, "could not identify one isolated cached body")
    path, value, message = candidates[0]
    message["id"] = "shared-msg-001"
    message["bodyText"] = "WRONG SYNTHETIC CACHE IDENTITY"
    path.write_text(json.dumps(value))
    # Reject a corrupt entry or recover the genuine requested message; never return mismatched data.
    client.next_id += 1
    request = {"id": f"test-{client.next_id}", "account": ACCOUNTS[0], "cmd": "mail.read", "messageId": "shared-msg-012"}
    client.raw(json.dumps(request).encode() + b"\n")
    reply = client.receive()
    require(reply.get("id") == request["id"] and reply.get("account") == ACCOUNTS[0], "cache rejection lost response identity")
    if reply.get("ok"):
        require(reply["data"]["id"] == "shared-msg-012" and "WRONG SYNTHETIC" not in reply["data"]["bodyText"],
                "corrupt body returned under the requested identity")
    else:
        require(reply.get("error", {}).get("code") == "CacheIdentityMismatch", "corrupt identity did not produce explicit cache error")


def cached_body_account_swap(client):
    for account in ACCOUNTS[:2]:
        client.request("mail.read", account, messageId="shared-msg-012")
    bodies = {}
    for path in (client.directory / "cache").rglob("*.json"):
        value = json.loads(path.read_text())
        if value.get("account") in ACCOUNTS[:2] and value.get("message", {}).get("id") == "shared-msg-012":
            bodies[value["account"]] = path
    require(set(bodies) == set(ACCOUNTS[:2]), "cached bodies omitted account provenance")
    bodies[ACCOUNTS[0]].write_bytes(bodies[ACCOUNTS[1]].read_bytes())
    error = client.request("mail.read", ACCOUNTS[0], messageId="shared-msg-012", ok=False)
    require(error["code"] == "CacheIdentityMismatch", "swapped same-ID body was not rejected")
    require(ACCOUNTS[1] in client.request("mail.read", ACCOUNTS[1], messageId="shared-msg-012")["bodyText"],
            "rejecting corrupt account altered the valid other cache")


def cache_permissions(client):
    list_all(client, ACCOUNTS[0])
    client.request("mail.read", messageId="shared-msg-003")
    client.request("draft.create", draft={"to": ["recipient@example.org"], "subject": "Private fixture draft", "bodyText": "Synthetic."})
    root = client.directory / "cache"
    paths = [root, *root.rglob("*")]
    require(len(paths) > 1, "fixture did not exercise disk persistence")
    for path in paths:
        info = path.lstat()
        require(not stat.S_ISLNK(info.st_mode), "cache unexpectedly created a symlink")
        require(stat.S_IMODE(info.st_mode) & 0o077 == 0, "cache permissions expose mail to another local user")
        require("@" not in path.name and "shared-msg" not in path.name, "cache filename exposed an account/provider identifier")


def backend_cache_isolation(client):
    # Explicitly materialize an empty isolated store; metrics remain read-only.
    client.request("cache.clear")
    root = client.directory / "cache"
    account_hash = hashlib.sha256(ACCOUNTS[0].encode()).hexdigest()
    fixture_index = root / "fixtures" / account_hash / "index.json"
    require(fixture_index.is_file(), "fixture store omitted its distinct backend namespace")
    state = json.loads(fixture_index.read_text())
    live = root / "live" / account_hash
    live.mkdir(parents=True, mode=0o700)
    live.parent.chmod(0o700)
    state["entries"] = [{"message": {"id": "live-synthetic-sentinel", "threadId": "live-sentinel-thread",
                                    "subject": "LIVE SYNTHETIC SENTINEL", "bodyText": ""}, "bytes": 0}]
    live_index = live / "index.json"
    live_index.write_text(json.dumps(state))
    live_index.chmod(0o600)
    require(client.request("cache.stats")["metadataEntries"] == 0, "fixture backend consumed live cache metadata")
    message = client.request("mail.read", messageId="shared-msg-001")
    require("LIVE SYNTHETIC SENTINEL" not in message["bodyText"], "fixture read consumed live content")
    fixture_state = json.loads(fixture_index.read_text())
    fixture_bytes = fixture_index.read_bytes()
    with Client(client.binary, client.directory, fixtures=False) as live_client:
        stats = live_client.request("cache.stats")
        require(stats["metadataEntries"] == 1 and stats["fixtureCalls"] == 0, "live backend consumed the fixture cache")
        error = live_client.request("mail.read", messageId="shared-msg-001", ok=False)
        require(error["code"] in {"PermissionDenied", "NotConnected", "OAuthClientRequired"},
                "unconnected live account read a cached fixture message")
        require(live_client.request("draft.list")["drafts"] == [], "live backend exposed a fixture draft")
    require(fixture_index.read_bytes() == fixture_bytes, "live cache operations changed fixture state")
    require(json.loads(live_index.read_text())["entries"][0]["message"]["id"] == "live-synthetic-sentinel",
            "fixture reads altered the seeded live sentinel")
    require(fixture_state["entries"][0]["message"]["id"] == "shared-msg-001", "fixture cache was not actually exercised")


def cache_special_file_refusal(client):
    # Refusal probes need a persisted index, not a metrics side effect.
    client.request("cache.clear")
    indexes = list((client.directory / "cache").rglob("index.json"))
    require(len(indexes) == 1, "special-file fixture did not have one account store")
    directory = indexes[0].parent
    client.evidence = {"specialFileRefusals": []}
    for name in ["index.json", "lock"]:
        path = directory / name
        original = path.read_bytes()
        target = client.directory / f"synthetic-{name}-target"
        target.write_bytes(original)
        target.chmod(0o600)
        for kind in ["symlink", "public-mode", "fifo", "directory"]:
            path.unlink()
            if kind == "symlink":
                path.symlink_to(target)
            elif kind == "public-mode":
                path.write_bytes(original)
                path.chmod(0o644)
            elif kind == "fifo":
                os.mkfifo(path, 0o600)
            else:
                path.mkdir(mode=0o700)
            try:
                started = time.monotonic()
                error = client.request("cache.stats", ok=False)
                elapsed = time.monotonic() - started
                client.evidence["specialFileRefusals"].append({"file": name, "kind": kind,
                                                             "elapsedSeconds": round(elapsed, 6), "code": error["code"]})
                require(error["code"] == "InsecureCacheFile", f"{name} {kind} was not explicitly refused")
                require(elapsed < 2, f"{name} {kind} refusal blocked on the special file")
                require(target.read_bytes() == original, "cache refusal modified a symlink target")
            finally:
                if path.is_dir() and not path.is_symlink():
                    path.rmdir()
                else:
                    path.unlink()
                path.write_bytes(original)
                path.chmod(0o600)
            cache_limits(client, ACCOUNTS[0])


def atomic_replacement_quota(client):
    client.extra = ("--disk-limit-bytes", "131072")
    client.restart()
    draft = client.request("draft.create", draft={"to": ["recipient@example.org"], "subject": "Synthetic atomic quota",
                                                  "bodyText": "x" * 70000})
    root = client.directory / "cache"
    stop = threading.Event()
    observed = {"peak": 0, "samples": 0, "error": None}

    def watch():
        while not stop.is_set():
            try:
                total = 0
                for path in root.rglob("*"):
                    try:
                        info = path.lstat()
                    except FileNotFoundError:
                        continue
                    if stat.S_ISREG(info.st_mode):
                        total += info.st_size
                observed["peak"] = max(observed["peak"], total)
                observed["samples"] += 1
            except Exception as error:
                observed["error"] = str(error)
                return
            stop.wait(.001)

    watcher = threading.Thread(target=watch)
    watcher.start()
    try:
        # Each final version fits. Both copies coexist during atomic replacement,
        # so replacing one retained70KB draft with another must fail at131072B.
        error = client.request("draft.update", draftId=draft["id"], draft={**draft, "bodyText": "y" * 70000}, ok=False)
        require(error["code"] == "DiskQuotaExceeded", "atomic replacement ignored the retained old file's logical bytes")
        require(client.request("draft.read", draftId=draft["id"]) == draft, "rejected atomic replacement changed the retained draft")
        for index in range(12):
            updated = client.request("draft.update", draftId=draft["id"], draft={**draft, "bodyText": str(index) * 10000})
            require(updated["bodyText"] == str(index) * 10000, "allowed bounded atomic replacement changed draft content")
            cache_limits(client, ACCOUNTS[0])
    finally:
        stop.set()
        watcher.join(timeout=3)
        client.evidence = {"logicalByteWatcher": {"quotaBytes": 131072, "sampledPeakBytes": observed["peak"],
                                                  "samples": observed["samples"], "sampleIntervalMs": 1,
                                                  "limitation": "sampling may miss a short transient; old-plus-new refusal is checked independently"}}
    require(not watcher.is_alive() and observed["error"] is None and observed["samples"] > 0,
            "finite logical-byte quota watcher failed")
    require(observed["peak"] <= 131072, "sampled atomic replacement transiently exceeded logical-byte quota")


def finite_regular_cli_inputs(client):
    fifo = client.directory / "synthetic input fifo"
    os.mkfifo(fifo, 0o600)
    target = client.directory / "synthetic input regular.json"
    target.write_text("{}")
    target.chmod(0o600)
    link = client.directory / "synthetic input symlink"
    link.symlink_to(target)
    checks = []
    client.evidence = {"finiteFileInputRefusals": checks}
    for family, verb, option in [("mail", "compose", "--body-file"), ("mail", "compose", "--draft-file"),
                                 ("mail", "compose", "--attach-file"), ("contacts", "upsert", "--contact-file")]:
        for path, code in [(fifo, "NotRegularFile"), (link, "SymbolicLinkNotAllowed")]:
            argv = [str(client.binary), family, verb, "--fixtures", "--fixture-root", str(FIXTURES),
                    "--cache-dir", str(client.directory / "cache"), "--account", ACCOUNTS[0], option, str(path)]
            started = time.monotonic()
            result = subprocess.run(argv, input=b"", capture_output=True, cwd=client.directory,
                                    env=client.environment, preexec_fn=no_core_dump, timeout=3)
            elapsed = time.monotonic() - started
            require(elapsed < 2 and len(result.stdout) + len(result.stderr) <= 16384,
                    "CLI unsafe file input blocked or produced unbounded diagnostics")
            require(result.returncode != 0 and code.encode() in result.stdout + result.stderr,
                    f"CLI {option} did not refuse {code} with a failure exit")
            checks.append({"option": option, "kind": "fifo" if path == fifo else "symlink",
                           "code": code, "exitCode": result.returncode, "elapsedSeconds": round(elapsed, 6)})
    require(not client.request("draft.list")["drafts"], "CLI file-input refusal created an orphan draft")


def restart_persistence(client):
    for account in ACCOUNTS:
        list_all(client, account)
    before = {a: cache_limits(client, a) for a in ACCOUNTS}
    params = {"draft": {"to": ["recipient@example.org"], "subject": "Persisted operation", "bodyText": "Synthetic."},
              "operationId": "fixture-restart-send"}
    sent = client.request("mail.send", **params)
    require(sent["outcome"] == "applied", "fixture send was not applied")
    client.restart()
    for account in ACCOUNTS:
        require(cache_limits(client, account)["metadataEntries"] >= before[account]["metadataEntries"],
                "restart lost explicit cached metadata")
    calls_before = cache_limits(client, ACCOUNTS[0])["fixtureSends"]
    require(client.request("mail.send", **params) == sent, "restart lost operation deduplication receipt")
    require(cache_limits(client, ACCOUNTS[0])["fixtureSends"] == calls_before, "restart operation replay resent mail")


def denied_mutations(client):
    before = cache_limits(client, ACCOUNTS[0])
    client.request("mail.trash", messageId="shared-msg-001", operationId="fixture-denied-trash", ok=False)
    client.request("mail.send", draft={"to": ["recipient@example.org"], "subject": "Denied", "bodyText": "Body"},
                   operationId="fixture-denied-send", ok=False)
    client.request("contacts.upsert", contact={"name": "Denied Fixture", "emails": ["denied@example.org"]},
                   operationId="fixture-denied-contact", ok=False)
    client.request("invitation.reply", messageId="shared-msg-009", status="accepted",
                   operationId="fixture-denied-rsvp", ok=False)
    after = cache_limits(client, ACCOUNTS[0])
    require(after["fixtureCalls"] == before["fixtureCalls"] and after["fixtureSends"] == before["fixtureSends"],
            "permission rejection reached provider")


def rejected_mutation_rollback(client):
    before = client.request("mail.read", messageId="shared-msg-001")
    client.request("mail.trash", messageId="shared-msg-001", operationId="fixture-rejected-trash", ok=False)
    client.request("mail.mark", messageId="shared-msg-001", unread=False, operationId="fixture-rejected-mark", ok=False)
    require(client.request("mail.read", messageId="shared-msg-001") == before, "rejected mutation changed local state")


def unknown_send(client):
    before = cache_limits(client, ACCOUNTS[0])
    params = {"draft": {"to": ["recipient@example.org"], "subject": "Unknown fixture", "bodyText": "Body"},
              "operationId": "fixture-unknown-send"}
    first = client.request("mail.send", **params)
    require(first["outcome"] == "unknown", "lost response claimed definite delivery/failure")
    require(bool(first.get("draftId")), "uncertain direct send omitted its recoverable draft identity")
    draft = client.request("draft.read", draftId=first["draftId"])
    require(draft["subject"] == params["draft"]["subject"] and draft["bodyText"] == params["draft"]["bodyText"]
            and addresses(draft["to"]) == ["recipient@example.org"], "uncertain direct send lost reviewed content")
    require(client.request("draft.discard", draftId=draft["id"], ok=False)["code"] == "UnknownOutcome",
            "uncertain submission allowed recovery draft deletion")
    require(client.request("draft.update", draftId=draft["id"], draft={**draft, "bodyText": "Overwritten uncertain content"}, ok=False)["code"] == "UnknownOutcome",
            "uncertain submission allowed reviewed content overwrite")
    after = cache_limits(client, ACCOUNTS[0])
    replay = client.request("mail.send", **params)
    require(replay == first, "unknown operation replay changed its unresolved outcome")
    require(cache_limits(client, ACCOUNTS[0])["fixtureSends"] == after["fixtureSends"], "unknown operation automatically resent")
    require(after["fixtureCalls"] > before["fixtureCalls"], "fault fixture did not exercise provider boundary")
    operations = client.request("operation.list")["operations"]
    require(len(operations) == 1 and operations[0] == first, "uncertain send omitted its single original journal receipt")
    for command, arguments in [("mail.send", {"draft": params["draft"]}), ("draft.send", {"draftId": draft["id"]})]:
        receipt = client.request(command, **arguments, operationId=f"fixture-new-{command}")
        require(receipt == first, "new operation ID bypassed unknown-send protection")
        require(client.request("operation.list")["operations"] == operations, "new operation ID added a second uncertain journal entry")
        stats = cache_limits(client, ACCOUNTS[0])
        require(stats["fixtureCalls"] == after["fixtureCalls"] and stats["fixtureSends"] == after["fixtureSends"],
                "new operation ID redispatched an uncertain payload")
        require([item["id"] for item in client.request("draft.list")["drafts"]] == [draft["id"]],
                "unknown-send replay created a duplicate recovery draft")
    client.restart()
    restarted_sends = cache_limits(client, ACCOUNTS[0])["fixtureSends"]
    require(client.request("mail.send", **params) == first, "restart discarded unknown operation outcome")
    require(cache_limits(client, ACCOUNTS[0])["fixtureSends"] == restarted_sends, "restart retried unresolved send")
    require(client.request("draft.read", draftId=draft["id"]) == draft, "restart lost uncertain direct-send recovery draft")
    restarted_calls = cache_limits(client, ACCOUNTS[0])["fixtureCalls"]
    require(client.request("mail.send", draft=params["draft"], operationId="fixture-new-after-restart") == first,
            "restart allowed a new operation ID to bypass uncertainty")
    require(client.request("operation.list")["operations"] == operations
            and cache_limits(client, ACCOUNTS[0])["fixtureCalls"] == restarted_calls,
            "restart redispatched or re-journaled an uncertain payload")
    client.request("cache.clear")
    require(client.request("operation.read", operationId=params["operationId"]) == first,
            "cache clear lost unresolved operation receipt")
    require(client.request("draft.read", draftId=draft["id"]) == draft, "cache clear lost uncertain recovery draft")


CASES = [("pagination-account-isolation", pagination_and_isolation, None),
         ("account-discovery-search", accounts_and_search, None), ("attachment-binary-roundtrip", attachment_roundtrip, None),
         ("cursor-account-query-binding", cursor_binding, None), ("mime-and-readonly", mime_and_readonly, None),
         ("thread-and-reply-all", thread_and_reply, None), ("draft-send-idempotency", draft_and_send, None),
         ("header-injection", header_injection, None), ("labels-trash-restore", labels_and_trash, None),
         ("draft-wrong-type-rollback", draft_wrong_type_rollback, None),
         ("invalid-message-id-reply", invalid_message_id_reply, None),
         ("incoming-recipient-over32", incoming_recipient_over32, None),
         ("incoming-reply-to-local65", incoming_reply_to_local65, None),
         ("outgoing-address-limits-unchanged", outgoing_address_limits_unchanged, None),
         ("incoming-header-count-and-budget", incoming_header_count_and_budget, None),
         ("gmail-inline-underdeclared-text", gmail_inline_underdeclared_text, None),
         ("quote-body-limit-rollback", quote_body_limit_rollback, None),
         ("decoded-body-boundary", decoded_body_boundary, None),
         ("mime-refusal-preserves-valid-cache", mime_refusal_preserves_valid_cache, None),
         ("optional-field-type-rejection", optional_field_type_rejection, None),
         ("one-shot-commands", one_shot_commands, None),
         ("one-shot-cached-server-search", one_shot_cached_server_search, None),
         ("sent-outbox-persistence", sent_outbox_persistence, None),
         ("sent-mutations-persist", sent_mutations_persist, None),
         ("draft-attachment-bounds", draft_attachment_bounds, None),
         ("contacts-concurrency", contacts_and_conflicts, None), ("recurring-rsvp", rsvp_semantics, None),
         ("cache-clear-isolation", cache_clear_isolation, None), ("malformed-recovery", malformed_recovery, None),
         ("cache-private-permissions", cache_permissions, None),
         ("backend-cache-isolation", backend_cache_isolation, None),
         ("cache-special-file-refusal", cache_special_file_refusal, None),
         ("atomic-replacement-quota", atomic_replacement_quota, None),
         ("finite-regular-cli-inputs", finite_regular_cli_inputs, None),
         ("cache-configured-eviction", cache_eviction_bounds, None),
         ("oversized-request-recovery", oversized_request_recovery, None),
         ("stdout-backpressure", stdout_backpressure, None), ("agent-cli-alias", agent_alias, None),
         ("mutation-survives-body-eviction", mutation_survives_body_eviction, None),
         ("reopen-enforces-lowered-limits", reopening_lower_limits, None),
         ("rsvp-replay-persistence", rsvp_replay_persistence, None),
         ("cached-body-identity", cached_body_identity, None),
         ("cached-body-account-swap", cached_body_account_swap, None),
         ("restart-cache-and-operation-persistence", restart_persistence, None),
         ("readonly-capability-gates", denied_mutations, "readonly"),
         ("rejected-mutation-rollback", rejected_mutation_rollback, "rejected-mutation"),
         ("send-not-applied-response-lost", unknown_send, "unknown-send"),
         ("send-applied-response-lost", unknown_send, "applied-lost")]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--build-mode", type=build_mode, default="debug")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--case", action="append", choices=[name for name, _, _ in CASES])
    args = parser.parse_args()
    output = args.output or ROOT / "tests/results" / f"terminal-integration-{args.build_mode}.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    binary = args.binary.resolve()
    identity = read_build_info(binary, args.build_mode)
    report = {"date": time.strftime("%Y-%m-%dT%H:%M:%S%z"), **identity,
              "binarySha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "fixtureManifestSha256": hashlib.sha256((FIXTURES / "manifest.json").read_bytes()).hexdigest(),
              "inboundAddressFixtureSha256": hashlib.sha256((FIXTURES / "inbound-addresses.json").read_bytes()).hexdigest(),
              "inboundHeaderFixtureSha256": hashlib.sha256((FIXTURES / "inbound-headers.json").read_bytes()).hexdigest(),
              "inlineTextSizeFixtureSha256": hashlib.sha256((FIXTURES / "inline-text-size.json").read_bytes()).hexdigest(),
              "synthetic": True, "liveWrites": False, "desktopUsed": False, "cases": []}
    with tempfile.TemporaryDirectory(prefix="omagma-terminal-test-") as directory:
        for name, check, scenario in CASES:
            if args.case and name not in args.case:
                continue
            start = time.monotonic()
            receipt = {"name": name, "scenario": scenario}
            client = None
            try:
                with Client(binary, Path(directory) / name, scenario) as client:
                    check(client)
                require(client.process.returncode == 0, "CLI did not exit cleanly after the completed case")
                require(not client.stderr, "CLI wrote unexpected stderr")
                receipt.update(passed=True, frames=client.frame_count, maxFrameBytes=client.max_frame_bytes)
            except Exception as error:
                receipt.update(passed=False, error=f"{type(error).__name__}: {error}")
                traceback.print_exc()
            if client:
                if hasattr(client, "evidence"):
                    receipt["evidence"] = client.evidence
                receipt["exitCode"] = client.process.returncode
                receipt["stderrBytes"] = len(client.stderr)
                if client.stderr:
                    stderr_path = output.with_name(f"{output.stem}-{name}.stderr.log")
                    stderr_path.write_bytes(client.stderr)
                    receipt["stderrFile"] = stderr_path.name
            receipt["elapsedSeconds"] = round(time.monotonic() - start, 4)
            report["cases"].append(receipt)
            print(json.dumps(receipt), flush=True)
    report["passed"] = bool(report["cases"]) and all(c["passed"] for c in report["cases"])
    output.write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
