#!/usr/bin/env python3
"""Fictional invitation CLI regressions; run under the cooperative host lock.

The source fixture corpus is copied before changes. No real mailbox, browser,
credentials or provider write is used. --old-binary additionally qualifies the
targeted upgrade of a metadata-only invitation body cached by an older build.
"""
from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import json
from pathlib import Path
import re
import shutil
import tempfile

from terminal_integration import ACCOUNTS, Client, FIXTURES, addresses, require


POSITIVE = ("named-calendar", "named-octet", "named-application", "duplicate", "wide")
STATUSES = ("accepted", "tentative", "declined")
CASE_NAMES = ("formats", "refusals", "replay", "unknown", "legacy")


def encoded(value):
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


def identity(case, account):
    key = account.split("@")[0]
    return {"uid": f"{case}-{key}@example.test", "organizer": f"organizer-{key}@example.test",
            "attendee": account, "sequence": 7, "recurrenceId": "20261012T100000"}


def invitation(case, account, attendee=None, wide=False, method="REQUEST", extra_event=False):
    expected = identity(case, account)
    lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Fixture//Provider-shaped calendar//EN",
             f"METHOD:{method}", "BEGIN:VTIMEZONE", "TZID:W. Europe Standard Time",
             "BEGIN:STANDARD", "DTSTART:19700101T000000", "TZOFFSETFROM:+0100", "TZOFFSETTO:+0100",
             "END:STANDARD", "END:VTIMEZONE", "BEGIN:VEVENT", f"UID:{expected['uid']}",
             "DTSTAMP:20261007T090000Z", "SEQUENCE:7", "SUMMARY:Fictional calendar meeting",
             'DTSTART;TZID="W. Europe Standard Time":20261012T100000',
             'DTEND;TZID="W. Europe Standard Time":20261012T110000',
             'RECURRENCE-ID;TZID="W. Europe Standard Time":20261012T100000',
             f'ORGANIZER;CN="Fixture Host: Department":MAILTO:{expected["organizer"]}']
    if wide:
        lines += [f'ATTENDEE;CN="Guest {number}";RSVP=TRUE:mailto:guest{number}@example.test'
                  for number in range(80)]
    lines += [f'ATTENDEE;CN="Fixture, Guest; Department";ROLE=REQ-PARTICIPANT;RSVP=TRUE:MAILTO:{attendee or account}',
              "DESCRIPTION:Join this fictional meeting at https://teams.microsoft.com/",
              " l/meetup-join/fictional", "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT15M",
              "DESCRIPTION:Fixture reminder", "END:VALARM", "END:VEVENT"]
    if extra_event:
        lines += ["BEGIN:VEVENT", "UID:unrelated@example.test", "END:VEVENT"]
    return "\r\n".join(lines + ["END:VCALENDAR", ""]).encode()


def part(kind, value=None, filename="", external=None):
    headers = [{"name": "Content-Type", "value": kind + ('; charset=utf-8; method="REQUEST"' if kind == "text/calendar" else "")}]
    if filename:
        headers.append({"name": "Content-Disposition", "value": f'attachment; filename="{filename}"'})
    body = {"size": len(value or b"")}
    if external:
        body["attachmentId"] = external
    else:
        body["data"] = encoded(value or b"")
    return {"partId": "calendar", "mimeType": kind, "filename": filename, "headers": headers, "body": body}


