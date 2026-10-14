#!/usr/bin/env python3
"""Attachment lifecycle acceptance using fictional provider data and owned PTYs.

Run only within the coordinator's cooperative host reservation. The checked-in
payload files are the byte oracle; no expectation comes from omagma's output.
External replies are staged after FULL reads so fixture normalization cannot
silently preload them and bypass the shared Gmail attachment adapter.
"""
from __future__ import annotations

import argparse
import base64
import copy
from contextlib import contextmanager
from email import policy
from email.message import EmailMessage
from email.parser import BytesParser
import hashlib
from html import unescape
import json
import os
from pathlib import Path
import re
import stat
import struct
import tempfile
import time
import traceback
import zlib

from build_info import read_build_info
from terminal_integration import ACCOUNTS, Client, require


FIXTURE = Path(__file__).resolve().parent / "fixtures/terminal/attachment-lifecycle"
ORACLE = json.loads((FIXTURE / "expected.json").read_text())
THREAD = ORACLE["threadId"]
RECEIVED, SENT, DUPLICATES, FORMATTED = ORACLE["messageIds"]
CASES = ("provider", "rotated", "missing_body", "unindexed", "conversation_modes", "large_forwards", "large_related", "send_boundaries", "drafts", "uncertain", "failures", "tui", "tui_forward")


def read_snapshot(client, saved):
    """Verify stored fields, then retain the complete public read projection."""
    snapshot = client.request("draft.read", draftId=saved["id"])
    stored = dict(snapshot)
    digest = stored.pop("contentDigest")
    require(len(digest) == 64 and all(c in "0123456789abcdef" for c in digest),
            "draft read lost its bounded content digest")
    require(stored == saved, "draft read changed stored fields before the restart/failure oracle")
    return snapshot


def encode(raw):
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def decode(value):
    return base64.b64decode(value + "=" * (-len(value) % 4), altchars=b"-_", validate=True)


def payload(row):
    raw = (FIXTURE / row["payload"]).read_bytes()
    require(len(raw) == row["size"] and hashlib.sha256(raw).hexdigest() == row["sha256"],
            "checked-in attachment oracle is inconsistent")
    return raw


def expected(account=ACCOUNTS[0], message_id=None):
    return [row for row in ORACLE["accounts"][account]
            if message_id is None or row["messageId"] == message_id]


def leaves(part):
    if part.get("parts"):
        for child in part["parts"]:
            yield from leaves(child)
    else:
        yield part


class LifecycleFixture:
    def __init__(self, directory):
        self.root = Path(directory) / "provider"
        (self.root / "accounts").mkdir(mode=0o700, parents=True)
        self.sources = {}
        self.downloads = {}
        for account in ACCOUNTS:
            source = json.loads((FIXTURE / "accounts" / (account.split("@")[0] + ".json")).read_text())
            self.downloads[account] = source.pop("externalBodies")
            self.sources[account] = source
            self.save(account)

    def path(self, account):
        return self.root / "accounts" / (account.split("@")[0] + ".json")

    def save(self, account=ACCOUNTS[0], downloads=False):
        source = copy.deepcopy(self.sources[account])
        if downloads:
            source["externalBodies"] = self.downloads[account]
        self.path(account).write_text(json.dumps(source, ensure_ascii=False) + "\n")

    def message(self, message_id, account=ACCOUNTS[0]):
        return next(item for item in self.sources[account]["messages"] if item["id"] == message_id)

    def rotate(self, message_id, new_id, account=ACCOUNTS[0], occurrence=0):
        parts = [part for part in leaves(self.message(message_id, account)["payload"])
                 if "attachmentId" in part.get("body", {})]
        part = parts[occurrence]
        old_id = part["body"]["attachmentId"]
        part["body"]["attachmentId"] = new_id
        self.downloads[account][new_id] = self.downloads[account].pop(old_id)
        self.save(account)
        return old_id

    def options(self, metadata_limit=32):
        return ("--fixture-root", str(self.root), "--metadata-limit", str(metadata_limit), "--prefetch-bodies", "0")


def attachment(message, row, occurrence=0):
    matches = [part for part in message["attachments"] if part["filename"] == row["filename"]
               and part["mimeType"] == row["mimeType"]]
    require(len(matches) > occurrence, f"missing attachment {row['filename']!r} in {message['id']}")
    selected = matches[occurrence]
    require(selected["id"] and selected["size"] == row["size"], "attachment identity or decoded size missing")
    return selected


def verify_file(path, raw):
    require(path.is_file() and not path.is_symlink(), f"save did not produce a regular file: {path.name}")
    require(path.read_bytes() == raw and hashlib.sha256(path.read_bytes()).digest() == hashlib.sha256(raw).digest(),
            f"saved the wrong attachment bytes: {path.name}")
    require(stat.S_IMODE(path.stat().st_mode) == 0o600, "saved attachment is not private")


def save(client, message_id, part, destination, raw, account=ACCOUNTS[0]):
    result = client.request("mail.attachment-save", account, messageId=message_id,
                            attachmentId=part["id"], path=str(destination))
    require(result["saved"] and result["path"] == str(destination) and result["size"] == len(raw),
            "successful save receipt lost the explicit destination/size")
    verify_file(destination, raw)
    return result


def no_writes(client, account=ACCOUNTS[0]):
    require(client.request("cache.stats", account)["fixtureSends"] == 0, "reading/saving/opening submitted mail")
    require(client.request("operation.list", account)["operations"] == [], "attachment access created a write operation")


def provider(binary, directory):
    fixture = LifecycleFixture(directory)
    count = 0
    with Client(binary, directory / "client", extra=fixture.options()) as client:
        for account in ACCOUNTS[:2]:
            client.request("mail.refresh", account, limit=10, prefetchLimit=0)
            metadata = next(message for message in client.request("mail.list", account, label="SENT", cacheOnly=True)["messages"]
                            if message["id"] == SENT)
            require(not metadata["bodyCached"], "metadata-only setup unexpectedly fetched a body")
            thread = client.request("mail.thread", account, threadId=THREAD)["messages"]
            require([message["id"] for message in thread] == ORACLE["messageIds"],
                    "received/sent conversation lost chronological message identity")
            by_id = {message["id"]: message for message in thread}
            require("SENT" in by_id[SENT]["labels"], "sent card was not a provider SENT message")
            for message in thread:
                rows = expected(account, message["id"])
                require(len(message["attachments"]) == len(rows),
                        f"provider omitted or invented files in {message['id']}; empty files must remain visible")
                for part, row in zip(message["attachments"], rows):
                    require(part["filename"] == row["filename"] and part["size"] == row["size"],
                            "attachment MIME order/name/size changed")
                    if row["providerId"]:
                        require(part["id"] == row["providerId"] and not part["data"] and not part.get("blobId"),
                                "fixture preloaded external data or replaced the opaque provider identity")
            fixture.save(account, downloads=True)
            output = directory / account.split("@")[0]
            output.mkdir()
            for number, row in enumerate(expected(account)):
                occurrence = sum(prior["messageId"] == row["messageId"] and prior["filename"] == row["filename"]
                                 for prior in expected(account)[:number])
                part = attachment(by_id[row["messageId"]], row, occurrence)
                save(client, row["messageId"], part, output / f"{number}-initial.bin", payload(row), account)
                count += 1
            no_writes(client, account)
        # Same message IDs and tokens across two accounts must retain different bytes.
        require(payload(expected(ACCOUNTS[0], SENT)[0]) != payload(expected(ACCOUNTS[1], SENT)[0]),
                "account-isolation oracle accidentally uses identical content")
        client.restart()
        for account in ACCOUNTS[:2]:
            for message_id in (SENT, FORMATTED):
                cached = client.request("mail.read", account, messageId=message_id, cacheOnly=True)
                for number, row in enumerate(expected(account, message_id)):
                    part = attachment(cached, row)
                    save(client, message_id, part,
                         directory / account.split("@")[0] / f"{message_id}-{number}-restart.bin", payload(row), account)
                    count += 1
            no_writes(client, account)
    return {"verifiedSaves": count, "accounts": 2, "zeroByteFile": True, "fixtureSends": 0}


def rotated(binary, directory):
    fixture = LifecycleFixture(directory)
    row = expected(message_id=SENT)[0]
    with Client(binary, directory / "client", extra=fixture.options()) as client:
        original = client.request("mail.read", messageId=SENT)
        token_a = attachment(original, row)["id"]
        token_b = "sent-token-B/percent%plus+question?"
        fixture.rotate(SENT, token_b)
        fresh = {item["id"]: item for item in client.request("mail.thread", threadId=THREAD)["messages"]}[SENT]
        selected = attachment(fresh, row)
        require(selected["id"] == token_b and not selected["data"], "fresh thread did not publish unloaded token B")
        cached = client.request("mail.read", messageId=SENT, cacheOnly=True)
        require(attachment(cached, row)["id"] == token_a,
                "test no longer exercises retained body A against independently refreshed thread/index B")
        fixture.save(downloads=True)
        save(client, SENT, selected, directory / "sent-picked-in-thread.pdf", payload(row))
        downloaded = client.request("mail.attachment", messageId=SENT, attachmentId=token_b)
        require(decode(downloaded["data"]) == payload(row), "fetch and save resolved different refreshed attachments")
        client.restart()
        save(client, SENT, selected, directory / "sent-picked-after-restart.pdf", payload(row))

        # Another reader publishes C while this chooser still holds verified B.
        # The bounded descriptor history must preserve that exact message/part
        # binding. An invented or another message's token remains forbidden.
        fixture.rotate(SENT, "sent-token-C")
        client.request("mail.thread", threadId=THREAD)
        fixture.save(downloads=True)
        save(client, SENT, selected, directory / "verified-picker-after-refresh.pdf", payload(row))
        missing = directory / "unknown-must-not-exist.pdf"
        refused = client.request("mail.attachment-save", messageId=SENT, attachmentId="never-observed-token",
                                 path=str(missing), ok=False)
        require(refused["code"] == "AttachmentNotFound" and not missing.exists(),
                "unrecognized picker token guessed another file or reported success")
        alien = client.request("mail.attachment-save", messageId=RECEIVED, attachmentId="sent-token-C",
                               path=str(missing), ok=False)
        require(alien["code"] == "AttachmentNotFound" and not missing.exists(),
                "attachment identity crossed from one thread card into another")
        no_writes(client)
    return {"retainedBodyToken": "A", "verifiedThreadToken": "B", "restart": True,
            "verifiedPickerSurvivesRefresh": True, "unknownPickerRefused": True,
            "wrongMessageRefused": True, "fixtureSends": 0}


