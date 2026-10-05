#!/usr/bin/env python3
"""Fictional cache-first/delta checks; requires the cooperative host window."""
from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import json
from pathlib import Path
import signal
import tempfile
import time

from build_info import build_mode, read_build_info
from probes.cache_refresh_fixture import ACCOUNTS, FIXTURES, RETAINED_COUNT, corpus
from terminal_integration import Client, require
from terminal_pty import Terminal
from terminal_status_screen import StatusScreen
from terminal_reader import reader_contains

BODY_IDS = ("shared-msg-057", "shared-msg-091", "shared-msg-092", "shared-msg-093", "shared-msg-094", "shared-msg-095", "shared-msg-096")
FETCH_COLOR = ("rgb", 92, 177, 255)
CURRENT_COLOR = ("rgb", 133, 207, 149)
OFFLINE_COLOR = ("rgb", 255, 198, 98)


class CacheFailure(Exception):
    def __init__(self, message, diagnostics):
        super().__init__(message)
        self.diagnostics = diagnostics


class ProviderFixture:
    def __init__(self, directory):
        self.root = Path(directory) / "provider"
        (self.root / "accounts").mkdir(parents=True, mode=0o700)
        self.data = {account: corpus(account) for account in ACCOUNTS}
        for account in ACCOUNTS:
            self.stage(account, "baseline")

    def path(self, account):
        return self.root / "accounts" / f"{account.split('@')[0]}.json"

    def stage(self, account, name, held=False):
        data = self.data[account]
        source = copy.deepcopy(data[name])
        if name == "baseline":
            sync = copy.deepcopy(data["noChangeHistory"])
        elif name == "delta":
            sync = {"historyId": "1001", "historyPages": copy.deepcopy(data["historyPages"])}
        else:
            sync = {"historyId": "1100", "history": [], "expired": True}
        if held:
            key = account.split("@")[0]
            sync.update(fixtureHold=f"{key}.hold", fixtureEntered=f"{key}.entered")
            hold, entered = self.markers(account)
            hold.write_text("synthetic provider held\n")
            entered.unlink(missing_ok=True)
        source["sync"] = sync
        self.path(account).write_text(json.dumps(source, ensure_ascii=False) + "\n")

    def markers(self, account=ACCOUNTS[0]):
        key = account.split("@")[0]
        return self.root / f"{key}.hold", self.root / f"{key}.entered"

    def is_held(self, account=ACCOUNTS[0]):
        hold, entered = self.markers(account)
        return hold.exists() and entered.exists()

    def release(self, account=ACCOUNTS[0]):
        self.markers(account)[0].unlink(missing_ok=True)

    def wait_entered(self, process, account=ACCOUNTS[0], pump=None):
        deadline = time.monotonic() + 5
        while not self.is_held(account):
            require(process.poll() is None, "provider owner exited before held remote boundary")
            require(time.monotonic() < deadline, "fixture did not acknowledge remote hold within5s")
            if pump: pump(.01)
            else: time.sleep(.005)

    def options(self, *extra):
        return ("--fixture-root", str(self.root), "--metadata-limit", str(RETAINED_COUNT), *extra)


def cached(client, command, account=ACCOUNTS[0], **params):
    return client.request(command, account, cacheOnly=True, **params)


def metrics(client, account=ACCOUNTS[0]):
    value = cached(client, "cache.stats", account)
    for key in ("syncCalls", "syncListCalls", "syncHistoryPages", "syncMetadataGets", "syncBodyGets"):
        require(type(value.get(key)) is int, f"cache stats omit independent {key} counter")
    return value


def pages(client, account=ACCOUNTS[0], **params):
    result, cursor, seen = [], "", set()
    for _ in range(20):
        page = cached(client, "mail.list", account, limit=12, cursor=cursor, **params)
        require(len(page["messages"]) <= 12, "cached page exceeds requested bound")
        result.extend(page["messages"])
        cursor = page.get("nextCursor") or ""
        if not cursor:
            break
        require(cursor not in seen, "cached pagination cursor cycles")
        seen.add(cursor)
    else:
        raise AssertionError("cached pagination did not terminate")
    ids = [message["id"] for message in result]
    require(len(ids) == len(set(ids)), "cache duplicate IDs after history merge")
    return result


