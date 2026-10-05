#!/usr/bin/env python3
"""Regenerate public synthetic provider fixtures; never accesses an account."""
from __future__ import annotations

import base64
from email import policy
from email.parser import BytesParser
import hashlib
import json
from pathlib import Path
import quopri

ROOT = Path(__file__).resolve().parent
ACCOUNTS = ["personal@example.com", "work@example.com", "optional@example.com"]
TEXT = "Olá, fixture team 👋\nCafé costs €3.50.\nLiteral <b>text</b> stays text.\nLiteral =3D stays =3D.\n"
HTML = ('<html><head><style>body{display:none}</style><script>alert("fixture")</script></head>'
        '<body><h1>Synthetic invitation</h1><p>Café &amp; tea 👋</p>'
        '<img src="https://tracker.example.invalid/pixel">'
        '<a href="javascript:alert(1)">unsafe</a>'
        '<a href="https://docs.example.org/fixture">safe link</a></body></html>')
ATTACHMENT = b"Synthetic attachment only.\nNo private data.\nBinary fixture bytes: \x00\x01\x7f\x80\xff\n"


def b64url(data):
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def save_json(name, value):
    path = ROOT / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def part(message, part_id=""):
    result = {"partId": part_id, "mimeType": message.get_content_type(),
              "filename": message.get_filename() or "",
              "headers": [{"name": key, "value": value} for key, value in message.raw_items()],
              "body": {"size": 0}}
    if message.is_multipart():
        result["parts"] = [part(child, str(index) if not part_id else f"{part_id}.{index}")
                           for index, child in enumerate(message.iter_parts())]
    else:
        data = message.get_payload(decode=True) or b""
        result["body"] = {"size": len(data), "data": b64url(data)}
    return result


