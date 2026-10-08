#!/usr/bin/env python3
"""Composer focus/preview and literal native file UX in owned fixture PTYs."""
import argparse
import base64
import copy
import json
from pathlib import Path
import tempfile

from terminal_cache import ProviderFixture
from terminal_integration import ACCOUNTS, Client, require
from terminal_mouse import start

FIRST = b"First received preview file\n"
SECOND = b"Second received preview file\n"
URI = "https://example.test/compose-preview?literal=1"
ATTACH_TITLE = "Attach file · local draft"
SAVE_TITLE = "Save attachment · new file"


def fixture_setup(binary, directory):
    source = ProviderFixture(directory)
    for account in ACCOUNTS:
        message = next(value for value in source.data[account]["baseline"]["messages"] if value["id"] == "shared-msg-096")
        text = "\n".join(f"PREVIEW LINE {number:03} · literal fictional text for keyboard scrolling." for number in range(120)) + f"\n{URI}\n"
        plain = copy.deepcopy(message["payload"])
        plain.update(partId="0", headers=[{"name": "Content-Type", "value": "text/plain; charset=utf-8"}],
                     body={"size": len(text.encode()), "data": base64.urlsafe_b64encode(text.encode()).decode().rstrip("=")})
        mixed = message["payload"]
        mixed.update(mimeType="multipart/mixed", body={"size": 0, "data": ""}, parts=[plain])
        for header in mixed["headers"]:
            if header["name"].lower() == "content-type":
                header["value"] = "multipart/mixed; boundary=polish-preview"
        for number, (name, data) in enumerate((("preview-one.txt", FIRST), ("preview-two.txt", SECOND)), 1):
            mixed["parts"].append({"partId": str(number), "mimeType": "application/octet-stream", "filename": name,
                "headers": [{"name": "Content-Disposition", "value": f'attachment; filename="{name}"'}],
                "body": {"size": len(data), "data": base64.urlsafe_b64encode(data).decode().rstrip("=")}})
        source.stage(account, "baseline")
    with Client(binary, directory, extra=source.options()) as client:
        client.request("mail.refresh", limit=40, prefetchLimit=40)
        client.request("mail.read", messageId="shared-msg-096")
    return source


def panel_text(terminal, title):
    found = None
    for row_number, cells in enumerate(terminal.screen.cells):
        row_text = "".join(cells)
        if title in row_text and any(character in row_text for character in "╭┌╔"):
            found = {"row": row_number, "column": row_text.index(title)}
            break
    require(found is not None, "actual expected panel title missing")
    row = terminal.screen.cells[found["row"]]
    left = next((column for column in range(found["column"], -1, -1) if row[column] in "╭┌╔"), None)
    right = next((column for column in range(found["column"], terminal.columns) if row[column] in "╮┐╗"), None)
    require(left is not None and right is not None, "panel border missing from current cells")
    bottom = next((index for index in range(found["row"] + 1, terminal.rows)
                   if terminal.screen.cells[index][left] in "╰└╚"), terminal.rows - 2)
    return "\n".join("".join(terminal.screen.cells[index][left + 1:right]) for index in range(found["row"] + 1, bottom))


def prompt_contains(terminal, name):
    return any("Path:" in line and name in line for line in terminal.screen.lines())


def draft(binary, directory, source):
    with Client(binary, directory, extra=source.options()) as client:
        values = client.request("draft.list")["drafts"]
        require(len(values) == 1, "composer changed local draft identity/count")
        value = client.request("draft.read", draftId=values[0]["id"])
        require(client.request("cache.stats")["fixtureSends"] == 0, "polish workflow sent mail")
        return value