def missing_body(binary, directory):
    row = expected(message_id=SENT)[0]
    for condition in ("removed", "corrupt"):
        location = directory / condition
        fixture = LifecycleFixture(location)
        client_dir = location / "client"
        with Client(binary, client_dir, extra=fixture.options()) as client:
            initial = client.request("mail.read", messageId=SENT)
            require(attachment(initial, row)["id"] == row["providerId"], "missing-body setup lost token A")
            token_b = f"sent-{condition}-selected-B/%+?"
            fixture.rotate(SENT, token_b)
            thread = client.request("mail.thread", threadId=THREAD)["messages"]
            selected = attachment(next(message for message in thread if message["id"] == SENT), row)
            require(selected["id"] == token_b and not selected["data"], "picker did not receive unloaded token B")

            # Only touch this test's owned cache. A missing/corrupt immutable
            # body is recoverable; it must not erase the already verified
            # descriptor that the user selected from the thread.
            bodies = []
            for path in (client_dir / "cache").rglob("mail-*.json"):
                value = json.loads(path.read_text())
                if value.get("account") == ACCOUNTS[0] and value.get("message", {}).get("id") == SENT:
                    bodies.append(path)
            require(len(bodies) == 1, "missing-body setup could not identify its one owned immutable body")
            if condition == "removed":
                bodies[0].unlink()
            else:
                damaged = json.loads(bodies[0].read_text())
                damaged["message"]["bodyText"] = "Synthetic body bytes no longer match their verified hash."
                bodies[0].write_text(json.dumps(damaged) + "\n")

            # B remains a valid download token even though the next FULL read
            # reports C. Expected bytes still come from the checked-in PDF.
            response_b = copy.deepcopy(fixture.downloads[ACCOUNTS[0]][token_b])
            fixture.rotate(SENT, f"sent-{condition}-current-C")
            fixture.downloads[ACCOUNTS[0]][token_b] = response_b
            fixture.save(downloads=True)
            destination = location / "selected-before-body-loss.pdf"
            save(client, SENT, selected, destination, payload(row))
            fetched = client.request("mail.attachment", messageId=SENT, attachmentId=token_b)
            require(decode(fetched["data"]) == payload(row), "body recovery changed the selected download identity")
            no_writes(client)
    return {"bodyRemoved": True, "bodyCorrupt": True, "verifiedPickerTokenSurvivesNextFullRead": True,
            "fixtureSends": 0}


def unindexed(binary, directory):
    fixture = LifecycleFixture(directory)
    # This conversation is older than every retained metadata row. Provider
    # fixture dates otherwise overlap the pressure cache and admit the targets.
    for ordinal, message in enumerate(fixture.sources[ACCOUNTS[0]]["messages"]):
        message["internalDate"] = str(1600000000000 + ordinal * 1000)
    fixture.save()
    client_dir = directory / "client"
    seed_pressure_metadata(client_dir, 2000)
    with Client(binary, client_dir, extra=fixture.options(metadata_limit=2000)) as client:
        visible = client.request("mail.thread", threadId=THREAD)["messages"]
        parts = {message["id"]: message["attachments"][0] for message in visible}
        state_path = next((client_dir / "cache").rglob("index.json"))
        state = json.loads(state_path.read_text())
        require(len(state["entries"]) == 2000 and not any(
            entry["message"]["id"] in (RECEIVED, SENT) for entry in state["entries"]),
            "old-message test accidentally retained its targets in the bounded index")
        for message_id in (RECEIVED, SENT):
            row = expected(message_id=message_id)[0]
            selected = parts[message_id]
            old_id = selected["id"]
            old_reply = copy.deepcopy(fixture.downloads[ACCOUNTS[0]][old_id])
            fixture.rotate(message_id, "unindexed-next-full-" + message_id)
            fixture.downloads[ACCOUNTS[0]][old_id] = old_reply
            fixture.save(downloads=True)
            save(client, message_id, selected, directory / (message_id + "-visible.pdf"), payload(row))
            client.restart()
            save(client, message_id, selected, directory / (message_id + "-restart.pdf"), payload(row))
            require(client.request("cache.stats")["metadataEntries"] == 2000,
                    "saving an old message dropped unrelated cached metadata")
        no_writes(client)
    return {"metadataEntries": 2000, "olderIncomingAndSent": True, "restart": True, "fixtureSends": 0}


PRESSURE = json.loads((FIXTURE / "pressure.json").read_text())


