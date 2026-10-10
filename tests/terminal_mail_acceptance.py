#!/usr/bin/env python3
"""Literal provider mail through legacy cache recovery and an owned TUI PTY.

Synthetic only: no desktop, credentials, network or installed cache. Run with
the coordinator's cooperative host reservation. Darwin uses the existing PTY
guardian so the session survives long enough to verify restored termios.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import platform
import shutil
import sys
import tempfile

from build_info import build_mode, read_build_info
from terminal_integration import ACCOUNTS, Client, require
from terminal_pty import Terminal, wait_saved_compose
from terminal_polish_compose import panel_text
from terminal_reader import reader_contains, reader_rows
from terminal_mouse_screen import MouseScreen


FIXTURE = Path(__file__).resolve().parent / "fixtures/terminal/provider-acceptance"
ACCOUNT = ACCOUNTS[0]
GOOD = "provider-bom-contract"
INVALID = "provider-truncated-text"
LARGE_IMAGE_BYTES = 5 * 1024 * 1024
LARGE_IMAGE_NAME = "contract-photo.png"
LARGE_IMAGE_REASON = "Embedded images exceed 2 MiB · choose Text quote"
COUNTERS = ("fixtureCalls", "syncCalls", "syncMetadataGets", "syncListCalls",
            "syncHistoryPages", "syncBodyGets")


class AcceptanceScreen(MouseScreen):
    """Never treat a partly painted synchronized VT frame as an actual state."""
    def __init__(self, columns=160, rows=42):
        super().__init__(columns, rows)
        self.frame_open = False
        self.completed_frames = 0

    def csi(self, sequence, final):
        super().csi(sequence, final)
        if sequence == "?2026" and final in ("h", "l"):
            self.frame_open = final == "h"
            if final == "l":
                self.completed_frames += 1


def decode(data):
    return base64.urlsafe_b64decode(data + "===")


def validate_fixture():
    """Independent literal oracles; do not manufacture provider size metadata."""
    manifest = json.loads((FIXTURE / "manifest.json").read_text())
    source = json.loads((FIXTURE / "accounts/personal.json").read_text())
    legacy = json.loads((FIXTURE / "legacy-cache.json").read_text())
    draft = json.loads((FIXTURE / "legacy-draft.json").read_text())
    require(source["account"] == legacy["account"] == ACCOUNT, "fixture account identity differs")
    require(legacy["schema"] == 1 and legacy.get("decoderRevision", 0) == 0,
            "fixture no longer represents a legacy schema-1 decoder refusal")
    require(all(entry["bodyError"] == "BodySizeMismatch" and entry["bytes"] == 0
                for entry in legacy["entries"]), "legacy refusal fixture has cached bodies")
    messages = {message["id"]: message for message in source["messages"]}
    mixed = messages[GOOD]["payload"]
    require(mixed["mimeType"] == "multipart/mixed", "literal mixed MIME root changed")
    envelope = {header["name"].lower(): header["value"] for header in mixed["headers"]}
    require("Fictional Teammate <teammate@example.test>" in envelope["to"]
            and "Fictional Reviewer <reviewer@example.test>" in envelope["cc"]
            and "TEAMMATE@example.test" in envelope["cc"] and ACCOUNT in envelope["cc"],
            "reply-all literal fixture lost named participants or duplicate/self addresses")
    alternative, document, image = mixed["parts"]
    require(alternative["mimeType"] == "multipart/alternative", "literal nested alternative changed")
    for part, prefix in zip(alternative["parts"], ("plain", "html")):
        raw = decode(part["body"]["data"])
        require(part["mimeType"] == "text/" + prefix, "literal alternative leaf changed")
        headers = {header["name"].lower(): header["value"] for header in part["headers"]}
        require("utf-8" in headers["content-type"].lower()
                and headers["content-transfer-encoding"].lower() == "base64",
                "stripped-BOM fixture lost its UTF-8/base64 wire shape")
        require(len(raw) == manifest[prefix + "DecodedBytes"]
                and part["body"]["size"] == manifest[prefix + "DeclaredBytes"]
                and part["body"]["size"] == len(raw) + 3,
                "literal provider size must include the three stripped BOM bytes")
        require(not raw.startswith(b"\xef\xbb\xbf"), "provider data still includes its BOM")
        require(raw.decode().replace("\r\n", "\n") == manifest[prefix + "Expected"].replace("\r\n", "\n"),
                "provider literal differs from the independent body oracle")
    require(manifest["plainExpected"].strip() not in messages[GOOD]["snippet"],
            "metadata snippet could satisfy the full-body oracle")
    external = source["externalBodies"][document["body"]["attachmentId"]]
    require(document["filename"] == manifest["documentFilename"]
            and document["mimeType"] == "application/rtf", "external document identity changed")
    require(document["body"]["size"] == external["size"] == manifest["documentDeclaredBytes"]
            and len(decode(external["data"])) == manifest["documentDecodedBytes"],
            "external document no longer has exact declared byte counts")
    require(decode(external["data"]) == manifest["documentExpected"].encode(),
            "external document differs from its independent literal bytes")
    image_response = source["externalBodies"][image["body"]["attachmentId"]]
    image_bytes = decode(image_response["data"])
    require(image["body"]["size"] == image_response["size"] == manifest["imageDeclaredBytes"]
            and image_bytes == base64.b64decode(manifest["imageExpectedBase64"])
            and hashlib.sha256(image_bytes).hexdigest() == manifest["imageSha256"],
            "external inline image differs from independent literal bytes")
    require(any(header == {"name": "Content-ID", "value": "<" + manifest["imageContentId"] + ">"}
                for header in image["headers"])
            and "cid:" + manifest["imageContentId"] in manifest["htmlExpected"],
            "external image no longer binds to the original HTML's literal CID")
    invalid = messages[INVALID]["payload"]["body"]
    require(len(decode(invalid["data"])) == manifest["invalidDecodedBytes"]
            and invalid["size"] == manifest["invalidDeclaredBytes"]
            and invalid["size"] == len(decode(invalid["data"])) + 4,
            "invalid fixture no longer exceeds the narrow compatibility exception")
    return manifest, legacy, draft


def private_copy(source, destination):
    destination.write_bytes(source.read_bytes())
    destination.chmod(0o600)


class ProviderFixture:
    def __init__(self, directory):
        self.root = directory / "provider"
        shutil.copytree(FIXTURE / "accounts", self.root / "accounts")
        self.path = self.root / "accounts/personal.json"
        self.hold = self.root / "legacy-refresh.hold"
        self.entered = self.root / "legacy-refresh.entered"
        source = json.loads(self.path.read_text())
        source["sync"].update(fixtureHold=self.hold.name, fixtureEntered=self.entered.name)
        self.path.write_text(json.dumps(source, ensure_ascii=False) + "\n")
        self.hold.write_text("Owned synthetic provider refresh held.\n")

    def options(self):
        return ("--fixture-root", str(self.root), "--prefetch-bodies", "2")


class LargeInlineFixture:
    """A literal unloaded 5 MiB descriptor; never manufacture giant JSON data."""
    def __init__(self, directory):
        self.root = directory / "provider"
        shutil.copytree(FIXTURE / "accounts", self.root / "accounts")
        path = self.root / "accounts/personal.json"
        source = json.loads(path.read_text())
        message = next(value for value in source["messages"] if value["id"] == GOOD)
        # The independent literal HTML body remains unchanged. Without its
        # plain sibling, the ordinary reader must render the image placeholder.
        alternative, _, image = message["payload"]["parts"]
        alternative["parts"] = [alternative["parts"][1]]
        image["filename"] = LARGE_IMAGE_NAME
        image["body"] = {"size": 5242880, "attachmentId": "provider-large-photo"}
        image["headers"] = [
            {"name": "Content-Type", "value": "image/png"},
            {"name": "Content-Disposition", "value": 'inline; filename="contract-photo.png"'},
            {"name": "Content-ID", "value": "<provider-logo@example.test>"},
        ]
        source["externalBodies"].pop("provider-external-logo")
        path.write_text(json.dumps(source, ensure_ascii=False) + "\n")
        require(path.stat().st_size < 20 * 1024 and "provider-large-photo" not in source["externalBodies"],
                "large-image fixture accidentally hydrated the external photo")

    def options(self):
        return ("--fixture-root", str(self.root), "--prefetch-bodies", "2")


def seed_cache(directory, draft):
    path = directory / "cache"
    for part in (path, path / "fixtures", path / "fixtures" / hashlib.sha256(ACCOUNT.encode()).hexdigest()):
        part.mkdir(mode=0o700)
    account = part
    private_copy(FIXTURE / "legacy-cache.json", account / "index.json")
    private_copy(FIXTURE / "legacy-draft.json",
                 account / f"draft-{hashlib.sha256(draft['id'].encode()).hexdigest()}.json")
    return account


def index(account):
    return json.loads((account / "index.json").read_text())


def entries(state):
    return {entry["message"]["id"]: entry for entry in state["entries"]}


def preserved(state, legacy, additional_drafts=()):
    require(state["account"] == ACCOUNT and state["schema"] == 1, "decoder migration changed cache identity")
    require(state["historyId"] == legacy["historyId"], "decoder recovery reset the history checkpoint")
    require(state["inboxArrivalCount"] == legacy["inboxArrivalCount"], "decoder recovery counted old mail as an arrival")
    require(state["generation"] > legacy["generation"] and state["serial"] >= legacy["serial"],
            "decoder recovery reset generation or local draft serial")
    require(state["fixtureSends"] == 0, "reader workflow sent synthetic mail")
    require({entry["id"] for entry in state["drafts"]}
            == {entry["id"] for entry in legacy["drafts"]} | set(additional_drafts),
            "decoder recovery discarded or invented a draft")
    fields = ("id", "name", "type")
    require(sorted(tuple(label[key] for key in fields) for label in state["labels"])
            == sorted(tuple(label[key] for key in fields) for label in legacy["labels"]),
            "decoder recovery changed existing labels")
    for key in COUNTERS:
        require(state[key] >= legacy[key], f"decoder recovery reset the {key} counter")
    require(set(entries(state)) == {GOOD, INVALID}, "decoder recovery changed retained mail identities")
    require(entries(state)[GOOD]["message"]["labels"] == ["INBOX", "Label_contract"],
            "decoder recovery lost the message's custom label")


def accepted_reader(terminal, manifest):
    return (not terminal.screen.frame_open
            and all(reader_contains(terminal.screen, line) for line in manifest["plainExpected"].splitlines()))


def require_available(terminal):
    cells = "\n".join(line for _, line in reader_rows(terminal.screen))
    require(all(label not in cells for label in ("Body unavailable", "Body not cached", "BodySizeMismatch")),
            "accepted mail reader still shows an unavailable-body diagnostic")


def panel_contains(terminal, title, literal):
    try:
        return "".join(literal.split()) in "".join(panel_text(terminal, title).split())
    except AssertionError:
        return False


def preserved_original(draft, manifest, action):
    original = draft.get("original")
    require(isinstance(original, dict) and original["sourceMessageId"] == GOOD,
            f"{action} omitted the original source identity")
    require(original["bodyText"] == manifest["plainExpected"]
            and original["bodyHtml"] == manifest["htmlExpected"],
            f"{action} changed the literal source's plain/HTML body")
    resources = original["resources"]
    require(len(resources) == 1, f"{action} lost or duplicated the referenced inline image")
    image = resources[0]
    require(image["contentId"].strip("<>") == manifest["imageContentId"]
            and image["filename"] == manifest["imageFilename"]
            and image["size"] == manifest["imageDeclaredBytes"]
            and decode(image["data"]) == base64.b64decode(manifest["imageExpectedBase64"]),
            f"{action} changed the original image's CID, metadata or bytes")
    if action == "forward":
        require(draft["to"] == draft["cc"] == draft["bcc"] == [], "forward inherited original recipients")
        require(draft["threadId"] == draft["inReplyTo"] == draft["references"] == "",
                "forward inherited reply threading")
        require(len(draft["attachments"]) == 1, "forward lost document or duplicated the inline image as a file")
        document = draft["attachments"][0]
        require(document["filename"] == manifest["documentFilename"]
                and document["size"] == manifest["documentDecodedBytes"]
                and decode(document["data"]) == manifest["documentExpected"].encode(),
                "forward changed the ordinary external document")
    else:
        require(draft["to"] == manifest["replyToExpected"]
                and draft["cc"] == (manifest["replyAllCcExpected"] if action == "reply-all" else []),
                f"{action} lost a fictional recipient name/address or kept duplicate/self recipients")
        participants = [item["address"].lower() for field in ("to", "cc", "bcc") for item in draft[field]]
        require(ACCOUNT not in participants and len(participants) == len(set(participants)) and not draft["bcc"],
                f"{action} kept duplicate/self recipients or inferred Bcc")
        require(not draft["attachments"] and draft["threadId"] == "provider-contract-thread"
                and draft["inReplyTo"] == "<provider-contract@example.test>", f"{action} lost reply threading")
    return original


def formatted_action(binary, directory, source, terminal, manifest, action, known_drafts):
    key = {"reply": b"r", "reply-all": b"R", "forward": b"f"}[action]
    terminal.send(key)
    terminal.until(lambda: "[Keep formatting k]" in terminal.text() and "[Text quote t]" in terminal.text())
    terminal.send(b"k")
    terminal.until(lambda: "Compose" in terminal.text() and "Subject:" in terminal.text()
                   and "formatted original" in terminal.text() and "[Keep formatting k]" not in terminal.text())
    require("BodySizeMismatch" not in terminal.text(), f"{action} keep-formatting showed the incoming body refusal")
    terminal.until(lambda: panel_contains(terminal, "Outgoing preview", manifest["plainExpected"].splitlines()[0]))
    with Client(binary, directory, extra=source.options()) as client:
        rows = client.request("draft.list")["drafts"]
        new = [row for row in rows if row["id"] not in known_drafts]
        require(len(new) == 1, f"{action} chooser failed to create exactly one local draft")
        created = client.request("draft.read", draftId=new[0]["id"])
        preserved_original(created, manifest, action)
        preview = client.request("draft.preview", draftId=created["id"])
        source_body = manifest["htmlExpected"].split("<body>", 1)[1].split("</body>", 1)[0]
        require(source_body in preview["bodyHtml"]
                and manifest["plainExpected"].strip() in preview["plainText"],
                f"{action} outgoing preview lost the original body or its literal CID reference")
        require(client.request("cache.stats")["fixtureSends"] == 0, f"{action} preview submitted mail")
    require(client.process.returncode == 0 and not client.stderr, "formatted preview child failed cleanup")

    note = f"Editable fictional {action} note.\n"
    terminal.send(b"\x07i\x1b[200~" + note.encode() + b"\x1b[201~")
    terminal.until(lambda: panel_contains(terminal, "Compose", note))
    terminal.send(b"\x1b")
    wait_saved_compose(terminal, int(action == "forward"))
    terminal.send(b"p")
    terminal.until(lambda: all(panel_contains(terminal, "Original message", line)
                              for line in manifest["plainExpected"].splitlines()))
    frame = terminal.screen.completed_frames
    terminal.send(b"q")  # Save locally and return to the mailbox.
    terminal.until(lambda: terminal.screen.completed_frames > frame and not terminal.screen.frame_open
                   and "Compose" not in terminal.screen.lines()[0])
    # A formatted composer owns its saved source separately and clears the
    # mailbox reader. Reopen through the normal key after the Back frame ends.
    frame = terminal.screen.completed_frames
    terminal.send(b"\r")
    terminal.until(lambda: terminal.screen.completed_frames > frame and accepted_reader(terminal, manifest))
    with Client(binary, directory, extra=source.options()) as client:
        saved = client.request("draft.read", draftId=created["id"])
        require(saved["bodyText"] == note, f"{action} lost the editable note when returning to the reader")
        require(preserved_original(saved, manifest, action) == created["original"],
                f"{action} note edit changed the saved original")
        require(client.request("cache.stats")["fixtureSends"] == 0
                and not client.request("operation.list")["operations"], f"{action} queued or submitted mail")
    require(client.process.returncode == 0 and not client.stderr, "formatted save child failed cleanup")
    return saved


class AcceptanceFailure(Exception):
    def __init__(self, message, diagnostics):
        super().__init__(message)
        self.diagnostics = diagnostics


def run_large_images(binary, directory, terminal_type=Terminal):
    manifest, _, _ = validate_fixture()
    directory.mkdir(mode=0o700, parents=True)
    source = LargeInlineFixture(directory)
    terminal = terminal_type(binary, directory, extra=source.options(), columns=160, rows=42,
                             screen_type=AcceptanceScreen,
                             environment={"NO_COLOR": None, "COLORTERM": "truecolor", "TZ": "UTC0"})
    stage = "large-inline-reader"
    saved = []
    try:
        terminal.until(lambda: accepted_reader(terminal, manifest)
                       and reader_contains(terminal.screen, "[Image: Fictional logo]"))
        require_available(terminal)
        with Client(binary, directory, extra=source.options()) as client:
            message = client.request("mail.read", messageId=GOOD, cacheOnly=True)
            photo = next(item for item in message["attachments"] if item["filename"] == LARGE_IMAGE_NAME)
            require(message["bodySource"] == "html" and photo["size"] == LARGE_IMAGE_BYTES and photo["data"] == "",
                    "ordinary reading refused or eagerly hydrated the large inline image")
        stage = "large-inline-drawer"
        terminal.send(b"B")
        terminal.until(lambda: not terminal.screen.frame_open and all(label in terminal.text() for label in
                                  ("Received attachments", LARGE_IMAGE_NAME, "5.2 MB")))
        terminal.send(b"\x1b")
        terminal.until(lambda: "Received attachments" not in terminal.text() and accepted_reader(terminal, manifest))

        def button_background(label):
            found = terminal.screen.locate(label)
            require(found is not None, "format-picker action disappeared")
            return terminal.screen.styles[found["row"]][found["column"]][1]

        def no_new_draft():
            with Client(binary, directory, extra=source.options()) as client:
                require({item["id"] for item in client.request("draft.list")["drafts"]} == {item["id"] for item in saved},
                        "disabled format action created a local draft")
                require(client.request("cache.stats")["fixtureSends"] == 0
                        and not client.request("operation.list")["operations"], "large-image picker queued or sent mail")

        for action, key in (("reply", b"r"), ("reply-all", b"R"), ("forward", b"f")):
            stage = "large-inline-" + action
            terminal.send(key)
            terminal.until(lambda: not terminal.screen.frame_open and "[Keep formatting k]" in terminal.text()
                           and LARGE_IMAGE_REASON in terminal.text())
            selected = button_background("[Text quote t]")
            require(selected != button_background("[Keep formatting k]"), "unavailable formatting retained default focus")
            terminal.send(b"k")
            terminal.gap(.08)
            no_new_draft()
            require(terminal.screen.mouse_tracking_mode in (1000, 1002, 1003)
                    and 1006 in terminal.screen.mouse_modes, "owned PTY has no active cell mouse reporting")
            found = terminal.screen.locate("[Keep formatting k]")
            terminal.send(f"\x1b[<0;{found['column'] + 1};{found['row'] + 1}M".encode())
            terminal.send(f"\x1b[<0;{found['column'] + 1};{found['row'] + 1}m".encode())
            terminal.gap(.08)
            no_new_draft()
            frame = terminal.screen.completed_frames
            terminal.send(b"\x1b[Z")
            terminal.until(lambda: terminal.screen.completed_frames > frame and not terminal.screen.frame_open
                           and button_background("[Back Esc/q]") == selected)
            frame = terminal.screen.completed_frames
            terminal.send(b"\t")
            terminal.until(lambda: terminal.screen.completed_frames > frame and not terminal.screen.frame_open
                           and button_background("[Text quote t]") == selected)
            if action == "forward":
                require(button_background("[Attach original .eml e]") != selected,
                        "definitely oversized original email retained an enabled action")
                terminal.send(b"e")
                terminal.until(lambda: "Original email exceeds 2 MiB · choose Text quote" in terminal.text())
                no_new_draft()
                terminal.send(b"\x1b")
                terminal.until(lambda: "[Keep formatting k]" not in terminal.text() and accepted_reader(terminal, manifest))
                continue
            if action == "reply-all":
                found = terminal.screen.locate("[Text quote t]")
                terminal.send(f"\x1b[<0;{found['column'] + 1};{found['row'] + 1}M".encode())
                terminal.send(f"\x1b[<0;{found['column'] + 1};{found['row'] + 1}m".encode())
            else:
                terminal.send(b"\r")  # The focused, enabled Text quote action.
            terminal.until(lambda: not terminal.screen.frame_open and "Compose" in terminal.screen.lines()[0]
                           and "Subject:" in terminal.text())
            note = f"Large-photo {action} note.\n\n"
            terminal.send(b"\x07i\x1b[200~" + note.encode() + b"\x1b[201~")
            terminal.until(lambda: panel_contains(terminal, "Compose", note))
            terminal.send(b"\x1b")
            wait_saved_compose(terminal, 0)
            frame = terminal.screen.completed_frames
            terminal.send(b"q")
            terminal.until(lambda: terminal.screen.completed_frames > frame and not terminal.screen.frame_open
                           and "Compose" not in terminal.screen.lines()[0])
            terminal.send(b"\r")
            terminal.until(lambda: accepted_reader(terminal, manifest))
            with Client(binary, directory, extra=source.options()) as client:
                rows = client.request("draft.list")["drafts"]
                new = [item for item in rows if item["id"] not in {item["id"] for item in saved}]
                require(len(new) == 1, "Text quote did not create exactly one editable local draft")
                value = client.request("draft.read", draftId=new[0]["id"])
                require(value.get("original") is None and not value["attachments"] and value["bodyText"].startswith(note),
                        "Text quote hydrated the photo or lost the editable note")
                require(value["to"] == manifest["replyToExpected"]
                        and value["cc"] == (manifest["replyAllCcExpected"] if action == "reply-all" else []),
                        "large-image Text quote changed reply recipients")
                saved.append(value)
            no_new_draft()
        result = terminal.finish()
        result.update(largeInlineBytes=LARGE_IMAGE_BYTES, descriptorOnly=True, actualImagePlaceholder=True,
                      attachmentDrawerHumanSize="5.2 MB", disabledFormattingActions=["reply", "reply-all", "forward"],
                      disabledOriginalEmail=True, textQuoteNotesSaved=["reply", "reply-all"], forwardedPickerCancelled=True,
                      enabledTextQuoteMouseActivated=True, fixtureSends=0, operations=0)
        return result
    except Exception as failure:
        raise AcceptanceFailure(str(failure), {"stage": stage, "currentCells": terminal.screen.lines(),
                                "outputTail": bytes(terminal.output[-8192:]).decode("utf-8", "backslashreplace")}) from failure
    finally:
        terminal.close()


def run_case(binary, directory, terminal_type=Terminal):
    manifest, legacy, draft = validate_fixture()
    directory.mkdir(mode=0o700, parents=True)
    source = ProviderFixture(directory)
    account = seed_cache(directory, draft)
    terminal = None
    stage = "legacy-cache-migration"
    result = {}
    formatted = []
    try:
        terminal = terminal_type(binary, directory, extra=source.options(), columns=160, rows=42, screen_type=AcceptanceScreen,
                                 environment={"NO_COLOR": None, "COLORTERM": "truecolor", "TZ": "UTC0"})
        terminal.until(lambda: source.entered.exists())
        terminal.until(lambda: terminal.screen.completed_frames > 0 and not terminal.screen.frame_open
                       and "Mock provider" in terminal.screen.lines()[0])
        migrated = index(account)
        require(migrated.get("decoderRevision", 0) > 0, "normal TUI startup did not migrate the legacy decoder revision")
        require(all(not entry["bodyError"] for entry in migrated["entries"]),
                "normal TUI startup retained an old decoder's body refusal")
        require(migrated["syncBodyGets"] == legacy["syncBodyGets"],
                "provider gate did not isolate migration before incoming body fetches")
        preserved(migrated, legacy)
        require(migrated["serial"] == legacy["serial"], "decoder migration changed the draft serial")
        source.hold.unlink()

        stage = "refresh-full-body"
        terminal.send(b"\x12")  # The normal Ctrl+R mail refresh shortcut.
        terminal.until(lambda: index(account)["lastSyncAt"] > 0
                       and index(account)["syncBodyGets"] >= legacy["syncBodyGets"] + 2)
        terminal.until(lambda: accepted_reader(terminal, manifest))
        require_available(terminal)
        warmed = index(account)
        require(warmed["syncBodyGets"] == legacy["syncBodyGets"] + 2,
                "refresh did not fetch each recovered legacy body exactly once")
        require(entries(warmed)[GOOD]["bytes"] > 0 and not entries(warmed)[GOOD]["bodyError"],
                "accepted provider full body was not persisted")
        require(entries(warmed)[INVALID]["bytes"] == 0
                and entries(warmed)[INVALID]["bodyError"] == "BodySizeMismatch",
                "refresh accepted the genuinely truncated neighboring body")
        preserved(warmed, legacy)

        stage = "reopen-reader-and-document"
        terminal.send(b"\r")
        terminal.until(lambda: accepted_reader(terminal, manifest))
        require_available(terminal)
        terminal.send(b"B")
        terminal.until(lambda: all(text in terminal.text() for text in
                                  ("Received attachments", manifest["documentFilename"],
                                   manifest["documentHumanSize"], "[s Save]")))
        require("No received attachments" not in terminal.text()
                and "Body unavailable" not in terminal.text(), "document drawer still presents refused mail")

        stage = "keyboard-save-exact-document"
        terminal.send(b"s")
        terminal.until(lambda: "Save attachment · new file" in terminal.text()
                       and "Path:" in terminal.text() and "[Save]" in terminal.text())
        destination = directory / "saved contract.rtf"
        terminal.send(b"\x15" + str(destination).encode() + b"\r")
        terminal.until(lambda: destination.exists() and "Save attachment · new file" not in terminal.text())
        require(destination.read_bytes() == manifest["documentExpected"].encode(),
                "keyboard Save changed the external document's literal bytes")
        require(destination.stat().st_mode & 0o077 == 0, "received document is not owner-only")
        terminal.until(lambda: accepted_reader(terminal, manifest))
        require_available(terminal)

        for action in ("reply", "reply-all", "forward"):
            stage = "formatted-" + action
            formatted.append(formatted_action(binary, directory, source, terminal, manifest, action,
                                               {draft["id"], *(value["id"] for value in formatted)}))

        stage = "visible-refusal-and-revisit"
        terminal.send(b"J")  # Normal adjacent-mail navigation from the reader.
        terminal.until(lambda: reader_contains(terminal.screen, "Body unavailable")
                       and reader_contains(terminal.screen, "BodySizeMismatch"))
        require(not reader_contains(terminal.screen, "Unrecoverable truncated message."),
                "refused mail rendered the truncated body")
        terminal.send(b"K")
        terminal.until(lambda: accepted_reader(terminal, manifest))
        before_repeat = index(account)

        stage = "same-revision-refusal-does-not-loop"
        terminal.send(b"\x12")
        terminal.until(lambda: index(account)["syncCalls"] > before_repeat["syncCalls"]
                       and index(account)["lastSyncAt"] > before_repeat["lastSyncAt"])
        terminal.until(lambda: accepted_reader(terminal, manifest))
        require(index(account)["syncBodyGets"] == warmed["syncBodyGets"],
                "normal refresh retried an unchanged decoder refusal or accepted cached body")
        require_available(terminal)
        result["firstSession"] = terminal.finish()
        terminal.close()
        terminal = None

        stage = "cached-cli-and-unsent-draft"
        first = index(account)
        with Client(binary, directory, extra=source.options()) as client:
            cached = client.request("mail.read", messageId=GOOD, cacheOnly=True)
            require(cached["bodyText"] == manifest["plainExpected"]
                    and cached["bodyHtml"] == manifest["htmlExpected"],
                    "persisted provider plain/HTML body differs from independent literal oracles")
            require(cached["bodyCached"] is True and len(cached["attachments"]) == 2,
                    "cache-only contract lost its body or external document")
            document = cached["attachments"][0]
            # The first immutable FULL cache record retains lazy external
            # descriptors. Save and formatted forward above independently
            # prove the fetched bytes; cache-only read proves their identity.
            require(document["id"] == "provider-external-document"
                    and document["filename"] == manifest["documentFilename"]
                    and document["mimeType"] == "application/rtf"
                    and document["size"] == manifest["documentDecodedBytes"],
                    "cached external document metadata changed")
            if document["data"]:
                require(decode(document["data"]) == manifest["documentExpected"].encode(),
                        "cached embedded document bytes changed")
            retained = client.request("draft.read", draftId=draft["id"])
            require(all(retained[key] == value for key, value in draft.items()),
                    "decoder upgrade changed the unsent local draft")
            require(client.request("mail.read", messageId=INVALID, cacheOnly=True, ok=False)["code"] == "CacheMiss",
                    "refused body unexpectedly became readable from cache")
            for value in formatted:
                require(client.request("draft.read", draftId=value["id"]) == value,
                        "saved formatted draft changed during later reader actions")
        require(client.process.returncode == 0 and not client.stderr, "cache verification child failed cleanup")
        require((account / f"draft-{hashlib.sha256(draft['id'].encode()).hexdigest()}.json").read_bytes()
                == (FIXTURE / "legacy-draft.json").read_bytes(), "decoder recovery rewrote the local draft file")
        preserved(index(account), legacy, (value["id"] for value in formatted))

        stage = "restart-cached-reader"
        terminal = terminal_type(binary, directory, extra=source.options(), columns=160, rows=42, screen_type=AcceptanceScreen,
                                 environment={"NO_COLOR": None, "COLORTERM": "truecolor", "TZ": "UTC0"})
        terminal.until(lambda: accepted_reader(terminal, manifest))
        require_available(terminal)
        terminal.send(b"\r")
        terminal.until(lambda: accepted_reader(terminal, manifest))
        terminal.send(b"B")
        terminal.until(lambda: all(text in terminal.text() for text in
                                  ("Received attachments", manifest["documentFilename"],
                                   manifest["documentHumanSize"])))
        terminal.send(b"\x1b")
        terminal.until(lambda: "Received attachments" not in terminal.text()
                       and accepted_reader(terminal, manifest))
        result["restartedSession"] = terminal.finish()
        terminal.close()
        terminal = None
        last = index(account)
        preserved(last, legacy, (value["id"] for value in formatted))
        require(last["decoderRevision"] == first["decoderRevision"], "restart changed the accepted decoder revision")
        require(last["generation"] >= first["generation"], "restart reset the cache generation")
        require(last["syncBodyGets"] == first["syncBodyGets"], "restart refetched cached or same-revision refused bodies")
        require(entries(last)[INVALID]["bodyError"] == "BodySizeMismatch", "restart forgot the current decoder refusal")
        with Client(binary, directory, extra=source.options()) as restarted:
            for value in formatted:
                require(restarted.request("draft.read", draftId=value["id"]) == value,
                        "restart lost a local formatted draft's editable note or original resources")
            require(restarted.request("cache.stats")["fixtureSends"] == 0,
                    "restart submitted a locally saved formatted draft")
        require(restarted.process.returncode == 0 and not restarted.stderr, "draft recovery child failed cleanup")
        result.update(legacySchema=1, legacyDecoderRevision=0, decoderRevision=last["decoderRevision"],
                      actualReaderBody=True, externalDocumentFilename=manifest["documentFilename"],
                      externalDocumentHumanSize=manifest["documentHumanSize"], exactKeyboardSave=True,
                      externalDocumentSha256=hashlib.sha256(destination.read_bytes()).hexdigest(),
                      preservedUnsentDraft=True, preservedLabels=True, preservedHistory=True,
                      preservedArrivalCount=last["inboxArrivalCount"], generationBefore=legacy["generation"],
                      generationAfter=last["generation"], recoveredBodyFetches=last["syncBodyGets"] - legacy["syncBodyGets"],
                      stillInvalidRefused=True, repeatedRefusalBodyFetches=0, restartBodyFetches=0,
                      formattedActions=["reply", "reply-all", "forward"], preservedInlineImageCid=True,
                      editableNotesSaved=True, outgoingPreviewsChecked=True, formattedDraftsSent=0)
        return result
    except Exception as failure:
        state = index(account)
        diagnostics = {"stage": stage,
                       "cache": {key: state.get(key) for key in (*COUNTERS, "generation", "decoderRevision", "historyId", "inboxArrivalCount")},
                       "bodyRefusals": {message_id: entry["bodyError"] for message_id, entry in entries(state).items()},
                       "currentCells": terminal.screen.lines() if terminal is not None else [],
                       "outputTail": bytes(terminal.output[-8192:]).decode("utf-8", "backslashreplace") if terminal is not None else ""}
        raise AcceptanceFailure(str(failure), diagnostics) from failure
    finally:
        if terminal is not None:
            terminal.close()
        source.hold.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--build-mode", type=build_mode)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--fixture-only", action="store_true")
    parser.add_argument("--case", choices=("all", "legacy", "large-images"), default="all")
    args = parser.parse_args()
    validate_fixture()
    if args.fixture_only:
        print("PASS literal provider fixture: nested BOM-size text, exact external document, genuine truncation and legacy refusal")
        return 0
    require(args.binary is not None, "--binary is required unless --fixture-only is used")
    require(sys.platform in ("linux", "darwin"), "owned PTY acceptance supports Linux and macOS")
    require(args.receipt is None or not args.receipt.exists(), "refusing to overwrite a previous acceptance receipt")
    terminal_type = Terminal
    if sys.platform == "darwin":
        from terminal_macos import DarwinTerminal
        terminal_type = DarwinTerminal
    binary = args.binary.resolve()
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    receipt = {"schemaVersion": 1, "suite": "terminal-mail-acceptance", "passed": False,
               "syntheticOnly": True, "liveProviderWrites": 0, "desktopUsed": False,
               "platform": sys.platform, "architecture": platform.machine(),
               "guardianTty": sys.platform == "darwin", "binarySha256": digest,
               **read_build_info(binary, args.build_mode)}
    try:
        with tempfile.TemporaryDirectory(prefix="omagma-mail-acceptance-") as temporary:
            # Darwin's /var is a symlink; the file dialog requires the real path.
            root = Path(temporary).resolve()
            if args.case in ("all", "legacy"):
                receipt["result"] = run_case(binary, root / "owned", terminal_type)
            if args.case in ("all", "large-images"):
                receipt["largeInlineImages"] = run_large_images(binary, root / "owned-large", terminal_type)
        require(hashlib.sha256(binary.read_bytes()).hexdigest() == digest, "tested binary changed during acceptance")
        receipt["passed"] = True
    except Exception as failure:
        receipt["error"] = f"{type(failure).__name__}: {failure}"
        if isinstance(failure, AcceptanceFailure):
            receipt["diagnostics"] = failure.diagnostics
    if args.receipt:
        args.receipt.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
        args.receipt.chmod(0o600)
    if not receipt["passed"]:
        print(json.dumps(receipt, ensure_ascii=False, indent=2), file=sys.stderr)
        return 1
    print("PASS provider mail TUI: legacy recovery, full body, document save, formatted reply/reply-all/forward, refusal and restart")
    print(json.dumps(receipt, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
