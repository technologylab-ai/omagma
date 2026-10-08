#!/usr/bin/env python3
"""Fixture-only acceptance for inline formatted reply/forward and actual MIME.

Run with an isolated development binary under the cooperative host reservation.
ProviderFixture and Client never obtain credentials or contact a live provider.
Python's email parser independently checks the MIME captured by fixture send.
FormattedFixture, SOURCE_ID and check_snapshot are reusable by owned-PTY tests.
"""
from __future__ import annotations

import argparse
import base64
import copy
from email import policy
from email.message import EmailMessage
from email.parser import BytesParser
from email.utils import getaddresses
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import tempfile

from build_info import read_build_info
from probes.cache_refresh_fixture import repage
from terminal_cache import ProviderFixture
from terminal_cli_parity import one_shot
from terminal_integration import ACCOUNTS, Client, ROOT, addresses, require
from terminal_invitations import finished


SOURCE_ID = "formatted-original"
SOURCE_THREAD = "formatted-original-thread"
SOURCE_DATE = "Thu, 08 Oct 2026 12:00:00 +0000"
SOURCE_SUBJECT = "Synthetic formatted original 🌋"
LOGO_CID = "omagma-logo@omagma.invalid"
NAMED_CID = "named-picture@example.test"
NAMELESS_CID = "nameless-picture@example.test"
ORDINARY_CID = "ordinary-file@example.test"
LOCATION = "https://assets.example.test/source/named.png"
NOTE = "**Personal note** and [note link](https://example.test/note)."
CASES = ("lifecycle", "refusals", "unknown", "quota", "html_template")


