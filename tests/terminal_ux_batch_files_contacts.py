#!/usr/bin/env python3
"""File-batch and contact/draft UX acceptance in synthetic owned PTYs only."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import stat

from terminal_composer_workflow import setup as composer_setup
from terminal_file_dialog import FIRST, SECOND, fixture_setup
from terminal_integration import ACCOUNTS, Client, FIXTURES, require
from terminal_mouse import click, point
from terminal_pty import wait_saved_compose
from terminal_reader import reader_contains
from terminal_ux_batch_support import (TAB, ENTER, ESC, activate_button, capture,
    command, compose, diagnose, no_writes, read_draft, run_cases, start,
    wait_send_review, wait_ux_dialog)


def action_label(terminal, word):
    return next(label for label in re.findall(r"\[[^\]\n]+\]", terminal.text())
                if word.lower() in label.lower())


def attachment_bytes(directory, attachment, account=ACCOUNTS[0]):
    """Inspect only this test's private immutable imported fixture bytes."""
    handle = attachment.get("blobId")
    if handle:
        require(re.fullmatch(r"[0-9a-f]{64}", handle) is not None,
                "imported attachment omitted a bounded immutable identity")
        account_key = hashlib.sha256(account.encode()).hexdigest()
        path = directory / "cache" / "fixtures" / account_key / f"blob-{handle}.bin"
        require(stat.S_IMODE(path.stat().st_mode) == 0o600, "imported bytes are not private")
        raw = path.read_bytes()
        require(hashlib.sha256(raw).hexdigest() == handle, "imported bytes changed after approval")
        return raw
    import base64
    encoded = attachment["data"]
    return base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))