def pressure_payload(row):
    block = bytes((row["patternSeed"] + index * 37) % 256 for index in range(256))
    prefix = (b"\x89PNG\r\n\x1a\nSynthetic pressure image\n" if row["mimeType"] == "image/png"
              else b"%PDF-1.4\n% Synthetic pressure document\n")
    raw = (prefix + block * ((row["size"] - len(prefix) + 255) // 256))[:row["size"]]
    require(hashlib.sha256(raw).hexdigest() == row["sha256"], "pressure payload differs from independent hash oracle")
    return raw


def pressure_message(direction):
    account = ACCOUNTS[0]
    identifier = f"pressure-{direction}"
    sender = account if direction == "sent" else "maya@example.test"
    to = "recipient@example.test, teammate@example.test" if direction == "sent" else account + ", teammate@example.test"
    reply_to = account if direction == "sent" else "reply@example.test"
    text_start = f"Synthetic {direction} attachment discussion.\n"
    plain = (text_start + ("Ordinary review notes and a literal file description.\n" * 180))[:PRESSURE["plainBytes"] - 1] + "\n"
    require(len(plain.encode()) == PRESSURE["plainBytes"], "pressure plain-body fixture has the wrong size")
    html_start = ('<!doctype html><html><head><style>table{border-collapse:collapse}td{padding:8px}</style></head>'
                  '<body><table><tr><td>' + text_start.strip() + '</td></tr></table><p>')
    html_end = ('</p><img src="cid:avatar@pressure.example.test"><img src="cid:logo@pressure.example.test">'
                '<p>Sent with omagma</p></body></html>')
    padding = PRESSURE["htmlBytes"] - len((html_start + html_end).encode())
    context = "Synthetic table and review context. "
    html = html_start + (context * ((padding + len(context) - 1) // len(context)))[:padding] + html_end
    require(len(html.encode()) == PRESSURE["htmlBytes"], "pressure HTML fixture has the wrong size")
    envelope = [("From", f"Fictional Correspondent <{sender}>"), ("Reply-To", reply_to), ("To", to),
                ("Cc", "copied@example.test"), ("Subject", "Re: Synthetic pressure review"),
                ("Message-ID", f"<{identifier}@example.test>"),
                ("In-Reply-To", "<parent@example.test>"), ("References", "<grandparent@example.test> <parent@example.test>"),
                ("Date", "Tue, 13 Oct 2026 10:30:00 +0000")]
    def part(mime_type, body, part_id, name="", cid=None, token=None):
        headers = [{"name": "Content-Type", "value": mime_type + ("; charset=utf-8" if mime_type.startswith("text/") else "")}]
        if name:
            headers.append({"name": "Content-Disposition", "value": ("inline" if cid else "attachment") + f'; filename="{name}"'})
        if cid:
            headers.append({"name": "Content-ID", "value": "<" + cid + ">"})
        return {"partId": part_id, "mimeType": mime_type, "filename": name, "headers": headers,
                "body": {"size": len(body), **({"attachmentId": token} if token else {"data": encode(body)})}}
    resources, files, downloads = [], [], {}
    for index, row in enumerate(PRESSURE["attachments"]):
        data = pressure_payload(row)
        token = f"{identifier}-file-{index}-A/%+?"
        leaf = part(row["mimeType"], data, f"1.{index}", row["filename"], row["contentId"], token)
        (resources if row["contentId"] else files).append(leaf)
        downloads[token] = {"size": len(data), "data": encode(data)}
    related = {"partId": "0.1", "mimeType": "multipart/related", "filename": "", "headers": [], "body": {"size": 0},
               "parts": [part("text/html", html.encode(), "0.1.0"), *resources]}
    alternative = {"partId": "0", "mimeType": "multipart/alternative", "filename": "", "headers": [], "body": {"size": 0},
                   "parts": [part("text/plain", plain.encode(), "0.0"), related]}
    root = {"partId": "", "mimeType": "multipart/mixed", "filename": "", "headers": [{"name": k, "value": v} for k, v in envelope],
            "body": {"size": 0}, "parts": [alternative, *files]}
    # Independent MIME construction supplies exact .eml source for RAW forward.
    raw = EmailMessage(policy=policy.SMTP)
    for name, value in envelope:
        raw[name] = value
    raw.set_content(plain)
    raw.add_alternative(html, subtype="html")
    html_part = raw.get_payload()[-1]
    for row in PRESSURE["attachments"]:
        major, minor = row["mimeType"].split("/")
        if row["contentId"]:
            html_part.add_related(pressure_payload(row), maintype=major, subtype=minor,
                                  filename=row["filename"], cid="<" + row["contentId"] + ">", disposition="inline")
        else:
            raw.add_attachment(pressure_payload(row), maintype=major, subtype=minor, filename=row["filename"])
    source = raw.as_bytes()
    message = {"id": identifier, "threadId": "pressure-thread-" + direction, "internalDate": "1791887400000",
               "labelIds": ["SENT"] if direction == "sent" else ["INBOX", "UNREAD"], "historyId": "500",
               "snippet": text_start.strip(), "payload": root}
    return message, downloads, {"plain": plain, "html": html, "raw": source, "messageId": f"<{identifier}@example.test>"}


@contextmanager
def pressure_raw(fixture, message_id, raw):
    # Gmail supplies RAW separately from FULL. Keep the large encoded MIME out
    # of unrelated FULL/download responses, and do not load download replies
    # for a RAW request that already contains every original byte.
    message = fixture.message(message_id)
    require("raw" not in message, "pressure FULL fixture accidentally contains RAW MIME")
    message["raw"] = encode(raw)
    fixture.save()
    try:
        yield
    finally:
        message.pop("raw")
        fixture.save(downloads=True)


def seed_pressure_metadata(client_dir, count):
    account_dir = client_dir / "cache/fixtures" / hashlib.sha256(ACCOUNTS[0].encode()).hexdigest()
    account_dir.mkdir(mode=0o700, parents=True)
    for parent in (client_dir / "cache", client_dir / "cache/fixtures"):
        parent.chmod(0o700)
    entries = []
    for index in range(count):
        direction = ("incoming", "sent")[index] if index < 2 else None
        identifier = "pressure-" + direction if direction else f"metadata-pressure-{index:04}"
        references = " ".join(f"<prior-{index:04}-{number:02}-synthetic-metadata@example.test>" for number in range(16))
        message = {"id": identifier, "threadId": "pressure-thread-" + direction if direction else identifier,
                   "from": {"address": "sender@example.test", "name": "Fictional metadata sender"},
                   "to": [], "cc": [], "replyTo": [], "subject": "Synthetic retained metadata " + "subject context " * 12,
                   "snippet": "Synthetic cached snippet " + "mail context " * 10, "bodyText": "", "bodyHtml": None,
                   "messageId": f"<{identifier}@example.test>", "references": references,
                   "receivedAt": 1791887400000 if direction else 1791700000000 - index * 1000,
                   "labels": ["SENT"] if direction == "sent" else ["INBOX"], "attachments": []}
        entries.append({"message": message, "bytes": 0, "bodyHash": ""})
    state = {"schema": 1, "account": ACCOUNTS[0], "generation": 7, "entries": entries, "historyId": "500",
             "drafts": [], "outbox": [], "operations": [], "views": [], "contacts": []}
    path = account_dir / "index.json"
    path.write_text(json.dumps(state, separators=(",", ":")) + "\n")
    path.chmod(0o600)
    return path.stat().st_size


def begin_fresh_capture(fixture):
    # FULL has already captured this descriptor-only source when the gate is
    # entered. Make external replies available only for the subsequent adapter
    # downloads, so the fixture decoder cannot preload the file data.
    hold, entered = fixture.root / "attachment-body.hold", fixture.root / "attachment-body.entered"
    hold.write_text("Synthetic body boundary.\n")
    entered.unlink(missing_ok=True)
    fixture.sources[ACCOUNTS[0]]["sync"]["fixtureProgress"] = {
        "phase": "bodies", "completed": 0, "fixtureHold": hold.name, "fixtureEntered": entered.name}
    fixture.save()
    return hold, entered


def enable_fresh_downloads(fixture):
    fixture.sources[ACCOUNTS[0]]["sync"].pop("fixtureProgress")
    fixture.save(downloads=True)


def gated_fresh_draft(client, fixture, cmd, **params):
    hold, entered = begin_fresh_capture(fixture)
    client.next_id += 1
    request = {"id": f"test-{client.next_id}", "account": ACCOUNTS[0], "cmd": cmd, **params}
    client.raw(json.dumps(request).encode() + b"\n")
    try:
        deadline = time.monotonic() + 5
        while not entered.exists():
            require(client.process.poll() is None and time.monotonic() < deadline, "formatted FULL did not reach its descriptor-only fixture boundary")
            time.sleep(.005)
        enable_fresh_downloads(fixture)
    finally:
        hold.unlink(missing_ok=True)
    reply = client.receive(timeout=30)
    require(reply.get("id") == request["id"] and reply.get("account") == ACCOUNTS[0], "gated draft response lost its account/request identity")
    require(reply.get("ok") is True, f"{cmd} failed after a descriptor-only FULL: {reply.get('error', {}).get('code')}")
    return reply["data"]


def check_pressure_parts(parts, rows, inline=False):
    require(len(parts) == len(rows), "pressure draft lost or invented an attachment/resource")
    by_name = {part["filename"]: part for part in parts}
    require(len(by_name) == len(parts), "pressure draft duplicated a file identity")
    for row in rows:
        require(row["filename"] in by_name, "pressure draft omitted an expected file")
        part = by_name[row["filename"]]
        require(part["size"] == row["size"] and part["mimeType"] == row["mimeType"]
                and decode(part["data"]) == pressure_payload(row), "pressure draft changed attachment bytes/type/size")
        if inline:
            require(part["contentId"] == row["contentId"], "formatted snapshot changed an HTML resource reference")


def conversation_modes(binary, directory):
    outcomes, peak = [], 0
    for count in PRESSURE["metadataCounts"]:
        location = directory / str(count)
        fixture = LifecycleFixture(location)
        sources, downloads, originals = [], {}, {}
        for direction in ("incoming", "sent"):
            source, replies, original = pressure_message(direction)
            sources.append(source)
            downloads.update(replies)
            originals[direction] = original
        fixture.sources[ACCOUNTS[0]]["messages"] = sources
        fixture.downloads[ACCOUNTS[0]] = downloads
        fixture.save()
        client_dir = location / "client"
        index_bytes = seed_pressure_metadata(client_dir, count)
        extra = fixture.options(metadata_limit=count)
        with Client(binary, client_dir, extra=extra) as client:
            require(client.request("cache.stats")["metadataEntries"] == count, "pressure test did not retain the intended metadata population")
            for direction in ("incoming", "sent"):
                message_id = "pressure-" + direction
                message = client.request("mail.read", messageId=message_id)
                require(len(message["bodyText"].encode()) == PRESSURE["plainBytes"] and
                        len(message["bodyHtml"].encode()) == PRESSURE["htmlBytes"] and
                        len(message["attachments"]) == 4 and all(not part["data"] for part in message["attachments"]),
                        "pressure fixture preloaded external files or changed the normal mail shape")
            for direction in ("incoming", "sent"):
                for index in range(4):
                    fixture.rotate("pressure-" + direction, f"pressure-{direction}-{index}-B/%+?", occurrence=index)
                client.request("mail.thread", threadId="pressure-thread-" + direction)
            fixture.save(downloads=True)
            for direction in ("incoming", "sent"):
                message_id = "pressure-" + direction
                original = originals[direction]
                body_format = "markdown" if (count == 414) == (direction == "sent") else "plain"
                for mode in PRESSURE["modes"]:
                    forward = mode.startswith("forward-")
                    formatted = mode.endswith("formatted")
                    raw_original = mode == "forward-original"
                    omit = mode == "forward-omit"
                    params = {"messageId": message_id, "bodyFormat": body_format}
                    if formatted:
                        params["preserveFormatting"] = True
                    if raw_original:
                        params["original"] = True
                    if omit:
                        params["omitAttachments"] = True
                    if mode.startswith("reply-all-"):
                        params["all"] = True
                    cmd = "mail.forward" if forward else "mail.reply"
                    if raw_original:
                        with pressure_raw(fixture, message_id, original["raw"]):
                            draft = client.request(cmd, **params)
                    else:
                        draft = (gated_fresh_draft(client, fixture, cmd, **params) if formatted
                                 else client.request(cmd, **params))
                    require(draft["bodyFormat"] == body_format and not draft["bcc"], "conversation mode changed note format or inferred Bcc")
                    if forward:
                        require(not any(draft[key] for key in ("to", "cc", "threadId", "inReplyTo", "references")),
                                "forward retained source recipients or reply threading")
                    else:
                        wanted_to = ["recipient@example.test", "teammate@example.test"] if direction == "sent" else ["reply@example.test"]
                        wanted_cc = (["copied@example.test"] if direction == "sent" else ["teammate@example.test", "copied@example.test"]) if params.get("all") else []
                        require([value["address"] for value in draft["to"]] == wanted_to and
                                [value["address"] for value in draft["cc"]] == wanted_cc, "reply mode changed exact incoming/Sent recipients")
                        require(draft["threadId"] == "pressure-thread-" + direction and
                                draft["inReplyTo"] == original["messageId"] and draft["references"].endswith(original["messageId"]),
                                "reply mode lost original threading")
                    if formatted:
                        snapshot = draft["original"]
                        require(snapshot["sourceMessageId"] == message_id and snapshot["bodyText"] == original["plain"]
                                and snapshot["bodyHtml"] == original["html"] and not draft["bodyText"],
                                "formatted mode changed its frozen original or editable note")
                        check_pressure_parts(snapshot["resources"], PRESSURE["attachments"][:2], inline=True)
                        check_pressure_parts(draft["attachments"], PRESSURE["attachments"][2:] if forward else [])
                    elif raw_original:
                        require(len(draft["attachments"]) == 1 and draft["attachments"][0]["filename"].endswith(".eml")
                                and decode(draft["attachments"][0]["data"]) == original["raw"], "RAW forward changed the exact original MIME")
                    else:
                        # Markdown source escapes punctuation; the visible
                        # identifying phrase remains the same in both formats.
                        require("Synthetic " + direction + " attachment discussion" in draft["bodyText"] and not draft.get("original"),
                                "text mode lost the quoted source or invented an HTML snapshot")
                        check_pressure_parts(draft["attachments"], PRESSURE["attachments"] if forward and not omit else [])
                    require(draft.get("omittedAttachments", 0) == (4 if omit else 0), "explicit omitted-file warning changed")
                    stats = client.request("cache.stats")
                    require(stats["metadataEntries"] == count and stats["rejectedAllocations"] == 0
                            and stats["allocatorPeakBytes"] <= stats["terminalHeapLimitBytes"],
                            "conversation mode exceeded its bounded heap or dropped retained metadata")
                    peak = max(peak, stats["allocatorPeakBytes"])
                    snapshot = read_snapshot(client, draft)
                    client.restart()
                    require(client.request("draft.read", draftId=draft["id"]) == snapshot, "reopened pressure draft lost frozen files/resources or participants")
                    client.request("draft.discard", draftId=draft["id"])
                    outcomes.append({"metadataEntries": count, "direction": direction, "mode": mode,
                                     "bodyFormat": body_format, "indexBytes": index_bytes})
            no_writes(client)
    return {"workflows": outcomes, "workflowCount": len(outcomes), "allocatorPeakBytes": peak,
            "plainBytes": PRESSURE["plainBytes"], "htmlBytes": PRESSURE["htmlBytes"], "fixtureSends": 0}


def large_forward_source(direction, sizes):
    """Independent MIME construction; byte expectations never come from the app."""
    mail = EmailMessage(policy=policy.SMTP)
    mail["From"] = ACCOUNTS[0] if direction == "sent" else "maya@example.test"
    mail["To"] = "recipient@example.test" if direction == "sent" else ACCOUNTS[0]
    mail["Subject"] = "Synthetic multi-document review"
    mail["Message-ID"] = f"<large-{direction}@example.test>"
    mail["Date"] = "Tue, 13 Oct 2026 10:30:00 +0000"
    mail.set_content("Please review all three attached documents.\n")
    mail.add_alternative("<html><body><p>Please review all three attached documents.</p></body></html>", subtype="html")
    expected_files = {}
    for index, size in enumerate(sizes):
        prefix = f"%PDF-1.4\n% Synthetic independent document {index}\n".encode()
        pattern = bytes((index * 31 + offset * 17) % 256 for offset in range(256))
        content = prefix + (pattern * ((size - len(prefix) + 255) // 256))[:size - len(prefix)]
        name = f"review-{index + 1}.pdf"
        expected_files[name] = content
        mail.add_attachment(content, maintype="application", subtype="pdf", filename=name)
    raw = mail.as_bytes()
    source, downloads = gmail_from_wire({"id": "pressure-" + direction,
                                        "threadId": "pressure-thread-" + direction, "fixtureRaw": encode(raw)}, 17)
    source.pop("raw")
    source["labelIds"] = ["SENT"] if direction == "sent" else ["INBOX", "UNREAD"]
    return source, downloads, expected_files, raw


def verify_draft_file(client_dir, part, raw):
    require(part["size"] == len(raw), "forward changed a document's decoded size")
    if part.get("blobId"):
        require(not part["data"], "forward mixed inline bytes with a file handle")
        candidates = list((client_dir / "cache").rglob("blob-" + part["blobId"] + ".bin"))
        require(len(candidates) == 1, "forwarded document has no unique private backing file")
        verify_file(candidates[0], raw)
    else:
        require(decode(part["data"]) == raw, "forward changed a document's bytes")


def large_forwards(binary, directory):
    outcomes = []
    # Both are commonplace: several sub-2-MiB PDFs, then several individually
    # larger PDFs. The populated cache must not consume the forwarding budget.
    for label, sizes in (("aggregate", (900000,) * 3), ("individual", (2200000,) * 3)):
        for direction in ("incoming", "sent"):
            location = directory / (label + "-" + direction)
            fixture = LifecycleFixture(location)
            source, downloads, expected_files, raw = large_forward_source(direction, sizes)
            fixture.sources[ACCOUNTS[0]]["messages"] = [source]
            fixture.downloads[ACCOUNTS[0]] = downloads
            fixture.save()
            client_dir = location / "client"
            seed_pressure_metadata(client_dir, 2000)
            message_id = source["id"]
            with Client(binary, client_dir, extra=fixture.options(metadata_limit=2000)) as client:
                visible = client.request("mail.read", messageId=message_id)
                require(len(visible["attachments"]) == 3 and all(not part["data"] and not part.get("blobId")
                        for part in visible["attachments"]), "large forward test preloaded documents")
                for mode in ("text", "formatted", "original"):
                    if mode == "original":
                        # RAW includes MIME overhead; all examples remain well
                        # below the normal outgoing message limit.
                        with pressure_raw(fixture, message_id, raw):
                            draft = client.request("mail.forward", messageId=message_id, original=True)
                        require(len(draft["attachments"]) == 1 and draft["attachments"][0]["filename"].endswith(".eml"),
                                "original-message forwarding lost its .eml container")
                        verify_draft_file(client_dir, draft["attachments"][0], raw)
                    else:
                        if mode == "formatted":
                            draft = gated_fresh_draft(client, fixture, "mail.forward", messageId=message_id, preserveFormatting=True)
                            require("Please review all three" in draft["original"]["bodyHtml"],
                                    "formatted large forward lost the original HTML")
                        else:
                            fixture.save(downloads=True)
                            draft = client.request("mail.forward", messageId=message_id)
                        require(len(draft["attachments"]) == 3, "large forward omitted ordinary documents")
                        for part in draft["attachments"]:
                            require(part["filename"] in expected_files, "large forward invented a filename")
                            verify_draft_file(client_dir, part, expected_files[part["filename"]])
                    require(not any(draft[key] for key in ("to", "cc", "bcc", "threadId", "inReplyTo", "references")),
                            "large forward retained source recipients or threading")
                    live_stats = client.request("cache.stats")
                    require(live_stats["metadataEntries"] == 2000 and live_stats["rejectedAllocations"] == 0,
                            "large forward exhausted the heap or evicted metadata before restart")
                    snapshot = read_snapshot(client, draft)
                    client.restart()
                    require(client.request("draft.read", draftId=draft["id"]) == snapshot,
                            "large forwarded files did not survive a cold restart")
                    client.request("draft.discard", draftId=draft["id"])
                    stats = client.request("cache.stats")
                    require(stats["metadataEntries"] == 2000 and stats["rejectedAllocations"] == 0,
                            "large forward exhausted the heap or evicted metadata to succeed")
                    outcomes.append({"shape": label, "direction": direction, "mode": mode,
                                     "fileBytes": sum(sizes), "rawBytes": len(raw),
                                     "allocatorPeakBytes": live_stats["allocatorPeakBytes"]})
                no_writes(client)
    return {"workflows": outcomes, "workflowCount": len(outcomes), "metadataEntries": 2000, "fixtureSends": 0}


def synthetic_png(size, ordinal):
    """A complete independent raster, including valid chunk lengths and CRCs."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    height, width = 256, (size - 8192) // (256 * 3)
    row = bytes((ordinal * 19 + n * 13) % 256 for n in range(width * 3))
    pixels = b"".join(b"\0" + row for _ in range(height))
    start = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    start += chunk(b"IDAT", zlib.compress(pixels, level=0))
    end = chunk(b"IEND", b"")
    padding = size - len(start) - len(end) - 12
    require(padding >= 0, "invalid raster oracle size")
    return start + chunk(b"npAD", b"x" * padding) + end


def large_related_source(direction, sizes):
    mail = EmailMessage(policy=policy.SMTP)
    mail["From"] = ACCOUNTS[0] if direction == "sent" else "maya@example.test"
    mail["To"] = "recipient@example.test" if direction == "sent" else ACCOUNTS[0]
    mail["Cc"] = "copied@example.test"
    mail["Subject"] = "Synthetic illustrated review"
    mail["Message-ID"] = f"<illustrated-{direction}@example.test>"
    mail["Date"] = "Tue, 13 Oct 2026 10:30:00 +0000"
    mail.set_content("Please review the embedded illustrations and attached document.\n")
    html = "<html><body><p>Original illustrated review</p>" + "".join(
        f'<img alt="Illustration {i}" src="' + (f"assets/photo-{i}.png" if i == 1 else f"cid:photo-{i}@example.test") + '">'
        for i in range(len(sizes))) + "</body></html>\r\n"
    mail.add_alternative(html, subtype="html")
    rich = mail.get_payload()[1]
    images = {}
    for i, size in enumerate(sizes):
        content = synthetic_png(size, i)
        name = f"photo-{i}.png"
        images[name] = content
        rich.add_related(content, maintype="image", subtype="png", filename=name,
                         cid=f"<photo-{i}@example.test>", disposition="inline")
        if i == 1:
            rich.get_payload()[-1]["Content-Location"] = f"assets/photo-{i}.png"
    document = b"%PDF-1.4\n% Synthetic separate review document\n%%EOF\n"
    mail.add_attachment(document, maintype="application", subtype="pdf", filename="review.pdf")
    raw = mail.as_bytes()
    parsed = BytesParser(policy=policy.default).parsebytes(raw)
    expected_html = next(part.get_payload(decode=True).decode() for part in parsed.walk() if part.get_content_type() == "text/html")
    source, downloads = gmail_from_wire({"id": "pressure-" + direction,
                                        "threadId": "pressure-thread-" + direction, "fixtureRaw": encode(raw)}, 19)
    source.pop("raw")
    source["labelIds"] = ["SENT"] if direction == "sent" else ["INBOX", "UNREAD"]
    return source, downloads, images, document, expected_html


def large_related(binary, directory):
    outcomes = []
    for shape, sizes in (("aggregate", (900000,) * 3), ("individual", (2200000,))):
        for direction in ("incoming", "sent"):
            location = directory / (shape + "-" + direction)
            fixture = LifecycleFixture(location)
            source, downloads, images, document, html = large_related_source(direction, sizes)
            fixture.sources[ACCOUNTS[0]]["messages"] = [source]
            fixture.downloads[ACCOUNTS[0]] = downloads
            fixture.save()
            client_dir = location / "client"
            seed_pressure_metadata(client_dir, 2000)
            with Client(binary, client_dir, extra=fixture.options(metadata_limit=2000)) as client:
                visible = client.request("mail.read", messageId=source["id"])
                require(len(visible["attachments"]) == len(images) + 1 and all(not item["data"] for item in visible["attachments"]),
                        "illustration fixture preloaded file bytes")
                for mode in ("reply", "reply-all", "forward"):
                    params = {"messageId": source["id"], "preserveFormatting": True}
                    if mode == "reply-all":
                        params["all"] = True
                    draft = gated_fresh_draft(client, fixture, "mail.forward" if mode == "forward" else "mail.reply", **params)
                    original = draft["original"]
                    require(original["bodyHtml"] == html, "preserved illustrated mail changed its original HTML")
                    require(len(original["resources"]) == len(images), "preserved mail omitted an inline resource")
                    for part in original["resources"]:
                        require(part["filename"] in images and part["contentId"] == part["filename"].removesuffix(".png") + "@example.test",
                                "preserved resource lost its filename or CID")
                        if part["filename"] == "photo-1.png":
                            require(part["contentLocation"] == "assets/photo-1.png", "preserved resource lost Content-Location")
                        verify_draft_file(client_dir, part, images[part["filename"]])
                    require(len(draft["attachments"]) == (1 if mode == "forward" else 0), "related resources leaked into ordinary attachments")
                    if mode == "forward":
                        verify_draft_file(client_dir, draft["attachments"][0], document)
                        require(not any(draft[key] for key in ("to", "cc", "bcc", "threadId")), "forward inferred recipients or reply threading")
                    live = client.request("cache.stats")
                    require(live["rejectedAllocations"] == 0 and live["metadataEntries"] == 2000,
                            "large inline resources exhausted the heap or discarded cache metadata")
                    snapshot = read_snapshot(client, draft)
                    client.restart()
                    require(client.request("draft.read", draftId=draft["id"]) == snapshot, "cold draft reopen lost related files or HTML")
                    preview = client.request("draft.open-preview", draftId=draft["id"])
                    preview_path = Path(preview["path"])
                    require(not preview["opened"] and stat.S_IMODE(preview_path.stat().st_mode) == 0o600,
                            "fixture preview opened a browser or published nonprivate content")
                    preview_bytes = preview_path.read_bytes()
                    rendered = [base64.b64decode(value, validate=True) for value in re.findall(rb"data:image/png;base64,([A-Za-z0-9+/=]+)", preview_bytes)]
                    require(all(raw in rendered for raw in images.values()), "browser preview dropped or changed a large embedded image")
                    preview_markup = unescape(preview_bytes.decode())
                    require("connect-src 'none'" in preview_markup and "img-src data:" in preview_markup,
                            "preview no longer restricts remote network content")
                    blobs = [part for part in original["resources"] if part.get("blobId")]
                    require(blobs, "large illustrated original was not backed by private files")
                    for part in blobs:
                        refused = client.request("attachment.discard", blobId=part["blobId"], ok=False)
                        require(refused["code"] == "AttachmentInUse", "related draft did not protect its original's blob")
                    outcomes.append({"shape": shape, "direction": direction, "mode": mode,
                                     "resourceBytes": sum(sizes), "allocatorPeakBytes": live["allocatorPeakBytes"],
                                     "previewBytes": len(preview_bytes)})
                    client.request("draft.discard", draftId=draft["id"])
                no_writes(client)
    return {"workflowCount": len(outcomes), "workflows": outcomes, "fixtureSends": 0}



def send_boundaries(binary, directory):
    """Exercise outgoing transport after a real forward/reply, across both
    MIME/base64 expansion and the separate 2-MiB blob-spill boundary."""
    outcomes = []
    for sizes in ((1200000,), (1900000,), (900000, 900000), (2200000,)):
        for direction in ("incoming", "sent"):
            for illustrated in (False, True):
                location = directory / (str(sizes) + direction + str(illustrated))
                fixture = LifecycleFixture(location)
                if illustrated:
                    source, downloads, images, document, html = large_related_source(direction, sizes)
                    expected_files = images | {"review.pdf": document}
                    modes = ("reply", "reply-all", "forward")
                else:
                    source, downloads, expected_files, _raw = large_forward_source(direction, sizes)
                    modes = ("text", "formatted")
                fixture.sources[ACCOUNTS[0]]["messages"] = [source]
                fixture.downloads[ACCOUNTS[0]] = downloads
                # Gmail FULL carries attachment descriptors; attachment bytes
                # arrive through separate requests. Do not inject the complete
                # download map into the FULL decoder (a >2-MiB file is not a
                # >2-MiB message body).
                fixture.save()
                client_dir = location / "client"
                with Client(binary, client_dir, extra=fixture.options()) as client:
                    visible = client.request("mail.read", messageId=source["id"])
                    require(not visible["bodyCacheError"] and all(not part["data"] for part in visible["attachments"]),
                            "send boundary did not start from a descriptor-only FULL")
                    fixture.save(downloads=True)
                    for mode in modes:
                        params = {"messageId": source["id"]}
                        if mode != "text":
                            params["preserveFormatting"] = True
                        if mode == "reply-all":
                            params["all"] = True
                        cmd = "mail.reply" if mode.startswith("reply") else "mail.forward"
                        draft = (client.request(cmd, **params) if mode == "text"
                                 else gated_fresh_draft(client, fixture, cmd, **params))
                        draft["to"] = [{"address": "recipient@example.test"}]
                        draft["bodyText"] = "Reviewed synthetic mail."
                        draft = client.request("draft.update", draftId=draft["id"], draft=draft)
                        snapshot = read_snapshot(client, draft)
                        client.restart()
                        require(client.request("draft.read", draftId=draft["id"]) == snapshot,
                                "send boundary draft changed after restart")
                        operation = "transport-" + mode
                        sent = client.request("draft.send", draftId=draft["id"], operationId=operation)
                        require(sent["outcome"] == "applied", "ordinary mail exceeded the JSON send transport")
                        require(client.request("draft.send", draftId=draft["id"], operationId=operation) == sent,
                                "send boundary retried the provider")
                        message = client.request("mail.read", messageId=sent["messageId"])
                        for ordinal, part in enumerate(message["attachments"]):
                            require(part["filename"] in expected_files, "send invented an attachment")
                            save(client, message["id"], part, location / (mode + str(ordinal) + ".bin"), expected_files[part["filename"]])
                        expected_count = len(sizes) + (1 if illustrated and mode == "forward" else 0)
                        require(len(message["attachments"]) == expected_count, "send lost a forwarded or inline part")
                        client.restart()
                        cold = client.request("mail.read", messageId=sent["messageId"], cacheOnly=True)
                        require(cold["attachments"] == message["attachments"], "sent attachments changed after restart")
                        stats = client.request("cache.stats")
                        require(stats["rejectedAllocations"] == 0, "send boundary exhausted its operation budget")
                        outcomes.append({"sizes": sizes, "direction": direction, "mode": mode,
                                         "illustrated": illustrated, "allocatorPeakBytes": stats["allocatorPeakBytes"]})
    return {"workflowCount": len(outcomes), "workflows": outcomes}


def imported(client, directory, name, raw, mime_type="application/octet-stream"):
    directory.mkdir(parents=True, exist_ok=True)
    source = directory / name
    source.write_bytes(raw)
    part = client.request("attachment.import", path=str(source), mimeType=mime_type)
    require(part.get("blobId") and not part["data"] and part["size"] == len(raw),
            "import did not freeze the selected file")
    source.unlink()
    return part


def gmail_from_wire(sent, ordinal):
    """Independent email parser models Gmail's new part/token assignment.

    It supplies provider data, never expected file bytes. The cold consumer has
    no fixture outbox and no imported blob from the producing session.
    """
    wire = decode(sent["fixtureRaw"])
    parsed = BytesParser(policy=policy.default).parsebytes(wire)
    require(all(not item.defects for item in parsed.walk()), "synthetic send produced malformed MIME")
    external = {}

    def convert(item, path):
        result = {"partId": path, "mimeType": item.get_content_type(),
                  "filename": item.get_filename() or "",
                  "headers": [{"name": key, "value": str(value)} for key, value in item.items()]}
        if item.is_multipart():
            result["body"] = {"size": 0}
            result["parts"] = [convert(child, f"{path}.{index}") for index, child in enumerate(item.iter_parts())]
        else:
            raw = item.get_payload(decode=True) or b""
            if result["filename"] or item.get("Content-ID"):
                token = f"gmail-{ordinal}-{path}/opaque%+?"
                result["body"] = {"size": len(raw), "attachmentId": token}
                # Empty external descriptors need no download response.
                if raw:
                    external[token] = {"size": len(raw), "data": encode(raw)}
            else:
                result["body"] = {"size": len(raw), "data": encode(raw)}
        return result

    return ({"id": sent["id"], "threadId": sent["threadId"], "labelIds": ["SENT"],
             "internalDate": str(1791886000000 + ordinal * 1000), "historyId": "500",
             "snippet": "Synthetic provider-owned sent attachment", "payload": convert(parsed, "0"),
             "raw": encode(wire)}, external)


def expected_parts(message, rows):
    selected = []
    seen = {}
    for name, raw in rows:
        occurrence = seen.get(name, 0)
        candidates = [part for part in message["attachments"] if part["filename"] == name]
        require(len(candidates) > occurrence, f"sent message lost {name!r}")
        selected.append((candidates[occurrence], raw))
        seen[name] = occurrence + 1
    return selected


def capture_small_wire(client, draft, blobs, operation):
    # Imported-file sends use a disposable spool and intentionally expose no
    # fixtureRaw. Keep those sends' own retention checks, and separately send
    # this small equivalent inline draft to inspect the actual emitted MIME.
    # Blob content comes from the original import oracle, never the outbox DTO.
    inline = copy.deepcopy(draft)
    inline.pop("id", None)
    for part in inline["attachments"] + (inline.get("original") or {}).get("resources", []):
        if part.get("blobId"):
            raw = blobs[part["blobId"]]
            require(len(raw) == part["size"], "inline wire twin changed its reviewed file size")
            part.update(data=encode(raw), blobId=None)
    saved = client.request("draft.create", draft=inline)
    receipt = client.request("draft.send", draftId=saved["id"], operationId=operation)
    require(receipt["outcome"] == "applied", "small inline wire fixture did not apply")
    sent = client.request("mail.read", messageId=receipt["messageId"])
    require(sent.get("fixtureRaw"), "small inline fixture send omitted its actual MIME")
    return sent


def drafts(binary, directory):
    fixture = LifecycleFixture(directory)
    submitted = []
    report = payload(expected(message_id=SENT)[0])
    duplicate = payload(expected(message_id=DUPLICATES)[1])
    with Client(binary, directory / "producer", extra=fixture.options()) as client:
        first = imported(client, directory / "imports/one", "report.pdf", report, "application/pdf")
        second = imported(client, directory / "imports/two", "report.pdf", duplicate, "application/pdf")
        empty = imported(client, directory / "imports/empty", "empty café.txt", b"", "text/plain")
        blobs = {first["blobId"]: report, second["blobId"]: duplicate, empty["blobId"]: b""}
        draft = client.request("draft.create", draft={"to": "recipient@example.test", "subject": "Three synthetic files",
                               "bodyText": "Review the attached files.", "attachments": [first, second, empty]})
        retained = client.request("draft.create", draft={"to": "later@example.test", "subject": "Retained shared file",
                                  "bodyText": "Keep this local draft.", "attachments": [first]})
        client.restart()
        require(client.request("draft.read", draftId=draft["id"])["attachments"] == draft["attachments"],
                "restart changed imported multiple-file draft")
        no_writes(client)
        receipt = client.request("draft.send", draftId=draft["id"], operationId="lifecycle-new")
        require(receipt["outcome"] == "applied", "synthetic new composition did not apply")
        sent = client.request("mail.read", messageId=receipt["messageId"])
        rows = [("report.pdf", report), ("report.pdf", duplicate), ("empty café.txt", b"")]
        submitted.append((capture_small_wire(client, draft, blobs, "lifecycle-wire-new"), rows))
        for index, (part, raw) in enumerate(expected_parts(sent, rows)):
            save(client, sent["id"], part, directory / f"local-sent-{index}.bin", raw)
        require(client.request("attachment.discard", blobId=first["blobId"], ok=False)["code"] == "AttachmentInUse",
                "sending discarded a blob still referenced by another draft")
        client.restart()
        require(client.request("draft.read", draftId=retained["id"])["attachments"] == [first],
                "sending/restarting changed a retained draft sharing the imported file")
        reopened = client.request("mail.read", messageId=sent["id"], cacheOnly=True)
        for index, (part, raw) in enumerate(expected_parts(reopened, rows)):
            save(client, sent["id"], part, directory / f"local-sent-restarted-{index}.bin", raw)

        # Ordinary forward keeps files. Reply-all keeps its inline original,
        # adds an explicitly imported file, and preserves recipient/thread IDs.
        fixture.save(downloads=True)
        for index, forward in enumerate((True, False), 1):
            params = {"messageId": FORMATTED, "preserveFormatting": True, "bodyFormat": "markdown"}
            if not forward:
                params["all"] = True
            item = client.request("mail.forward" if forward else "mail.reply", **params)
            require(item.get("original") and len(item["original"]["resources"]) == 1,
                    "formatted original lost its independent inline resource")
            if forward:
                require([part["filename"] for part in item["attachments"]] == ["café β notes.bin", "empty.txt"],
                        "forward dropped ordinary or empty files")
                item["to"] = [{"address": "recipient@example.test"}]
            else:
                require([value["address"] for value in item["to"]] == ["maya@example.test"] and
                        {value["address"] for value in item["cc"]} == {"teammate@example.test", "copied@example.test"},
                        "reply-all changed recipients")
                require(item["threadId"] == THREAD and not item["attachments"], "reply-all duplicated source files")
            item["attachments"].append(first)
            item["bodyText"] = "**Reviewed** synthetic attachments."
            item = client.request("draft.update", draftId=item["id"], draft=item)
            if forward:
                resource = next(row for row in expected(message_id=FORMATTED) if row["contentId"])
                handle = imported(client, directory / "imports/resource", resource["filename"], payload(resource), "image/png")
                blobs[handle["blobId"]] = payload(resource)
                supported = copy.deepcopy(item)
                supported["original"]["resources"][0].update(data="", blobId=handle["blobId"])
                item = client.request("draft.update", draftId=item["id"], draft=supported)
                verify_draft_file(client.directory, item["original"]["resources"][0], payload(resource))
                snapshot = read_snapshot(client, item)
                wrong_size = copy.deepcopy(item)
                wrong_size["original"]["resources"][0]["size"] += 1
                refused = client.request("draft.update", draftId=item["id"], draft=wrong_size, ok=False)
                require(refused["code"] in ("AttachmentChanged", "BodySizeMismatch", "InvalidAttachment"),
                        "wrong-size resource handle was not refused")
                foreign = copy.deepcopy(item)
                foreign["original"]["resources"][0]["blobId"] = "0" * 64
                refused = client.request("draft.update", draftId=item["id"], draft=foreign, ok=False)
                require(refused["code"] == "AttachmentHandleNotFound",
                        f"unowned resource handle returned the wrong failure: {refused['code']}")
                require(client.request("draft.read", draftId=item["id"]) == snapshot,
                        "refused original-resource update changed the saved draft")
            frozen = copy.deepcopy(item["original"])
            client.request("cache.clear")
            client.restart()
            require(client.request("draft.read", draftId=item["id"])["original"] == frozen,
                    "cache clear/restart changed the frozen original resource")
            result = client.request("draft.send", draftId=item["id"], operationId=f"lifecycle-formatted-{index}")
            require(result["outcome"] == "applied", "synthetic formatted send did not apply")
            sent = client.request("mail.read", messageId=result["messageId"])
            resource = next(row for row in expected(message_id=FORMATTED) if row["contentId"])
            rows = [(resource["filename"], payload(resource)), ("report.pdf", report)]
            if forward:
                rows += [(row["filename"], payload(row)) for row in expected(message_id=FORMATTED) if not row["contentId"]]
            submitted.append((capture_small_wire(client, item, blobs, f"lifecycle-wire-formatted-{index}"), rows))
            require(client.request("draft.send", draftId=item["id"], operationId=f"lifecycle-formatted-{index}") == result,
                    "send receipt replay changed its outcome")
            client.restart()
            reopened = client.request("mail.read", messageId=sent["id"], cacheOnly=True)
            for part_number, (part, raw) in enumerate(expected_parts(reopened, rows)):
                save(client, sent["id"], part, directory / f"formatted-restarted-{index}-{part_number}.bin", raw)
        require(client.request("cache.stats")["fixtureSends"] == 6,
                "lifecycle send count differs from three imported-file sends and three small wire captures")

    # A new provider session receives Gmail-shaped MIME with unrelated IDs.
    # Never let fixture readOutbox or local immutable blobs stand in for Gmail.
    fixture.sources[ACCOUNTS[0]]["messages"] = []
    fixture.downloads[ACCOUNTS[0]] = {}
    for index, (sent, _) in enumerate(submitted):
        message, external = gmail_from_wire(sent, index)
        fixture.sources[ACCOUNTS[0]]["messages"].append(message)
        fixture.downloads[ACCOUNTS[0]].update(external)
    fixture.save()
    cold = directory / "cold-provider-reader"
    with Client(binary, cold, extra=fixture.options()) as client:
        read = {sent["id"]: client.request("mail.read", messageId=sent["id"]) for sent, _ in submitted}
        require(not list((cold / "cache").rglob("blob-*.bin")), "provider reread accidentally reused producer blobs")
        fixture.save(downloads=True)
        client.restart()
        for number, (sent, rows) in enumerate(submitted):
            for index, (part, raw) in enumerate(expected_parts(read[sent["id"]], rows)):
                require(part["id"].startswith("gmail-") and not part.get("blobId") and not part["data"],
                        "provider reread retained an imported/local attachment identity")
                save(client, sent["id"], part, directory / f"provider-sent-{number}-{index}.bin", raw)
        no_writes(client)
    return {"explicitFixtureSends": 6, "newForwardReplyAll": True, "coldProviderRemap": True,
            "retainedSharedDraft": True, "frozenOriginalResources": True}


def uncertain(binary, directory):
    fixture = LifecycleFixture(directory)
    fixture.save(downloads=True)
    for scenario in ("unknown-send", "applied-lost"):
        with Client(binary, directory / scenario, scenario=scenario, extra=fixture.options()) as client:
            draft = client.request("mail.forward", messageId=FORMATTED, preserveFormatting=True)
            file = imported(client, directory / scenario / "source", "report.pdf", payload(expected(message_id=SENT)[0]))
            draft.update(to=[{"address": "recipient@example.test"}], bodyText="Synthetic uncertain review.")
            draft["attachments"].append(file)
            draft = client.request("draft.update", draftId=draft["id"], draft=draft)
            snapshot = read_snapshot(client, draft)
            receipt = client.request("draft.send", draftId=draft["id"], operationId="attachment-unknown")
            require(receipt["outcome"] == "unknown", "fixture uncertainty became a definite send")
            before = client.request("cache.stats")
            client.request("cache.clear")
            client.restart()
            require(client.request("draft.read", draftId=draft["id"]) == snapshot, "uncertain send lost retained attachments/original")
            for cmd, params in (("draft.discard", {"draftId": draft["id"]}),
                                ("draft.update", {"draftId": draft["id"], "draft": {**draft, "attachments": []}})):
                require(client.request(cmd, ok=False, **params)["code"] == "UnknownOutcome", "uncertain draft was editable/discardable")
            require(client.request("attachment.discard", blobId=file["blobId"], ok=False)["code"] == "AttachmentInUse",
                    "uncertain send allowed its imported bytes to be removed")
            for operation in ("attachment-unknown", "another-identity"):
                require(client.request("draft.send", draftId=draft["id"], operationId=operation) == receipt,
                        "uncertain attachment send was resubmitted")
            after = client.request("cache.stats")
            require(after["fixtureCalls"] == before["fixtureCalls"] and after["fixtureSends"] == before["fixtureSends"],
                    "uncertain replay reached the provider")
    return {"unknownSendAndLostResponse": True, "restart": True, "resubmissions": 0}


def failures(binary, directory):
    fixture = LifecycleFixture(directory)
    row = expected(message_id=SENT)[0]
    with Client(binary, directory / "client", extra=fixture.options()) as client:
        part = attachment(client.request("mail.read", messageId=SENT), row)
        fixture.save(downloads=True)
        targets = directory / "destinations"
        targets.mkdir()
        sentinel = b"Preserve existing user content.\n"
        regular = targets / "report.pdf"
        regular.write_bytes(sentinel)
        linked = targets / "linked.pdf"
        linked.symlink_to(regular)
        fifo = targets / "pipe.pdf"
        os.mkfifo(fifo, 0o600)
        existing = {path.name for path in targets.iterdir()}
        for destination in (regular, linked, fifo):
            before = destination.lstat()
            client.request("mail.attachment-save", messageId=SENT, attachmentId=part["id"],
                           path=str(destination), ok=False)
            after = destination.lstat()
            require((before.st_ino, before.st_mode) == (after.st_ino, after.st_mode), "save replaced an existing destination")
            require(regular.read_bytes() == sentinel and linked.is_symlink() and stat.S_ISFIFO(fifo.lstat().st_mode),
                    "failed save altered a file, symlink target, or FIFO")
            require({path.name for path in targets.iterdir()} == existing, "failed atomic save left a partial/temp file")
        real_parent = directory / "real-folder"
        real_parent.mkdir()
        symlink_parent = directory / "linked-folder"
        symlink_parent.symlink_to(real_parent, target_is_directory=True)
        client.request("mail.attachment-save", messageId=SENT, attachmentId=part["id"],
                       path=str(symlink_parent / "must-not-exist.pdf"), ok=False)
        require(not list(real_parent.iterdir()), "save traversed a symlink parent")

        token = part["id"]
        good = copy.deepcopy(fixture.downloads[ACCOUNTS[0]][token])
        for label, data, code in (("truncated", encode(b"short"), "BodySizeMismatch"),
                                  ("invalid-base64", "%%%%", "InvalidBase64")):
            fixture.downloads[ACCOUNTS[0]][token] = {"size": row["size"], "data": data}
            fixture.save(downloads=True)
            destination = targets / (label + ".pdf")
            error = client.request("mail.attachment-save", messageId=SENT, attachmentId=token,
                                   path=str(destination), ok=False)
            require(error["code"] == code and not destination.exists(), "invalid download became a saved file")
            require({path.name for path in targets.iterdir()} == existing, "download refusal left partial bytes")
        fixture.downloads[ACCOUNTS[0]][token] = good
        fixture.save(downloads=True)
        save(client, SENT, part, targets / "recovered.pdf", payload(row))
        no_writes(client)

    # A genuinely refused body must stay an honest metadata placeholder. A
    # descriptor absent from it must never cause success with empty/wrong data.
    fixture = LifecycleFixture(directory / "refused")
    source = fixture.message(SENT)["payload"]["parts"][0]
    source["body"]["size"] += 11
    fixture.save()
    with Client(binary, directory / "refused-client", extra=fixture.options()) as client:
        message = client.request("mail.read", messageId=SENT)
        require(message["bodyCacheError"] == "BodySizeMismatch" and not message["bodyText"],
                "malformed body did not remain an explicit metadata-only refusal")
        destination = directory / "body-refusal-must-not-exist.pdf"
        error = client.request("mail.attachment-save", messageId=SENT, attachmentId=row["providerId"],
                               path=str(destination), ok=False)
        require(error["code"] in {"AttachmentNotFound", "BodySizeMismatch", "MessageBodyUnavailable"}
                and not destination.exists(), "refused body produced a false successful attachment")
        no_writes(client)
    return {"preservedRegularSymlinkFifo": True, "symlinkParentRefused": True,
            "corruptDownloadsAtomic": True, "bodyRefusalHonest": True, "fixtureSends": 0}


def tui(binary, directory):
    from terminal_file_dialog import open_popup, popup_text, type_path
    from terminal_mouse import click
    from terminal_reader import reader_contains
    from terminal_ux_batch_support import command, focused, start

    def choose_sent_report(terminal):
        # The picker initially selects the current reader card. Select the
        # displayed part and verify its owning message instead of assuming a
        # particular starting row for keyboard movement.
        label = "2. report.pdf"
        terminal.until(lambda: terminal.screen.locate(label) is not None)
        position = terminal.screen.locate(label)
        owner = "".join(terminal.screen.cells[position["row"] + 1])
        require("Fixture Owner" in owner, "received picker report belongs to the wrong message")
        click(terminal, position["column"], position["row"])
        terminal.until(lambda: focused(terminal, label))
        terminal.send(b"o")

    fixture = LifecycleFixture(directory)
    client_dir = directory / "client"
    (client_dir / "home/Downloads").mkdir(parents=True)
    with Client(binary, client_dir, extra=fixture.options()) as client:
        client.request("mail.refresh", limit=10, prefetchLimit=0)
        client.request("mail.thread", threadId=THREAD)
    fixture.rotate(SENT, "sent-TUI-token-B/%+?")
    terminal = start(binary, client_dir, fixture.options(), "Final formatted reply with Unicode and empty files.", rows=44)
    try:
        terminal.send(b"\r")
        terminal.until(lambda: "4/4 mails" in terminal.text() and "Cached thread · partial" not in terminal.text())
        # Let a separate consumer observe that the new provider descriptor was
        # published while the immutable body still owns the previous token.
        with Client(binary, client_dir, extra=fixture.options()) as client:
            cached = client.request("mail.read", messageId=SENT, cacheOnly=True)
            require(attachment(cached, expected(message_id=SENT)[0])["id"] == "sent-token-A/+%?",
                    "TUI setup lost the old immutable body token")
        fixture.save(downloads=True)
        terminal.send(b"B")
        terminal.until(lambda: "Received attachments" in terminal.text() and "[o Save & open]" in terminal.text())
        choose_sent_report(terminal)
        title = open_popup(terminal, received=True)
        terminal.until(lambda: "[Save & open]" in popup_text(terminal, title))
        opened = directory / "opened sent report.pdf"
        type_path(terminal, title, opened, confirm=True)
        terminal.until(lambda: opened.exists() and "mock file-open validated" in terminal.text())
        verify_file(opened, payload(expected(message_id=SENT)[0]))

        terminal.send(b"{t")
        terminal.until(lambda: "3/4 mails" in terminal.text() and reader_contains(terminal.screen, "Two reports with the same filename."))
        destination = directory / "both reports"
        destination.mkdir()
        preserved = destination / "report.pdf"
        preserved.write_bytes(b"Existing report must survive.\n")
        command(terminal, "save-all " + str(destination))
        terminal.until(lambda: "Saved 2 attachments" in terminal.text() and len(list(destination.iterdir())) == 3)
        require(preserved.read_bytes() == b"Existing report must survive.\n", "SaveAll overwrote existing same-name file")
        created = [path for path in destination.iterdir() if path != preserved]
        require(sorted(path.read_bytes() for path in created) == sorted(payload(row) for row in expected(message_id=DUPLICATES)),
                "SaveAll crossed cards, duplicated one part, or dropped the duplicate filename")
        require(all(stat.S_IMODE(path.stat().st_mode) == 0o600 for path in created), "SaveAll files are not private")

        terminal.send(b"B")
        terminal.until(lambda: "Received attachments" in terminal.text() and "[o Save & open]" in terminal.text())
        choose_sent_report(terminal)
        title = open_popup(terminal, received=True)
        before_output = len(terminal.output)
        type_path(terminal, title, opened, confirm=True)
        terminal.until(lambda: "already exists" in terminal.text().lower() or "PathAlreadyExists" in terminal.text())
        require("mock file-open validated" not in bytes(terminal.output[before_output:]).decode(errors="replace"),
                "failed save reported that it opened a file")
        verify_file(opened, payload(expected(message_id=SENT)[0]))
        terminal.send(b"\x1b\x1b")
        terminal.gap(.1)
        with Client(binary, client_dir, extra=fixture.options()) as client:
            no_writes(client)
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    return {"threadCards": 4, "sentPdfSaveAndOpen": True, "duplicateSaveAll": True,
            "failedSaveHasNoOpenSuccess": True, "fixtureSends": 0}


def wait_forward_choice(terminal):
    terminal.until(lambda: all(value in terminal.text() for value in (
        "Forward · original format", "HTML · 2 embedded resources", "[Keep formatting k]",
        "[Text quote t]", "[Attach original .eml e]", "[Back Esc/q]", "Tab / Shift+Tab · Enter")))
    from terminal_ux_batch_support import focused
    require(focused(terminal, "[Keep formatting k]"), "ordinary HTML forward preflight disabled its default formatting choice")
    require("OutOfMemory" not in terminal.text() and "AttachmentNotFound" not in terminal.text(),
            "forward chooser displayed a failure before a mode was selected")


def tui_forward(binary, directory):
    from terminal_mouse import MouseTerminal
    from terminal_reader import reader_contains
    from terminal_ux_batch_support import FocusScreen, private_preferences

    outcomes = []
    # Risk-based representatives: every initial f preflight runs with a real
    # four-card thread; all three successful source choices are exercised.
    scenarios = ((414, "incoming", "text"), (414, "sent", "formatted"),
                 (2000, "incoming", "original"), (2000, "sent", "formatted"))
    for count, direction, mode in scenarios:
        location = directory / f"{count}-{direction}-{mode}"
        fixture = LifecycleFixture(location)
        context = [fixture.message(DUPLICATES), fixture.message(FORMATTED)]
        sources, downloads, originals = [], {}, {}
        for source_direction in ("incoming", "sent"):
            source, replies, original = pressure_message(source_direction)
            sources.append(source)
            downloads.update(replies)
            originals[source_direction] = original
        sources.extend(context)
        thread = "pressure-four-card-thread"
        for index, source in enumerate(sources):
            source.update(threadId=thread, internalDate=str(1791887400000 + index * 60000))
        fixture.sources[ACCOUNTS[0]]["messages"] = sources
        # Keep the lightweight context cards independently downloadable too.
        downloads.update(fixture.downloads[ACCOUNTS[0]])
        fixture.downloads[ACCOUNTS[0]] = downloads
        fixture.save()
        client_dir = location / "client"
        seed_pressure_metadata(client_dir, count)
        extra = fixture.options(metadata_limit=count)
        with Client(binary, client_dir, extra=extra) as client:
            initial = client.request("mail.thread", threadId=thread)["messages"]
            require([value["id"] for value in initial] == [value["id"] for value in sources],
                    "pressure TUI setup did not retain four chronological cards")
            require(client.request("cache.stats")["metadataEntries"] == count,
                    "pressure TUI setup dropped retained metadata")
        for source_direction in ("incoming", "sent"):
            for index in range(4):
                fixture.rotate("pressure-" + source_direction, f"tui-{source_direction}-{index}-B/%+?", occurrence=index)

        settings = private_preferences(client_dir)
        terminal = MouseTerminal(binary, client_dir, extra=(*extra, *settings), columns=160, rows=44,
                                 screen_type=FocusScreen, environment={"NO_COLOR": None, "COLORTERM": "truecolor"})
        stage = "open four-card thread"
        try:
            terminal.until(lambda: reader_contains(terminal.screen, "Final formatted reply with Unicode and empty files."))
            terminal.send(b"\r")
            terminal.until(lambda: "4/4 mails" in terminal.text() and "Cached thread · partial" not in terminal.text())
            selected_card = 1 if direction == "incoming" else 2
            for card in range(3, selected_card - 1, -1):
                terminal.send(b"{")
                terminal.until(lambda card=card: f"{card}/4 mails" in terminal.text())
            terminal.send(b"t")  # Expand the selected older card.
            marker = f"Synthetic {direction} attachment discussion."
            terminal.until(lambda: reader_contains(terminal.screen, marker) and "f Forward" in terminal.text())
            with Client(binary, client_dir, extra=extra) as client:
                cached = client.request("mail.read", messageId="pressure-" + direction, cacheOnly=True)
                require(len(cached["attachments"]) == 4 and all(
                    value["id"].endswith("-A/%+?") and not value["data"] for value in cached["attachments"]),
                    "pressure TUI setup lost retained unloaded body A")
                require(("SENT" in cached["labels"]) == (direction == "sent"), "pressure TUI selected the wrong incoming/Sent context")

            stage = "initial f preflight before selecting a format"
            terminal.send(b"f")
            wait_forward_choice(terminal)
            with Client(binary, client_dir, extra=extra) as client:
                require(client.request("draft.list")["drafts"] == [], "opening f preflight created a partial draft")
                no_writes(client)
            terminal.send(b"\x1b")
            terminal.until(lambda: "[Keep formatting k]" not in terminal.text() and reader_contains(terminal.screen, marker))
            with Client(binary, client_dir, extra=extra) as client:
                require(client.request("draft.list")["drafts"] == [], "canceling f preflight created a local draft")

            stage = "reopen f and choose " + mode
            terminal.send(b"f")
            wait_forward_choice(terminal)
            expected_files = 2 if mode == "formatted" else 1 if mode == "original" else 4

            def wait_compose():
                terminal.until(lambda: "Compose" in terminal.text() and "Subject:" in terminal.text()
                               and f"Attachments {expected_files}" in terminal.text() and "Ctrl+S Review" in terminal.text()
                               and "[Keep formatting k]" not in terminal.text(), seconds=20)

            if mode == "formatted":
                hold, entered = begin_fresh_capture(fixture)
                try:
                    terminal.send(b"k")
                    terminal.until(entered.exists)
                    enable_fresh_downloads(fixture)
                finally:
                    hold.unlink(missing_ok=True)
                wait_compose()
            elif mode == "original":
                with pressure_raw(fixture, "pressure-" + direction, originals[direction]["raw"]):
                    terminal.send(b"e")
                    wait_compose()
            else:
                fixture.save(downloads=True)
                terminal.send(b"t")
                wait_compose()
            require("OutOfMemory" not in terminal.text() and "AttachmentNotFound" not in terminal.text(),
                    "contextual forward reached compose with a hidden failure")
            stage = "close and reopen the saved forward"
            terminal.finish()
        except Exception:
            print(json.dumps({"stage": stage, "metadataEntries": count, "direction": direction, "mode": mode,
                              "currentCells": terminal.screen.lines(), "outputBytes": terminal.output_total}))
            raise
        finally:
            terminal.close()

        with Client(binary, client_dir, extra=extra) as client:
            drafts = client.request("draft.list")["drafts"]
            require(len(drafts) == 1, "contextual forward did not retain exactly one local draft")
            draft = client.request("draft.read", draftId=drafts[0]["id"])
            require(draft["bodyFormat"] == "markdown" and not any(draft[key] for key in
                    ("to", "cc", "bcc", "threadId", "inReplyTo", "references")),
                    "TUI forward changed note format or retained original recipients/threading")
            original = originals[direction]
            if mode == "formatted":
                snapshot = draft["original"]
                require(snapshot["sourceMessageId"] == "pressure-" + direction and snapshot["bodyText"] == original["plain"]
                        and snapshot["bodyHtml"] == original["html"] and not draft["bodyText"],
                        "TUI forward captured another card or changed the protected original")
                check_pressure_parts(snapshot["resources"], PRESSURE["attachments"][:2], inline=True)
                check_pressure_parts(draft["attachments"], PRESSURE["attachments"][2:])
            elif mode == "original":
                require(len(draft["attachments"]) == 1 and draft["attachments"][0]["filename"].endswith(".eml")
                        and decode(draft["attachments"][0]["data"]) == original["raw"], "TUI .eml forward changed its selected card's bytes")
            else:
                require(marker.removesuffix(".") in draft["bodyText"] and not draft.get("original"), "TUI text forward lost the selected source quotation")
                check_pressure_parts(draft["attachments"], PRESSURE["attachments"])
            require(client.request("cache.stats")["metadataEntries"] == count, "TUI forwarding dropped retained metadata")
            no_writes(client)
        outcomes.append({"metadataEntries": count, "direction": direction, "mode": mode,
                         "selectedThreadCard": selected_card, "initialPreflightAndCancel": True})
    return {"workflows": outcomes, "threadCards": 4, "fixtureSends": 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--case", choices=CASES, action="append")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    receipt = {"build": read_build_info(binary), "cases": []}
    for name in args.case or CASES:
        try:
            with tempfile.TemporaryDirectory(prefix=f"omagma-attachment-{name}-") as temporary:
                result = globals()[name](binary, Path(temporary))
            receipt["cases"].append({"name": name, "status": "passed", **result})
            print(f"PASS attachment lifecycle: {name}")
        except Exception:
            receipt["cases"].append({"name": name, "status": "failed", "traceback": traceback.format_exc()})
            print(receipt["cases"][-1]["traceback"])
            if args.output:
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
            raise
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