def raw_message(account, index, case="plain"):
    thread_start = ((index - 1) // 3) * 3 + 1
    from_self = index % 3 == 0
    headers = [f"From: Fixture account <{account}>" if from_self else "From: Alex Fixture <alex@example.org>",
               "To: alex@example.org, teammate@example.org" if from_self else f"To: {account}, teammate@example.org",
               f"Subject: Synthetic {account.split('@')[0]} thread {(index - 1) // 3:03}",
               f"Message-ID: <fixture-{index:03}-{account.split('@')[0]}@example.org>",
               "Date: Sat, 7 Nov 2026 09:00:00 +0000", "MIME-Version: 1.0"]
    if index > thread_start:
        parents = [f"<fixture-{i:03}-{account.split('@')[0]}@example.org>" for i in range(thread_start, index)]
        headers += ["References: " + " ".join(parents), "In-Reply-To: " + parents[-1]]
    if case == "reply-all":
        headers += ["Reply-To: Replies Fixture <replies@example.org>",
                    f"Cc: {account.upper()}, teammate@example.org, colleague@example.net",
                    "Bcc: hidden@example.org"]
    if case == "missing-message-id":
        headers = [h for h in headers if not h.startswith("Message-ID:")]
    if case == "encoded-display-name":
        encoded_name = "=?utf-8?B?Rml4dHVyZSwgQ2Fmw6k=?="
        headers[0] = f"From: {encoded_name} <{account}>"
        headers[1] = f"To: {encoded_name} <alex@example.org>, teammate@example.org"
    if case == "quoted-printable":
        headers += ["Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: quoted-printable"]
        body = quopri.encodestring(TEXT.encode()).decode()
    elif case == "base64":
        headers += ["Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: base64"]
        body = base64.encodebytes(TEXT.encode()).decode()
    elif case == "latin1":
        headers += ["Content-Type: text/plain; charset=iso-8859-1", "Content-Transfer-Encoding: quoted-printable"]
        body = "Caf=E9 and cr=E8me.\n"
    elif case in {"alternative-attachment", "external-body"}:
        headers += ['Content-Type: multipart/mixed; boundary="fixture-mixed"']
        body = ('--fixture-mixed\nContent-Type: multipart/alternative; boundary="fixture-alt"\n\n'
                '--fixture-alt\nContent-Type: text/plain; charset=utf-8\n'
                'Content-Transfer-Encoding: quoted-printable\n\n' + quopri.encodestring(TEXT.encode()).decode() +
                '\n--fixture-alt\nContent-Type: text/html; charset=utf-8\n'
                'Content-Transfer-Encoding: base64\n\n' + base64.encodebytes(HTML.encode()).decode() +
                '\n--fixture-alt--\n--fixture-mixed\nContent-Type: application/octet-stream\n'
                'Content-Disposition: attachment; filename="../../escape.txt"\n'
                'Content-Transfer-Encoding: base64\n\n' + base64.encodebytes(ATTACHMENT).decode() +
                '\n--fixture-mixed--\n')
    elif case == "html-only":
        headers += ["Content-Type: text/html; charset=utf-8", "Content-Transfer-Encoding: base64"]
        body = base64.encodebytes(HTML.encode()).decode()
    elif case == "controls":
        headers += ["Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: base64"]
        body = base64.encodebytes(b"Literal terminal controls: \x1b[2J\x1b]52;c;ZmFrZQ==\x07\x1b]8;;https://example.org\x07link\x1b]8;;\x07\roverwrite\x00end\n").decode()
    elif case in {"invitation", "recurring-invitation"}:
        headers += ["Content-Type: text/calendar; charset=utf-8; method=REQUEST", "Content-Transfer-Encoding: base64"]
        body = base64.encodebytes(invitation(account, case == "recurring-invitation")).decode()
    else:
        headers += ["Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: 8bit"]
        body = f"Synthetic {account} message {index:03}.\n" + TEXT
        if case == "cache-pressure":
            body += "Synthetic bounded cache pressure.\n" * 2048
    return ("\n".join(headers) + "\n\n" + body).replace("\r\n", "\n").replace("\n", "\r\n").encode()


def invitation(account, recurring=False, method="REQUEST", status="NEEDS-ACTION"):
    lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Omagma//Synthetic fixture//EN", f"METHOD:{method}",
             "BEGIN:VEVENT", "UID:fixture-meeting@example.org", "DTSTAMP:20261101T080000Z", "SEQUENCE:4",
             "DTSTART:20261107T100000Z", "DTEND:20261107T103000Z", "ORGANIZER:mailto:organizer@example.org",
             f"ATTENDEE;CN=Fixture account;RSVP=TRUE;PARTSTAT={status}:mailto:{account}",
             "SUMMARY:Synthetic meeting", "DESCRIPTION:Café\\, tea and fixture discussion."]
    if recurring:
        lines += ["RECURRENCE-ID:20261107T100000Z"]
    if method == "REQUEST":
        lines += ["ATTENDEE;CN=Other fixture;PARTSTAT=ACCEPTED:mailto:other@example.net"]
    return ("\r\n".join(lines + ["END:VEVENT", "END:VCALENDAR"]) + "\r\n").encode()


def inbound_address_cases():
    """Fictional delivered headers are distinct from a valid send envelope."""
    accounts = {}
    for address in ACCOUNTS:
        key = address.split("@")[0]
        wide = [address] + [f"many-{key}-{index:02}@example.org" for index in range(33)]
        local65 = (f"reply-{key}-" + "x" * 65)[:65] + "@example.org"
        accounts[address] = {
            "manyRecipients": {"messageId": "shared-msg-095", "headerName": "To",
                               "headerValue": ", ".join(wide), "expectedAddresses": wide,
                               "normalReplyRecipient": "alex@example.org"},
            "longReplyTo": {"messageId": "shared-msg-094", "headerName": "Reply-To",
                            "headerValue": f"Fictional reply boundary <{local65}>",
                            "expectedAddresses": [local65], "localPartBytes": 65},
        }
    return {"synthetic": True, "networkRequired": False, "accounts": accounts,
            "incomingRecipientCount": 34, "outgoingRecipientLimit": 32,
            "outgoingLocalPartLimit": 64,
            "expected": "read all delivered participants; refuse oversized or invalid outgoing envelopes without truncation"}


