#!/usr/bin/env python3
"""Synthetic connected Gmail handoff/import lifecycle; never uses real Gmail."""
import argparse
import base64
import json
from pathlib import Path
import tempfile
from terminal_integration import Client, ACCOUNTS, require


def create(client):
    return client.request("draft.create", draft={
        "to": [{"address": "reader@example.test", "name": "Reader"}],
        "cc": [{"address": "copy@example.test"}], "bcc": [{"address": "hidden@example.test"}],
        "subject": "Gmail continuity fixture", "bodyText": "# Local source\n\nFull text café 👋",
        "bodyFormat": "markdown", "attachments": [{"id": "owned-file", "filename": "notes.txt", "mimeType": "text/plain", "size": 5, "data": base64.urlsafe_b64encode(b"notes").decode().rstrip("=")}]})


def info(client, draft):
    return client.request("draft.gmail-info", draftId=draft["id"])


def upload(client, draft):
    current = info(client, draft)
    return client.request("draft.gmail-save", draftId=draft["id"], expectedVersion=current["link"]["version"] if current.get("link") else 0, expectedDigest=current["contentDigest"])


def expect(client, cmd, code, **arguments):
    result = client.request(cmd, ok=False, **arguments)
    require(result["code"] == code, f"{cmd}: expected {code}, got {result}")


def lifecycle(binary, root):
    with Client(binary, root) as client:
        draft = create(client)
        linked = upload(client, draft)
        require(linked["outcome"] == "linked" and linked["link"]["paused"], "upload did not pause local source")
        expect(client, "draft.update", "DraftPausedInGmail", draftId=draft["id"], draft={**draft, "bodyText": "Should not save"})
        expect(client, "draft.discard", "DraftPausedInGmail", draftId=draft["id"])
        expect(client, "draft.send", "DraftPausedInGmail", draftId=draft["id"], operationId="paused-send")
        expect(client, "draft.gmail-save", "GmailDraftAlreadyLinked", draftId=draft["id"], expectedVersion=linked["link"]["version"], expectedDigest=linked["contentDigest"])
        expect(client, "draft.gmail-info", "DraftNotFound", account=ACCOUNTS[1], draftId=draft["id"])
        client.restart()
        require(info(client, draft)["link"] == linked["link"], "restart changed persisted Gmail ownership")
        checked = client.request("draft.gmail-status", draftId=draft["id"], expectedVersion=linked["link"]["version"])
        imported = client.request("draft.gmail-import", draftId=draft["id"], expectedVersion=checked["link"]["version"], expectedRemoteMessageId=checked["remote"]["messageId"])
        copy = client.request("draft.read", draftId=imported["importedDraftId"])
        require(copy["id"] != draft["id"] and copy["bodyFormat"] == "plain", "Gmail download overwrote source or invented Markdown")
        require(copy["bcc"][0]["address"] == "hidden@example.test" and len(copy["attachments"]) == 1, "import lost hidden recipient or file")
        require("Full text café 👋" in copy["bodyText"] and copy["gmailLink"]["paused"] is False, "import lost text or left new copy paused")
        original = client.request("draft.read", draftId=draft["id"])
        require(original["bodyText"] == draft["bodyText"] and original["gmailLink"]["paused"], "download changed original local source")
        expect(client, "draft.send", "GmailCopyUnchecked", draftId=copy["id"], operationId="unchecked-copy")
        client.restart()
        expect(client, "draft.send", "GmailCopyUnchecked", draftId=copy["id"], operationId="restart-unchecked")
        changed = client.request("draft.update", draftId=copy["id"], draft={**copy, "bodyText": "Changed after import"})
        expect(client, "draft.send", "DraftChanged", draftId=copy["id"], operationId="old-copy-ack", acknowledgeGmailCopy=True, gmailCopyDigest=copy["contentDigest"])
        digest = info(client, changed)["contentDigest"]
        client.request("draft.send", draftId=copy["id"], operationId="explicit-copy-send", acknowledgeGmailCopy=True, gmailCopyDigest=digest)
    print("PASS Gmail drafts: upload, restart, paused mutation guards, download new full-text copy, Bcc/files, exact send acknowledgement")


