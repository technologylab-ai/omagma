#!/usr/bin/env python3
"""Synthetic JSONL/one-shot Send now preserves the reviewed durable queue.

Run under the coordinator's cooperative host reservation. Every submission is
to an isolated fixture; no credentials, desktop or real mailbox is used.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import tempfile
import time

from build_info import build_mode, read_build_info
from terminal_cli_parity import one_shot
from terminal_integration import Client, read_saved_draft, require


def draft(client, subject):
    saved = client.request("draft.create", draft={"to": ["recipient@example.test"],
                           "subject": subject, "bodyText": "Only this reviewed fixture note is sent."})
    return read_saved_draft(client, saved)


def stage(client, source, operation):
    queued = client.request("draft.queue", draftId=source["id"], operationId=operation)
    require(queued["state"] == "queued" and queued.get("operation") is None
            and queued["dueAtMs"] - queued["createdAtMs"] == 10000,
            "default queue did not retain its original ten-second reviewed intent")
    return queued


def identity(before, after):
    require(all(before[key] == after[key] for key in
                ("queueId", "draftId", "operationId", "createdAtMs", "dueAtMs")),
            "Send now created a new queue/operation or rescheduled the original deadline")


def counters(client):
    value = client.request("cache.stats")
    return value["fixtureCalls"], value["fixtureSends"]


def applied(binary, directory):
    with Client(binary, directory) as client:
        source = draft(client, "Immediate fixture submission")
        queued = stage(client, source, "send-now-applied")
        require(client.request("queue.process", queueId=queued["queueId"], ok=False)["code"] == "QueueNotDue",
                "ordinary processing bypassed the queued deadline")
        require(time.time_ns() // 1000000 < queued["dueAtMs"], "CLI Send now case reached its original deadline")
        receipt = one_shot(client, "queue", "send-now", ["--queue-id", queued["queueId"]])
        identity(queued, receipt)
        require(receipt["state"] == "applied" and receipt["operation"]["id"] == queued["operationId"]
                and receipt["operation"]["outcome"] == "applied", "Send now did not apply its original reviewed operation")
        retained_queues = client.request("history.queues")
        retained_operations = client.request("history.operations")
        expected_queue_record = {key: value for key, value in receipt.items() if key != "operation"}
        expected_queue_record["hash"] = receipt["operation"]["hash"]
        require(client.request("queue.list")["queue"] == []
                and client.request("operation.list")["operations"] == []
                and retained_queues["items"] == [expected_queue_record] and not retained_queues["nextCursor"]
                and retained_operations["items"] == [receipt["operation"]] and not retained_operations["nextCursor"]
                and client.request("queue.read", queueId=queued["queueId"]) == receipt
                and client.request("operation.read", operationId=queued["operationId"]) == receipt["operation"],
                "Send now lost, changed, or duplicated its retained queue/operation receipts")
        sent = client.request("mail.read", messageId=receipt["operation"]["messageId"], cacheOnly=True)
        require(sent["subject"] == source["subject"] and sent["bodyText"] == source["bodyText"],
                "Send now changed the reviewed draft")
        before = counters(client)
        require(before[1] == 1, "Send now did not submit exactly one fixture message")
        for command in ("queue.send-now", "queue.process"):
            require(client.request(command, queueId=queued["queueId"]) == receipt,
                    "JSONL replay changed the completed queue receipt")
        require(one_shot(client, "queue", "send-now", ["--queue-id", queued["queueId"]]) == receipt,
                "separate one-shot replay changed the completed queue receipt")
        client.restart()
        require(client.request("queue.send-now", queueId=queued["queueId"]) == receipt
                and counters(client) == before, "restart or mixed-interface replay redispatched a completed Send now")
        require(client.request("draft.list")["drafts"] == []
                and client.request("draft.read", draftId=source["id"]) == source,
                "Send now cloned or changed the exact retained reviewed draft")
        next_source = draft(client, "Next message still waits")
        next_queue = stage(client, next_source, "send-now-next-default")
        client.request("queue.cancel", queueId=next_queue["queueId"])
        require(counters(client) == before, "per-message Send now changed or submitted the next default countdown")
    require(client.process.returncode == 0 and not client.stderr, "Send now applied client did not exit cleanly")


def canceled(binary, directory):
    with Client(binary, directory) as client:
        source = draft(client, "Canceled queue stays local")
        queued = stage(client, source, "send-now-canceled")
        receipt = client.request("queue.cancel", queueId=queued["queueId"])
        identity(queued, receipt)
        require(receipt["state"] == "canceled" and receipt.get("operation") is None, "cancel created a submission receipt")
        before = counters(client)
        for command in ("queue.send-now", "queue.process"):
            require(client.request(command, queueId=queued["queueId"]) == receipt, "canceled queue became sendable")
        require(one_shot(client, "queue", "send-now", ["--queue-id", queued["queueId"]]) == receipt,
                "one-shot Send now revived a canceled queue")
        require(counters(client) == before and before[1] == 0
                and not client.request("operation.list")["operations"], "canceled Send now submitted or journaled mail")
        require(client.request("draft.read", draftId=source["id"]) == source, "canceled Send now changed the retained draft")
    require(client.process.returncode == 0 and not client.stderr, "Send now canceled client did not exit cleanly")


def unknown(binary, directory):
    for scenario, sends in (("unknown-send", 0), ("applied-lost", 1)):
        with Client(binary, directory / scenario, scenario=scenario) as client:
            source = draft(client, "Uncertain queue cannot send again")
            queued = stage(client, source, "send-now-unknown")
            receipt = one_shot(client, "queue", "send-now", ["--queue-id", queued["queueId"]])
            identity(queued, receipt)
            require(receipt["state"] == "unknown" and receipt["operation"]["outcome"] == "unknown",
                    "uncertain Send now claimed a known outcome")
            before = counters(client)
            require(before[1] == sends, "uncertain fixture has an unexpected actual submission count")
            for command in ("queue.send-now", "queue.process"):
                require(client.request(command, queueId=queued["queueId"]) == receipt,
                        "unknown queue was redispatched by JSONL")
            require(one_shot(client, "queue", "send-now", ["--queue-id", queued["queueId"]]) == receipt,
                    "unknown queue was redispatched by one-shot Send now")
            client.restart()
            require(client.request("queue.send-now", queueId=queued["queueId"]) == receipt
                    and counters(client) == before, "unknown queue was redispatched after restart")
            require(client.request("queue.list")["queue"] == [receipt]
                    and client.request("operation.list")["operations"] == [receipt["operation"]],
                    "unknown queue duplicated its durable intent or journal")
            require(client.request("draft.read", draftId=source["id"]) == source,
                    "unknown Send now discarded or changed the protected draft")
        require(client.process.returncode == 0 and not client.stderr, "Send now unknown client did not exit cleanly")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--build-mode", type=build_mode)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    require(args.receipt is None or not args.receipt.exists(), "refusing to overwrite Send now evidence")
    binary = args.binary.resolve()
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    receipt = {"schemaVersion": 1, "suite": "terminal-queue-send-now", "passed": False,
               "syntheticOnly": True, "liveProviderWrites": 0, "binarySha256": digest,
               **read_build_info(binary, args.build_mode), "cases": []}
    try:
        with tempfile.TemporaryDirectory(prefix="omagma-send-now-cli-") as temporary:
            root = Path(temporary).resolve()
            for name, case in (("applied", applied), ("canceled", canceled), ("unknown", unknown)):
                case(binary, root / name)
                receipt["cases"].append({"name": name, "passed": True})
        require(hashlib.sha256(binary.read_bytes()).hexdigest() == digest, "tested Send now binary changed")
        receipt["passed"] = True
    except Exception as failure:
        receipt["error"] = f"{type(failure).__name__}: {failure}"
    if args.receipt:
        args.receipt.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
        args.receipt.chmod(0o600)
    print(json.dumps(receipt))
    return 0 if receipt["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