def body_files(directory, account=ACCOUNTS[0]):
    result = {}
    for path in (Path(directory) / "cache").rglob("*.json"):
        value = json.loads(path.read_text())
        message = value.get("message")
        if value.get("account") == account and isinstance(message, dict) and "bodyText" in message:
            result[message["id"]] = {"path": path, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    return result


def digests(directory, account=ACCOUNTS[0]):
    return {key: value["sha256"] for key, value in body_files(directory, account).items()}


def seed(binary, directory, fixture, accounts=(ACCOUNTS[0],), bodies=BODY_IDS, extra=(), byte_guard=False):
    with Client(binary, directory, extra=fixture.options(*extra)) as client:
        for account in accounts:
            client.request("mail.refresh", account, limit=40)
            ids = [m["id"] for m in pages(client, account)]
            expected = fixture.data[account]["expected"]["baselineIds"]
            require(ids == (expected[:len(ids)] if byte_guard else expected),
                    "cold bootstrap retained IDs differ from newest-count oracle")
            require(bool(ids), "bootstrap lost every metadata row")
            if not byte_guard:
                require(len(body_files(directory, account)) == RETAINED_COUNT, "cold bootstrap did not prefetch complete offline head")
            for message_id in bodies:
                message = client.request("mail.read", account, messageId=message_id)
                require(account in message["bodyText"], "seed full body lost account identity")
    require(client.process.returncode == 0 and not client.stderr, "seed CLI child failed cleanup")


def start_refresh(client, account=ACCOUNTS[0], **params):
    client.next_id += 1
    request = {"id": f"test-{client.next_id}", "cmd": "mail.refresh", "account": account, "limit": 40, **params}
    client.raw(json.dumps(request).encode() + b"\n")
    return request


def finish_refresh(client, request):
    reply = client.receive(timeout=8)
    require(reply.get("id") == request["id"] and reply.get("account") == request["account"], "held refresh lost response identity")
    require(reply.get("ok") is True, f"held refresh failed: {reply.get('error', {}).get('code', 'missing')}")
    return reply["data"]


def clean(client):
    require(client.process.returncode == 0 and not client.stderr, "CLI child failed exit/stderr gate")


def cli_case(binary, directory, fixture, name):
    receipt = {}
    if name == "cache-only-and-misses":
        with Client(binary, directory, extra=fixture.options()) as client:
            before = metrics(client)
            for command, params in (("mail.read", {"messageId": "shared-msg-092"}), ("mail.thread", {"threadId": "shared-thread-030"})):
                error = client.request(command, cacheOnly=True, ok=False, **params)
                require(error["code"] == "CacheMiss", "cache-only miss was not explicit")
            require(metrics(client)["fixtureCalls"] == before["fixtureCalls"], "cache-only miss contacted provider")
        clean(client)
        seed(binary, directory, fixture)
        before_bytes = digests(directory)
        with Client(binary, directory, scenario="offline-refresh", extra=fixture.options()) as client:
            before = metrics(client)
            require(len(pages(client)) == 40, "offline cached newest list unavailable")
            message = cached(client, "mail.read", messageId="shared-msg-092")
            thread = cached(client, "mail.thread", threadId="shared-thread-030")
            require("message 092" in message["bodyText"] and {m["id"] for m in thread["messages"]} == {"shared-msg-091", "shared-msg-092", "shared-msg-093"}, "offline cached full bodies/thread unavailable")
            require(metrics(client)["fixtureCalls"] == before["fixtureCalls"], "offline cache reads contacted provider")
        clean(client)
        require(digests(directory) == before_bytes, "cache-only reads rewrote immutable bodies")
        receipt.update(cacheOnlyProviderCalls=0, cachedThreadMessages=3)
    elif name == "no-change-history":
        seed(binary, directory, fixture)
        original = digests(directory)
        with Client(binary, directory, extra=fixture.options()) as client:
            before = metrics(client)
            client.request("mail.refresh", limit=40)
            after = metrics(client)
            require(after["syncCalls"] == before["syncCalls"] + 1, "no-change did not check history")
            require(after["syncListCalls"] == before["syncListCalls"] and after["syncHistoryPages"] == before["syncHistoryPages"] + 1, "no-change history relisted mailbox or skipped history check")
            require(after["syncMetadataGets"] == before["syncMetadataGets"] and after["syncBodyGets"] == before["syncBodyGets"], "no-change history refetched metadata or bodies")
            require(after["historyId"] == "1000", "no-change history checkpoint changed")
        clean(client)
        require(digests(directory) == original, "no-change rewrote cached full bodies")
        receipt.update(metadataRefetches=0, bodyRefetches=0, immutableBodyDigests=True)
    elif name == "delta-delete-labels-tail":
        seed(binary, directory, fixture)
        before_files = body_files(directory)
        fixture.stage(ACCOUNTS[0], "delta")
        with Client(binary, directory, extra=fixture.options()) as client:
            # Recently reading the oldest row must not make it newer mail.
            cached(client, "mail.read", messageId="shared-msg-057")
            before = metrics(client)
            client.request("mail.refresh", limit=40)
            rows = pages(client)
            require([m["id"] for m in rows] == fixture.data[ACCOUNTS[0]]["expected"]["deltaIds"], "delta retained IDs differ from timestamp oracle")
            changed = next(m for m in rows if m["id"] == "shared-msg-093")
            require(changed["unread"] is False and "STARRED" in changed["labels"], "label/read delta not applied")
            full_changed = cached(client, "mail.read", messageId="shared-msg-093")
            require(full_changed["unread"] is False and "STARRED" in full_changed["labels"], "cached full body ignored label/read delta")
            require("INBOX" not in next(m for m in rows if m["id"] == "shared-msg-094")["labels"], "removed INBOX label retained")
            after = metrics(client)
            require(after["syncListCalls"] == before["syncListCalls"] and after["syncHistoryPages"] - before["syncHistoryPages"] == 2, "delta did not consume exactly two history pages without full relist")
            require(after["syncMetadataGets"] - before["syncMetadataGets"] == 2 and after["syncBodyGets"] - before["syncBodyGets"] == 2, "delta refetched unchanged metadata/body or duplicate new ID")
            for message_id in ("shared-msg-095", "shared-msg-057"):
                require(client.request("mail.read", cacheOnly=True, messageId=message_id, ok=False)["code"] == "CacheMiss", "deleted/evicted body remains readable")
                require(not before_files[message_id]["path"].exists(), "deleted/evicted body file remains on disk")
        clean(client)
        after_files = digests(directory)
        for message_id in ("shared-msg-093", "shared-msg-094", "shared-msg-092"):
            require(after_files[message_id] == before_files[message_id]["sha256"], "label delta rewrote immutable body")
        receipt.update(retainedRows=40, historyPages=2, listRefetches=0, newMetadataGets=2, newFullBodyGets=2, unchangedBodyRefetches=0, wholeTailBodyEvicted=True)
    elif name in ("held-refresh-cache-usable", "history404-bounded-resync"):
        seed(binary, directory, fixture)
        stage = "delta" if name == "held-refresh-cache-usable" else "expired"
        fixture.stage(ACCOUNTS[0], stage, held=True)
        with Client(binary, directory, extra=fixture.options()) as owner:
            request = start_refresh(owner)
            fixture.wait_entered(owner.process)
            with Client(binary, directory, extra=fixture.options()) as reader:
                require(len(pages(reader)) == 40, "held refresh blocked cached list")
                full = cached(reader, "mail.read", messageId="shared-msg-092")
                thread = cached(reader, "mail.thread", threadId="shared-thread-030")
                require("message 092" in full["bodyText"] and len(thread["messages"]) == 3, "held refresh blocked full read/thread")
                before = metrics(reader)
                require(fixture.is_held(), "remote completed before cached read/thread")
            clean(reader)
            fixture.release()
            finish_refresh(owner, request)
            rows = pages(owner)
            expected = fixture.data[ACCOUNTS[0]]["expected"]["resyncIds" if stage == "expired" else "deltaIds"]
            require([m["id"] for m in rows] == expected, "held refresh commit differs from newest-count oracle")
            after = metrics(owner)
            if stage == "expired":
                require(0 < after["syncMetadataGets"] - before["syncMetadataGets"] <= 40, "history404 resync exceeded configured newest count")
                require(0 <= after["syncBodyGets"] - before["syncBodyGets"] <= 40, "history404 full-body resync exceeded newest-count bound")
            require(len(body_files(directory)) == RETAINED_COUNT, "successful refresh did not retain complete offline head")
        clean(owner)
        receipt.update(cachedFullReadBeforeRemoteRelease=True, cachedThreadBeforeRemoteRelease=True, retainedRows=40)
    elif name == "failed-refresh-preserves-cache":
        seed(binary, directory, fixture)
        original = digests(directory)
        with Client(binary, directory, scenario="offline-refresh", extra=fixture.options()) as client:
            before = metrics(client)
            require(client.request("mail.refresh", limit=40, ok=False)["code"] == "TransientFailure", "offline fixture did not fail remotely")
            require([m["id"] for m in pages(client)] == fixture.data[ACCOUNTS[0]]["expected"]["baselineIds"], "failed refresh discarded cached rows")
            require("message 092" in cached(client, "mail.read", messageId="shared-msg-092")["bodyText"], "failed refresh discarded full body")
            require(metrics(client)["historyId"] == before["historyId"], "failed refresh advanced checkpoint")
        clean(client)
        require(digests(directory) == original, "failed refresh changed full-body files")
        with Client(binary, directory, extra=fixture.options()) as restarted:
            require(len(pages(restarted)) == 40, "offline failure damaged restart cache")
        clean(restarted)
        receipt.update(cachedRowsPreserved=40, fullBodyDigestsPreserved=True, checkpointPreserved=True)
    elif name == "account-query-folder-isolation":
        seed(binary, directory, fixture, accounts=ACCOUNTS)
        original = {account: digests(directory, account) for account in ACCOUNTS}
        fixture.stage(ACCOUNTS[0], "delta")
        with Client(binary, directory, extra=fixture.options()) as client:
            token = cached(client, "mail.list", limit=12)["nextCursor"]
            for account, params in ((ACCOUNTS[1], {}), (ACCOUNTS[0], {"query": "subject:thread 030"}), (ACCOUNTS[0], {"label": "STARRED"})):
                require(client.request("mail.list", account, cacheOnly=True, cursor=token, limit=12, ok=False, **params)["code"] == "InvalidCursor", "cached cursor leaked account/query/folder")
            client.request("mail.refresh", limit=40)
            for account in ACCOUNTS[1:]:
                require([m["id"] for m in pages(client, account)] == fixture.data[account]["expected"]["baselineIds"], "another account consumed delta with colliding IDs")
                require(account in cached(client, "mail.read", account, messageId="shared-msg-092")["bodyText"], "cross-account body routing failed")
                require(digests(directory, account) == original[account], "refresh changed another account's bodies")
            before_ids = [m["id"] for m in pages(client)]
            client.request("mail.refresh", limit=40, label="STARRED", query="subject:thread 030")
            require([m["id"] for m in pages(client)] == before_ids, "narrow view replaced global newest-mail retention")
            require({m["id"] for m in pages(client, label="STARRED")} == {"shared-msg-093"}, "folder labels leaked another query/account")
            draft = client.request("draft.create", draft={"to": ["recipient@example.org"], "subject": "Preserve local draft across resync", "bodyText": "Synthetic unsent content."})
            retained_body_digest = digests(directory)["shared-msg-093"]
            fixture.stage(ACCOUNTS[0], "expired")
            before = metrics(client)
            client.request("mail.refresh", limit=40, label="STARRED", query="subject:thread 030")
            require([m["id"] for m in pages(client)] == fixture.data[ACCOUNTS[0]]["expected"]["resyncIds"],
                    "expired narrow refresh replaced global head with scoped result")
            require({m["id"] for m in pages(client, label="STARRED", query="subject:thread 030")} == {"shared-msg-093"},
                    "expired narrow refresh lost requested view identity")
            after = metrics(client)
            require(after["historyId"] == "1100", "expired resync did not establish authoritative checkpoint")
            require(0 < after["syncMetadataGets"] - before["syncMetadataGets"] <= 2 * RETAINED_COUNT,
                    "global plus scoped resync exceeded bounded metadata union")
            require(0 <= after["syncBodyGets"] - before["syncBodyGets"] <= RETAINED_COUNT,
                    "scoped resync prefetched bodies outside retained newest head")
            require(digests(directory)["shared-msg-093"] == retained_body_digest,
                    "expired resync rewrote unchanged retained body")
            require(client.request("draft.read", draftId=draft["id"]) == draft, "expired resync discarded local draft")
            for account in ACCOUNTS[1:]:
                require([m["id"] for m in pages(client, account)] == fixture.data[account]["expected"]["baselineIds"],
                        "expired scoped resync replaced another account's global cache")
        clean(client)
        # Simulate a pre-history cache only while every cache owner is closed.
        # The index is private synthetic state; body files and drafts stay intact.
        indexes = []
        for path in (directory / "cache").rglob("index.json"):
            state = json.loads(path.read_text())
            if state.get("account") == ACCOUNTS[0]:
                indexes.append((path, state))
        require(len(indexes) == 1, "could not identify one fictional account index")
        path, state = indexes[0]
        state.pop("historyId", None)
        state.pop("lastSyncAt", None)
        path.write_text(json.dumps(state) + "\n")
        require(path.stat().st_mode & 0o077 == 0, "legacy-cache simulation changed private permissions")
        with Client(binary, directory, extra=fixture.options()) as restarted:
            before = metrics(restarted)
            require(before["historyId"] == "", "legacy cache did not exercise missing checkpoint")
            restarted.request("mail.refresh", limit=40, label="STARRED", query="subject:thread 030")
            require([m["id"] for m in pages(restarted)] == fixture.data[ACCOUNTS[0]]["expected"]["resyncIds"],
                    "missing-history narrow bootstrap replaced whole-account newest head")
            after = metrics(restarted)
            require(after["historyId"] == "1100" and 0 < after["syncMetadataGets"] - before["syncMetadataGets"] <= 2 * RETAINED_COUNT,
                    "legacy narrow bootstrap failed authoritative bounded projection")
            require(digests(directory)["shared-msg-093"] == retained_body_digest,
                    "legacy bootstrap rewrote unchanged retained body")
            require(restarted.request("draft.read", draftId=draft["id"]) == draft, "legacy bootstrap discarded local draft")
        clean(restarted)
        receipt.update(accountsIsolated=3, cursorContextsRejected=3, narrowViewPreservesGlobalCache=True,
                       expiredNarrowRefreshPreservesGlobalHead=True, missingHistoryNarrowBootstrapPreservesGlobalHead=True,
                       unchangedBodyDigestAndLocalDraftPreserved=True, globalAndScopedMetadataBound=2 * RETAINED_COUNT)
    elif name == "secondary-byte-quota":
        # Bodies are immutable synthetic text and remain below the 2MiB limit.
        account = ACCOUNTS[0]
        for number in (80, 81, 82):
            message = next(m for m in fixture.data[account]["baseline"]["messages"] if m["id"] == f"shared-msg-{number:03}")
            body = (f"Synthetic {account} body {number:03}.\n" + "Quota-only fictional text.\n" * 2600).encode()
            message["payload"]["body"] = {"size": len(body), "data": base64.urlsafe_b64encode(body).decode().rstrip("=")}
        fixture.stage(account, "baseline")
        seed(binary, directory, fixture, accounts=ACCOUNTS, bodies=(), extra=("--disk-limit-bytes", "131072"), byte_guard=True)
        with Client(binary, directory, extra=fixture.options("--disk-limit-bytes", "131072")) as client:
            for number in (80, 81, 82):
                body = client.request("mail.read", messageId=f"shared-msg-{number:03}")
                require(len(body["bodyText"].encode()) > 64 * 1024, "quota body does not exercise byte guard")
                stats = metrics(client)
                require(stats["diskBytes"] <= 131072 and stats["metadataEntries"] <= 40, "secondary byte/count guard exceeded")
                ids = [m["id"] for m in pages(client)]
                require(ids == fixture.data[account]["expected"]["baselineIds"][:len(ids)], "byte guard evicted newer metadata before the old tail")
            for other in ACCOUNTS[1:]:
                require(len(pages(client, other)) == 40, "one account's byte pressure evicted another account")
        clean(client)
        receipt.update(byteQuota=131072, newestCountBound=40, accountByteIsolation=True)
    else:
        raise AssertionError("unknown cache CLI case")
    return receipt


def status_color(terminal, label, expected):
    terminal.until(lambda: terminal.screen.locate(label) is not None)
    actual = terminal.screen.foregrounds(label)
    require(actual == {expected}, f"current status {label!r} color differs: {actual}")
    return {"label": label, "foreground": list(expected) if expected else None}


def contains_body(terminal, number):
    return reader_contains(terminal.screen, f"Synthetic {ACCOUNTS[0]} message {number:03}.")


def tui_case(binary, directory, fixture, name):
    seeded = name != "tui-cold-fetching"
    if seeded:
        seed(binary, directory, fixture)
    if name == "tui-offline-cache":
        extra = fixture.options("--fixture-scenario", "offline-refresh")
    else:
        fixture.stage(ACCOUNTS[0], "delta" if seeded else "baseline", held=True)
        extra = fixture.options()
    environment = {"NO_COLOR": "1" if name == "tui-no-color-owner-exit" else None, "COLORTERM": "truecolor"}
    terminal = Terminal(binary, directory, extra=extra, environment=environment, screen_type=StatusScreen)
    try:
        if name == "tui-cold-fetching":
            fixture.wait_entered(terminal.process, pump=terminal.pump)
            color = status_color(terminal, "Fetching mail", FETCH_COLOR)
            require("Fetching mail…" in terminal.text(), "cold startup lacks explicit fetching placeholder")
            require(fixture.is_held(), "cold status was checked after remote completed")
            fixture.release()
            status_color(terminal, "Up to date", CURRENT_COLOR)
            terminal.until(lambda: "Synthetic personal thread 031" in terminal.text())
            return {**terminal.finish(), "coldFetchingColor": color, "freshRowsVisibleAfterRelease": True}
        label = "Offline cached mail" if name == "tui-offline-cache" else "Refreshing cached mail"
        if name != "tui-offline-cache":
            fixture.wait_entered(terminal.process, pump=terminal.pump)
        color = status_color(terminal, label, None if name == "tui-no-color-owner-exit" else OFFLINE_COLOR if name == "tui-offline-cache" else FETCH_COLOR)
        terminal.until(lambda: "Synthetic personal thread 031" in terminal.text() and contains_body(terminal, 96))
        terminal.send(b"l")  # Enter reader focus; J/K select mail there.
        terminal.gap()
        # Each navigation boundary is observed; never batch keys over a worker.
        for number in (95, 94, 93):
            terminal.send(b"J")
            terminal.until(lambda number=number: contains_body(terminal, number))
            require("No matching messages" not in terminal.text() and "Fetching mail…" not in terminal.text(), "cached list reset empty while refreshing")
        require(name == "tui-offline-cache" or fixture.is_held(), "remote completed before cached navigation/full read")
        terminal.send(b"\r")
        terminal.until(lambda: contains_body(terminal, 91))
        require(name == "tui-offline-cache" or fixture.is_held(), "remote completed before cached thread reading")
        if name == "tui-no-color-owner-exit":
            started = time.monotonic()
            result = terminal.finish(signal_mode=signal.SIGTERM)
            require(fixture.is_held(), "owner exit test accidentally released remote")
            result.update(noColorStatusText=True, heldRefreshCancelled=True, exitSeconds=round(time.monotonic() - started, 4))
            return result
        if name == "tui-offline-cache":
            return {**terminal.finish(), "offlineStatusColor": color, "cachedReadAndThreadUsable": True}
        # Select96 whose INBOX index really changes0->2.  For93 the two new
        # rows cancel delete95/archive94 and its index happens not to move.
        terminal.send(b"h")
        terminal.gap()
        terminal.send(b"\x1b[H")
        terminal.until(lambda: contains_body(terminal, 96))
        require(fixture.is_held(), "selection chosen after remote completed")
        fixture.release()
        status_color(terminal, "Up to date", CURRENT_COLOR)
        terminal.until(lambda: "Synthetic personal delta 098" in terminal.text())
        require(contains_body(terminal, 96), "refresh jumped selection from original message identity")
        require("No matching messages" not in terminal.text(), "merge reset cached list empty")
        return {**terminal.finish(), "cachedRowsBeforeRemoteRelease": True, "cachedFullReadBeforeRemoteRelease": True,
                "cachedThreadBeforeRemoteRelease": True, "selectedIdentityPreserved": True,
                "fetchingColor": color, "currentColor": list(CURRENT_COLOR)}
    except Exception as error:
        raise CacheFailure(f"{type(error).__name__}: {error}", {
            "currentCells": terminal.text().splitlines(), "exitCode": terminal.process.poll(),
            "outputBytes": terminal.output_total,
            "escapedSyntheticOutputTail": bytes(terminal.output[-262144:]).decode("utf-8", errors="replace"),
        }) from None
    finally:
        terminal.close()


CASES = (
    "cache-only-and-misses", "no-change-history", "delta-delete-labels-tail", "held-refresh-cache-usable",
    "failed-refresh-preserves-cache", "history404-bounded-resync", "account-query-folder-isolation", "secondary-byte-quota",
    "tui-warm-held-selection", "tui-offline-cache", "tui-no-color-owner-exit", "tui-cold-fetching",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--build-mode", type=build_mode, default="debug")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--case", choices=CASES)
    args = parser.parse_args()
    args.binary = args.binary.resolve()
    require(not args.output.exists(), "refusing to overwrite preserved cache qualification receipt")
    info = read_build_info(args.binary, args.build_mode)
    report = {**info, "binarySha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
              "syntheticOnly": True, "desktopUsed": False, "liveWrites": False,
              "heldProviderUsesExplicitMarkers": True, "retainedNewestCount": RETAINED_COUNT, "cases": []}
    with tempfile.TemporaryDirectory(prefix="omagma-cache-fixture-") as temporary:
        for name in (args.case,) if args.case else CASES:
            directory = Path(temporary) / name
            directory.mkdir(mode=0o700)
            fixture = ProviderFixture(directory)
            started = time.monotonic()
            result = {"name": name}
            try:
                value = tui_case(args.binary, directory, fixture, name) if name.startswith("tui-") else cli_case(args.binary, directory, fixture, name)
                result.update(value, passed=True)
            except Exception as error:
                result.update(passed=False, error=f"{type(error).__name__}: {error}")
                if isinstance(error, CacheFailure):
                    result.update(error.diagnostics)
            result["elapsedSeconds"] = round(time.monotonic() - started, 4)
            report["cases"].append(result)
            print(json.dumps(result), flush=True)
            # The first observed failure returns the host window for diagnosis.
            if not result["passed"]:
                break
    report["passed"] = len(report["cases"]) == (1 if args.case else len(CASES)) and all(case["passed"] for case in report["cases"])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