def conflicts(binary, root):
    with Client(binary, root) as client:
        draft = create(client)
        linked = upload(client, draft)
    with Client(binary, root, scenario="gmail-draft-import-race") as client:
        checked = client.request("draft.gmail-status", draftId=draft["id"], expectedVersion=linked["link"]["version"])
        expect(client, "draft.gmail-import", "GmailDraftChanged", draftId=draft["id"], expectedVersion=linked["link"]["version"], expectedRemoteMessageId=checked["remote"]["messageId"])
        require(len(client.request("draft.list")["drafts"]) == 1, "remote version race left partial new draft")
    with Client(binary, root, scenario="gmail-draft-conflict") as client:
        checked = client.request("draft.gmail-status", draftId=draft["id"], expectedVersion=linked["link"]["version"])
        require(checked["outcome"] == "changed", "remote edits not exposed")
        expect(client, "draft.gmail-take-back", "GmailDraftConflict", draftId=draft["id"], expectedVersion=checked["link"]["version"])
        expect(client, "draft.gmail-import", "GmailDraftChanged", draftId=draft["id"], expectedVersion=checked["link"]["version"], expectedRemoteMessageId=linked["remote"]["messageId"])
        downloaded = client.request("draft.gmail-import", draftId=draft["id"], expectedVersion=checked["link"]["version"], expectedRemoteMessageId=checked["remote"]["messageId"])
        copy = client.request("draft.read", draftId=downloaded["importedDraftId"])
        require("Edited in Gmail" in copy["bodyText"], "remote edits not imported")
        current = info(client, draft)
        resumed = client.request("draft.gmail-take-back", draftId=draft["id"], expectedVersion=current["link"]["version"], keepLocalAfterChange=True, expectedRemoteMessageId=checked["remote"]["messageId"])
        require(not resumed["link"]["paused"], "explicit keep-both choice did not resume local source")
    with Client(binary, root, scenario="gmail-draft-missing") as client:
        current = info(client, draft)
        expect(client, "draft.gmail-take-back", "GmailDraftMissing", draftId=draft["id"], expectedVersion=current["link"]["version"])
        taken = client.request("draft.gmail-take-back", draftId=draft["id"], expectedVersion=current["link"]["version"], acknowledgeMissingCopy=True)
        require(taken["link"]["possiblySentElsewhere"], "missing Gmail copy treated as safe delivery failure")
    print("PASS Gmail drafts: remote edits, stale download refusal, preserved both copies, missing-copy acknowledgement")


def unknown(binary, root):
    with Client(binary, root, scenario="gmail-draft-unknown") as client:
        draft = create(client)
        result = upload(client, draft)
        require(result["outcome"] == "unknown" and result["link"]["paused"], "uncertain upload not durably paused")
        client.restart()
        expect(client, "draft.gmail-save", "GmailDraftOutcomeUnknown", draftId=draft["id"], expectedVersion=result["link"]["version"], expectedDigest=result["contentDigest"])
        result = client.request("draft.gmail-status", draftId=draft["id"], expectedVersion=result["link"]["version"])
        require(result["outcome"] == "linked", "positive exact-message lookup did not reconcile create")
    with Client(binary, root / "absent", scenario="gmail-draft-unknown-missing") as client:
        draft = create(client)
        result = upload(client, draft)
        absent = client.request("draft.gmail-status", draftId=draft["id"], expectedVersion=result["link"]["version"])
        require(absent["outcome"] == "unknown" and absent["link"]["paused"], "empty remote search incorrectly authorized retry")
    print("PASS Gmail drafts: unknown create, no automatic retry, restart, positive-only reconciliation")


def permissions(binary, root):
    with Client(binary, root, scenario="readonly") as client:
        draft = create(client)
        before = info(client, draft)
        expect(client, "draft.gmail-save", "PermissionDenied", draftId=draft["id"], expectedVersion=0, expectedDigest=before["contentDigest"])
        require(info(client, draft).get("link") is None, "permission refusal paused draft")
    with Client(binary, root, scenario="offline-refresh") as client:
        current = info(client, draft)
        expect(client, "draft.gmail-save", "TransientFailure", draftId=draft["id"], expectedVersion=0, expectedDigest=current["contentDigest"])
        require(info(client, draft).get("link") is None, "offline preflight paused draft")
    with Client(binary, root, scenario="gmail-draft-rejected") as client:
        result = upload(client, draft)
        require(result["link"]["phase"] == "rejected" and not result["link"]["paused"], "definite rejection blocked safe local editing")
        changed = client.request("draft.update", draftId=draft["id"], draft={**draft, "bodyText": "Corrected source"})
    with Client(binary, root) as client:
        current = info(client, changed)
        expect(client, "draft.gmail-save", "DraftChanged", draftId=changed["id"], expectedVersion=current["link"]["version"], expectedDigest="0" * 64)
        result = upload(client, changed)
        require(result["outcome"] == "linked", "explicit upload after definite rejection failed")
    print("PASS Gmail drafts: missing permission/offline preflight, definite rejection, stale-content fence, explicit retry")


