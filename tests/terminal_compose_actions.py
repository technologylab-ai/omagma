#!/usr/bin/env python3
"""Visible composer actions in an owned PTY, fictional mail and mock browser only."""
import argparse
import json
from pathlib import Path
import tempfile

from build_info import read_build_info
from terminal_integration import Client, require
from terminal_mouse import click, point, report
from terminal_reader_editor import MouseTerminal
from terminal_compose_screen import ComposerScreen, check_compose_resize_oracle
from terminal_reader_next_ux import capture
from terminal_polish_compose import panel_text
from terminal_pty import send_review_ready, wait_saved_compose


def exercise(binary, root, captures):
    check_compose_resize_oracle()
    body = "## Visible preview\n\nComplete fictional body.\nLast line."
    with Client(binary, root) as client:
        draft = client.request("draft.create", draft={
            "to": [{"address": "reader@example.test"}], "subject": "Visible composer actions",
            "bodyText": body, "bodyFormat": "markdown"})
    terminal = MouseTerminal(binary, root, screen_type=ComposerScreen, columns=120, rows=40,
                             environment={"NO_COLOR": None, "COLORTERM": "truecolor"})
    try:
        terminal.until(lambda: terminal.ready())
        terminal.send(b"h")
        terminal.until(lambda: terminal.screen.locate("Drafts") is not None)
        click(terminal, *point(terminal, "Drafts"))
        terminal.until(lambda: "Visible composer actions" in terminal.text())
        terminal.gap(.5)  # Drain initial mailbox/label jobs before opening the draft.
        terminal.send(b"\r")
        terminal.until(lambda: "[P Preview in browser]" in terminal.text()
                       and "Local draft · no mail sent" in terminal.text())
        sizes = ((38, 24), (64, 24), (90, 30), (120, 40), (180, 50))
        for columns, rows in sizes:
            terminal.resize(columns, rows)
            terminal.until(lambda: terminal.screen.compose_geometry_ready()
                           and "[P Preview in browser]" in terminal.text()
                           and "[g Continue in Gmail]" in terminal.text())
            capture(terminal, captures, f"compose-actions-{columns}x{rows}")
        terminal.resize(64, 24)
        terminal.until(lambda: terminal.screen.compose_geometry_ready()
                       and "[P Preview in browser]" in terminal.text())
        terminal.send(b"p")
        terminal.until(lambda: "[Back]" in terminal.text())
        require("[P Preview in browser]" in terminal.text()
                and "[g Continue in Gmail]" in terminal.text(), "full preview hid native actions")
        capture(terminal, captures, "compose-actions-full-preview")
        # Preview scroll -> inline toggle -> Back -> browser: Enter opens only
        # a local HTML preview through the fixture browser implementation.
        terminal.send(b"\t\t\t\r")
        terminal.until(lambda: "Mock browser target validated" in terminal.text())
        previews = list(root.rglob("preview.html"))
        require(len(previews) == 1 and "Last line." in previews[0].read_text(),
                "keyboard browser button did not retain the complete body")
        terminal.send(b"q")
        terminal.until(lambda: "Subject:" in terminal.text())
        # INSERT must keep shortcut letters as authored text, with stable-width
        # labels that do not advertise currently inactive letter shortcuts.
        body_x, body_y = point(terminal, "Body:")
        click(terminal, body_x, body_y + 1)
        terminal.send(b"Pg")
        terminal.until(lambda: "[  Preview in browser]" in terminal.text())
        require("[  Continue in Gmail]" in terminal.text(), "INSERT advertised an active g shortcut")
        terminal.send(b"\x1b")
        terminal.gap(.1)
        click(terminal, *point(terminal, "To:"))
        terminal.send(b"\x05" + b"\x7f" * len("reader@example.test") + b"unfinished recipient <")
        terminal.until(lambda: "unfinished recipient <" in terminal.text())
        terminal.send(b"\x1b")
        terminal.gap(.1)
        preview_stamp = previews[0].stat().st_mtime_ns
        terminal.send(b"P")
        terminal.until(lambda: previews[0].stat().st_mtime_ns != preview_stamp
                       and "Mock browser target validated" in terminal.text())
        with Client(binary, root) as client:
            saved = client.request("draft.read", draftId=draft["id"])
            require(saved["recoveryFields"][0] == "unfinished recipient <",
                    "browser preview lost unfinished address text")
            require(saved["recoveryFields"][4] == body + "Pg", "INSERT shortcut letters changed the body")
            require(client.request("draft.gmail-info", draftId=draft["id"]).get("link") is None,
                    "preview unexpectedly uploaded a Gmail draft")
        # Complete the recipient, then exercise the mouse Gmail action. The
        # dialog itself is local review; only its explicit Upload row writes.
        click(terminal, *point(terminal, "To:"))
        terminal.send(b"\x05" + b"\x7f" * len("unfinished recipient <") + b"reader@example.test\x1b")
        terminal.gap(.1)
        click(terminal, *point(terminal, "[g Continue in Gmail]"))
        terminal.until(lambda: "Upload once" in terminal.text())
        with Client(binary, root) as client:
            require(client.request("draft.gmail-info", draftId=draft["id"]).get("link") is None,
                    "opening Gmail review performed an upload")
        terminal.send(b"\x1b")
        terminal.until(lambda: "[g Continue in Gmail]" in terminal.text())
        terminal.send(b"g")
        terminal.until(lambda: "Upload once" in terminal.text())
        terminal.send(b"j\r")
        terminal.until(lambda: "Draft is available in Gmail" in terminal.text())
        terminal.send(b"\x1b")
        terminal.until(lambda: "[g Gmail status]" in terminal.text())
        terminal.resize(120, 40)
        terminal.until(lambda: terminal.screen.compose_geometry_ready(gmail_status=True)
                       and "[g Gmail status]" in terminal.text())
        terminal.send(b"P")
        terminal.until(lambda: "Gmail may be newer" in terminal.text())
        capture(terminal, captures, "compose-actions-paused-local-preview")
        with Client(binary, root) as client:
            saved = client.request("draft.read", draftId=draft["id"])
            require(saved["gmailLink"]["paused"] and saved["bodyText"] == body + "Pg",
                    "paused browser preview changed local ownership or content")
        return {**terminal.finish(), "sizes": sizes, "nativeActionsVisible": True,
                "unfinishedRecipientsPreserved": True, "insertLettersAreText": True,
                "gmailRequiresExplicitUpload": True, "pausedPreviewIsSavedLocalCopy": True}
    except Exception:
        print(terminal.text())
        capture(terminal, captures, "compose-actions-failure")
        raise
    finally:
        terminal.close()