class InvitationFixture:
    def __init__(self, directory):
        self.root = Path(directory) / "provider"
        shutil.copytree(FIXTURES, self.root)
        self.sources = {}
        self.downloads = {}
        for account in ACCOUNTS:
            source = json.loads(self.path(account).read_text())
            template = copy.deepcopy(source["messages"][0])
            for case in (*POSITIVE, "conflicting", "html-only", "foreign", "publish", "multi-event"):
                message = copy.deepcopy(template)
                message_id = "invite-" + case
                message.update(id=message_id, threadId=message_id + "-thread", labelIds=["INBOX", "UNREAD"],
                               snippet="Fictional invitation fixture " + case)
                calendar = invitation(case, account, wide=case == "wide",
                                      attendee=ACCOUNTS[(ACCOUNTS.index(account) + 1) % len(ACCOUNTS)] if case == "foreign" else None,
                                      method="PUBLISH" if case == "publish" else "REQUEST",
                                      extra_event=case == "multi-event")
                envelope = [{"name": "From", "value": "Fixture Forwarder <forwarder@example.test>"},
                            {"name": "Reply-To", "value": "Wrong RSVP address <ordinary-reply@example.test>"},
                            {"name": "To", "value": account},
                            {"name": "Subject", "value": "Fictional " + case},
                            {"name": "Message-ID", "value": f"<{message_id}-{account.split('@')[0]}@example.test>"}]
                if case == "html-only":
                    payload = part("text/html", b'<p>Zoom copied invitation</p><a href="https://example.zoom.us/j/00000000000">Join Zoom Meeting</a>')
                elif case in ("duplicate", "conflicting"):
                    repeated = calendar.replace(b"\r\n", b"\n").rstrip(b"\n")
                    # The duplicate has different physical folds and newlines
                    # while retaining every logical calendar line.
                    repeated = repeated.replace(b"DESCRIPTION:Join this fictional", b"DESCRIPTION:Join this \n fictional")
                    if case == "conflicting":
                        repeated = repeated.replace(b"SEQUENCE:7", b"SEQUENCE:8")
                    payload = {"partId": "", "mimeType": "multipart/mixed", "filename": "", "headers": [],
                               "body": {"size": 0}, "parts": [part("text/calendar", calendar),
                                                                part("application/octet-stream", repeated, "invite.ics")]}
                else:
                    kind = {"named-calendar": "text/calendar", "named-octet": "application/octet-stream",
                            "named-application": "application/ics"}.get(case, "text/calendar")
                    external_id = "download-" + case
                    payload = part(kind, calendar, "invite.ics", external_id)
                    self.downloads[(account, case)] = {"size": len(calendar), "data": encoded(calendar)}
                    source.setdefault("externalBodies", {})[external_id] = self.downloads[(account, case)]
                payload["headers"] = envelope + payload["headers"]
                message["payload"] = payload
                source["messages"].append(message)
            self.sources[account] = source
            self.save(account)

    def path(self, account):
        return self.root / "accounts" / (account.split("@")[0] + ".json")

    def save(self, account):
        self.path(account).write_text(json.dumps(self.sources[account], ensure_ascii=False) + "\n")

    def options(self):
        return ("--fixture-root", str(self.root), "--prefetch-bodies", "0")

    def legacy_download(self, account, case, present):
        downloads = self.sources[account].setdefault("externalBodies", {})
        key = "download-" + case
        if present:
            downloads[key] = self.downloads[(account, case)]
        else:
            downloads.pop(key, None)
        self.save(account)


def inspect_identity(value, case, account):
    for key, expected in identity(case, account).items():
        require(value.get(key) == expected, f"{case}: invitation inspection changed {key}")
    require(value["summary"] == "Fictional calendar meeting", f"{case}: summary was lost")


def reply_identity(receipt, case, account, status, operation_id):
    expected = identity(case, account)
    lines = receipt["icalendar"].replace("\r\n", "\n").splitlines()
    for line in ("BEGIN:VCALENDAR", "VERSION:2.0", "METHOD:REPLY", "BEGIN:VEVENT", "END:VEVENT", "END:VCALENDAR",
                 f'UID:{expected["uid"]}', "SEQUENCE:7", f'ORGANIZER:mailto:{expected["organizer"]}',
                 f'ATTENDEE;PARTSTAT={status.upper()}:mailto:{account}',
                 'RECURRENCE-ID;TZID="W. Europe Standard Time":20261012T100000'):
        require(line in lines, f"{case}/{status}: reply lost literal {line}")
    require(sum(line.startswith("ATTENDEE") for line in lines) == 1, "RSVP included another attendee")
    stamps = [line for line in lines if line.startswith("DTSTAMP:")]
    require(len(stamps) == 1 and re.fullmatch(r"DTSTAMP:\d{8}T\d{6}Z", stamps[0]), "RSVP omitted a UTC timestamp")
    expected_wire = hashlib.sha256((account + "\0" + operation_id).encode()).hexdigest()
    require(receipt["rfcMessageId"] == f"<omagma-{expected_wire}@mail.invalid>", "RSVP wire identity lost account/operation binding")
    require(receipt["id"] == operation_id and len(receipt["hash"]) == 64, "RSVP operation journal identity invalid")


