#!/usr/bin/env python3
"""Forward failure diagnostics and shortcuts in a synthetic owned terminal."""
import argparse
import base64
import copy
import json
from pathlib import Path
import tempfile

from terminal_cache import ProviderFixture
from terminal_integration import ACCOUNTS, Client, require
from terminal_mouse import start


def exercise(binary, directory):
    fixture = ProviderFixture(directory)
    body = b"A fictional message.\nUNAVAILABLE-FORWARD-FILE"
    for account in ACCOUNTS:
        message = next(item for item in fixture.data[account]["baseline"]["messages"] if item["id"] == "shared-msg-096")
        plain = copy.deepcopy(message["payload"])
        plain.update(partId="0", mimeType="text/plain", filename="", parts=[],
                     headers=[{"name": "Content-Type", "value": "text/plain; charset=utf-8"}],
                     body={"size": len(body), "data": base64.urlsafe_b64encode(body).decode().rstrip("=")})
        message["payload"].update(mimeType="multipart/mixed", body={"size": 0, "data": ""}, parts=[plain,
            {"partId": "1", "mimeType": "image/jpeg", "filename": "fictional-image.jpg",
             "headers": [{"name": "Content-Disposition", "value": "inline; filename=fictional-image.jpg"}],
             "body": {"size": 7, "attachmentId": "unavailable-fixture-attachment"}}])
        for header in message["payload"]["headers"]:
            if header["name"].lower() == "content-type": header["value"] = "multipart/mixed; boundary=forward-ux"
        fixture.stage(account, "baseline")
    with Client(binary, directory, extra=fixture.options()) as client:
        client.request("mail.refresh", limit=32, prefetchLimit=32)
    terminal = start(binary, directory, fixture, columns=100, rows=32)
    try:
        terminal.forward_stage="mailbox-body-and-forward-hint"
        terminal.until(lambda: "UNAVAILABLE-FORWARD-FILE" in terminal.text() and "f Forward" in terminal.screen.lines()[-2])
        footer = terminal.screen.lines()[-2]
        require("f Forward" in footer, "Forward shortcut missing from actual mailbox footer")
        terminal.forward_stage="unavailable-forward-diagnostic"
        terminal.send(b"f")
        terminal.until(lambda: "AttachmentNotFound" in terminal.text()
                       and "An attachment could not be retrieved" in terminal.text())
        require("An attachment could not be retrieved" in terminal.text(), "forward error lacks readable explanation")
        terminal.send(b"?")
        terminal.until(lambda: "Diagnostic: AttachmentNotFound" in terminal.text() and "NAVIGATION" in terminal.text())
        code = terminal.screen.locate("Diagnostic: AttachmentNotFound")
        help_heading = terminal.screen.locate("NAVIGATION")
        require(code["row"] < help_heading["row"], "diagnostic remains hidden below Help instructions")
        terminal.forward_stage="help-return-original-body"
        terminal.send(b"\x1b")
        terminal.gap(.05)
        terminal.until(lambda: "Keyboard & mouse" not in terminal.text()
                       and "UNAVAILABLE-FORWARD-FILE" in terminal.text())
        require("UNAVAILABLE-FORWARD-FILE" in terminal.text(), "Help return lost originating message")
        with Client(binary, directory, extra=fixture.options()) as client:
            require(client.request("draft.list")["drafts"] == [], "failed forward created a partial draft")
            require(client.request("cache.stats")["fixtureSends"] == 0, "forward failure submitted mail")
        return terminal.finish()
    except Exception:
        print(json.dumps({"stage":getattr(terminal,"forward_stage","forward"),
                          "currentCells":terminal.screen.lines(),"outputBytes":terminal.output_total}))
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="omagma-forward-ux-") as temporary:
        result = exercise(args.binary.resolve(), Path(temporary))
    print(json.dumps({"passed": True, "syntheticOnly": True, "forwardHint": True,
                      "visibleDiagnostic": True, "helpBanner": True, **result}))


if __name__ == "__main__": main()