def native_pty(binary, root, captures):
    from terminal_mouse import MouseTerminal, click, point
    from terminal_reader_editor import ReaderScreen
    from terminal_reader_context import command
    from terminal_reader_next_ux import fixture, capture
    source = fixture(binary, root)
    with Client(binary, root, extra=source.options()) as client:
        draft = create(client)
    terminal = MouseTerminal(binary, root, extra=source.options(), screen_type=ReaderScreen,
                             environment={"NO_COLOR": None, "COLORTERM": "truecolor"}, columns=100, rows=32)
    try:
        terminal.until(lambda: "PLAIN-ALTERNATIVE" in terminal.text())
        terminal.send(b"h")
        terminal.until(lambda: terminal.screen.locate("Drafts") is not None)
        click(terminal, *point(terminal, "Drafts"))
        terminal.until(lambda: "Gmail continuity fixture" in terminal.text())
        terminal.send(b"\r")
        terminal.until(lambda: "Ctrl+S" in terminal.text() and "Local source" in terminal.text())
        terminal.gap(.5)  # Let receipt lookup and recent-recipient loading finish.
        command(terminal, "gmail-draft")
        terminal.until(lambda: "Upload once" in terminal.text())
        capture(terminal, captures, "gmail-draft-upload-review")
        terminal.send(b"j\r")
        terminal.until(lambda: "Draft is available in Gmail" in terminal.text())
        capture(terminal, captures, "gmail-draft-linked")
        terminal.resize(48, 22)
        terminal.gap(.3)
        capture(terminal, captures, "gmail-draft-narrow-linked")
        terminal.resize(100, 32)
        terminal.gap(.3)
        terminal.send(b"\x1b")
        terminal.until(lambda: "Continue in Gmail" not in terminal.text() and "paused in Gmail" in terminal.text())
        terminal.gap(.15)
        terminal.send(b"i")
        terminal.gap(.15)
        require("paused in Gmail" in terminal.text(), "paused composer became editable")
        capture(terminal, captures, "gmail-draft-paused-editor")
        with Client(binary, root, extra=source.options()) as client:
            stored = client.request("draft.read", draftId=draft["id"])
            require(stored["bodyText"] == draft["bodyText"] and stored["gmailLink"]["paused"], "paused composer accepted typed edits")
        command(terminal, "gmail-draft")
        terminal.until(lambda: "Check Gmail draft" in terminal.text())
        terminal.send(b"jj\r")
        terminal.until(lambda: "Import Gmail text as a new draft" in terminal.text())
        terminal.send(b"jjj\r")
        terminal.until(lambda: "local copy · Gmail copy kept" in terminal.text())
        terminal.gap(.5)
        capture(terminal, captures, "gmail-draft-imported-copy")
        terminal.send(b"\x13")
        terminal.until(lambda: not terminal.screen.frame_open and "[ ] Gmail copy kept" in terminal.text())
        require("[g I checked Gmail]" in terminal.text(), "acknowledgement incorrectly promises a Gmail check")
        capture(terminal, captures, "gmail-draft-copy-send-review")
        terminal.resize(48, 22)
        terminal.gap(.3)
        require("[Back]  [y Send]  [g I checked Gmail]" in terminal.text(), "narrow review clipped its acknowledgement control")
        capture(terminal, captures, "gmail-draft-narrow-send-review")
        terminal.send(b"g")
        terminal.until(lambda: not terminal.screen.frame_open and "[g Acknowledged]" in terminal.text())
        require("[x] I checked Gmail Drafts and Sent;" in terminal.text(), "acknowledgement implies application verification")
        capture(terminal, captures, "gmail-draft-narrow-acknowledged")
        terminal.send(b"\x1b")
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    print("PASS Gmail drafts owned PTY: explicit handoff, paused editor, status, import new copy, send warning")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--captures", type=Path)
    parser.add_argument("--pty", action="store_true")
    parser.add_argument("--pty-only", action="store_true", help="Refresh terminal checks/captures without repeating CLI groups")
    args = parser.parse_args()
    from build_info import read_build_info
    print(json.dumps(read_build_info(args.binary)), flush=True)
    with tempfile.TemporaryDirectory(prefix="omagma-gmail-drafts-") as temporary:
        root = Path(temporary)
        if not args.pty_only:
            lifecycle(args.binary, root / "lifecycle")
            conflicts(args.binary, root / "conflicts")
            unknown(args.binary, root / "unknown")
            permissions(args.binary, root / "permissions")
        if args.pty or args.pty_only:
            native_pty(args.binary, root / "pty", args.captures)


if __name__ == "__main__":
    main()