def compose_case(binary, directory):
    source = fixture_setup(binary, directory)
    picks = directory / "attach picks"
    picks.mkdir(mode=0o700)
    payloads = {"alpha notes.txt": b"First outgoing fixture\n", "alpha summary.txt": b"Second outgoing fixture\n"}
    for name, data in payloads.items():
        (picks / name).write_bytes(data)
    (picks / "alpha-link.txt").symlink_to(picks / "alpha notes.txt")
    terminal = start(binary, directory, source, columns=160, rows=40)
    try:
        terminal.until(lambda: "PREVIEW LINE 000" in terminal.text())
        terminal.send(b"r")
        terminal.until(lambda: "Compose" in terminal.text() and "Subject:" in terminal.text())
        original = draft(binary, directory, source)
        original_id = original["id"]
        require(original["bodyFormat"] == "markdown", "fresh reply did not select Markdown")
        terminal.until(lambda: "Outgoing preview" in terminal.text() and "[Plain Ctrl+T]" in terminal.text())
        # Recipient/subject line starts are explicit. The untouched fresh body
        # caret must already be above the quote, so do not move it to hide a bug.
        terminal.send(b"i\x01" + b"\x1b[3~" * 256 + b"alex@example.test\t\t\t"
                      + b"\x01" + b"\x1b[3~" * 256 + b"Polish composer fixture\t"
                      + b"LB literal typing")
        terminal.until(lambda: "Body: INSERT" in terminal.text() and "LB literal typing" in terminal.text())
        require("Received attachments" not in terminal.text() and "Links · explicit" not in terminal.text(), "typing L/B opened a preview picker")
        body = terminal.screen.locate("Body: INSERT")
        from_row = terminal.screen.locate("From:")
        require(terminal.screen.styles[body["row"]][body["column"]][1] != terminal.screen.styles[from_row["row"]][from_row["column"]][1], "Body focus lacks the selected-row background")
        require(terminal.screen.styles[body["row"]][70][1] == terminal.screen.styles[body["row"]][body["column"]][1], "Body highlight does not cover its full row")
        require(terminal.screen.styles[from_row["row"]][from_row["column"]][2] is False, "From is styled like a focused field")
        require("Ctrl+S Review" not in panel_text(terminal, "Compose"), "composer has an extra in-pane shortcut footer")
        terminal.send(b"\x1b")
        terminal.gap(.05)
        terminal.send(b"p")
        terminal.until(lambda: "Original message" in terminal.text())
        preview_before = panel_text(terminal, "Original message")
        require("PREVIEW LINE 000" in preview_before, "original preview did not start with expected body")
        terminal.send(b"\x04")
        terminal.until(lambda: "PREVIEW LINE 000" not in panel_text(terminal, "Original message"))
        require("PREVIEW LINE" in panel_text(terminal, "Original message"), "keyboard preview scroll erased the body")
        terminal.send(b"\x15")
        terminal.until(lambda: "PREVIEW LINE 000" in panel_text(terminal, "Original message"))
        terminal.send(b"?")
        terminal.until(lambda: "NAVIGATION" in terminal.text())
        terminal.send(b"\x1b")
        terminal.gap(.05)
        terminal.until(lambda: "NAVIGATION" not in terminal.text() and "Subject:" in terminal.text())
        terminal.send(b"L")
        terminal.until(lambda: "Links · explicit browser open" in terminal.text() and URI in terminal.text())
        terminal.send(b"\x1b")
        terminal.gap(.05)
        terminal.until(lambda: "Links · explicit browser open" not in terminal.text() and "Subject:" in terminal.text())
        for number, expected in enumerate(payloads, 1):
            terminal.send(b"A")
            terminal.until(lambda: ATTACH_TITLE in terminal.text() and "Path:" in terminal.text())
            terminal.send(str(picks / "alp").encode() + b"\x06")
            terminal.until(lambda: "alpha notes.txt" in terminal.text() and "alpha summary.txt" in terminal.text()
                           and prompt_contains(terminal, "alpha ") and "Ctrl+F Complete" in terminal.text())
            require("alpha-link.txt" not in terminal.text(), "completion offered a symlink")
            # Tab changes control focus, preserving the common-prefix path;
            # Ctrl+F (or Ctrl+Shift+F) chooses a completed filename explicitly.
            terminal.send(b"\t")
            terminal.gap(.05)
            require(prompt_contains(terminal, "alpha "), "Tab replaced the path instead of focusing a control")
            terminal.send(b"\x1b[Z")
            terminal.send(b"\x06" if number == 1 else b"\x1b[102;6u")
            terminal.until(lambda expected=expected: prompt_contains(terminal, expected))
            terminal.send(b"\r")
            terminal.until(lambda number=number: f"Attachments {number}" in terminal.text())
        require("B [x]" in terminal.text(), "attachment size/remove controls run together")
        # Save a received file from the preview while the outgoing draft is
        # dirty. It must return to compose and retain body/files/account/id.
        terminal.send(b"B")
        terminal.until(lambda: "Received attachments" in terminal.text() and "preview-one.txt" in terminal.text())
        terminal.send(b"s")
        terminal.until(lambda: SAVE_TITLE in terminal.text() and "[Save]" in terminal.text() and "Path:" in terminal.text())
        received = directory / "home/Downloads/preview-one.txt"
        terminal.send(b"\r")
        terminal.until(lambda: received.exists() and "Subject:" in terminal.text() and "Received attachments" not in terminal.text())
        require(received.read_bytes() == FIRST, "compose preview saved the wrong received file")
        terminal.send(b"\x13")
        terminal.until(lambda: "Sending account:" in terminal.text() and "Review send" in terminal.text())
        require("personal@example.com" in terminal.text() and "alex@example.test" in terminal.text(),
                "reply review lost its actual sending identity or recipient")
        # This reply deliberately keeps its120-line quoted original. Outgoing
        # attachment review follows that body; visit those rows explicitly.
        for _ in range(8):
            if "Attachment 2: alpha summary.txt" in terminal.text():
                break
            terminal.send(b"\x1b[6~")
            terminal.gap(.08)
        terminal.until(lambda: "Attachment 1: alpha notes.txt" in terminal.text()
                       and "Attachment 2: alpha summary.txt" in terminal.text())
        retained = draft(binary, directory, source)
        require(retained["id"] == original_id and retained["bodyText"] == "LB literal typing" + original["bodyText"],
                "preview/picker changed draft identity, quote source or top-of-quote insertion")
        require(retained["bodyFormat"] == "markdown", "preview/picker changed draft format")
        require(retained["to"][0]["address"] == "alex@example.test", "preview/picker changed recipients")
        require([file["filename"] for file in retained["attachments"]] == list(payloads), "preview/picker lost outgoing files")
        for file in retained["attachments"]:
            data = base64.urlsafe_b64decode(file["data"] + "=" * (-len(file["data"]) % 4))
            require(data == payloads[file["filename"]], "Ctrl+F selected another outgoing file")
        terminal.finish()
        print("PASS polish compose:Body/From focus, one hints footer, explicit Original preview, top-of-quote insert, Tab controls/Ctrl+F files, received Save preserves draft")
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()


