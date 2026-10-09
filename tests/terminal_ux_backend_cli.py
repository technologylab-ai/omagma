#!/usr/bin/env python3
"""Synthetic one-shot UX API parity; run under the cooperative host lock."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import tempfile

from build_info import read_build_info


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    binary = args.binary.resolve()
    build = read_build_info(binary)
    with tempfile.TemporaryDirectory(prefix="omagma-ux-cli-") as temporary:
        # Darwin spells its temporary root through /var, a system symlink.
        # Use this owned directory's real spelling for the attachment saver,
        # whose directory walker deliberately refuses symlink components.
        root = Path(temporary).resolve()
        environment = os.environ.copy()
        environment.update(HOME=str(root / "home"), XDG_CONFIG_HOME=str(root / "config"),
                           XDG_CACHE_HOME=str(root / "xdg-cache"), XDG_DATA_HOME=str(root / "data"))
        calls = 0

        def run(family, verb, *flags, account="personal@example.com", error=None):
            nonlocal calls
            calls += 1
            command = [str(binary), family, verb, "--fixtures", "--cache-dir", str(root / "cache"),
                       "--account", account, *map(str, flags)]
            result = subprocess.run(command, capture_output=True, env=environment, cwd=root, timeout=35)
            assert len(result.stdout) <= 3 * 1024 * 1024 and len(result.stderr) < 16384
            if not result.stdout:
                assert error and result.returncode and error.encode() in result.stderr, result.stderr.decode()
                return None
            frames = result.stdout.splitlines()
            assert len(frames) == 1, result.stdout[:500]
            frame = json.loads(frames[0])
            assert frame["account"] == account and frame["ok"] is (error is None), frame
            assert (result.returncode == 0) is (error is None), result.stderr.decode()
            if error:
                assert frame["error"]["code"] == error, frame
                return frame["error"]
            assert not result.stderr, result.stderr.decode()
            return frame["data"]

        palette = run("labels", "palette")
        assert "#fb4c2f" in palette["colors"]
        label = run("labels", "create", "--name", "Synthetic CLI", "--operation-id", "cli-label-create",
                    "--background-color", "#FB4C2F", "--text-color", "#ffffff")["label"]
        colored = run("labels", "color", "--label-id", label["id"], "--operation-id", "cli-label-color",
                      "--background-color", "#a479e2", "--text-color", "#ffffff")
        assert colored["label"]["color"]["backgroundColor"] == "#a479e2"
        scope = run("mail", "triage-scope", "--message-id", "demo-1", "--scope", "conversation")
        assert scope["complete"] and scope["count"] == len(scope["messageIds"]) == 3
        archived = run("mail", "archive", "--message-id", "demo-1", "--scope", "conversation")
        assert archived["appliedCount"] == 3
        restored = run("mail", "undo", "--undo-token", archived["undoToken"], "--message-ids", "demo-1")
        assert restored["restoredCount"] == 1
        mixed = run("mail", "labels", "--message-ids", "demo-1,demo-2")
        assert mixed["complete"] and mixed["count"] == 2
        assert next(item for item in mixed["labels"] if item["id"] == "INBOX")["appliedCount"] == 1
        run("mail", "archive", "--scope", "conversation", "--message-ids", "demo-1,demo-2",
            error="ScopeRequiresSingleMessage")
        marked = run("mail", "batch", "--action", "mark", "--message-ids", "demo-1,demo-2",
                     "--add-label", label["id"])
        assert marked["appliedCount"] == 2
        spammed = run("mail", "spam", "--message-id", "demo-1")
        assert spammed["appliedCount"] == 1
        assert run("mail", "unspam", "--message-id", "demo-1")["appliedCount"] == 1

        tiny = root / "small file.bin"
        tiny.write_bytes(b"\x00\xff\x80fixture")
        small = run("draft", "create", "--to", "peer@example.test", "--body", "**literal**",
                    "--attach-file", tiny)
        encoded = small["attachments"][0]["data"]
        assert base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)) == tiny.read_bytes()
        preview = run("draft", "preview", "--draft-id", small["id"], "--browser")
        assert not preview["opened"] and preview["fixture"]
        artifact = Path(preview["path"])
        assert artifact.is_absolute() and artifact.name == "preview.html" and artifact.stat().st_mode & 0o077 == 0
        html = artifact.read_text()
        assert "sandbox" in html and "Content-Security-Policy" in html and "personal@example.com" in html
        assert preview["url"].startswith("file://") and preview["profile"].startswith("--profile-directory=")
        queued = run("draft", "queue", "--draft-id", small["id"], "--operation-id", "cli-canceled", "--delay-seconds", 30)
        assert queued["state"] == "queued" and queued["dueAtMs"] - queued["createdAtMs"] == 30000
        assert run("queue", "read", "--queue-id", queued["queueId"])["state"] == "queued"
        assert len(run("queue", "list")["queue"]) == 1
        assert run("queue", "cancel", "--queue-id", queued["queueId"])["state"] == "canceled"
        run("queue", "resume", "--queue-id", queued["queueId"], error="SendAlreadySubmitted")
        next_queue = run("draft", "queue", "--draft-id", small["id"], "--operation-id", "cli-resumed", "--delay-seconds", 30)
        assert run("queue", "resume", "--queue-id", next_queue["queueId"], "--delay-seconds", 0)["state"] == "queued"
        assert run("queue", "process", "--queue-id", next_queue["queueId"], "--wait")["state"] == "applied"
        assert run("queue", "process", "--queue-id", next_queue["queueId"])["state"] == "applied"

        large = root / "large report.bin"
        raw = bytes(range(256)) * (4 * 1024 * 1024 // 256)
        large.write_bytes(raw)
        attached = run("draft", "create", "--to", "peer@example.test", "--body", "Large file",
                       "--attach-file", large, "--attach-file", tiny)
        assert len(attached["attachments"]) == 2
        assert all(item["blobId"] and not item["data"] for item in attached["attachments"])
        assert attached["attachments"][0]["size"] == len(raw)
        wrong_account = root / "foreign-draft.json"
        wrong_account.write_text(json.dumps(attached))
        run("draft", "create", "--draft-file", wrong_account, account="work@example.com", error="AttachmentHandleNotFound")
        large.unlink()
        sent = run("draft", "send", "--draft-id", attached["id"], "--operation-id", "cli-large-send", "--send-delay", 0)
        assert sent["state"] == "applied"
        assert run("draft", "send", "--draft-id", attached["id"], "--operation-id", "cli-large-send", "--send-delay", 0)["state"] == "applied"
        received = run("mail", "read", "--message-id", sent["operation"]["messageId"])
        destination = root / "saved report.bin"
        saved = run("mail", "attachment-save", "--message-id", received["id"], "--attachment-id", received["attachments"][0]["id"], "--path", destination)
        assert saved["size"] == len(raw) and hashlib.sha256(destination.read_bytes()).digest() == hashlib.sha256(raw).digest()
        run("mail", "attachment-save", "--message-id", received["id"], "--attachment-id", received["attachments"][0]["id"], "--path", destination, error="PathAlreadyExists")
        run("attachment", "discard", "--blob-id", attached["attachments"][0]["blobId"], error="AttachmentInUse")
        disposable = root / "unused.bin"
        disposable.write_bytes(b"unreferenced fixture")
        imported = run("attachment", "import", "--path", disposable, "--mime-type", "application/octet-stream")
        assert run("attachment", "discard", "--blob-id", imported["blobId"])["discarded"]
        too_large = root / "too-large.bin"
        with too_large.open("wb") as file:
            file.truncate(25 * 1024 * 1024 + 1)
        run("attachment", "import", "--path", too_large, error="AttachmentsTooLarge")
        direct = run("mail", "send", "--to", "peer@example.test", "--body", "Direct grace fixture", "--operation-id", "cli-direct-delay", "--send-delay", 0)
        assert direct["state"] == "applied"
        run("mail", "send", "--to", "peer@example.test", "--body", "Direct grace fixture", "--operation-id", "cli-direct-delay", "--send-delay", 0, error="OperationConflict")
        assert run("cache", "stats")["fixtureSends"] == 3
        run("draft", "send", "--draft-id", small["id"], "--send-delay", 31, error="InvalidSendDelay")
        run("draft", "send", "--draft-id", small["id"], "--operation-id", "cached-refusal", "--send-delay", 0, "--cached", error="CacheUnsupported")
        run("draft", "send", "--draft-id", small["id"], "--operation-id", "attachment-refusal", "--attach-file", tiny, error="AttachmentsRequireDraftSource")
        run("mail", "read", "--wait", error="WaitRequiresQueueProcess")
        run("mail", "read", "--message-id", "demo-1", "--browser", error="BrowserRequiresPreview")
        assert run("draft", "discard", "--draft-id", small["id"])["discarded"]
        assert not artifact.exists(), "discarded draft content remained in browser preview file"
        print(json.dumps({"suite": "terminal-ux-backend-cli", "synthetic": True, "liveProviderWrites": 0,
                          **build, "calls": calls, "passed": True}))


if __name__ == "__main__":
    main()
