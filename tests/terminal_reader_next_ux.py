#!/usr/bin/env python3
"""Owned synthetic PTYs for density, received alternatives and long threads."""
import argparse
import base64
import copy
import json
from pathlib import Path
import tempfile

from terminal_cache import ProviderFixture
from terminal_integration import ACCOUNTS, Client, require
from terminal_mouse import start
from terminal_reader import reader_contains, frame_title
from terminal_reader_context import command
from terminal_html import screen_capture


def capture(terminal, destination, name):
    if destination is not None:
        terminal.gap(.12)
        destination.mkdir(parents=True, exist_ok=True)
        (destination / f"{name}.json").write_text(json.dumps(screen_capture(terminal)) + "\n")


def part(kind, text, charset="utf-8"):
    data = text.encode(charset)
    return {"mimeType": kind, "filename": "", "headers": [
        {"name": "Content-Type", "value": f"{kind}; charset={charset}"}],
        "body": {"size": len(data), "data": base64.urlsafe_b64encode(data).decode().rstrip("=")}}


def fixture(binary, directory, long=False, large=False):
    source = ProviderFixture(directory)
    for account in ACCOUNTS:
        for message in source.data[account]["baseline"]["messages"]:
            number = int(message["id"].rsplit("-", 1)[1])
            if long and number >= 34:
                message["threadId"] = "reader-long-thread"
            message["snippet"] = f"METADATA-ONLY-{number:03}"
            root = message["payload"]
            body = f"OWNED-BODY-{number:03}\nPlain café body.\n"
            if large and number in (77, 78, 79, 96):
                body = f"OWNED-BODY-{number:03}\n" + "x" * (1_600_000 if number == 96 else 1_000_000)
            root["body"] = part("text/plain", body)["body"]
            if number == 96 and not long:
                root["mimeType"] = "multipart/alternative"
                root["body"] = {"size": 0, "data": ""}
                for header in root["headers"]:
                    if header["name"].lower() == "content-type":
                        header["value"] = "multipart/alternative; boundary=reader-choice"
                root["parts"] = [
                    part("text/plain", "PLAIN-ALTERNATIVE café €\nNoch eine lange Straße voller Wörter im Brief.\n", "iso-8859-15"),
                    part("text/html", '<h1>FORMATTED-ALTERNATIVE</h1><p>Safe semantic body.</p>'
                         '<img src="https://example.test/unloaded.png"><script>BAD-SCRIPT-TEXT</script>')]
            elif long and number in (75, 76, 95):
                plain = copy.deepcopy(root)
                plain["headers"] = [{"name": "Content-Type", "value": "text/plain; charset=utf-8"}]
                root["mimeType"] = "multipart/mixed"
                root["body"] = {"size": 0, "data": ""}
                for header in root["headers"]:
                    if header["name"].lower() == "content-type":
                        header["value"] = "multipart/mixed; boundary=reader-files"
                attachment = part("text/plain", f"Attachment owned by message {number}.")
                attachment["filename"] = f"owner-{number:03}.txt"
                attachment["headers"].append({"name": "Content-Disposition", "value": f'attachment; filename="owner-{number:03}.txt"'})
                root["parts"] = [plain, attachment]
        source.stage(account, "baseline")
    with Client(binary, directory, extra=source.options("--prefetch-bodies", "0")) as client:
        client.request("mail.refresh", limit=96, prefetchLimit=0)
        client.request("mail.read", messageId="shared-msg-096")
    return source


