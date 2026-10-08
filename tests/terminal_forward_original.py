#!/usr/bin/env python3
"""Synthetic original-email forwarding, CLI parity, persistence and refusals.

Use an isolated development binary under the cooperative host reservation.
Actual outgoing MIME byte fidelity is independently checked by the injected
Gmail transport unit test; this suite verifies the persisted CLI contract.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import tempfile

from build_info import read_build_info
from terminal_cli_parity import one_shot
from terminal_integration import ACCOUNTS, Client, FIXTURES, require
from terminal_invitations import finished


ORIGINAL = (
    b"From: Fictional Publisher <publisher@example.test>\r\n"
    b"To: personal@example.com\r\n"
    b"Date: Thu, 08 Oct 2026 12:00:00 +0000\r\n"
    b"Subject: Original HTML and embedded image\r\n"
    b"Message-ID: <original-source@example.test>\r\n"
    b"MIME-Version: 1.0\r\n"
    b'Content-Type: multipart/mixed; boundary="omagma-v1-part"\r\n\r\n'
    b"--omagma-v1-part\r\n"
    b'Content-Type: multipart/related; boundary="source-related"\r\n\r\n'
    b"--source-related\r\n"
    b"Content-Type: text/html; charset=UTF-8\r\n"
    b"Content-Transfer-Encoding: quoted-printable\r\n\r\n"
    b'<html><body style="background:#123456"><table><tr><td>Original styled =\r\n'
    b'mail</td></tr></table><img src="cid:original-image@example.test"></body></html>\r\n'
    b"--source-related\r\n"
    b"Content-Type: image/png\r\n"
    b"Content-Disposition: inline\r\n"
    b"Content-ID: <original-image@example.test>\r\n"
    b"Content-Transfer-Encoding: base64\r\n\r\n"
    b"AP+A\r\n"
    b"--source-related--\r\n"
    b"--omagma-v1-part\r\n"
    b"Content-Type: application/octet-stream\r\n"
    b'Content-Disposition: attachment; filename="original.bin"\r\n'
    b"Content-Transfer-Encoding: base64\r\n\r\n"
    b"AAH/gA0K\r\n"
    b"--omagma-v1-part--\r\n\r\n"
)


def encoded(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


class RawFixture:
    """Copied fictional account data with immutable exact original sources."""

    def __init__(self, directory: Path):
        self.root = directory / "original-fixtures"
        (self.root / "accounts").mkdir(parents=True)
        for account in ACCOUNTS:
            name = account.split("@")[0]
            source = json.loads((FIXTURES / "accounts" / f"{name}.json").read_text())
            if account == ACCOUNTS[0]:
                cases = {
                    "raw-original": ORIGINAL,
                    "raw-utf8": ORIGINAL.replace(b"Subject: Original HTML and embedded image", "Subject: UTF-8 original 🌋".encode()),
                    "raw-binary": ORIGINAL + b"\x00\xff",
                    "raw-oversize": b"Subject: Too large\r\n\r\n" + b"x" * (2 * 1024**2),
                    "raw-invalid-headers": b"No header boundary here",
                }
                for message_id, raw in cases.items():
                    message = dict(source["messages"][0])
                    message.update(id=message_id, threadId="source-thread", raw=encoded(raw))
                    # Forwarding an original must not need the semantic MIME
                    # reader to accept FULL. Raw source remains valid/exact.
                    message["payload"] = {"body": {"size": 1, "data": "eA"}}
                    source["messages"].append(message)
                bad = dict(source["messages"][-1])
                bad.update(id="raw-invalid-base64", raw="%%%%")
                source["messages"].append(bad)
                missing = dict(source["messages"][-1])
                missing.update(id="raw-missing")
                missing.pop("raw")
                source["messages"].append(missing)
            (self.root / "accounts" / f"{name}.json").write_text(json.dumps(source))

    def options(self):
        return ("--fixture-root", str(self.root))


def exact_attachment(draft, original=ORIGINAL):
    require(len(draft["attachments"]) == 1, "original forwarding duplicated contained files")
    attachment = draft["attachments"][0]
    require(attachment["filename"].endswith(".eml"), "original forwarding omitted .eml filename")
    require(attachment["size"] == len(original), "original source size changed")
    actual = base64.urlsafe_b64decode(attachment["data"] + "===")
    require(actual == original, "original MIME/HTML/CID/binary bytes changed")
    return attachment


def exercise(binary: Path, directory: Path):
    fixture = RawFixture(directory)
    with Client(binary, directory / "client", extra=fixture.options()) as client:
        # Invalid FULL parsing confirms the original path reads RAW directly.
        client.request("mail.forward", messageId="raw-original", ok=False)
        original = client.request("mail.forward", messageId="raw-original", original=True, bodyFormat="markdown")
        require(original["subject"] == "Fwd: Original HTML and embedded image", "original subject was not derived safely")
        require(original["bodyText"] == "" and original["bodyFormat"] == "markdown", "original forwarding did not leave a separate editable note")
        require(not original["threadId"] and not original["inReplyTo"] and not original["references"], "original forwarding retained old threading")
        require(exact_attachment(original)["mimeType"] == "message/rfc822", "ordinary original was not encapsulated as a message")
        command = one_shot(client, "mail", "forward", ["--message-id", "raw-original", "--original", "--format", "markdown"])
        require({k: v for k, v in command.items() if k != "id"} == {k: v for k, v in original.items() if k != "id"}, "one-shot and JSONL original forwards differ")
        note = "**My personal note**, above the original."
        original.update(to=[{"address": "recipient@example.test"}], bodyText=note)
        client.request("draft.update", draftId=original["id"], draft=original)
        client.restart()
        reopened = client.request("draft.read", draftId=original["id"])
        require(reopened["bodyText"] == note, "reopened draft lost editable note")
        exact_attachment(reopened)
        preview = client.request("draft.preview", draftId=original["id"])
        require("<strong>My personal note</strong>" in preview["bodyHtml"], "note lost normal Omagma Markdown design")
        receipt = client.request("draft.send", draftId=original["id"], operationId="raw-original-send")
        require(receipt["outcome"] == "applied", "synthetic original forwarding did not submit")
        exact_attachment(client.request("mail.read", messageId=receipt["messageId"]))
        before = client.request("cache.stats")["fixtureSends"]
        require(client.request("draft.send", draftId=original["id"], operationId="raw-original-send") == receipt, "original send replay changed receipt")
        require(client.request("cache.stats")["fixtureSends"] == before, "original send replay resubmitted mail")
        utf8_bytes = ORIGINAL.replace(b"Subject: Original HTML and embedded image", "Subject: UTF-8 original 🌋".encode())
        utf8 = client.request("mail.forward", messageId="raw-utf8", original=True)
        require(exact_attachment(utf8, utf8_bytes)["mimeType"] == "message/global", "UTF-8 headers lost message/global classification")
        binary_draft = client.request("mail.forward", messageId="raw-binary", original=True)
        require(exact_attachment(binary_draft, ORIGINAL + b"\x00\xff")["mimeType"] == "application/octet-stream", "binary original was not preserved through safe transport")
        prior_drafts = client.request("draft.list")["drafts"]
        for message_id, expected in (("raw-oversize", "BodyTooLarge"), ("raw-invalid-base64", "InvalidBase64"), ("raw-missing", "MissingField"), ("raw-invalid-headers", "MissingHeaderBoundary")):
            require(client.request("mail.forward", messageId=message_id, original=True, ok=False)["code"] == expected, f"incorrect refusal for {message_id}")
            require(client.request("draft.list")["drafts"] == prior_drafts, "failed original forward created partial draft")
        require(client.request("mail.forward", messageId="raw-original", original="true", ok=False)["code"] == "InvalidRequest", "wrong original field type was accepted")
        client.request("mail.forward", account=ACCOUNTS[1], messageId="raw-original", original=True, ok=False)
        client.request("mail.forward", account="unknown@example.test", messageId="raw-original", original=True, ok=False)
        one_shot(client, "mail", "reply", ["--message-id", "raw-original", "--original"], error="OriginalRequiresForward")
        one_shot(client, "draft", "create", ["--original"], error="OriginalRequiresForward")
    finished(client)
    with Client(binary, directory / "unknown", scenario="unknown-send", extra=fixture.options()) as client:
        draft = client.request("mail.forward", messageId="raw-original", original=True)
        draft.update(to="recipient@example.test", bodyText="Unknown note")
        client.request("draft.update", draftId=draft["id"], draft=draft)
        receipt = client.request("draft.send", draftId=draft["id"], operationId="raw-unknown")
        require(receipt["outcome"] == "unknown", "unknown original send became definite")
        client.restart()
        retained = client.request("draft.read", draftId=draft["id"])
        exact_attachment(retained)
        retained["bodyText"] = "Changed note"
        require(client.request("draft.update", draftId=draft["id"], draft=retained, ok=False)["code"] == "UnknownOutcome", "protected original source was edited")
        replay = client.request("draft.send", draftId=draft["id"], operationId="raw-another")
        require(replay == receipt, "new identity bypassed protected original-send receipt")
    finished(client)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory(prefix="omagma-original-fixtures-") as temporary:
        exercise(binary, Path(temporary))
    require(hashlib.sha256(binary.read_bytes()).hexdigest() == digest, "tested binary changed")
    receipt = {"schemaVersion": 1, "suite": "terminal-forward-original", "status": "passed", "synthetic": True, "liveProviderWrites": 0, "binarySha256": digest, **read_build_info(binary, None)}
    if args.receipt:
        args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    print("PASS original forwarding: exact MIME source, note, CLI parity, persistence, limits and protected recovery")


if __name__ == "__main__":
    main()
