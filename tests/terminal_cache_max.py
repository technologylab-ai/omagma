#!/usr/bin/env python3
"""One independent2000-row cache/delta stress gate; cooperative host lock required."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import tempfile
import time

from build_info import build_mode, read_build_info
from terminal_integration import ACCOUNTS, Client, require

COUNT = 2000
NEW = 100
DELETED = set(range(1000, 1010))
BODY_SAMPLES = (50, 1005, 1500, 1999)
BODY_LIMIT = 2 * 1024**2
HEAP_LIMIT = 64 * 1024**2
FIXTURE_LIMIT = 16 * 1024**2
DISK_LIMIT = 256 * 1024**2
BASE_DATE = 1794042000000


def identifier(number):
    return f"max-cache-{number:04}"


def model(number, full=False):
    references = [f"<r{number:04}-{parent:02}-{'x' * 18}@example.org>" for parent in range(16)]
    result = {"id": identifier(number), "threadId": f"max-thread-{number:04}",
              "from": {"address": "sender@example.org", "name": "Synthetic bounded sender"},
              "to": [], "cc": [], "replyTo": [],
              "subject": f"Synthetic maximum cache message {number:04} " + "s" * 192,
              "snippet": f"Synthetic bounded snippet {number:04} " + "n" * 128,
              "bodyText": "", "bodyHtml": None,
              "messageId": f"<max-message-{number:04}@example.org>", "references": " ".join(references),
              "inReplyTo": references[-1], "labels": ["INBOX", "UNREAD"],
              "receivedAt": BASE_DATE + number * 60000, "unread": True, "attachments": [], "invitation": None}
    if full:
        result["to"] = [{"address": ACCOUNTS[0], "name": "Fictional account"}]
        result["bodyText"] = f"Synthetic private-cache fixture body {number:04}.\nCafé 👋.\n"
    return result


def gmail(number):
    message = model(number, full=True)
    body = message["bodyText"].encode()
    return {"id": message["id"], "threadId": message["threadId"], "internalDate": str(message["receivedAt"]),
            "labelIds": message["labels"], "historyId": "1001", "snippet": message["snippet"],
            "sizeEstimate": len(body), "payload": {"partId": "", "mimeType": "text/plain", "filename": "",
                "headers": [{"name": "From", "value": "Synthetic bounded sender <sender@example.org>"},
                            {"name": "To", "value": ACCOUNTS[0]}, {"name": "Subject", "value": message["subject"]},
                            {"name": "Message-ID", "value": message["messageId"]},
                            {"name": "References", "value": message["references"]},
                            {"name": "In-Reply-To", "value": message["inReplyTo"]},
                            {"name": "Content-Type", "value": "text/plain; charset=utf-8"}],
                "body": {"size": len(body), "data": base64.urlsafe_b64encode(body).decode().rstrip("=")}}}


def encode(value):
    return (json.dumps(value, separators=(",", ":"), ensure_ascii=False) + "\n").encode()


def private_write(path, raw):
    path.write_bytes(raw)
    path.chmod(0o600)


def prepare(directory):
    cache = directory / "cache"
    namespace = cache / "fixtures"
    account_dir = namespace / hashlib.sha256(ACCOUNTS[0].encode()).hexdigest()
    for path in (cache, namespace, account_dir): path.mkdir(mode=0o700)
    entries, original_bodies = [], {}
    for number in range(COUNT - 1, -1, -1):
        entry = {"message": model(number), "bytes": 0, "bodyHash": ""}
        if number in BODY_SAMPLES:
            raw = encode({"schema": 1, "account": ACCOUNTS[0], "message": model(number, full=True)})
            digest = hashlib.sha256(raw).hexdigest()
            entry.update(bytes=len(raw), bodyHash=digest)
            body_path = account_dir / ("mail-" + hashlib.sha256(identifier(number).encode()).hexdigest() + ".json")
            private_write(body_path, raw)
            original_bodies[number] = (body_path, digest)
        entries.append(entry)
    metadata_average = sum(len(encode(entry)) for entry in entries) / COUNT
    require(1200 <= metadata_average <= 2200, "maximum-cache metadata is not representative1.5KiB scale")
    state = {"schema": 1, "account": ACCOUNTS[0], "generation": 7, "serial": 0, "entries": entries,
             "historyId": "1000", "lastSyncAt": BASE_DATE, "views": [], "drafts": [], "contacts": [],
             "operations": [], "outbox": [], "fixtureCalls": 0, "fixtureSends": 0,
             "syncCalls": 0, "syncListCalls": 0, "syncHistoryPages": 0, "syncMetadataGets": 0, "syncBodyGets": 0}
    index = account_dir / "index.json"
    private_write(index, encode(state))
    provider = directory / "provider"
    (provider / "accounts").mkdir(parents=True, mode=0o700)
    changed = [{"message": {"id": identifier(number)}} for number in range(COUNT, COUNT + NEW)]
    deleted = [{"message": {"id": identifier(number)}} for number in sorted(DELETED)]
    source = {"account": ACCOUNTS[0], "generation": 1001,
              "messages": [gmail(number) for number in range(COUNT + NEW - 1, -1, -1) if number not in DELETED],
              "sync": {"historyId": "1001", "historyPages": [{"historyId": "1001", "history": [
                  {"id": "1001", "messagesAdded": changed, "messagesDeleted": deleted}]}]}}
    raw = encode(source)
    require(len(raw) < FIXTURE_LIMIT, "maximum-cache provider fixture exceeds16MiB")
    private_write(provider / "accounts/personal.json", raw)
    expected_numbers = [number for number in range(COUNT + NEW - 1, -1, -1) if number not in DELETED][:COUNT]
    require(len(expected_numbers) == COUNT and expected_numbers[-1] == 90, "independent timestamp/deletion oracle wrong")
    return {"provider": provider, "accountDirectory": account_dir, "index": index, "originalBodies": original_bodies,
            "expectedIds": [identifier(number) for number in expected_numbers], "metadataAverageBytes": round(metadata_average, 1),
            "initialIndexBytes": index.stat().st_size, "providerFixtureBytes": len(raw)}


def metric(client):
    value = client.request("cache.stats", cacheOnly=True)
    require(value["metadataEntries"] <= COUNT and value["diskBytes"] <= DISK_LIMIT, "maximum-cache count/disk limit exceeded")
    require(value["allocatorPeakBytes"] <= HEAP_LIMIT and value["rejectedAllocations"] == 0,
            "maximum-cache heap capped allocation denied or exceeded64MiB")
    return value


def run(binary, directory):
    fixture = prepare(directory)
    extra = ("--fixture-root", str(fixture["provider"]), "--metadata-limit", str(COUNT), "--disk-limit-bytes", str(DISK_LIMIT))
    with Client(binary, directory, extra=extra) as client:
        before = metric(client)
        require(before["metadataEntries"] == COUNT and before["historyId"] == "1000", "preseed schema/checkpoint not loaded")
        started = time.monotonic()
        client.next_id += 1
        request = {"id": f"test-{client.next_id}", "account": ACCOUNTS[0], "cmd": "mail.refresh", "limit": NEW}
        client.raw(json.dumps(request).encode() + b"\n")
        reply = client.receive(timeout=40)
        require(reply.get("id") == request["id"] and reply.get("account") == ACCOUNTS[0], "stress response routing changed")
        require(reply.get("ok") is True, f"max-cache refresh failed: {reply.get('error', {}).get('code', 'missing')}")
        elapsed = round(time.monotonic() - started, 4)
        after = metric(client)
        require(after["historyId"] == "1001" and after["metadataEntries"] == COUNT, "stress lost newest count/checkpoint")
        require(after["syncMetadataGets"] - before["syncMetadataGets"] == NEW and after["syncBodyGets"] - before["syncBodyGets"] == NEW,
                "stress delta did not fetch exactly100 new metadata/full bodies")
        require(after["syncListCalls"] == before["syncListCalls"], "stress delta relisted entire2000-row mailbox")
        actual, cursor = [], ""
        for _ in range(21):
            page = client.request("mail.list", limit=100, cursor=cursor, cacheOnly=True)
            actual.extend(message["id"] for message in page["messages"])
            cursor = page.get("nextCursor") or ""
            if not cursor: break
        require(actual == fixture["expectedIds"], "stress retained IDs differ from independent newest/deletion oracle")
        for number, (path, digest) in fixture["originalBodies"].items():
            if identifier(number) not in fixture["expectedIds"]:
                require(not path.exists(), "stress evicted/deleted body orphan remains")
            else:
                require(path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == digest, "stress rewrote retained full body")
                message = client.request("mail.read", messageId=identifier(number), cacheOnly=True)
                require(message["id"] == identifier(number) and f"body {number:04}" in message["bodyText"], "stress retained body identity invalid")
        state = json.loads(fixture["index"].read_text())
        referenced = {}
        for entry in state["entries"]:
            if entry.get("bytes", 0):
                name = "mail-" + hashlib.sha256(entry["message"]["id"].encode()).hexdigest() + ".json"
                referenced[name] = entry
        files = {path.name: path for path in fixture["accountDirectory"].glob("mail-*.json")}
        require(set(files) == set(referenced), "stress leaves orphan or missing referenced body files")
        for name, path in files.items():
            raw = path.read_bytes()
            record = json.loads(raw)
            entry = referenced[name]
            require(len(raw) == entry["bytes"] and hashlib.sha256(raw).hexdigest() == entry["bodyHash"], "stress body bytes/hash reference mismatch")
            require(record["account"] == ACCOUNTS[0] and record["message"]["id"] == entry["message"]["id"], "stress body/account identity mismatch")
        final = metric(client)
        status = (Path("/proc") / str(client.process.pid) / "status").read_text()
        os_peak = next(int(line.split()[1]) for line in status.splitlines() if line.startswith("VmHWM:"))
    require(client.process.returncode == 0 and not client.stderr, "stress child exit/stderr cleanup failed")
    return {"passed": True, "preseedMetadata": COUNT, "newMessages": NEW, "deletedMessages": len(DELETED), "tailEvictedMessages": 90,
            "retainedNewestCount": len(actual), "bodyReferencesValidated": len(files), "retainedBodyDigestsPreserved": True,
            "metadataAverageBytes": fixture["metadataAverageBytes"], "initialIndexBytes": fixture["initialIndexBytes"],
            "providerFixtureBytes": fixture["providerFixtureBytes"], "providerFixtureLimitBytes": FIXTURE_LIMIT,
            "refreshSeconds": elapsed, "allocatorPeakBytes": final["allocatorPeakBytes"], "terminalHeapLimitBytes": HEAP_LIMIT,
            "rejectedAllocations": final["rejectedAllocations"], "fixedBackendReservationBytes": final["fixedBackendReservationBytes"],
            "diskBytes": final["diskBytes"], "diskLimitBytes": DISK_LIMIT, "osPeakRssKiB": os_peak,
            "wholeProcessRssIsSeparateFromHeap": True, "absoluteRssLimit": None, "childrenReaped": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--build-mode", type=build_mode, default="debug")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()
    require(not args.output.exists(), "refusing to overwrite stress evidence")
    report = {**read_build_info(binary, args.build_mode), "binarySha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "case": "max-cache", "syntheticOnly": True, "liveWrites": False, "desktopUsed": False}
    try:
        with tempfile.TemporaryDirectory(prefix="omagma-max-cache-") as temporary:
            report.update(run(binary, Path(temporary)))
    except Exception as error:
        report.update(passed=False, error=f"{type(error).__name__}: {error}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