def alternatives(binary, directory, captures=None):
    source = fixture(binary, directory)
    preferences = directory / "ui" / "settings.json"
    terminal = start(binary, directory, source, extra=("--ui-file", str(preferences), "--prefetch-bodies", "0"), columns=100, rows=30)
    try:
        terminal.until(lambda: reader_contains(terminal.screen, "PLAIN-ALTERNATIVE café €"))
        capture(terminal, captures, "reader-plain-latin9")
        terminal.send(b"lp")
        terminal.until(lambda: reader_contains(terminal.screen, "FORMATTED-ALTERNATIVE"))
        require(not reader_contains(terminal.screen, "BAD-SCRIPT-TEXT"), "received HTML executed or exposed script text")
        require(not reader_contains(terminal.screen, "PLAIN-ALTERNATIVE"), "formatted choice still painted weak plain alternative")
        capture(terminal, captures, "reader-formatted")
        terminal.send(b"p")
        terminal.until(lambda: reader_contains(terminal.screen, "PLAIN-ALTERNATIVE café €"))
        terminal.resize(30, 16)
        command(terminal, "find lange STRASSE voller WÖRTER")
        terminal.until(lambda: "Find 1/1" in terminal.text())
        require(reader_contains(terminal.screen, "lange Straße voller Wörter"),
                "full case folding changed source bytes or lost a wrapped match")
        capture(terminal, captures, "reader-narrow-unicode-find")
        terminal.resize(100, 30)
        terminal.until(lambda: "Find 1/1" in terminal.text())
        terminal.send(b"\x1b")
        terminal.gap(.1)
        command(terminal, "density compact")
        terminal.until(lambda: "Density compact" in terminal.text())
        capture(terminal, captures, "reader-compact")
        terminal.send(b"H")
        terminal.until(lambda: reader_contains(terminal.screen, "To:"))
        capture(terminal, captures, "reader-expanded-headers")
        terminal.send(b"Hq")
        terminal.until(lambda: frame_title(terminal.screen, "Mail ·") is not None)
        title = frame_title(terminal.screen, "Mail ·")
        rows = terminal.screen.lines()
        require("Synthetic" in rows[title["row"] + 1] and "Synthetic" in rows[title["row"] + 2],
                "compact mail rows retained comfortable gaps")
        capture(terminal, captures, "reader-compact-mailbox")
        terminal.finish()
        require(json.loads(preferences.read_text())["density"] == "compact", "compact preference did not persist")
        print("PASS received Plain/Formatted, Latin-9 text, compact density and expandable headers")
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()


def windows(binary, directory, captures=None):
    source = fixture(binary, directory, long=True)
    with Client(binary, directory, extra=source.options("--prefetch-bodies", "0")) as client:
        latest = client.request("mail.thread", threadId="reader-long-thread", progressive=True, focusMessageId="shared-msg-096")
        require(latest["totalMessages"] == 63 and len(latest["messages"]) == 20 and latest["olderMessages"] == 43, "thread did not return bounded newest window")
        require(latest["deferredMessages"] == 19, "thread read bodies that were not selected")
        require(all(not message["bodyText"] and not message.get("bodyHtml") and not message["attachments"]
                    for message in latest["messages"][:-1]), "unopened fixture cards decoded or retained MIME bodies")
        require(latest["messages"][0]["id"] == "shared-msg-077" and latest["messages"][-1]["id"] == "shared-msg-096", "thread window is not in stable timestamp order")
        old = client.request("mail.thread", threadId="reader-long-thread", progressive=True, beforeMessageId="shared-msg-077")
        require(old["focusMessageId"] == "shared-msg-076" and old["olderMessages"] == 23 and old["newerMessages"] == 20, "older window lost exact continuation counts")
        require(old["messages"][-1]["attachments"][0]["filename"] == "owner-076.txt", "focused body lost its owning attachment")
        stale = client.request("mail.thread", ok=False, threadId="reader-long-thread", progressive=True, beforeMessageId="gone-member")
        require(stale["code"] == "ThreadWindowChanged", "missing stable boundary silently changed the window")
    terminal = start(binary, directory, source, extra=("--prefetch-bodies", "0"), columns=120, rows=32)
    try:
        terminal.until(lambda: reader_contains(terminal.screen, "OWNED-BODY-096"))
        terminal.send(b"\r")
        terminal.until(lambda: "63/63 mails" in terminal.text() and "window 44" in terminal.text())
        capture(terminal, captures, "reader-newest-window")
        terminal.send(b"[")
        terminal.until(lambda: "43/63 mails" in terminal.text() and reader_contains(terminal.screen, "OWNED-BODY-076"))
        capture(terminal, captures, "reader-older-window")
        terminal.send(b"{")
        terminal.until(lambda: reader_contains(terminal.screen, "OWNED-BODY-075"))
        terminal.send(b"B")
        terminal.until(lambda: "owner-075.txt" in terminal.text())
        require("owner-076.txt" in terminal.text(), "opening another card discarded already-read attachment identity")
        capture(terminal, captures, "reader-window-attachments")
        terminal.send(b"q]")
        terminal.until(lambda: "44/63 mails" in terminal.text() and reader_contains(terminal.screen, "OWNED-BODY-077"))
        terminal.finish()
        print("PASS 63-message progressive windows, exact counts, selected bodies and owning attachments")
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()


