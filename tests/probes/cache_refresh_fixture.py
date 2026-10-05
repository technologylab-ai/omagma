"""Independent fictional Gmail history/snapshot oracles for cache refresh tests.

This development helper never uses credentials or accesses a mailbox.  It builds
temporary copies of the released 96-message corpus, leaving that corpus intact.
"""
from __future__ import annotations

import base64
import copy
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests/fixtures/terminal"
ACCOUNTS = ("personal@example.com", "work@example.com", "optional@example.com")
RETAINED_COUNT = 40


def newest_ids(messages, limit=RETAINED_COUNT, label=None):
    """Compute expectations from literal timestamps, independently of the core."""
    selected = [m for m in messages if label is None or label in m["labelIds"]]
    selected.sort(key=lambda m: (-int(m["internalDate"]), m["id"]))
    return [m["id"] for m in selected[:limit]]


def new_message(source, account, number):
    message = copy.deepcopy(source["messages"][-1])
    message.update(id=f"shared-msg-{number:03}", threadId=f"shared-thread-new-{number:03}",
                   labelIds=["INBOX", "UNREAD"], historyId="1001",
                   internalDate=str(1794042000000 + number * 60000),
                   snippet=f"Synthetic {account.split('@')[0]} delta {number:03}")
    body = f"Synthetic {account} newly delivered message {number:03}.\nCafé 👋.\n".encode()
    message["payload"] = {
        "partId": "", "mimeType": "text/plain", "filename": "",
        "headers": [
            {"name": "From", "value": "Delta Fixture <delta@example.org>"},
            {"name": "To", "value": account},
            {"name": "Subject", "value": f"Synthetic {account.split('@')[0]} delta {number:03}"},
            {"name": "Message-ID", "value": f"<delta-{number:03}-{account.split('@')[0]}@example.org>"},
            {"name": "Content-Type", "value": "text/plain; charset=utf-8"},
        ],
        "body": {"size": len(body), "data": base64.urlsafe_b64encode(body).decode().rstrip("=")},
    }
    message["sizeEstimate"] = len(body)
    return message


def repage(source):
    account_key = source["account"].split("@")[0]
    generation = source["generation"]
    messages = source["messages"]
    source["pages"] = []
    for offset in range(0, len(messages), 12):
        token = f"synthetic-{account_key}-{generation}-offset-{offset}"
        response = {"messages": [{"id": m["id"], "threadId": m["threadId"]} for m in messages[offset:offset + 12]],
                    "resultSizeEstimate": len(messages)}
        if offset + 12 < len(messages):
            response["nextPageToken"] = f"synthetic-{account_key}-{generation}-offset-{offset + 12}"
        source["pages"].append({"pageToken": "" if offset == 0 else token, "response": response})


def corpus(account):
    source = json.loads((FIXTURES / "accounts" / f"{account.split('@')[0]}.json").read_text())
    baseline = copy.deepcopy(source)
    delta = copy.deepcopy(source)
    delta["generation"] = 1001
    delta["messages"] = [m for m in delta["messages"] if m["id"] != "shared-msg-095"]
    for message in delta["messages"]:
        if message["id"] == "shared-msg-093":
            message["labelIds"] = ["INBOX", "STARRED"]
            message["historyId"] = "1001"
        if message["id"] == "shared-msg-094":
            message["labelIds"] = [label for label in message["labelIds"] if label != "INBOX"]
            message["historyId"] = "1001"
    delta["messages"] += [new_message(source, account, number) for number in (97, 98)]
    delta["messages"].sort(key=lambda m: -int(m["internalDate"]))
    expired = copy.deepcopy(delta)
    expired["generation"] = 1100
    expired["messages"] += [new_message(source, account, number) for number in range(99, 107)]
    for message in expired["messages"]:
        message["historyId"] = "1100"
    expired["messages"].sort(key=lambda m: -int(m["internalDate"]))

    def ref(number):
        return {"id": f"shared-msg-{number:03}"}

    # Two real Gmail-shaped pages, including duplicate references.  Tests count
    # unique IDs, not every history entry or Gmail resultSizeEstimate.
    history = [
        {"historyId": "1001", "nextPageToken": "synthetic-history-page-2", "history": [
            {"id": "1001", "messages": [ref(98), ref(97), ref(95)],
             "messagesAdded": [{"message": ref(98)}, {"message": ref(97)}],
             "messagesDeleted": [{"message": ref(95)}]},
        ]},
        {"historyId": "1001", "history": [
            {"id": "1001", "messages": [ref(98), ref(93), ref(94)],
             "messagesAdded": [{"message": ref(98)}],
             "labelsAdded": [{"message": ref(93), "labelIds": ["STARRED"]}],
             "labelsRemoved": [{"message": ref(93), "labelIds": ["UNREAD"]},
                               {"message": ref(94), "labelIds": ["INBOX"]}]},
        ]},
    ]
    old_ids = newest_ids(baseline["messages"])
    new_ids = newest_ids(delta["messages"])
    for snapshot in (baseline, delta, expired):
        repage(snapshot)
    return {
        "account": account, "baseline": baseline, "delta": delta, "expired": expired,
        "noChangeHistory": {"historyId": "1000", "history": []}, "historyPages": history,
        "expected": {
            "retainedCount": RETAINED_COUNT, "baselineIds": old_ids, "deltaIds": new_ids,
            "resyncIds": newest_ids(expired["messages"]),
            "deletedIds": ["shared-msg-095"], "tailEvictedIds": [i for i in old_ids if i not in new_ids and i != "shared-msg-095"],
            "newIds": ["shared-msg-098", "shared-msg-097"],
            "labelChangedIds": ["shared-msg-093", "shared-msg-094"],
            "selectedMessageId": "shared-msg-096", "cachedBodyMessageId": "shared-msg-092",
            "unchangedFullBodyShaMustMatch": True,
        },
    }


def write_corpus(destination):
    destination = Path(destination)
    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
    for account in ACCOUNTS:
        value = corpus(account)
        (destination / f"{account.split('@')[0]}.json").write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    return destination