def main():
    cases = {1: "quoted-printable", 2: "base64", 3: "alternative-attachment", 4: "html-only",
             5: "reply-all", 6: "missing-message-id", 7: "controls", 8: "invitation",
             9: "recurring-invitation", 10: "external-body", 11: "latin1", 12: "encoded-display-name",
             13: "cache-pressure", 14: "cache-pressure", 15: "cache-pressure"}
    for address in ACCOUNTS:
        key = address.split("@")[0]
        messages = []
        external = {}
        for index in range(1, 97):
            raw = raw_message(address, index, cases.get(index, "plain"))
            parsed = BytesParser(policy=policy.default).parsebytes(raw)
            payload = part(parsed)
            message = {"id": f"shared-msg-{index:03}", "threadId": f"shared-thread-{(index - 1) // 3:03}",
                       "labelIds": ["INBOX"] + (["UNREAD"] if index % 2 else []),
                       "snippet": f"Synthetic {key} message {index:03}; café 👋",
                       "historyId": "1000", "internalDate": str(1794042000000 + index * 60000),
                       "sizeEstimate": len(raw), "payload": payload}
            if index == 10:
                leaf = payload["parts"][0]["parts"][0]
                external_id = f"shared-body-{index:03}"
                external[external_id] = dict(leaf["body"])
                leaf["body"] = {"size": leaf["body"]["size"], "attachmentId": external_id}
            messages.append(message)
            if index in cases:
                p = ROOT / "mime" / f"{key}-{index:03}-{cases[index]}.eml"
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(raw)
        messages.reverse()
        pages = []
        for offset in range(0, 96, 12):
            response = {"messages": [{"id": m["id"], "threadId": m["threadId"]} for m in messages[offset:offset+12]],
                        "resultSizeEstimate": 96}
            if offset + 12 < 96:
                response["nextPageToken"] = f"fixture-{key}-inbox-1000-offset-{offset+12}"
            pages.append({"pageToken": "" if offset == 0 else f"fixture-{key}-inbox-1000-offset-{offset}",
                          "response": response})
        save_json(f"accounts/{key}.json", {"account": address, "generation": 1000, "messages": messages,
                                          "pages": pages, "externalBodies": external})
        save_json(f"contacts/{key}.json", {"account": address, "connections": [
            {"resourceName": "people/shared-contact-001", "etag": f"fixture-{key}-person-v1",
             "metadata": {"sources": [{"type": "CONTACT", "id": "shared-contact-001", "etag": f"fixture-{key}-source-v1"}]},
             "names": [{"displayName": f"Alex {key.title()} Fixture", "givenName": "Alex", "familyName": "Fixture"}],
             "emailAddresses": [{"value": f"alex-{key}@example.org", "type": "work"}]},
            {"resourceName": "people/shared-contact-002", "etag": f"fixture-{key}-person-v1b",
             "metadata": {"sources": [{"type": "CONTACT", "id": "shared-contact-002", "etag": f"fixture-{key}-source-v1b"}]},
             "names": [{"displayName": "Unicode Café Fixture 👋"}], "emailAddresses": [{"value": "unicode@example.net"}]}]})
        p = ROOT / "calendar"
        p.mkdir(exist_ok=True)
        (p / f"{key}-request.ics").write_bytes(invitation(address))
        (p / f"{key}-recurring-request.ics").write_bytes(invitation(address, True))
        for status in ["ACCEPTED", "TENTATIVE", "DECLINED"]:
            (p / f"{key}-reply-{status.lower()}.ics").write_bytes(invitation(address, True, "REPLY", status))
    save_json("manifest.json", {"schemaVersion": 1, "synthetic": True, "networkRequired": False,
              "accounts": ACCOUNTS, "messagesPerAccount": 96, "pageSize": 12, "pagesPerAccount": 8,
              "sharedIdsIntentional": True, "caseByMessageId": {f"shared-msg-{k:03}": v for k, v in cases.items()},
              "bodyExpected": {"quoted-printable": TEXT, "base64": TEXT, "alternative-attachment": TEXT,
                               "external-body": TEXT, "latin1": "Café and crème.\n"},
              "attachmentExpected": {"filenameInput": "../../escape.txt", "safeFilename": "escape.txt",
                                     "size": len(ATTACHMENT), "sha256": hashlib.sha256(ATTACHMENT).hexdigest()},
              "displayNameExpected": {"messageId": "shared-msg-012", "name": "Fixture, Café",
                                      "to": ["alex@example.org", "teammate@example.org"]},
              "replyAllExpected": {a: {"to": ["replies@example.org"], "cc": ["teammate@example.org", "colleague@example.net"],
                                      "excluded": [a, "hidden@example.org"]} for a in ACCOUNTS},
              "capabilities": ["mail-read", "mail-modify", "mail-send", "contacts-read", "contacts-write", "calendar-rsvp"],
              "permanentDeleteSupported": False})
    save_json("failure-contract.json", {"schemaVersion": 1, "cases": [
        {"name": "permission-denied", "expected": "reject before provider call; state unchanged"},
        {"name": "label-remote-rejected", "expected": "rollback labels; unrelated account unchanged"},
        {"name": "trash-remote-rejected", "expected": "rollback trash; original message remains readable"},
        {"name": "send-applied-response-lost", "expected": "unknown outcome; no automatic second send"},
        {"name": "send-not-applied-response-lost", "expected": "unknown outcome; no claim of success"},
        {"name": "send-known-operation-replayed", "expected": "same result; exactly one provider send"},
        {"name": "operation-id-content-conflict", "expected": "reject reused operation id with different payload"},
        {"name": "contact-stale-source-etag", "expected": "conflict; no lost update"},
        {"name": "foreign-page-token", "expected": "reject account/filter/generation mismatch"},
        {"name": "recipient-crlf", "input": "fixture@example.org\r\nBcc: hidden@example.net", "expected": "reject header injection"},
        {"name": "terminal-controls", "expected": "render escaped/inert; never emit mail-derived terminal control bytes"},
        {"name": "mime-budget", "expected": "bounded error for size, parts, depth or charset policy; retain valid cache"},
        {"name": "invitation-not-attendee", "expected": "reject RSVP for account absent from ATTENDEE"},
        {"name": "permanent-delete", "expected": "unsupported; never substitute trash or delete"}]})
    save_json("invalid-inputs.json", {"headers": [{"to": ["fixture@example.org\r\nBcc: hidden@example.net"]},
                                                {"subject": "hello\r\nX-Injected: true"}],
                                     "base64urlBodies": ["A", "***", "a\u0000b"],
                                     "unsupportedCharset": "x-fixture-unsupported"})
    leaf = {"partId": "0", "mimeType": "text/plain", "filename": "", "headers": [],
            "body": {"size": 4, "data": b64url(b"text")}}
    nested = leaf
    for _ in range(33):
        nested = {"partId": "0", "mimeType": "multipart/mixed", "filename": "", "headers": [],
                  "body": {"size": 0}, "parts": [nested]}
    save_json("mime-limits.json", {"synthetic": True, "expected": "bounded error without corrupting existing cache",
              "cases": {"declaredBodyOver2MiB": {**leaf, "body": {"size": 2 * 1024 * 1024 + 1, "data": b64url(b"text")}},
                        "sizeMismatch": {**leaf, "body": {"size": 1000, "data": b64url(b"text")}},
                        "unsupportedCharset": {**leaf, "headers": [{"name": "Content-Type", "value": "text/plain; charset=x-fixture-unsupported"}]},
                        "depth33": nested,
                        "parts513": {"partId": "", "mimeType": "multipart/mixed", "filename": "", "headers": [],
                                     "body": {"size": 0}, "parts": [leaf] * 513}}})
    save_json("inbound-addresses.json", inbound_address_cases())


if __name__ == "__main__":
    main()