def focused_budget(binary, directory):
    source = fixture(binary, directory, long=True, large=True)
    with Client(binary, directory, extra=source.options("--prefetch-bodies", "0")) as client:
        for number in (77, 78, 79):
            client.request("mail.read", messageId=f"shared-msg-{number:03}")
        for cached in (False, True):
            window = client.request("mail.thread", threadId="reader-long-thread", progressive=True,
                                    focusMessageId="shared-msg-096", cacheOnly=cached)
            selected = window["messages"][-1]
            require(selected["id"] == "shared-msg-096" and selected["bodyCached"] and
                    len(selected["bodyText"]) > 1_600_000,
                    "cached neighbors consumed the selected message's thread allowance: " +
                    repr({"cachedRequest": cached, "id": selected["id"], "bodyCached": selected["bodyCached"],
                          "bodyBytes": len(selected["bodyText"]), "bodyCacheError": selected.get("bodyCacheError")}))
            require(any(message.get("bodyCacheError") == "ThreadBodyBudgetExceeded"
                        for message in window["messages"]), "large cached neighbors escaped the aggregate body bound")
    print("PASS selected long-thread body retains priority over MiB-scale cached neighbors")



def duplicate_owner(binary, directory, captures=None):
    source = fixture(binary, directory, long=True)
    expected = b"Exact attachment from later message 096.\n"
    for account in ACCOUNTS:
        for message in source.data[account]["baseline"]["messages"]:
            if message["id"] not in ("shared-msg-095", "shared-msg-096"):
                continue
            number = int(message["id"].rsplit("-", 1)[1])
            root = message["payload"]
            for header in root["headers"]:
                if header["name"].lower() == "from":
                    header["value"] = f"Owner {number} <owner{number}@example.test>"
            if number == 96:
                plain = part("text/plain", "OWNED-BODY-096\nLater message with its own invoice.\n")
                attachment = part("text/plain", expected.decode())
                root["mimeType"] = "multipart/mixed"
                root["body"] = {"size": 0, "data": ""}
                root["parts"] = [plain, attachment]
                for header in root["headers"]:
                    if header["name"].lower() == "content-type":
                        header["value"] = "multipart/mixed; boundary=duplicate-invoice"
            attachment = root["parts"][-1]
            attachment["filename"] = "invoice.pdf"
            attachment["headers"] = [{"name": "Content-Disposition", "value": 'attachment; filename="invoice.pdf"'}]
        source.stage(account, "baseline")
    with Client(binary, directory, extra=source.options("--prefetch-bodies", "0")) as client:
        client.request("cache.clear")
        client.request("mail.refresh", limit=96, prefetchLimit=0)
        for number in (95, 96):
            client.request("mail.read", messageId=f"shared-msg-{number:03}")
    terminal = start(binary, directory, source, extra=("--prefetch-bodies", "0"), columns=100, rows=30)
    try:
        terminal.until(lambda: reader_contains(terminal.screen, "OWNED-BODY-096"))
        terminal.send(b"\r")
        terminal.until(lambda: "63/63 mails" in terminal.text())
        terminal.send(b"B")
        terminal.until(lambda: "Owner 95" in terminal.text() and "Owner 96" in terminal.text()
                       and terminal.text().count("invoice.pdf") >= 2)
        capture(terminal, captures, "reader-later-card-duplicate-attachments")
        destination = directory / "selected-later-invoice.pdf"
        terminal.send(b"s")
        terminal.until(lambda: "Save attachment · new file" in terminal.text())
        terminal.send(b"\x15" + str(destination).encode() + b"\r")
        terminal.until(lambda: destination.exists() and "Save attachment · new file" not in terminal.text())
        require(destination.read_bytes() == expected, "B selected the earlier card's same-name attachment")
        terminal.finish()
        print("PASS later-card B selects its own duplicate-name attachment, with visible owner and date")
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--case", choices=("alternatives", "windows", "budget", "duplicate-owner", "all"), default="all")
    parser.add_argument("--capture-dir", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="omagma-reader-next-") as temp:
        root = Path(temp)
        if args.case in ("alternatives", "all"):
            alternatives(args.binary.resolve(), root / "alternatives", args.capture_dir)
        if args.case in ("windows", "all"):
            windows(args.binary.resolve(), root / "windows", args.capture_dir)
        if args.case in ("duplicate-owner", "all"):
            duplicate_owner(args.binary.resolve(), root / "duplicate-owner", args.capture_dir)
        if args.case in ("budget", "all"):
            focused_budget(args.binary.resolve(), root / "budget")


if __name__ == "__main__":
    main()