def finished(client):
    require(client.process.returncode == 0 and not client.stderr, "invitation CLI child failed clean cleanup")


def body_digest(directory, message_id, account=ACCOUNTS[0]):
    account_key = hashlib.sha256(account.encode()).hexdigest()
    message_key = hashlib.sha256(message_id.encode()).hexdigest()
    path = Path(directory) / "cache" / "fixtures" / account_key / ("mail-" + message_key + ".json")
    require(path.is_file(), "independent cached body oracle is missing")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def formats(binary, directory, source):
    with Client(binary, directory, extra=source.options()) as client:
        for case in POSITIVE:
            before = client.request("cache.stats")
            inspect_identity(client.request("invitation.inspect", messageId="invite-" + case), case, ACCOUNTS[0])
            require(client.request("cache.stats")["fixtureSends"] == before["fixtureSends"], "inspection sent RSVP")
            message = client.request("mail.read", messageId="invite-" + case, cacheOnly=True)
            require(message.get("invitation") is not None, "calendar discovery did not persist the body")
            if case.startswith("named-"):
                attachment = client.request("mail.attachment", messageId=message["id"], attachmentId=message["attachments"][0]["id"])
                data = attachment.get("data") or attachment.get("base64")
                wire = base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))
                require(wire == invitation(case, ACCOUNTS[0]), "calendar discovery changed downloadable .ics bytes")
            for status in STATUSES:
                operation_id = f"rsvp-{case}-{status}"
                result = client.request("invitation.reply", messageId=message["id"], status=status, operationId=operation_id)
                require(result["outcome"] == "applied", "fixture RSVP did not apply")
                reply_identity(result, case, ACCOUNTS[0], status, operation_id)
                require(client.request("operation.read", operationId=operation_id) == result, "RSVP receipt was not journaled")
                sent = client.request("mail.read", messageId=result["messageId"], cacheOnly=True)
                require(addresses(sent["to"]) == [identity(case, ACCOUNTS[0])["organizer"]], "RSVP used email From/Reply-To instead of organizer")
                require(sent["from"]["address"] == ACCOUNTS[0] and sent["messageId"] == result["rfcMessageId"], "sent wire identity changed")
                require(sent["invitation"] == result["icalendar"], "outbox lost its reviewed calendar response")
        require(client.request("cache.stats")["fixtureSends"] == 15, "format cases submitted an unexpected number of replies")
        inspect_identity(client.request("invitation.inspect", ACCOUNTS[1], messageId="invite-named-calendar"), "named-calendar", ACCOUNTS[1])
        require(client.request("cache.stats", ACCOUNTS[1])["fixtureSends"] == 0, "another account inherited sends")
        require(client.request("operation.list", ACCOUNTS[1])["operations"] == [], "another account inherited RSVP receipts")
        operation_id = "rsvp-named-calendar-accepted"
        personal = client.request("operation.read", operationId=operation_id)
        work = client.request("invitation.reply", ACCOUNTS[1], messageId="invite-named-calendar", status="accepted", operationId=operation_id)
        reply_identity(work, "named-calendar", ACCOUNTS[1], "accepted", operation_id)
        require(work["rfcMessageId"] != personal["rfcMessageId"], "equal operation IDs across accounts shared a wire identity")
        require(client.request("operation.read", operationId=operation_id) == personal, "another account overwrote the personal receipt")
        require(client.request("cache.stats")["fixtureSends"] == 15, "work RSVP altered personal send accounting")
    finished(client)