def preview_wheel(binary, root, captures):
    """Real wheel reports scroll only the visible preview; they never send."""
    body = "\n".join(f"WHEEL BODY {number:03} — fictional preview line." for number in range(90))
    terminal = MouseTerminal(binary, root, screen_type=ComposerScreen, columns=120, rows=32,
                             environment={"NO_COLOR": None, "COLORTERM": "truecolor"})
    try:
        terminal.until(lambda: terminal.ready()
                       and terminal.screen.mouse_tracking_mode == 1002)
        terminal.send(b"c")
        terminal.until(lambda: "Subject:" in terminal.text() and "Attachments 0" in terminal.text())
        terminal.send(b"ireader@example.test\t\t\tPreview wheel fixture\t"
                      + b"\x1b[200~" + body.encode() + b"\x1b[201~\x1b")
        terminal.until(lambda: "WHEEL BODY 089" in terminal.text() and "INSERT" not in terminal.text())
        terminal.send(b"\x14")
        terminal.until(lambda: "[Markdown Ctrl+T]" in terminal.text())
        wait_saved_compose(terminal, 0)
        with Client(binary, root) as client:
            drafts = client.request("draft.list")["drafts"]
            require(len(drafts) == 1, "preview fixture did not retain one draft")
            draft = client.request("draft.read", draftId=drafts[0]["id"])
            recovery = draft.get("recoveryFields") or []
            saved_body = recovery[4] if recovery else draft["bodyText"]
            require(saved_body == body and draft["bodyFormat"] == "plain",
                    "preview fixture source was not saved exactly")
        terminal.until(lambda: terminal.screen.compose_geometry_ready()
                       and "WHEEL BODY 000" in panel_text(terminal, "Draft preview"))
        # The existing side preview owns this wheel target, independently of
        # the editable body which contains the same text on the left.
        preview_point = (terminal.columns - 4, 8)
        report(terminal, *preview_point, button=65)
        terminal.until(lambda: "WHEEL BODY 000" not in panel_text(terminal, "Draft preview")
                       and "WHEEL BODY" in panel_text(terminal, "Draft preview"))
        report(terminal, *preview_point, button=64)
        terminal.until(lambda: "WHEEL BODY 000" in panel_text(terminal, "Draft preview"))
        terminal.resize(64, 24)
        terminal.until(lambda: terminal.screen.compose_geometry_ready())
        terminal.send(b"p")
        terminal.until(lambda: "[Back]" in terminal.text()
                       and "WHEEL BODY 000" in panel_text(terminal, "Draft preview"))
        report(terminal, terminal.columns - 4, 8, button=65)
        terminal.until(lambda: "WHEEL BODY 000" not in panel_text(terminal, "Draft preview")
                       and "WHEEL BODY" in panel_text(terminal, "Draft preview"))
        report(terminal, terminal.columns - 4, 8, button=64)
        terminal.until(lambda: "WHEEL BODY 000" in panel_text(terminal, "Draft preview"))
        terminal.send(b"q")
        terminal.until(lambda: terminal.screen.compose_geometry_ready())
        sizes = ((64, 24), (120, 32))
        for columns, rows in sizes:
            if (terminal.columns, terminal.rows) != (columns, rows):
                terminal.resize(columns, rows)
            terminal.until(lambda: terminal.screen.compose_geometry_ready())
            terminal.send(b"\x13")
            terminal.until(lambda: send_review_ready(terminal)
                           and "Sending account:" in terminal.text())
            review_point = (columns - 4, 7)
            for button in ("[Back]", "[y Send]"):
                report(terminal, *review_point, button=65)
                terminal.until(lambda: "Sending account:" not in terminal.text()
                               and "To:" not in terminal.text() and "Review send" in terminal.text())
                # A wheel on a fixed control must neither scroll nor activate
                # it. The following k must expose the third envelope line,
                # proving the wheel did not add another three-row movement.
                report(terminal, *point(terminal, button), button=65)
                terminal.send(b"k")
                terminal.until(lambda: "To:" in terminal.text() and "Review send" in terminal.text())
                report(terminal, *review_point, button=64)
                terminal.until(lambda: "Sending account:" in terminal.text())
            for _ in range(40):
                report(terminal, *review_point, button=65)
            terminal.until(lambda: "WHEEL BODY 089" in terminal.text()
                           and "Sending account:" not in terminal.text())
            bottom = panel_text(terminal, "Review send")
            # k then one wheel-down returns to the same final clamped page.
            terminal.send(b"k")
            terminal.until(lambda: panel_text(terminal, "Review send") != bottom)
            report(terminal, *review_point, button=65)
            terminal.until(lambda: panel_text(terminal, "Review send") == bottom)
            for _ in range(40):
                report(terminal, *review_point, button=64)
            terminal.until(lambda: "Sending account:" in terminal.text())
            capture(terminal, captures, f"compose-review-wheel-{columns}x{rows}")
            terminal.send(b"\x1b")
            terminal.until(lambda: terminal.screen.compose_geometry_ready())
        terminal.finish()
        with Client(binary, root) as client:
            saved = client.request("draft.read", draftId=draft["id"])
            require(saved["bodyText"] == body and saved["bodyFormat"] == "plain"
                    and [recipient["address"] for recipient in saved["to"]] == ["reader@example.test"]
                    and saved["subject"] == "Preview wheel fixture",
                    "preview scrolling changed the saved draft")
            require(client.request("cache.stats")["fixtureSends"] == 0,
                    "preview wheel sent mail")
            require(client.request("operation.list")["operations"] == []
                    and client.request("queue.list")["queue"] == [],
                    "preview wheel staged or dispatched a send")
        return dict(sidePreview=True, fullPreview=True, reviewSizes=sizes,
                    boundedReviewScroll=True, fixedControlsDoNotActivate=True, draftPreserved=True,
                    sends=0, queuedSends=0)
    except Exception:
        print(terminal.text())
        capture(terminal, captures, "compose-preview-wheel-failure")
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--captures", type=Path)
    parser.add_argument("--case", choices=("actions", "preview-wheel", "all"), default="all")
    args = parser.parse_args()
    binary = args.binary.resolve()
    print(json.dumps(read_build_info(binary)), flush=True)
    with tempfile.TemporaryDirectory(prefix="omagma-compose-actions-") as directory:
        root = Path(directory).resolve()
        result = exercise(binary, root, args.captures) if args.case != "preview-wheel" else {}
        if args.case != "actions":
            result["previewWheel"] = preview_wheel(binary, root / "preview-wheel", args.captures)
        print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