def save_all(binary, directory, capture_dir=None):
    source = fixture_setup(binary, directory)
    terminal = start(binary, directory, source.options(), "Fictional file-dialog message 096.")
    try:
        destination = directory / "received files with spaces"
        destination.mkdir(mode=0o700)
        preserved = destination / "report.txt"
        sentinel = b"Existing destination must remain unchanged.\n"
        preserved.write_bytes(sentinel)
        command(terminal, "save-all " + str(destination))
        terminal.until(lambda: len(list(destination.iterdir())) == 3)
        terminal.until(lambda: "Saved" in terminal.text())
        require(preserved.read_bytes() == sentinel, "SaveAll overwrote an existing destination")
        created = [file for file in destination.iterdir() if file != preserved]
        require(sorted(file.read_bytes() for file in created) == sorted((FIRST, SECOND)),
                "SaveAll saved a different scope or changed received bytes")
        require(all(stat.S_IMODE(file.stat().st_mode) == 0o600 for file in created),
                "SaveAll created a non-private file")
        capture(terminal, capture_dir, "ux-save-all-outcomes")
        no_writes(binary, directory, source.options())
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def multi_select(binary, directory, capture_dir=None):
    source = fixture_setup(binary, directory)
    terminal = start(binary, directory, source.options(), "Fictional file-dialog message 096.")
    try:
        folder = directory / "files with spaces"
        folder.mkdir(mode=0o700)
        other_folder = directory / "another folder"
        other_folder.mkdir(mode=0o700)
        first_name, second_name = "qjk café notes.txt", "literal $(not-a-command).bin"
        expected = {first_name: b"Fictional first file.\n",
                    second_name: bytes(range(256)) * (4 * 1024 * 1024 // 256)}
        (folder / first_name).write_bytes(expected[first_name])
        (other_folder / second_name).write_bytes(expected[second_name])
        compose(terminal, subject="Multiple files fixture")
        terminal.send(b"A")
        terminal.until(lambda: "Path:" in terminal.text() and "[Attach]" in terminal.text())
        terminal.send(b"\x15" + str(folder).encode() + b"/" + ENTER)
        terminal.until(lambda: first_name in terminal.text())
        terminal.send(TAB * 4 + b" ")
        terminal.until(lambda: "1 selected" in terminal.text() and "[x] " + first_name in terminal.text())
        terminal.send(b"\x15" + str(other_folder).encode() + b"/" + ENTER)
        terminal.until(lambda: second_name in terminal.text() and "1 selected" in terminal.text())
        terminal.send(TAB * 4 + b" ")
        terminal.until(lambda: "2 selected" in terminal.text() and "4.2 MB combined" in terminal.text()
                       and "[x] " + second_name in terminal.text())
        click(terminal, *point(terminal, "[x] " + second_name))
        terminal.until(lambda: "1 selected" in terminal.text() and "[ ] " + second_name in terminal.text())
        click(terminal, *point(terminal, "[ ] " + second_name))
        terminal.until(lambda: "2 selected" in terminal.text() and "[x] " + second_name in terminal.text())
        capture(terminal, capture_dir, "ux-outgoing-multi-select")
        label = action_label(terminal, "Attach")
        activate_button(terminal, label)
        terminal.until(lambda: "Attachments 2" in terminal.text() and "Path:" not in terminal.text())
        wait_saved_compose(terminal, 2)
        terminal.send(b"\x13")
        wait_send_review(terminal)
        retained = read_draft(binary, directory, source.options())
        require({file["filename"] for file in retained["attachments"]} == set(expected),
                "multi-select changed a literal filename or selected a different file set")
        (folder / first_name).unlink()
        (other_folder / second_name).write_bytes(b"Changed user source after import.\n")
        for file in retained["attachments"]:
            require(file.get("blobId") and not file["data"], "TUI did not retain an immutable handle")
            raw = attachment_bytes(directory, file)
            require(raw == expected[file["filename"]], "multi-select changed file bytes")
        terminal.send(ENTER)
        no_writes(binary, directory, source.options())
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def multi_preflight(binary, directory, capture_dir=None):
    source = fixture_setup(binary, directory)
    terminal = start(binary, directory, source.options(), "Fictional file-dialog message 096.")
    try:
        folder = directory / "preflight files"
        folder.mkdir(mode=0o700)
        (folder / "a-small.txt").write_bytes(b"Retain this only after full preflight.\n")
        with (folder / "z-large.bin").open("wb") as stream:
            stream.truncate(25 * 1024 * 1024 + 1)
        compose(terminal, subject="Whole selection preflight")
        terminal.send(b"A")
        terminal.until(lambda: "Path:" in terminal.text())
        terminal.send(b"\x15" + str(folder).encode() + b"/" + ENTER)
        terminal.until(lambda: "z-large.bin" in terminal.text())
        terminal.send(TAB * 4 + b" j ")
        terminal.until(lambda: "2 selected" in terminal.text())
        activate_button(terminal, "[Attach]")
        terminal.until(lambda: any(word in terminal.text().lower() for word in ("limit", "too large", "supported size")))
        require(not list((directory / "cache").rglob("blob-*.bin")),
                "failed selection imported an earlier file before checking the full set")
        require(read_draft(binary, directory, source.options())["attachments"] == [],
                "failed selection partially changed the draft")
        capture(terminal, capture_dir, "ux-selection-preflight-refusal")
        click(terminal, *point(terminal, "[x] z-large.bin"))
        terminal.until(lambda: "1 selected" in terminal.text())
        activate_button(terminal, "[Attach]")
        wait_saved_compose(terminal, 1)
        retained = read_draft(binary, directory, source.options())
        require([file["filename"] for file in retained["attachments"]] == ["a-small.txt"],
                "correcting a failed selection changed its remaining checked file")
        no_writes(binary, directory, source.options())
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def incoming_large(binary, directory, capture_dir=None):
    source = fixture_setup(binary, directory)
    extra = source.options("--metadata-limit", "100")
    raw = bytes(range(256)) * (4 * 1024 * 1024 // 256)
    imported_file = directory / "received large report.bin"
    imported_file.write_bytes(raw)
    # A mock send seeds the fixture outbox; the TUI may only save/open its
    # existing immutable bytes. No real provider or desktop is involved.
    with Client(binary, directory, extra=extra) as client:
        attachment = client.request("attachment.import", path=str(imported_file))
        draft = client.request("draft.create", draft={"to": "peer@example.test",
            "subject": "Large incoming attachment fixture", "bodyText": "Large immutable report ready to save.",
            "attachments": [attachment]})
        sent = client.request("draft.send", draftId=draft["id"], operationId="seed-large-received")
        require(sent["outcome"] == "applied", "large received fixture was not seeded")
        sent_rows = client.request("mail.list", label="SENT")["messages"]
        require(any(row["id"] == sent["messageId"] for row in sent_rows),
                "large received fixture was absent from its explicit Sent view")
    imported_file.unlink()
    terminal = start(binary, directory, extra, "Fictional file-dialog message 096.")
    try:
        terminal.until(lambda: terminal.screen.locate("Sent") is not None
                       and terminal.screen.mouse_tracking_mode == 1002)
        click(terminal, *point(terminal, "Sent"))
        terminal.until(lambda: reader_contains(terminal.screen, "Large immutable report ready to save.")
                       and reader_contains(terminal.screen, attachment["filename"])
                       and reader_contains(terminal.screen, "Attachment 1:")
                       and ''.join(terminal.screen.cells[1]).strip().startswith("Up to date"))
        direct = directory / "saved large literal $report.bin"
        command(terminal, "save-attachment 1 " + str(direct))
        terminal.until(lambda: direct.exists() and "Saved attachment" in terminal.text())
        require(direct.read_bytes() == raw and stat.S_IMODE(direct.stat().st_mode) == 0o600,
                "large direct save changed bytes or private permissions")
        terminal.send(b"Bo")
        terminal.until(lambda: "[Save & open]" in terminal.text())
        opened = directory / "opened large report.bin"
        terminal.send(b"\x15" + str(opened).encode() + ENTER)
        terminal.until(lambda: opened.exists() and "mock file-open validated" in terminal.text())
        require(opened.read_bytes() == raw and stat.S_IMODE(opened.stat().st_mode) == 0o600,
                "Save & open did not use the explicitly chosen private destination")
        destination = directory / "all large files"
        destination.mkdir(mode=0o700)
        command(terminal, "save-all " + str(destination))
        terminal.until(lambda: (destination / attachment["filename"]).exists() and "Saved" in terminal.text())
        require((destination / attachment["filename"]).read_bytes() == raw,
                "SaveAll did not preserve the large selected message attachment")
        capture(terminal, capture_dir, "ux-incoming-large-streamed-save")
        with Client(binary, directory, extra=extra) as client:
            require(client.request("cache.stats")["fixtureSends"] == 1, "saving received files sent mail")
            require(len(client.request("operation.list")["operations"]) == 1,
                    "saving/opening received files dispatched another provider write")
        terminal.finish(expected_sends=1)
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def large_file(binary, directory, capture_dir=None):
    source = fixture_setup(binary, directory)
    terminal = start(binary, directory, source.options(), "Fictional file-dialog message 096.")
    try:
        compose(terminal, subject="Oversized attachment fixture")
        file = directory / "oversized attachment.bin"
        with file.open("wb") as stream:
            stream.truncate(64 * 1024 * 1024)  # Sparse synthetic stat limit case.
        terminal.send(b"A")
        terminal.until(lambda: "Path:" in terminal.text())
        terminal.send(b"\x15" + str(file).encode() + ENTER)
        terminal.until(lambda: any(word in terminal.text().lower() for word in ("limit", "too large", "supported size")))
        capture(terminal, capture_dir, "ux-oversized-file-guidance")
        terminal.send(ESC)
        terminal.gap(.1)
        terminal.send(b"\x13")
        wait_send_review(terminal)
        retained = read_draft(binary, directory, source.options())
        require(retained["attachments"] == [], "oversized file was silently retained/truncated")
        require(retained["subject"] == "Oversized attachment fixture", "oversized refusal discarded the note")
        terminal.send(ENTER)
        no_writes(binary, directory, source.options())
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def contact_multiple_addresses(binary, directory, capture_dir=None):
    source = fixture_setup(binary, directory)
    shutil.copytree(FIXTURES / "contacts", source.root / "contacts")
    extra = source.options()
    path = source.root / "contacts/personal.json"
    data = json.loads(path.read_text())
    first = data["connections"][0]
    first["emailAddresses"].append({"value": "alex-second@example.test", "type": "home"})
    path.write_text(json.dumps(data))
    with Client(binary, directory, extra=extra) as client:
        contacts = client.request("contacts.list")["contacts"]
        original = next(contact for contact in contacts if contact["resourceName"] == first["resourceName"])
        require(len(original["emails"]) == 2, "multiple-address fixture did not seed both addresses")
    terminal = start(binary, directory, extra, "Fictional file-dialog message 096.")
    try:
        terminal.send(b"a")
        terminal.until(lambda: original["name"] in terminal.text())
        terminal.send(ENTER)
        terminal.until(lambda: "Name:" in terminal.text() and "alex-second@example.test" in terminal.text())
        capture(terminal, capture_dir, "ux-contact-multiple-addresses")
        terminal.send(b"\x01" + b"\x1b[3~" * len(original["name"]) + b"Renamed Multi Address" + b"\x13")
        terminal.until(lambda: "Renamed Multi Address" in terminal.text() and "Name:" not in terminal.text())
        with Client(binary, directory, extra=extra) as client:
            contacts = client.request("contacts.list", cacheOnly=True)["contacts"]
            after = next(contact for contact in contacts if contact["resourceName"] == first["resourceName"])
            require(after["name"] == "Renamed Multi Address", "contact edit did not save its visible name")
            require(after["emails"] == original["emails"], "renaming a contact dropped or changed an address")
            other = client.request("contacts.list", account=ACCOUNTS[1])["contacts"]
            require(not any(contact["name"] == after["name"] for contact in other), "contact edit crossed accounts")
            require(client.request("cache.stats")["fixtureSends"] == 0, "contact editing sent mail")
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def discard_draft(binary, directory, capture_dir=None):
    extra, body = composer_setup(binary, directory)
    terminal = start(binary, directory, extra, body["bodyText"].splitlines()[0])
    try:
        compose(terminal, subject="Discard only this local draft")
        terminal.send(b"\x13")
        wait_send_review(terminal)
        terminal.send(ENTER)
        terminal.until(lambda: "Review send" not in terminal.text())
        before = read_draft(binary, directory, extra)
        command(terminal, "discard-draft")
        wait_ux_dialog(terminal, "Discard local draft", "[Discard]", cancel="[Cancel]", filtered=False)
        terminal.send(ENTER)
        terminal.until(lambda: "[Cancel]" not in terminal.text() and "Subject:" in terminal.text())
        require(read_draft(binary, directory, extra)["id"] == before["id"], "default discard Enter deleted the draft")
        command(terminal, "discard-draft")
        wait_ux_dialog(terminal, "Discard local draft", "[Discard]", cancel="[Cancel]", filtered=False)
        capture(terminal, capture_dir, "ux-local-draft-discard-review")
        activate_button(terminal, action_label(terminal, "Discard"))
        terminal.until(lambda: "Subject:" not in terminal.text() and "[Cancel]" not in terminal.text())
        with Client(binary, directory, extra=extra) as client:
            require(client.request("draft.list")["drafts"] == [], "explicit local discard left recovery draft behind")
        no_writes(binary, directory, extra)
        terminal.finish()
    except Exception:
        diagnose(terminal)
        raise
    finally:
        terminal.close()


def main():
    cases = (("save-all", save_all), ("multi-select", multi_select),
             ("multi-preflight", multi_preflight), ("incoming-large", incoming_large),
             ("large-file", large_file), ("contact-multiple", contact_multiple_addresses),
             ("discard-draft", discard_draft))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--case", choices=[name for name, _ in cases], action="append")
    parser.add_argument("--capture-dir", type=Path)
    args = parser.parse_args()
    run_cases(args.binary, cases, args.case, args.capture_dir)


if __name__ == "__main__":
    main()
