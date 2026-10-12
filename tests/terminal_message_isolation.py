#!/usr/bin/env python3
"""Fictional good/unusual/good refresh, read, thread and restart acceptance.

Run with the cooperative host lease. All provider data and account caches are
temporary; this suite never opens a graphical window or a real mailbox.
"""
from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path
import tempfile

from terminal_integration import ACCOUNTS, FIXTURES, Client, require


def message(identifier, order, unusual=False, calendar=False, unsupported=False):
    body = f"Visible body of {identifier}.\n".encode()
    content_type = "text/calendar" if calendar else "text/plain; charset=Shift_JIS" if unsupported else "text/plain; charset=utf-8"
    raw = (f"From: One <one@example.test>\r\nReply-To: Actual reply <reply@example.test>\r\n"
           f"To: {ACCOUNTS[0]}\r\nSubject: Synthetic message {identifier}\r\n"
           f"Message-ID: <{identifier}@example.test>\r\nContent-Type: {content_type}\r\n\r\n").encode() + body
    return {
        "id": identifier, "threadId": "isolation-thread",
        "internalDate": str(1791651960000 + order * 1000),
        "labelIds": ["INBOX", "UNREAD"], "snippet": f"Visible snippet of {identifier}",
        "raw": base64.urlsafe_b64encode(raw).decode().rstrip("="),
        "payload": {
            "mimeType": "text/calendar" if calendar else "text/plain",
            "filename": "invite.ics" if calendar else "",
            "headers": [
                {"name": "From", "value": "One <one@example.test>, Two <two@example.test>" if unusual else "One <one@example.test>"},
                {"name": "Sender", "value": "agent@example.test"},
                {"name": "Reply-To", "value": "Actual reply <reply@example.test>"},
                {"name": "To", "value": ACCOUNTS[0]},
                {"name": "Subject", "value": f"Synthetic message {identifier}"},
                {"name": "Message-ID", "value": f"<{identifier}@example.test>"},
                {"name": "Content-Type", "value": content_type},
            ],
            "body": {"size": 128 * 1024 + 1 if calendar else len(body),
                     "data": "" if calendar else base64.urlsafe_b64encode(body).decode().rstrip("=")},
        },
    }


def by_id(result):
    values = result["messages"]
    result = {row["id"]: row for row in values}
    require(len(result) == len(values), "duplicate message identity")
    return result


