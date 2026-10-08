#!/usr/bin/env python3
"""Focused fixture-only outgoing Markdown CLI/JSONL parity and recovery checks.

No live mailbox, credentials, desktop input or provider mutation is used.
Run under the cooperative host lease with an isolated development binary.
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
from terminal_integration import Client, require
from terminal_invitations import finished


def exercise(binary: Path, directory: Path):
    source = "# Fixture 🌋\n\n**Hello**, team.\n\n- one\n  - child\n- two\n\n| Key | Value |\n| :--- | ---: |\n| α | 42 |\n\n```zig\nconst count = 42; // <literal>\n```\n\n<script>literal</script>\n[unsafe](javascript:alert(1))\n![remote](https://example.test/pixel.png)"
    source_file = directory / "body.md"
    source_file.write_text(source)
    attachment = directory / "binary.bin"
    binary_data = b"\x00\xff\x80\r\n"
    attachment.write_bytes(binary_data)
    with Client(binary, directory / "client") as client:
        draft = one_shot(client, "mail", "compose", ["--format", "markdown", "--to", "peer@example.test", "--subject", "Synthetic Markdown", "--body-file", str(source_file), "--attach-file", str(attachment)])
        require(draft["bodyFormat"] == "markdown" and draft["bodyText"] == source, "one-shot compose changed Markdown source/format")
        preview = client.request("draft.preview", draftId=draft["id"])
        require(preview == one_shot(client, "draft", "preview", ["--draft-id", draft["id"]]), "JSONL/one-shot persisted previews differ")
        require(preview["bodyText"] == source and "<strong>Hello</strong>" in preview["bodyHtml"], "preview omitted exact source or semantic HTML")
        require("<script>" not in preview["bodyHtml"] and 'href="javascript:' not in preview["bodyHtml"] and 'src="https:' not in preview["bodyHtml"], "outgoing preview activated untrusted markup/resources")
        require('class="omagma-syntax-keyword"' in preview["bodyHtml"] and "cid:omagma-logo@omagma.invalid" in preview["bodyHtml"], "code highlighting or trusted branding missing")
        require('style="color:#b84a10;text-decoration:underline">omagma</a> 🌋' in preview["bodyHtml"], "footer omagma-only orange underlined link/trailing volcano missing")
        require(preview["plainText"].endswith("Sent with omagma — https://technologylab-ai.github.io/omagma/ 🌋"), "plain footer order changed")
        require("**Hello**" not in preview["plainText"] and "Hello, team." in preview["plainText"], "plain alternative still contains source emphasis")
        by_stdin = one_shot(client, "draft", "preview", ["--format", "markdown", "--body-stdin"], stdin=source.encode())
        require(by_stdin == preview, "stdin source preview diverged from saved/file-backed source")
        client.restart()
        reopened = client.request("draft.read", draftId=draft["id"])
        require(reopened["bodyFormat"] == "markdown" and reopened["bodyText"] == source, "restart lost source format")
        replacement = dict(reopened)
        replacement.pop("bodyFormat")
        require(client.request("draft.update", draftId=draft["id"], draft=replacement)["bodyFormat"] == "markdown", "ordinary update lost the existing Markdown format")
        receipt = one_shot(client, "draft", "send", ["--draft-id", draft["id"], "--operation-id", "markdown-compose-send"])
        require(receipt["outcome"] == "applied", "fixture compose send did not apply")
        sent = client.request("mail.read", messageId=receipt["messageId"])
        require(sent["bodyText"] == preview["plainText"] and sent["bodyHtml"] == preview["bodyHtml"], "review/send alternatives diverged")
        require(base64.urlsafe_b64decode(sent["attachments"][0]["data"] + "===") == binary_data, "mixed attachments changed bytes")
        reply = one_shot(client, "mail", "reply", ["--format", "markdown", "--message-id", receipt["messageId"]])
        require(reply["bodyFormat"] == "markdown" and reply["threadId"] == sent["threadId"], "reply lost source format/thread")
        require(one_shot(client, "draft", "send", ["--draft-id", reply["id"], "--operation-id", "markdown-reply-send"])["outcome"] == "applied", "fixture Markdown reply send failed")
        forward = one_shot(client, "mail", "forward", ["--format", "markdown", "--message-id", receipt["messageId"]])
        require(not forward["threadId"] and len(forward["attachments"]) == 1, "forward lost independent conversation/file attachment")
        forward["to"] = [{"address": "forward-peer@example.test"}]
        forward_file = directory / "forward.json"
        forward_file.write_text(json.dumps(forward))
        one_shot(client, "draft", "update", ["--draft-id", forward["id"], "--draft-file", str(forward_file), "--format", "markdown"])
        require(one_shot(client, "draft", "send", ["--draft-id", forward["id"], "--operation-id", "markdown-forward-send"])["outcome"] == "applied", "fixture Markdown forward send failed")
        recovery = client.request("draft.recovery-save", draft={"bodyFormat": "markdown", "recoveryFields": ["unfinished", "", "", "Recovery", "**Retained** source"]})
        client.restart()
        restored = client.request("draft.read", draftId=recovery["id"])
        require(restored["bodyFormat"] == "markdown" and restored["recoveryFields"][4] == "**Retained** source", "recovery format/source was lost")
        require("<strong>Retained</strong>" in client.request("draft.preview", draftId=recovery["id"])["bodyHtml"], "recovery preview did not read raw body fields")
        require(client.request("draft.send", draftId=recovery["id"], operationId="recovery-blocked", ok=False)["code"] == "UnfinishedDraft", "unfinished recovery draft was submitted")
        plain = one_shot(client, "mail", "compose", ["--body", "**literal**"])
        require(plain["bodyFormat"] == "plain", "legacy one-shot default stopped being plain")
        require(client.request("draft.preview", draftId=plain["id"])["plainText"] == "**literal**", "legacy literal body was reinterpreted")
        require(client.request("draft.preview", account="work@example.com", draftId=draft["id"], ok=False)["code"] == "DraftNotFound", "draft preview crossed account boundaries")
        one_shot(client, "mail", "compose", ["--format", "html"], error="InvalidBodyFormat")
    finished(client)
    with Client(binary, directory / "unknown", scenario="unknown-send") as client:
        body = {"to": "peer@example.test", "bodyText": "**Unknown**", "bodyFormat": "markdown"}
        original = client.request("mail.send", operationId="unknown-original", draft=body)
        replay = client.request("mail.send", operationId="unknown-replay", draft=body)
        require(original["outcome"] == "unknown" and replay["id"] == original["id"], "unknown Markdown send was replayed")
        require(client.request("mail.send", operationId="unknown-original", draft={**body, "bodyFormat": "plain"}, ok=False)["code"] == "OperationConflict", "format change reused an uncertain operation")
    finished(client)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory(prefix="omagma-markdown-fixtures-") as temporary:
        exercise(binary, Path(temporary))
    require(hashlib.sha256(binary.read_bytes()).hexdigest() == digest, "tested binary changed")
    receipt = {"schemaVersion": 1, "suite": "terminal-markdown-mail", "status": "passed", "synthetic": True, "liveProviderWrites": 0, "binarySha256": digest, **read_build_info(binary, None)}
    if args.receipt:
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    print("PASS Markdown mail: CLI/JSONL compose, reply, forward, alternatives, recovery, attachments and unknown replay")


if __name__ == "__main__":
    main()