def refusals(binary, directory, source):
    with Client(binary, directory, extra=source.options()) as client:
        client.request("mail.read", messageId="invite-named-calendar")
        # Both comparison responses come from the cache: provider reads report
        # bodyCached=false, whereas explicit cached reads report true. Keep the
        # complete response oracle and also guard the immutable on-disk bytes.
        good = client.request("mail.read", messageId="invite-named-calendar", cacheOnly=True)
        digest = body_digest(directory, good["id"])
        for case, expected in (("conflicting", "AmbiguousCalendarPart"), ("html-only", "NotInvitation"),
                               ("foreign", "NotAnAttendee"), ("publish", "NotInvitationRequest"),
                               ("multi-event", "AmbiguousInvitation")):
            before = client.request("operation.list")["operations"]
            for command, params in (("invitation.inspect", {}), ("invitation.reply", {"status": "accepted", "operationId": "refused-" + case})):
                error = client.request(command, messageId="invite-" + case, ok=False, **params)
                require(error["code"] == expected, f"{case}: refused with an unexpected error {error['code']}")
            require(client.request("operation.list")["operations"] == before, "invalid invitation created a submission record")
            require(client.request("mail.read", messageId=good["id"], cacheOnly=True) == good, "refusal changed valid cached mail")
            require(body_digest(directory, good["id"]) == digest, "refusal rewrote immutable cached body bytes")
        require(client.request("cache.stats")["fixtureSends"] == 0, "refused invitation sent a response")
        error = client.request("invitation.reply", ACCOUNTS[1], messageId="invite-foreign", status="accepted",
                               operationId="wrong-selected-account", ok=False)
        require(error["code"] == "NotAnAttendee", "foreign configured attendee authorized the selected account")
        require(client.request("operation.list", ACCOUNTS[1])["operations"] == [], "foreign account rejection created a receipt")
    finished(client)


def replay(binary, directory, source):
    with Client(binary, directory, extra=source.options()) as client:
        params = {"messageId": "invite-named-calendar", "status": "accepted", "operationId": "known-rsvp"}
        first = client.request("invitation.reply", **params)
        reply_identity(first, "named-calendar", ACCOUNTS[0], "accepted", params["operationId"])
        before = client.request("cache.stats")
        require(client.request("invitation.reply", **params) == first, "completed RSVP replay changed the receipt")
        error = client.request("invitation.reply", **{**params, "status": "declined"}, ok=False)
        require(error["code"] == "OperationConflict", "operation ID reuse changed RSVP meaning")
        require(client.request("cache.stats")["fixtureSends"] == before["fixtureSends"], "replay/conflict resent RSVP")
        client.restart()
        require(client.request("invitation.reply", **params) == first, "restart replay changed the receipt")
        after = client.request("cache.stats")
        require(after["fixtureSends"] == 1 and after["fixtureCalls"] == before["fixtureCalls"], "restart redispatched a completed RSVP")
        require(client.request("operation.list")["operations"] == [first], "known RSVP duplicated its journal entry")
    finished(client)


def unknown(binary, directory, source):
    for scenario, sends in (("unknown-send", 0), ("applied-lost", 1)):
        with Client(binary, directory / scenario, scenario=scenario, extra=source.options()) as client:
            params = {"messageId": "invite-named-octet", "status": "tentative", "operationId": "uncertain-rsvp"}
            first = client.request("invitation.reply", **params)
            require(first["outcome"] == "unknown", "lost response claimed a known outcome")
            reply_identity(first, "named-octet", ACCOUNTS[0], "tentative", params["operationId"])
            before = client.request("cache.stats")
            require(before["fixtureSends"] == sends, "fault scenario has the wrong actual send count")
            for operation_id in (params["operationId"], "new-id-same-uncertain-rsvp"):
                require(client.request("invitation.reply", **{**params, "operationId": operation_id}) == first,
                        "unknown RSVP was redispatched or re-journaled")
            client.restart()
            require(client.request("invitation.reply", **{**params, "operationId": "after-restart-uncertain-rsvp"}) == first,
                    "restart permitted a new operation ID to resend uncertain RSVP")
            after = client.request("cache.stats")
            require(after["fixtureCalls"] == before["fixtureCalls"] and after["fixtureSends"] == sends,
                    "uncertain RSVP retry reached the provider")
            require(client.request("operation.list")["operations"] == [first], "unknown RSVP duplicated its journal")
        finished(client)


