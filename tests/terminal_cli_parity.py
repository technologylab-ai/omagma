#!/usr/bin/env python3
"""Fixture-only one-shot/JSONL parity checks; run under the cooperative lock.

Uses copied fictional provider data and an isolated home/cache. It never opens
a real browser/viewer, obtains credentials or sends to a live provider. The
invitation suite separately qualifies prior-build cache upgrades and MIME
refusals; these cases exercise the user-facing one-shot mappings as well.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import traceback
from urllib.parse import parse_qs, urlsplit

from build_info import build_mode, read_build_info
from terminal_integration import (
    ACCOUNTS, Client, FIXTURES, MANIFEST, MAX_FRAME, ROOT, addresses,
    no_core_dump, one_shot_cached_server_search, require,
)
from terminal_invitations import (
    InvitationFixture, finished, identity, inspect_identity, part, reply_identity,
)


CASES = ("invitations", "uncertainty", "permissions", "browser", "attachments", "search-labels")
PROFILES = ("Profile 3", "Profile 1", "Profile 2")


def one_shot(client, family, verb, arguments=(), account=ACCOUNTS[0], stdin=b"", error=None):
    argv = [str(client.binary), family, verb, "--fixtures", "--fixture-root", str(FIXTURES),
            "--cache-dir", str(client.directory / "cache")]
    if client.scenario:
        argv += ["--fixture-scenario", client.scenario]
    argv += list(client.extra)
    if account is not None:
        argv += ["--account", account]
    argv += list(arguments)
    result = subprocess.run(argv, input=stdin, capture_output=True, cwd=client.directory,
                            env=client.environment, timeout=12, preexec_fn=no_core_dump)
    require(len(result.stdout) < MAX_FRAME and len(result.stderr) < 16384,
            "one-shot output exceeded bounded diagnostic/frame limits")
    require(b"\x1b" not in result.stdout and b"\x00" not in result.stdout,
            "one-shot stdout contained raw terminal controls")
    if error and not result.stdout:
        require(result.returncode != 0 and error.encode() in result.stderr,
                f"one-shot parser did not reject input with {error}")
        return None
    lines = result.stdout.splitlines()
    require(len(lines) == 1, "one-shot stdout was not exactly one protocol frame")
    reply = json.loads(lines[0])
    require(reply.get("version") == 1 and reply.get("ok") is (error is None),
            "one-shot response omitted protocol version or disagreed with expected outcome")
    require((result.returncode == 0) is (error is None), "one-shot exit status disagreed with outcome")
    if account is not None:
        require(reply.get("account") == account, "one-shot response lost selected account")
    if error:
        require(reply.get("error", {}).get("code") == error, f"one-shot omitted error {error}")
        return reply["error"]
    require(not result.stderr and "data" in reply, "successful one-shot response wrote diagnostics or lost data")
    return reply["data"]


def invitations(binary, directory):
    source = InvitationFixture(directory)
    with Client(binary, directory / "client", extra=source.options()) as client:
        for case in ("named-calendar", "named-application", "named-octet"):
            flags = ["--message-id", "invite-" + case]
            inspected = one_shot(client, "invitations", "inspect", flags)
            inspect_identity(inspected, case, ACCOUNTS[0])
            require(client.request("invitation.inspect", messageId="invite-" + case) == inspected,
                    "one-shot invitation inspection differed from JSONL")
            for status in ("accepted", "tentative", "declined"):
                operation_id = f"one-shot-{case}-{status}"
                parameters = {"messageId": "invite-" + case, "status": status, "operationId": operation_id}
                result = one_shot(client, "invitations", "reply",
                                  [*flags, "--status", status, "--operation-id", operation_id])
                require(result["outcome"] == "applied", "one-shot fixture RSVP did not apply")
                reply_identity(result, case, ACCOUNTS[0], status, operation_id)
                before = client.request("cache.stats")
                require(client.request("invitation.reply", **parameters) == result,
                        "JSONL replay did not reuse the one-shot RSVP receipt")
                require(one_shot(client, "invitations", "reply",
                                 [*flags, "--status", status, "--operation-id", operation_id]) == result,
                        "separate one-shot process did not replay the completed RSVP receipt")
                require(one_shot(client, "operation", "read", ["--operation-id", operation_id]) == result,
                        "one-shot operation read lost the journaled RSVP")
                sent = one_shot(client, "mail", "read", ["--message-id", result["messageId"], "--cached"])
                require(addresses(sent["to"]) == [identity(case, ACCOUNTS[0])["organizer"]],
                        "one-shot RSVP replied to email From/Reply-To rather than calendar organizer")
                require(sent["from"]["address"] == ACCOUNTS[0] and sent["invitation"] == result["icalendar"],
                        "one-shot RSVP changed sender or reviewed calendar bytes")
                require(client.request("cache.stats")["fixtureSends"] == before["fixtureSends"],
                        "receipt inspection or mixed-interface replay resent RSVP")
        require(client.request("cache.stats")["fixtureSends"] == 9, "one-shot statuses submitted wrong reply count")
        shared_operation = "one-shot-named-calendar-accepted"
        personal = client.request("operation.read", operationId=shared_operation)
        work = one_shot(client, "invitations", "reply", ["--message-id", "invite-named-calendar",
                        "--status", "accepted", "--operation-id", shared_operation], account=ACCOUNTS[1])
        reply_identity(work, "named-calendar", ACCOUNTS[1], "accepted", shared_operation)
        require(work["rfcMessageId"] != personal["rfcMessageId"], "equal operation IDs leaked wire identity across accounts")
        require(client.request("operation.read", operationId=shared_operation) == personal,
                "one-shot reply overwrote another account's journal")
        one_shot(client, "invitations", "reply", ["--message-id", "invite-named-calendar", "--status", "declined",
                 "--operation-id", shared_operation], error="OperationConflict")
        for case, error in (("html-only", "NotInvitation"), ("foreign", "NotAnAttendee"),
                            ("publish", "NotInvitationRequest"), ("multi-event", "AmbiguousInvitation"),
                            ("conflicting", "AmbiguousCalendarPart")):
            one_shot(client, "invitations", "reply", ["--message-id", "invite-" + case, "--status", "accepted",
                     "--operation-id", "refused-" + case], error=error)
        for flags, error in ((["--message-id", "invite-named-calendar", "--status", "cancelled", "--operation-id", "bad-status"], "InvalidInvitationStatus"),
                             (["--message-id", "invite-named-calendar", "--status", "accepted"], "MissingField")):
            one_shot(client, "invitations", "reply", flags, error=error)
        require(client.request("cache.stats")["fixtureSends"] == 9, "invalid one-shot RSVP sent a response")
        require(len(client.request("operation.list")["operations"]) == 9, "invalid RSVP created a journal entry")
    finished(client)


def uncertainty(binary, directory):
    source = InvitationFixture(directory)
    for scenario, sends in (("unknown-send", 0), ("applied-lost", 1)):
        with Client(binary, directory / scenario, scenario=scenario, extra=source.options()) as client:
            flags = ["--message-id", "invite-named-octet", "--status", "tentative"]
            first = one_shot(client, "invitations", "reply", [*flags, "--operation-id", "uncertain-one-shot"])
            require(first["outcome"] == "unknown", "one-shot lost-response scenario claimed certainty")
            reply_identity(first, "named-octet", ACCOUNTS[0], "tentative", "uncertain-one-shot")
            before = client.request("cache.stats")
            for operation_id in ("uncertain-one-shot", "changed-id-one-shot"):
                require(one_shot(client, "invitations", "reply", [*flags, "--operation-id", operation_id]) == first,
                        "one-shot retry redispatched uncertain RSVP")
            client.restart()
            require(client.request("invitation.reply", messageId="invite-named-octet", status="tentative",
                                   operationId="changed-id-jsonl") == first,
                    "restart/mixed-interface retry duplicated uncertain RSVP")
            after = client.request("cache.stats")
            require(after["fixtureCalls"] == before["fixtureCalls"] and after["fixtureSends"] == sends,
                    "unknown RSVP retry reached provider")
            require(client.request("operation.list")["operations"] == [first], "unknown RSVP duplicated journal entry")
        finished(client)


def permissions(binary, directory):
    source = InvitationFixture(directory)
    with Client(binary, directory / "client", scenario="readonly", extra=source.options()) as client:
        accounts = client.request("accounts.list", account=None)["accounts"]
        require(all(value["capabilities"] == ["mail-read"] for value in accounts),
                "read-only fixture advertised terminal write capabilities")
        inspected = one_shot(client, "invitations", "inspect", ["--message-id", "invite-named-calendar"])
        inspect_identity(inspected, "named-calendar", ACCOUNTS[0])
        before = client.request("cache.stats")
        for account in ACCOUNTS:
            account_before = client.request("cache.stats", account)
            one_shot(client, "invitations", "reply", ["--message-id", "invite-named-calendar", "--status", "accepted",
                     "--operation-id", "readonly-rsvp"], account=account, error="PermissionDenied")
            require(client.request("operation.list", account)["operations"] == [], "denied RSVP created a receipt")
            account_after = client.request("cache.stats", account)
            require(account_after["fixtureCalls"] == account_before["fixtureCalls"] and account_after["fixtureSends"] == 0,
                    "one account's denied RSVP used a provider call or inherited a write grant")
        one_shot(client, "invitations", "inspect", ["--message-id", "invite-named-calendar"],
                 account=None, error="MissingField")
        one_shot(client, "invitations", "inspect", ["--message-id", "invite-named-calendar"],
                 account="foreign@example.test", error="UnknownAccount")
        after = client.request("cache.stats")
        require(after["fixtureCalls"] == before["fixtureCalls"] and after["fixtureSends"] == 0,
                "denied or implicit-account RSVP reached provider")
    finished(client)


def browser(binary, directory):
    extra = ("--config", str(ROOT / "tests/fixtures/all-accounts.json"), "--prefetch-bodies", "0")
    with Client(binary, directory / "client", extra=extra) as client:
        for account, profile in zip(ACCOUNTS, PROFILES):
            url = "https://example.test/meeting?id=42#join"
            jsonl = client.request("browser.open", account, url=url)
            require(one_shot(client, "mail", "open-link", ["--url", url], account) == jsonl,
                    "one-shot link target/profile differed from JSONL")
            require(jsonl == {"opened": False, "fixture": True, "url": url, "profile": "--profile-directory=" + profile},
                    "fixture browser command launched or changed explicit account profile/link")
            opened = one_shot(client, "mail", "open", ["--message-id", "shared-msg-012"], account)
            require(opened == client.request("mail.open", account, messageId="shared-msg-012"),
                    "one-shot Gmail target differed from JSONL")
            parsed = urlsplit(opened["url"])
            require(opened["opened"] is False and opened["fixture"] is True and opened["profile"] == "--profile-directory=" + profile,
                    "Gmail target lost profile or opened a real browser")
            require(parsed.scheme == "https" and parsed.netloc == "mail.google.com"
                    and parse_qs(parsed.query).get("authuser") == [account] and parsed.fragment == "all/shared-thread-003",
                    "Gmail target lost selected account/thread identity")
        for url in ("javascript:alert(1)", "file:///tmp/private", "https://user:password@example.test/", "https://example.test/\n"):
            one_shot(client, "mail", "open-link", ["--url", url], error="InvalidTarget")
            require(client.request("browser.open", url=url, ok=False)["code"] == "InvalidTarget",
                    "JSONL link validation differed from one-shot")
        path = str(directory / "chosen-private.txt")
        result = one_shot(client, "mail", "open-attachment", ["--path", path])
        require(result == client.request("attachment.open", path=path) == {"opened": False, "fixture": True},
                "fixture attachment command launched a desktop viewer")
        one_shot(client, "mail", "open-attachment", ["--path", ""], error="MissingField")
        require(client.request("cache.stats")["fixtureSends"] == 0, "browser/attachment opening submitted mail")
    finished(client)


def decoded(attachment):
    require(type(attachment.get("size")) is int, "CLI converted exact byte count to display units")
    data = attachment.get("data") or attachment.get("base64")
    require(isinstance(data, str), "attachment response lost base64url data")
    raw = base64.b64decode(data + "=" * (-len(data) % 4), altchars=b"-_", validate=True)
    require(len(raw) == attachment["size"], "attachment byte count disagreed with decoded bytes")
    return raw


def attachments(binary, directory):
    source = InvitationFixture(directory)
    raw_body = "I&#39;ve kept literal entities. HÃ¤nsel Ã¼ber GrÃ¶ße.\n"
    account = ACCOUNTS[0]
    message = source.sources[account]["messages"][0].copy()
    message.update(id="literal-cli-body", threadId="literal-cli-thread")
    message["payload"] = part("text/plain", raw_body.encode())
    source.sources[account]["messages"].append(message)
    source.save(account)
    with Client(binary, directory / "client", extra=source.options()) as client:
        literal = one_shot(client, "mail", "read", ["--message-id", "literal-cli-body"])
        require(literal["bodyText"] == raw_body and client.request("mail.read", messageId="literal-cli-body")["bodyText"] == raw_body,
                "TUI display repair changed machine-readable plain-text bytes")
        received_message = client.request("mail.read", messageId="shared-msg-003")
        attachment_id = received_message["attachments"][0]["id"]
        received = one_shot(client, "mail", "attachment", ["--message-id", "shared-msg-003", "--attachment-id", attachment_id])
        require(received == client.request("mail.attachment", messageId="shared-msg-003", attachmentId=attachment_id),
                "one-shot attachment download differed from JSONL")
        raw = decoded(received)
        oracle = MANIFEST["attachmentExpected"]
        require(len(raw) == oracle["size"] and hashlib.sha256(raw).hexdigest() == oracle["sha256"]
                and received["filename"] == oracle["safeFilename"], "downloaded attachment failed independent byte/filename oracle")
        private_file = directory / "chosen-private.txt"
        with private_file.open("xb") as output:
            output.write(raw)
        private_file.chmod(0o600)
        require(private_file.read_bytes() == raw, "CLI caller's explicitly saved file changed download bytes")
        files = ((directory / "first.txt", b"x" * 1005), (directory / "second.bin", bytes(range(256)) * 41))
        for path, contents in files:
            path.write_bytes(contents)
            path.chmod(0o600)
        flags = ["--to", "recipient@example.test", "--subject", "Fictional multi-file compose", "--body-stdin"]
        for path, _ in files:
            flags += ["--attach-file", str(path)]
        draft = one_shot(client, "mail", "compose", flags, stdin=raw_body.encode())
        require(draft["bodyText"] == raw_body and addresses(draft["to"]) == ["recipient@example.test"],
                "one-shot compose changed recipients/body")
        require(client.request("draft.read", draftId=draft["id"]) == draft, "one-shot multi-file draft was not JSONL-readable")
        require(len(draft["attachments"]) == 2, "repeatable attach-file omitted a selected file")
        for attachment, (path, contents) in zip(draft["attachments"], files):
            require(attachment["filename"] == path.name and attachment["mimeType"] == "application/octet-stream"
                    and decoded(attachment) == contents, "one-shot attachment changed filename/type/bytes")
        sent = one_shot(client, "draft", "send", ["--draft-id", draft["id"], "--operation-id", "one-shot-multi-file"])
        require(sent["outcome"] == "applied", "fixture multi-file draft did not send")
        outbox = client.request("mail.read", messageId=sent["messageId"], cacheOnly=True)
        require(outbox["attachments"] == draft["attachments"] and outbox["bodyText"] == raw_body,
                "shared send path lost multi-file bytes or changed display-only text")
        one_shot(client, "mail", "attachment", ["--message-id", "shared-msg-003", "--attachment-id", attachment_id,
                 "--output-file", str(directory / "invented.txt")], error="UnknownOption")
        require(not (directory / "invented.txt").exists(), "invented output-file flag wrote a file")
        many = [item for _ in range(17) for item in ("--attach-file", str(files[0][0]))]
        one_shot(client, "mail", "compose", many, error="TooManyAttachments")
        require(client.request("cache.stats")["fixtureSends"] == 1, "invalid attachment input submitted mail")
    finished(client)


def search_labels(binary, directory):
    with Client(binary, directory / "client") as client:
        one_shot_cached_server_search(client)
        listed = one_shot(client, "mail", "labels")
        require(listed == client.request("labels.list"), "one-shot label list differed from JSONL")
        before = client.request("cache.stats")
        require(one_shot(client, "mail", "labels", ["--cached"]) == client.request("labels.list", cacheOnly=True),
                "cached label discovery differed between interfaces")
        require(client.request("cache.stats")["fixtureCalls"] == before["fixtureCalls"], "cached labels reached provider")
        one_shot(client, "mail", "mark", ["--message-id", "shared-msg-096", "--add-label", "Projects"])
        marked = client.request("mail.read", messageId="shared-msg-096")
        require("Label_demo" in marked["labels"], "one-shot label name did not resolve to existing provider ID")
        one_shot(client, "mail", "mark", ["--message-id", "shared-msg-096", "--remove-label", "Projects"])
        require("Label_demo" not in client.request("mail.read", messageId="shared-msg-096")["labels"],
                "one-shot remove-label did not use canonical ID")
        require(client.request("labels.create", name="Invented-Label", ok=False)["code"] == "UnsupportedCommand",
                "CLI silently added unsupported label definition creation")
        require(client.request("cache.stats")["fixtureSends"] == 0, "search/label assignment submitted mail")
    finished(client)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--case", choices=("all", *CASES), default="all")
    parser.add_argument("--build-mode", type=build_mode)
    parser.add_argument("--receipt", type=Path, help="Optional local JSON evidence destination")
    args = parser.parse_args()
    binary = args.binary.resolve()
    require(binary.is_file(), "test binary does not exist")
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    receipt = {"schemaVersion": 1, "suite": "terminal-cli-parity", "synthetic": True,
               "liveProviderWrites": 0, "binarySha256": digest,
               **read_build_info(binary, args.build_mode), "cases": []}

    def write_receipt():
        if args.receipt:
            args.receipt.parent.mkdir(parents=True, exist_ok=True)
            args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")

    for name in CASES:
        if args.case not in ("all", name):
            continue
        try:
            with tempfile.TemporaryDirectory(prefix="omagma-cli-parity-") as temporary:
                globals()[name.replace("-", "_")](binary, Path(temporary))
        except Exception:
            receipt["cases"].append({"name": name, "status": "failed", "traceback": traceback.format_exc()})
            write_receipt()
            raise
        receipt["cases"].append({"name": name, "status": "passed"})
        write_receipt()
        print(f"PASS CLI parity {name}: one-shot/JSONL fixture contracts")
    require(hashlib.sha256(binary.read_bytes()).hexdigest() == digest, "tested binary changed during the suite")
    receipt["binaryUnchanged"] = True
    write_receipt()


if __name__ == "__main__":
    main()