def incoming_case(binary, directory):
    source = fixture_setup(binary, directory)
    downloads = directory / "download area"
    downloads.mkdir(mode=0o700)
    config = directory / "config"
    config.mkdir(mode=0o700, exist_ok=True)
    (config / "user-dirs.dirs").write_text(f'XDG_DOWNLOAD_DIR="{downloads}"\n')
    existing = downloads / "preview-one.txt"
    existing.write_bytes(b"KEEP EXISTING")
    (downloads / "preview-one (1).txt").symlink_to(existing)
    alternative = directory / "alternative saves/nested folder"
    alternative.mkdir(mode=0o700, parents=True)
    terminal = start(binary, directory, source)
    try:
        terminal.until(lambda: "PREVIEW LINE 000" in terminal.text())
        terminal.send(b"Bs")
        terminal.until(lambda: SAVE_TITLE in terminal.text() and "preview-one (2).txt" in terminal.text() and "[Save]" in terminal.text())
        terminal.send(b"\r")
        fresh = downloads / "preview-one (2).txt"
        terminal.until(lambda: fresh.exists())
        require(fresh.read_bytes() == FIRST and existing.read_bytes() == b"KEEP EXISTING", "default collision overwrote an existing file")
        require(fresh.stat().st_mode & 0o077 == 0, "saved default file is not private")
        terminal.send(b"Bjs")
        terminal.until(lambda: SAVE_TITLE in terminal.text() and "Path:" in terminal.text())
        terminal.send(b"\x15" + str(alternative.parent / "nest").encode() + b"\x06")
        terminal.until(lambda: "nested folder/" in terminal.text())
        terminal.send(b"received explicit.txt\r")
        explicit = alternative / "received explicit.txt"
        terminal.until(lambda: explicit.exists())
        require(explicit.read_bytes() == SECOND, "completed literal save directory targeted another file")
        terminal.send(b"Bjs")
        terminal.until(lambda: SAVE_TITLE in terminal.text() and "Path:" in terminal.text())
        terminal.send(b"\x15" + str(explicit).encode() + b"\r")
        terminal.until(lambda: "PathAlreadyExists" in terminal.text() or "already exists" in terminal.text().lower())
        require(explicit.read_bytes() == SECOND, "explicit save overwrote its existing target")
        with Client(binary, directory, extra=source.options()) as client:
            require(client.request("cache.stats")["fixtureSends"] == 0, "received file UX sent mail")
        terminal.finish()
        print("PASS polish received files:XDG default, fresh collision name, Ctrl+U override, directory Ctrl+F completion, no overwrite")
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="omagma-polish-composer-") as temporary:
        for name, case in (("compose", compose_case), ("incoming", incoming_case)):
            directory = Path(temporary) / name
            directory.mkdir(mode=0o700)
            case(args.binary.resolve(), directory)


if __name__ == "__main__":
    main()