def encoded(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def decoded(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def source_text(account: str) -> str:
    return f"Original layout for {account}. Café 🌋.\nOriginal link: https://example.test/original\n"


def source_html(account: str) -> str:
    return (
        '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        '<style id="source-style">body{background:#102030} '
        'p,a,span{color:#0066cc !important}.source-grid td{padding:17px}</style>'
        '</head><body class="original-layout" bgcolor="#102030" '
        'style="background:#102030;color:#f0e0d0">'
        '<table id="source-table" class="source-grid" width="620" '
        'style="border:3px solid #92a;table-layout:fixed"><tr><td>'
        f'Original layout for {account}. Café 🌋.</td><td align="right">42</td></tr></table>'
        '<p><a href="https://example.test/original?x=1&amp;y=2" '
        'style="color:#00bbcc">Original link</a></p>'
        f'<img id="source-named" src="cid:{NAMED_CID}" width="24">'
        f'<img id="source-nameless" src="cid:{NAMELESS_CID}" width="32">'
        # An existing footer must retain its own CID and bytes when the new
        # note's trusted logo placeholder is bound to the outgoing operation.
        f'<img id="source-old-logo" src="cid:{LOGO_CID}" width="16">'
        '<p>Earlier Sent with omagma footer.</p></body></html>'
    )


def resource_bytes(account: str) -> dict[str, bytes]:
    # A valid tiny PNG with distinct synthetic trailing bytes for each identity.
    png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==")
    return {cid: png + b"\x00" + account.encode() + b"\x00" + cid.encode()
            for cid in (NAMED_CID, NAMELESS_CID, LOGO_CID)}


def attachment_bytes(account: str) -> bytes:
    return b"\x00\x01\xff\x80\r\n" + account.encode() + b"\x00ordinary file\n"


def part(kind, data=b"", filename="", external=None, cid=None, location=None, disposition=None):
    headers = [{"name": "Content-Type", "value": kind}]
    if filename or cid or location:
        disposition = disposition or ("inline" if cid or location else "attachment")
        headers.append({"name": "Content-Disposition", "value": disposition +
                        (f'; filename="{filename}"' if filename else "")})
    if cid:
        headers.append({"name": "Content-ID", "value": f"<{cid}>"})
    if location:
        headers.append({"name": "Content-Location", "value": location})
    body = {"size": len(data)}
    body["attachmentId" if external else "data"] = external or encoded(data)
    return {"partId": external or filename or kind, "mimeType": kind,
            "filename": filename, "headers": headers, "body": body}


def multipart(kind, parts):
    return {"partId": kind, "mimeType": kind, "filename": "", "headers": [],
            "body": {"size": 0}, "parts": parts}


def leaves(value):
    if value.get("parts"):
        for child in value["parts"]:
            yield from leaves(child)
    else:
        yield value


class FormattedFixture(ProviderFixture):
    """One newest fictional styled message per account, also useful to PTYs."""

    def __init__(self, directory):
        super().__init__(directory)
        self.sources = {}
        self.raw_sources = {}
        for account in ACCOUNTS:
            source = json.loads(self.path(account).read_text())
            envelope = [
                {"name": "From", "value": "Fixture Publisher <publisher@example.test>"},
                {"name": "Reply-To", "value": "Reply Desk <reply@example.test>"},
                {"name": "To", "value": f"{account}, teammate@example.test"},
                {"name": "Cc", "value": "copied@example.test"},
                {"name": "Subject", "value": SOURCE_SUBJECT},
                {"name": "Date", "value": SOURCE_DATE},
                {"name": "Message-ID", "value": f"<source-{account.split('@')[0]}@example.test>"},
                {"name": "References", "value": "<parent@example.test>"},
            ]
            resources = resource_bytes(account)
            related = [part("text/html", source_html(account).encode()),
                       part("image/png", resources[NAMED_CID], "hero.png", "named-external", NAMED_CID, LOCATION, disposition="attachment"),
                       part("image/png", resources[NAMELESS_CID], "", "nameless-external", NAMELESS_CID, disposition="attachment"),
                       part("image/png", resources[LOGO_CID], "previous-logo.png", cid=LOGO_CID)]
            payload = multipart("multipart/mixed", [
                multipart("multipart/alternative", [part("text/plain", source_text(account).encode()),
                                                     multipart("multipart/related", related)]),
                part("application/octet-stream", attachment_bytes(account), "ordinary.bin", "ordinary-external", ORDINARY_CID, disposition="attachment"),
            ])
            payload["headers"] = envelope
            raw = EmailMessage(policy=policy.SMTP)
            for header in envelope:
                raw[header["name"]] = header["value"]
            raw.set_content(source_text(account))
            raw.add_alternative(source_html(account), subtype="html")
            html = raw.get_payload()[-1]
            for cid, data in resources.items():
                html.add_related(data, maintype="image", subtype="png", cid=f"<{cid}>",
                                 disposition="attachment" if cid in (NAMED_CID, NAMELESS_CID) else "inline")
            raw.add_attachment(attachment_bytes(account), maintype="application", subtype="octet-stream", filename="ordinary.bin", cid=f"<{ORDINARY_CID}>")
            self.raw_sources[account] = raw.as_bytes()
            source["messages"] = [{"id": SOURCE_ID, "threadId": SOURCE_THREAD,
                                   "labelIds": ["INBOX", "UNREAD"], "historyId": "1000",
                                   "internalDate": "1799999000000", "sizeEstimate": len(raw.as_bytes()),
                                   "snippet": "Synthetic styled original with embedded images",
                                   "payload": payload, "raw": encoded(raw.as_bytes())}]
            source["externalBodies"] = {
                "named-external": {"size": len(resources[NAMED_CID]), "data": encoded(resources[NAMED_CID])},
                "nameless-external": {"size": len(resources[NAMELESS_CID]), "data": encoded(resources[NAMELESS_CID])},
                "ordinary-external": {"size": len(attachment_bytes(account)), "data": encoded(attachment_bytes(account))},
            }
            self.sources[account] = source
            self.save(account)

    def message(self, account=ACCOUNTS[0], source_id=SOURCE_ID):
        return next(message for message in self.sources[account]["messages"] if message["id"] == source_id)

    def save(self, account=ACCOUNTS[0]):
        repage(self.sources[account])
        self.path(account).write_text(json.dumps(self.sources[account], ensure_ascii=False) + "\n")

    def options(self, *extra):
        return super().options("--prefetch-bodies", "0", *extra)


def check_snapshot(draft, account=ACCOUNTS[0]):
    original = draft.get("original")
    require(isinstance(original, dict) and original["version"] == 1, "formatted draft omitted versioned original snapshot")
    require(original["sourceMessageId"] == SOURCE_ID, "snapshot lost source message identity")
    require(original["from"]["address"] == "publisher@example.test" and
            addresses(original["to"]) == [account, "teammate@example.test"] and
            addresses(original["cc"]) == ["copied@example.test"], "original envelope crossed account or lost recipients")
    require(original["subject"] == SOURCE_SUBJECT and original["date"] == SOURCE_DATE, "original subject/date changed")
    require(original["bodyText"] == source_text(account) and original["bodyHtml"] == source_html(account),
            "snapshot changed original plain or styled HTML source")
    actual = {resource["contentId"].strip("<>"): resource for resource in original["resources"]}
    require(len(actual) == len(original["resources"]) == 3, "snapshot lost or duplicated related resources")
    require(ORDINARY_CID not in actual, "unused CID ordinary file became a related resource")
    for cid, data in resource_bytes(account).items():
        require(cid in actual and decoded(actual[cid]["data"]) == data and actual[cid]["size"] == len(data),
                f"resource {cid} changed bytes, size or account")
    require(actual[NAMED_CID]["contentLocation"] == LOCATION, "related Content-Location was lost")
    for cid in (NAMED_CID, NAMELESS_CID):
        require(actual[cid]["disposition"] == "attachment", "snapshot rewrote the referenced image's original disposition")
    return original


class HTMLFacts(HTMLParser):
    def __init__(self, value):
        super().__init__(convert_charrefs=True)
        self.tags = []
        self.feed(value)

    def handle_starttag(self, tag, attrs):
        self.tags.append((tag, dict(attrs)))


def check_preview(preview, account=ACCOUNTS[0], note=NOTE, body_format="markdown"):
    html = preview["bodyHtml"]
    require(preview["bodyText"] == note and preview["bodyFormat"] == body_format, "preview changed editable note source/format")
    require(isinstance(html, str), "formatted original was not previewed inline")
    original = source_html(account)
    source_body = original[original.index('<table id="source-table"'):original.index("</body>")]
    require(source_body in html, "preview flattened or changed original tables, images, links or styles")
    require('<style id="source-style">' in html and 'class="original-layout"' in html and
            'bgcolor="#102030"' in html and 'style="background:#102030;color:#f0e0d0"' in html,
            "preview lost original HEAD styles or BODY attributes")
    require(html.index("Personal note") < html.index('<table id="source-table"'), "new note did not precede inline original")
    facts = HTMLFacts(html)
    require(sum(tag == "html" for tag, _ in facts.tags) == 1 and sum(tag == "body" for tag, _ in facts.tags) == 1,
            "formatted original was nested as a second HTML document")
    brand = [attrs for tag, attrs in facts.tags if tag == "a" and "omagma-footer-link" in attrs.get("class", "").split()]
    require(len(brand) == 1 and re.search(r"color\s*:\s*#b84a10\s*!important", brand[0].get("style", "")),
            "original stylesheet can override the new note's orange Omagma link")
    if body_format == "markdown":
        require(re.search(r"<strong[^>]*>Personal note</strong>", html), "Markdown note lost emphasis")
        require("**Personal note**" not in preview["plainText"], "plain alternative retained Markdown emphasis")
    else:
        require("**Personal note**" in html and "**Personal note**" in preview["plainText"], "plain note was interpreted as Markdown")
    require(source_text(account).strip() in preview["plainText"], "plain alternative omitted original text")
    return html


def normal_newlines(value):
    return value.replace("\r\n", "\n").replace("\r", "\n")


def check_wire(sent, draft, preview, account=ACCOUNTS[0], forward=False):
    require(sent.get("fixtureRaw"), "fixture send did not retain actual MIME for independent inspection")
    raw = decoded(sent["fixtureRaw"])
    message = BytesParser(policy=policy.default).parsebytes(raw)
    require(all(not part.defects for part in message.walk()), "independent parser found malformed outgoing MIME")
    require(message.get_content_type() == ("multipart/mixed" if forward else "multipart/alternative"),
            "outgoing inline original has wrong MIME root")
    related = [part for part in message.walk() if part.get_content_type() == "multipart/related"]
    require(len(related) == 1 and related[0].get_param("type") == "text/html", "missing single HTML related root")
    children = list(related[0].iter_parts())
    require(children[0].get_content_type() == "text/html", "related root is an image instead of the HTML part")
    start = related[0].get_param("start")
    require(start is None or start == children[0].get("Content-ID"), "related start points away from HTML root")
    html = children[0].get_payload(decode=True).decode("utf-8")
    plain = [part for part in message.walk() if part.get_content_type() == "text/plain"]
    require(len(plain) == 1 and normal_newlines(plain[0].get_payload(decode=True).decode("utf-8")) == normal_newlines(preview["plainText"]),
            "actual MIME plain alternative differs from review")
    by_cid = {}
    for resource in children[1:]:
        cid = str(resource.get("Content-ID", "")).strip("<>")
        require(cid and cid not in by_cid, "outgoing related image lost or duplicated Content-ID")
        by_cid[cid] = resource
    originals = resource_bytes(account)
    require(len(by_cid) == len(originals) + 1, "wire omitted original resources or new Omagma logo")
    require(ORDINARY_CID not in by_cid, "wire hid unused CID ordinary file in the HTML related part")
    for cid, data in originals.items():
        require(cid in by_cid and by_cid[cid].get_payload(decode=True) == data, "wire changed original image bytes/CID/account")
        require(by_cid[cid].get_content_disposition() == "inline", "original related image became an ordinary file")
    require(by_cid[NAMED_CID]["Content-Location"] == LOCATION, "wire lost original Content-Location")
    logo_cid = next(cid for cid in by_cid if cid not in originals)
    require(by_cid[logo_cid].get_payload(decode=True) == (ROOT / "src/terminal/omagma-logo.png").read_bytes(),
            "new note logo bytes differ from approved embedded image")
    # Only the trusted new-note occurrence may change; the original's old logo
    # reference remains byte-for-byte bound to the original image.
    expected_html = preview["bodyHtml"].replace("cid:" + LOGO_CID, "cid:" + logo_cid, 1)
    require(normal_newlines(html) == normal_newlines(expected_html), "actual MIME HTML differs from reviewed original/note")
    for tag, attrs in HTMLFacts(html).tags:
        if tag == "img" and attrs.get("src", "").lower().startswith("cid:"):
            require(attrs["src"][4:] in by_cid, "HTML references an absent related CID")
    attachments = [part for part in message.walk() if part.get_content_disposition() == "attachment"]
    require(len(attachments) == int(forward), "ordinary file was lost, copied into reply or duplicated")
    if forward:
        require(attachments[0].get_filename() == "ordinary.bin" and attachments[0].get_payload(decode=True) == attachment_bytes(account),
                "ordinary forwarded attachment changed filename/bytes")
    require(not any(part.get_content_type() in ("message/rfc822", "message/global") for part in message.walk()),
            "formatted original was sent as an attached email instead of inline")
    if forward:
        require(not message.get("In-Reply-To") and not message.get("References") and sent["threadId"] != SOURCE_THREAD,
                "formatted forward retained source conversation threading")
    else:
        require(str(message["In-Reply-To"]) == draft["inReplyTo"] and
                str(message["References"]) == draft["references"] and sent["threadId"] == SOURCE_THREAD,
                "formatted reply lost original conversation threading")
    for header, key in (("To", "to"), ("Cc", "cc"), ("Bcc", "bcc")):
        require([address for _, address in getaddresses(message.get_all(header, []))] == addresses(draft[key]),
                f"wire {header} differs from reviewed recipients")
    return {"mimeBytes": len(raw), "relatedImages": len(by_cid), "attachments": len(attachments)}


def lifecycle(binary, directory):
    fixture = FormattedFixture(directory)
    with Client(binary, directory / "client", extra=fixture.options()) as client:
        drafts = []
        for account in ACCOUNTS[:2]:
            for forward in (False, True):
                command = "mail.forward" if forward else "mail.reply"
                params = {"messageId": SOURCE_ID, "preserveFormatting": True, "bodyFormat": "markdown"}
                if not forward:
                    params["all"] = True
                draft = client.request(command, account, **params)
                check_snapshot(draft, account)
                require(draft["bodyText"] == "", "formatted source was copied into editable note")
                require(len(draft["attachments"]) == int(forward), "ordinary attachments were duplicated or copied into reply")
                if forward:
                    ordinary = draft["attachments"][0]
                    require(ordinary.get("contentId") == ORDINARY_CID and ordinary.get("disposition") == "attachment" and
                            ordinary["filename"] == "ordinary.bin" and decoded(ordinary["data"]) == attachment_bytes(account),
                            "unused CID ordinary file was lost, hidden or changed")
                if not forward:
                    require(addresses(draft["to"]) == ["reply@example.test"] and
                            addresses(draft["cc"]) == ["teammate@example.test", "copied@example.test"],
                            "formatted reply-all changed Reply-To or copied recipients")
                else:
                    require(not draft["to"] and not draft["threadId"] and not draft["references"] and not draft["inReplyTo"],
                            "formatted forward is not a new recipient-free conversation")
                flags = ["--message-id", SOURCE_ID, "--preserve-formatting", "--format", "markdown"]
                if not forward:
                    flags.append("--all")
                cli = one_shot(client, "mail", "forward" if forward else "reply", flags, account=account)
                require({k: v for k, v in cli.items() if k != "id"} == {k: v for k, v in draft.items() if k != "id"},
                        "CLI and JSONL formatted drafts differ")
                client.request("draft.discard", account, draftId=cli["id"])
                draft.update(bodyText=NOTE, to=[{"address": "recipient@example.test"}],
                             cc=[{"address": "copied-note@example.test"}], bcc=[{"address": "blind-note@example.test"}])
                updated = copy.deepcopy(draft)
                updated.pop("original")
                updated.pop("bodyFormat")
                draft = client.request("draft.update", account, draftId=draft["id"], draft=updated)
                check_snapshot(draft, account)
                preview = client.request("draft.preview", account, draftId=draft["id"])
                check_preview(preview, account)
                require(one_shot(client, "draft", "preview", ["--draft-id", draft["id"]], account=account) == preview,
                        "persisted one-shot preview differs from JSONL review")
                drafts.append((account, forward, draft, preview))

        # Source deletion and cache eviction must not affect saved drafts.
        for account in ACCOUNTS[:2]:
            client.request("cache.clear", account)
            fixture.sources[account]["messages"] = []
            fixture.sources[account]["externalBodies"] = {}
            fixture.save(account)
        client.restart()
        for index, (account, forward, draft, preview) in enumerate(drafts):
            require(client.request("draft.read", account, draftId=draft["id"]) == draft,
                    "cache clear/restart changed frozen draft")
            require(client.request("draft.preview", account, draftId=draft["id"]) == preview,
                    "reopened preview depended on deleted source/cache")
            receipt = client.request("draft.send", account, draftId=draft["id"], operationId=f"formatted-send-{index}")
            require(receipt["outcome"] == "applied", "fixture formatted send failed")
            sent = client.request("mail.read", account, messageId=receipt["messageId"])
            check_wire(sent, draft, preview, account, forward)
            before = client.request("cache.stats", account)
            require(client.request("draft.send", account, draftId=draft["id"], operationId=f"formatted-send-{index}") == receipt,
                    "formatted send replay changed receipt")
            require(client.request("cache.stats", account)["fixtureSends"] == before["fixtureSends"], "formatted replay sent twice")

        # Recovery fields own only the note; the original stays independently
        # frozen through autosave, restart, completed update and plain format.
        account = ACCOUNTS[2]
        recovery = client.request("mail.reply", account, messageId=SOURCE_ID, preserveFormatting=True, bodyFormat="plain")
        snapshot = check_snapshot(recovery, account)
        recovery_input = copy.deepcopy(recovery)
        recovery_input.pop("original")
        recovery_input.pop("bodyFormat")
        recovery_input["recoveryFields"] = ["unfinished", "", "", "Recovery", NOTE]
        recovery = client.request("draft.recovery-save", account, draftId=recovery["id"],
                                  draft=recovery_input)
        require(recovery["original"] == snapshot and recovery["bodyFormat"] == "plain", "autosave lost original or note format")
        client.restart()
        recovery = client.request("draft.read", account, draftId=recovery["id"])
        check_preview(client.request("draft.preview", account, draftId=recovery["id"]), account, body_format="plain")
        require(client.request("draft.send", account, draftId=recovery["id"], operationId="unfinished", ok=False)["code"] == "UnfinishedDraft",
                "unfinished recovery was submitted")
        recovery.update(recoveryFields=None, to=[{"address": "recipient@example.test"}], bodyText=NOTE)
        recovery = client.request("draft.update", account, draftId=recovery["id"], draft=recovery)
        preview = client.request("draft.preview", account, draftId=recovery["id"])
        receipt = client.request("draft.send", account, draftId=recovery["id"], operationId="plain-formatted")
        require(receipt["outcome"] == "applied", "plain-note formatted fixture send failed")
        check_wire(client.request("mail.read", account, messageId=receipt["messageId"]), recovery, preview, account)

        # Legacy forward remains text; .eml forwarding remains its own mode.
        legacy = client.request("mail.forward", account, messageId=SOURCE_ID)
        require(legacy.get("original") is None and "Forwarded message" in legacy["bodyText"], "legacy default forward opted into formatting")
        attached = client.request("mail.forward", account, messageId=SOURCE_ID, original=True)
        require(attached.get("original") is None and len(attached["attachments"]) == 1 and
                decoded(attached["attachments"][0]["data"]) == fixture.raw_sources[account], "secondary .eml forward changed original bytes")
        client.request("draft.read", ACCOUNTS[0], draftId=recovery["id"], ok=False)
    finished(client)


def refusals(binary, directory):
    fixture = FormattedFixture(directory)
    source = fixture.sources[ACCOUNTS[0]]
    for name in ("plain-only", "duplicate-cid", "multiple-html", "missing-image", "wrong-size"):
        message = copy.deepcopy(fixture.message())
        message["id"] = name
        if name == "plain-only":
            body = part("text/plain", b"No HTML original")
            body["headers"] += message["payload"]["headers"]
            message["payload"] = body
        elif name == "duplicate-cid":
            related = message["payload"]["parts"][0]["parts"][1]["parts"]
            duplicate = copy.deepcopy(related[1])
            duplicate["partId"] = "duplicate-cid-part"
            related.append(duplicate)
        elif name == "multiple-html":
            message["payload"]["parts"].append(part("text/html", b"<p>Unrelated second HTML body</p>"))
        else:
            named = next(leaf for leaf in leaves(message["payload"]) if leaf["body"].get("attachmentId") == "named-external")
            named["body"]["attachmentId"] = name
            if name == "wrong-size":
                source["externalBodies"][name] = {"size": named["body"]["size"], "data": encoded(b"wrong")}
        source["messages"].append(message)
    fixture.save()
    with Client(binary, directory / "client", extra=fixture.options()) as client:
        for command in ("mail.reply", "mail.forward"):
            for message_id, expected in (("plain-only", "OriginalHtmlUnavailable"), ("duplicate-cid", "AmbiguousContentId"),
                                         ("multiple-html", "AmbiguousOriginalHtml"), ("missing-image", None), ("wrong-size", "BodySizeMismatch")):
                before = client.request("draft.list")["drafts"]
                error = client.request(command, messageId=message_id, preserveFormatting=True, ok=False)
                if expected:
                    require(error["code"] == expected, f"{command} {message_id} gave {error['code']} instead of {expected}")
                require(client.request("draft.list")["drafts"] == before, "refused capture created a partial draft")
        for params, expected in (({"preserveFormatting": "true"}, "InvalidRequest"),
                                 ({"preserveFormatting": True, "original": True}, "ConflictingForwardModes")):
            require(client.request("mail.forward", messageId=SOURCE_ID, ok=False, **params)["code"] == expected,
                    "invalid formatted mode was accepted")
        one_shot(client, "mail", "forward", ["--message-id", SOURCE_ID, "--original", "--preserve-formatting"], error="ConflictingForwardModes")
        one_shot(client, "mail", "compose", ["--preserve-formatting"], error="PreserveFormattingRequiresReplyOrForward")
        client.request("mail.forward", "unknown@example.test", messageId=SOURCE_ID, preserveFormatting=True, ok=False)
        require(client.request("cache.stats")["fixtureSends"] == 0, "capture/refusal submitted mail")

        # Reopen an older body cache without CID metadata. Capturing a formatted
        # original must use fresh FULL data, preserving the now-complete source.
        client.request("mail.read", messageId=SOURCE_ID)
        account_hash = hashlib.sha256(ACCOUNTS[0].encode()).hexdigest()
        message_hash = hashlib.sha256(SOURCE_ID.encode()).hexdigest()
        body = client.directory / "cache" / "fixtures" / account_hash / f"mail-{message_hash}.json"
        value = json.loads(body.read_text())
        for resource in value["message"]["attachments"]:
            for field in ("contentId", "contentLocation", "disposition"):
                resource.pop(field, None)
        legacy_bytes = (json.dumps(value) + "\n").encode()
        body.write_bytes(legacy_bytes)
        index_path = body.parent / "index.json"
        index = json.loads(index_path.read_text())
        entry = next(item for item in index["entries"] if item["message"]["id"] == SOURCE_ID)
        entry.update(bytes=len(legacy_bytes), bodyHash=hashlib.sha256(legacy_bytes).hexdigest())
        index_path.write_text(json.dumps(index) + "\n")
        client.restart()
        legacy = client.request("mail.read", messageId=SOURCE_ID, cacheOnly=True)
        require(all(item.get("contentId") is None for item in legacy["attachments"]),
                "legacy-cache fixture did not retain the old metadata shape")
        before = client.request("cache.stats")["fixtureCalls"]
        check_snapshot(client.request("mail.reply", messageId=SOURCE_ID, preserveFormatting=True))
        require(client.request("cache.stats")["fixtureCalls"] > before, "formatted capture reused incomplete legacy cached source")
    finished(client)


def unknown(binary, directory):
    fixture = FormattedFixture(directory)
    for scenario in ("unknown-send", "applied-lost"):
        with Client(binary, directory / scenario, scenario=scenario, extra=fixture.options()) as client:
            draft = client.request("mail.forward", messageId=SOURCE_ID, preserveFormatting=True, bodyFormat="markdown")
            draft.update(to=[{"address": "recipient@example.test"}], bodyText=NOTE)
            draft = client.request("draft.update", draftId=draft["id"], draft=draft)
            receipt = client.request("draft.send", draftId=draft["id"], operationId="formatted-unknown")
            require(receipt["outcome"] == "unknown", "lost fixture response became definite")
            before = client.request("cache.stats")
            client.request("cache.clear")
            client.restart()
            require(client.request("draft.read", draftId=draft["id"]) == draft, "unknown draft lost frozen original after restart/cache clear")
            for field, value in (("bodyText", "Changed note"), ("original", None)):
                changed = {**draft, field: value}
                require(client.request("draft.update", draftId=draft["id"], draft=changed, ok=False)["code"] == "UnknownOutcome",
                        "uncertain formatted draft allowed content changes")
            require(client.request("draft.discard", draftId=draft["id"], ok=False)["code"] == "UnknownOutcome", "uncertain formatted draft was discarded")
            for operation in ("formatted-unknown", "another-identity"):
                require(client.request("draft.send", draftId=draft["id"], operationId=operation) == receipt,
                        "new operation identity bypassed protected formatted send")
            after = client.request("cache.stats")
            require(after["fixtureCalls"] == before["fixtureCalls"] and after["fixtureSends"] == before["fixtureSends"],
                    "unknown formatted replay reached provider")
        finished(client)


def quota(binary, directory):
    fixture = FormattedFixture(directory)
    account = ACCOUNTS[0]
    image = next(leaf for leaf in leaves(fixture.message()["payload"]) if leaf["body"].get("attachmentId") == "named-external")
    large = resource_bytes(account)[NAMED_CID] + b"x" * 100000
    image["body"]["size"] = len(large)
    fixture.sources[account]["externalBodies"]["named-external"] = {"size": len(large), "data": encoded(large)}
    fixture.save()
    with Client(binary, directory / "client", extra=fixture.options("--disk-limit-bytes", "65536")) as client:
        prior = client.request("draft.list")["drafts"]
        for command in ("mail.reply", "mail.forward"):
            require(client.request(command, messageId=SOURCE_ID, preserveFormatting=True, ok=False)["code"] == "DiskQuotaExceeded",
                    "oversized persisted original did not respect disk quota")
            require(client.request("draft.list")["drafts"] == prior, "quota refusal retained a partial original draft")
            require(client.request("cache.stats")["fixtureSends"] == 0, "quota refusal sent mail")
    finished(client)


def html_template(binary, directory):
    fixture = FormattedFixture(directory)
    account = ACCOUNTS[0]
    original = source_html(account).replace(
        '<html lang="en">',
        '<html xmlns="http://www.w3.org/1999/xhtml" '
        'xmlns:o="urn:schemas-microsoft-com:office:office"><html lang="en">')
    damaged_paragraph = '<p style="color:#123456" <span>Fictional itinerary</span></p>'
    original = original.replace('<table id="source-table"', damaged_paragraph + '<table id="source-table"')
    leaf = next(item for item in leaves(fixture.message()["payload"]) if item["mimeType"] == "text/html")
    leaf["body"] = {"size": len(original.encode()), "data": encoded(original.encode())}
    fixture.save()
    with Client(binary, directory / "client", extra=fixture.options()) as client:
        for command in ("mail.reply", "mail.forward"):
            draft = client.request(command, messageId=SOURCE_ID, preserveFormatting=True, bodyFormat="markdown")
            require(draft["original"]["bodyHtml"] == original, "template repair changed the saved original")
            preview = client.request("draft.preview", draftId=draft["id"])
            output = preview["bodyHtml"]
            require('<html xmlns="http://www.w3.org/1999/xhtml" '
                    'xmlns:o="urn:schemas-microsoft-com:office:office"><html lang="en">' in output,
                    "source root tags or their attributes were changed")
            require(damaged_paragraph in output and '<style id="source-style">' in output,
                    "repair changed original paragraph markup or styles")
            require(len(draft["original"]["resources"]) == 3 and client.request("cache.stats")["fixtureSends"] == 0,
                    "template repair lost embedded images or sent mail")
    finished(client)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--case", action="append", choices=CASES)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    cases = args.case or CASES
    with tempfile.TemporaryDirectory(prefix="omagma-formatted-original-") as temporary:
        for case in cases:
            globals()[case](binary, Path(temporary) / case)
            print(f"PASS formatted original {case}")
    require(hashlib.sha256(binary.read_bytes()).hexdigest() == digest, "tested development binary changed")
    if args.receipt:
        receipt = {"schemaVersion": 1, "suite": "terminal-formatted-original", "status": "passed",
                   "synthetic": True, "liveProviderWrites": 0, "cases": list(cases),
                   "binarySha256": digest, **read_build_info(binary, None)}
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