def legacy(binary, old_binary, directory, source):
    for case in ("named-calendar", "named-octet"):
        account, other = ACCOUNTS[:2]
        cache = directory / case
        # The fixture executor bypasses live Gmail attachment retrieval. Its
        # old text/calendar seed must therefore omit the unresolved download,
        # reproducing the old live path's metadata-only named attachment. The
        # old octet-stream path needs no omission: it fails discovery itself.
        if case == "named-calendar":
            source.legacy_download(account, case, False)
        try:
            with Client(old_binary, cache, extra=source.options()) as client:
                old = client.request("mail.read", account, messageId="invite-" + case)
                require(old.get("invitation") is None and len(old["attachments"]) == 1,
                        "old binary did not seed a genuine invitation-null named attachment")
                client.request("mail.read", account, messageId="shared-msg-001")
                unrelated = client.request("mail.read", account, messageId="shared-msg-001", cacheOnly=True)
                unrelated_digest = body_digest(cache, "shared-msg-001", account)
                client.request("mail.read", other, messageId="shared-msg-001")
                before = client.request("cache.stats", account)
                foreign = client.request("cache.stats", other)
            finished(client)
        finally:
            source.legacy_download(account, case, True)
        with Client(binary, cache, extra=source.options()) as client:
            unchanged = client.request("mail.read", account, messageId="invite-" + case, cacheOnly=True)
            require(unchanged.get("invitation") is None, "ordinary cached reading performed an unsolicited upgrade")
            require(client.request("mail.read", account, messageId="shared-msg-001", cacheOnly=True) == unrelated,
                    "cache upgrade changed unrelated mail")
            require(body_digest(cache, "shared-msg-001", account) == unrelated_digest,
                    "targeted upgrade rewrote unrelated immutable cache bytes")
            require(client.request("cache.stats", account)["fixtureCalls"] == before["fixtureCalls"], "ordinary cached browsing reached provider")
            inspect_identity(client.request("invitation.inspect", account, messageId="invite-" + case), case, account)
            after = client.request("cache.stats", account)
            require(after["fixtureCalls"] == before["fixtureCalls"] + 1, "legacy inspection did not refetch exactly one message")
            upgraded = client.request("mail.read", account, messageId="invite-" + case, cacheOnly=True)
            require(upgraded.get("invitation") is not None, "targeted refetch did not upgrade cached ICS bytes")
            require(client.request("cache.stats", other)["fixtureCalls"] == foreign["fixtureCalls"], "cache upgrade fetched another account")
            client.restart()
            inspect_identity(client.request("invitation.inspect", account, messageId="invite-" + case), case, account)
            stable = client.request("cache.stats", account)
            require(stable["fixtureCalls"] == after["fixtureCalls"] and stable["fixtureSends"] == 0,
                    "persisted cache upgrade refetched or sent a response")
            require(client.request("operation.list", account)["operations"] == [], "cache upgrade created a send journal")
        finished(client)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--old-binary", type=Path)
    parser.add_argument("--case", choices=("all", *CASE_NAMES), default="all")
    args = parser.parse_args()
    binary = args.binary.resolve()
    old_binary = args.old_binary.resolve() if args.old_binary else None
    require(binary.is_file(), "test binary does not exist")
    if old_binary:
        require(old_binary.is_file(), "old test binary does not exist")
    for name in CASE_NAMES:
        if args.case not in ("all", name):
            continue
        if name == "legacy" and old_binary is None:
            print("SKIP invitations legacy: supply --old-binary to qualify the previous-build cache upgrade")
            continue
        with tempfile.TemporaryDirectory(prefix="omagma-invitations-") as temporary:
            directory = Path(temporary)
            source = InvitationFixture(directory)
            if name == "legacy":
                legacy(binary, old_binary, directory / "client", source)
            else:
                globals()[name](binary, directory / "client", source)
            print(f"PASS invitations {name}: synthetic CLI, recorded identity and bounded account-scoped state")


if __name__ == "__main__":
    main()
