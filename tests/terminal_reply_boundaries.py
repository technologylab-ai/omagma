#!/usr/bin/env python3
"""Narrow synthetic reply regressions; run under the cooperative host lock."""
from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path
import tempfile

from terminal_integration import ACCOUNTS, Client, FIXTURES, addresses, require


PARENT = "<parent@example.test>"
LARGE_BODY = "Complete source " + "x" * (2 * 1024**2) + " complete tail"
COUNT_REFS = [f"<m{index}@example.test>" for index in range(256)]
BYTE_REFS = [f"<r{index:03d}" + "a" * (length - 8) + "@b>"
             for index, length in enumerate([512] + [511] * 127)]


def fixture(root: Path):
    (root / "accounts").mkdir(parents=True)
    for account in ACCOUNTS:
        name = account.split("@")[0]
        source = json.loads((FIXTURES / "accounts" / f"{name}.json").read_text())
        if account == ACCOUNTS[0]:
            source["messages"] = []
            for identifier, body, references in [
                ("count-boundary", "Tiny complete body", COUNT_REFS),
                ("byte-boundary", "Tiny complete body", BYTE_REFS),
                ("large-refusal", LARGE_BODY, ["<root@example.test>"]),
            ]:
                headers = {
                    "From": "Source Sender <sender@example.test>",
                    "Reply-To": "Reply Target <reply@example.test>",
                    "To": f"{account}, peer@example.test",
                    "Cc": f"other@example.test, {account}",
                    "Subject": "Complete reply boundary",
                    "Message-ID": PARENT,
                    "References": " ".join(references),
                    "Content-Type": "text/plain; charset=utf-8",
                }
                source["messages"].append({
                    "id": identifier, "threadId": f"thread-{identifier}",
                    "labelIds": ["INBOX"], "internalDate": "1794047760000",
                    "payload": {"mimeType": "text/plain", "headers": [
                        {"name": key, "value": value} for key, value in headers.items()
                    ], "body": {"size": len(body.encode()), "data":
                        base64.urlsafe_b64encode(body.encode()).rstrip(b"=").decode()}},
                })
        (root / "accounts" / f"{name}.json").write_text(json.dumps(source))


def reply_invariants(draft, identifier, body, all_recipients):
    require(addresses(draft["to"]) == ["reply@example.test"], "Reply-To changed")
    require(addresses(draft["cc"]) == (["peer@example.test", "other@example.test"]
            if all_recipients else []), "reply-all destinations changed")
    require(not draft["bcc"], "reply acquired a Bcc destination")
    require(draft["subject"] == "Re: Complete reply boundary", "reply subject changed")
    require(draft["threadId"] == f"thread-{identifier}", "provider thread changed")
    require(draft["inReplyTo"] == PARENT, "direct parent changed")
    require(draft["bodyText"] == "\n\n> " + body + "\n", "source body was shortened")


def exercise(binary: Path, directory: Path, expect_old_failure: bool):
    root = directory / "fixtures"
    fixture(root)
    observations = []
    with Client(binary, directory / "client", extra=("--fixture-root", str(root))) as client:
        for identifier, references, error in [
            ("count-boundary", COUNT_REFS, "TooManyReferences"),
            ("byte-boundary", BYTE_REFS, "ReferencesTooLarge"),
        ]:
            for all_recipients in [False, True]:
                draft = client.request("mail.reply", messageId=identifier, all=all_recipients,
                                       ok=not expect_old_failure)
                if expect_old_failure:
                    require(draft["code"] == error, f"unexpected old reference refusal: {draft}")
                else:
                    reply_invariants(draft, identifier, "Tiny complete body", all_recipients)
                    result = draft["references"].split()
                    require(len(result) <= 256 and len(draft["references"].encode()) <= 65536,
                            "reply expanded the reference policy")
                    require(result[0] == references[0] and result[-1] == PARENT,
                            "bounded chain lost root or direct parent")
                    require(result[1:-1] == references[-(len(result) - 2):],
                            "bounded chain did not retain its recent suffix")
                observations.append({"case": identifier, "replyAll": all_recipients,
                                     "outcome": draft.get("code", "created")})

        for all_recipients in [False, True]:
            client.request("cache.clear")
            refused = client.request("mail.read", messageId="large-refusal")
            require(refused.get("bodyCacheError") == "BodyTooLarge",
                    "ordinary reader did not establish the expected size refusal")
            draft = client.request("mail.reply", messageId="large-refusal", all=all_recipients,
                                   ok=not expect_old_failure)
            if expect_old_failure:
                require(draft["code"] == "MessageBodyUnavailable", "unexpected old cached refusal")
            else:
                reply_invariants(draft, "large-refusal", LARGE_BODY, all_recipients)
                client.restart()
                saved = client.request("draft.read", draftId=draft["id"])
                reply_invariants(saved, "large-refusal", LARGE_BODY, all_recipients)
                bounded = client.request("mail.read", messageId="large-refusal", cacheOnly=True)
                require(bounded.get("bodyCacheError") == "ComposeSourceRequired"
                        and not bounded.get("bodyText"), "ordinary reader limits were weakened")
            observations.append({"case": "large-refusal", "replyAll": all_recipients,
                                 "outcome": draft.get("code", "created")})
    return observations


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--expect-old-failure", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="omagma-reply-boundaries-") as temporary:
        observations = exercise(args.binary.resolve(), Path(temporary).resolve(), args.expect_old_failure)
    print(json.dumps({"expectedOldFailures": args.expect_old_failure, "checks": observations}))


if __name__ == "__main__":
    main()