def exercise(binary, directory):
    root = directory / "provider"
    (root / "accounts").mkdir(parents=True)
    source = json.loads((FIXTURES / "accounts/personal.json").read_text())
    source["messages"] = [message("good1", 3), message("unusual", 2, unusual=True), message("good2", 1)]
    source["generation"] = 100
    source["sync"] = {"historyId": "100", "history": []}
    path = root / "accounts/personal.json"

    def save():
        path.write_text(json.dumps(source, ensure_ascii=False) + "\n")

    save()
    with Client(binary, directory / "client", extra=("--fixture-root", str(root))) as client:
        baseline = by_id(client.request("mail.refresh", label="INBOX", limit=10, prefetchLimit=10))
        require(set(baseline) == {"good1", "unusual", "good2"}, "bootstrap lost a neighbor")
        unusual = client.request("mail.read", messageId="unusual")
        require(unusual["decodeWarning"] == "AmbiguousSender" and unusual["metadataPartial"], "unusual envelope lacks visible status")
        require(unusual["bodyText"] == "Visible body of unusual.\n", "legal unusual envelope concealed the body")
        require(not unusual["from"]["address"] and not any(unusual[key] for key in ("to", "cc", "replyTo")), "display fallback invented reply recipients")
        require(client.request("mail.reply", messageId="unusual", ok=False)["code"] == "UnsafeReplyMetadata", "unsafe envelope reached reply preparation")
        require(set(by_id(client.request("mail.thread", threadId="isolation-thread"))) == set(baseline), "thread dropped unusual envelope or neighbor")

        source["messages"] += [message("calendar", 5, calendar=True), message("charset", 6, unsupported=True), message("good3", 4)]
        source["generation"] = 101
        source["sync"] = {"historyId": "101", "history": [{
            "id": "101", "messagesAdded": [{"message": {"id": "calendar"}}, {"message": {"id": "charset"}}, {"message": {"id": "good3"}}],
        }]}
        save()
        delta = by_id(client.request("mail.refresh", label="INBOX", limit=10, prefetchLimit=10))
        require(set(delta) == {"good1", "unusual", "good2", "calendar", "charset", "good3"}, "history merge lost a message")
        require(delta["calendar"]["bodyCacheError"] == "CalendarTooLarge", "calendar bound omitted final refusal")
        require(delta["charset"]["bodyCacheError"] == "UnsupportedCharset", "charset bound omitted final refusal")
        stats = client.request("cache.stats", cacheOnly=True)
        require(stats["historyId"] == "101", "message-local refusal pinned account history")
        before = stats["syncBodyGets"]
        drafts = client.request("draft.list")
        for identifier in ("calendar", "charset"):
            for command, options in (
                ("mail.reply", {}), ("mail.reply", {"all": True}),
                ("mail.reply", {"preserveFormatting": True, "bodyFormat": "markdown"}),
                ("mail.forward", {}), ("mail.forward", {"omitAttachments": True}),
                ("mail.forward", {"preserveFormatting": True, "bodyFormat": "markdown"}),
            ):
                failure = client.request(command, messageId=identifier, ok=False, **options)
                require(failure["code"] == "MessageBodyUnavailable", "refused body entered reply/forward construction")
                require(client.request("draft.list") == drafts, "refused body created an orphan draft")
            original = client.request("mail.forward", messageId=identifier, original=True)
            require(len(original["attachments"]) == 1 and original["attachments"][0]["filename"] == "original.eml",
                    "raw forward was unavailable for an undecodable body")
            expected = next(row["raw"] for row in source["messages"] if row["id"] == identifier)
            require(base64.urlsafe_b64decode(original["attachments"][0]["data"] + "===") ==
                    base64.urlsafe_b64decode(expected + "==="), "raw forward changed opaque original bytes")
            client.request("draft.discard", draftId=original["id"])
            require(client.request("draft.list") == drafts, "raw-forward cleanup changed other drafts")
        require(client.request("cache.stats", cacheOnly=True)["fixtureSends"] == 0, "refused-body actions dispatched mail")
        for cached in (False, True):
            calendar = client.request("mail.read", messageId="calendar", cacheOnly=cached)
            require(calendar["bodyCacheError"] == "CalendarTooLarge" and not calendar["bodyText"], "reader omitted bounded placeholder")
            thread = by_id(client.request("mail.thread", threadId="isolation-thread", cacheOnly=cached))
            require(set(thread) == set(delta), "refused body removed thread neighbors")
        client.request("mail.refresh", label="INBOX", limit=10, prefetchLimit=10)
        require(client.request("cache.stats", cacheOnly=True)["syncBodyGets"] == before, "same revision retried immutable refusal")
        client.restart()
        client.request("mail.refresh", label="INBOX", limit=10, prefetchLimit=10)
        after = client.request("cache.stats", cacheOnly=True)
        require(after["syncBodyGets"] == before and after["historyId"] == "101", "restart forgot final refusal/checkpoint")
        require(set(by_id(client.request("mail.list", label="INBOX", cacheOnly=True))) == set(delta), "restart removed placeholder")
    require(client.process.returncode == 0 and not client.stderr, "synthetic CLI cleanup failed")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="omagma-message-isolation-") as temporary:
        exercise(args.binary.resolve(), Path(temporary))
    print("PASS message isolation: neighbors, readable unusual envelopes, bounded placeholders, history checkpoint and restart")


if __name__ == "__main__":
    main()
