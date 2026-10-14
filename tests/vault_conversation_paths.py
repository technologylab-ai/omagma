#!/usr/bin/env python3
"""Connected encrypted conversation acceptance; owned synthetic daemon only.

Run inside the coordinator's host reservation. FULL responses initially contain
only attachment descriptors; the subsequent downloads exercise the native
transaction transitions. Expected bytes are produced by Python's MIME writer.
"""
from __future__ import annotations

import argparse
import copy
from email import policy
from email.message import EmailMessage
from email.parser import BytesParser
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import threading
import time

from terminal_attachment_lifecycle import (
    LifecycleFixture, decode, encode, gmail_from_wire, synthetic_png,
)

ACCOUNTS = ("personal@example.com", "work@example.com")
MESSAGE = "vault-conversation-source"
SMALL = "vault-conversation-small"


def changed_fields(before, after):
    def bounded(value):
        encoded = json.dumps(value, sort_keys=True).encode()
        return value if len(encoded) < 256 else dict(bytes=len(encoded), sha256=hashlib.sha256(encoded).hexdigest())
    return {key: dict(before=bounded(before.get(key)), after=bounded(after.get(key)))
            for key in sorted(before.keys() | after.keys()) if before.get(key) != after.get(key)}


def source_mail(account, ordinal):
    mail = EmailMessage(policy=policy.SMTP)
    mail["From"] = "Maya Fixture <maya@example.test>"
    mail["To"] = account
    mail["Cc"] = "copied@example.test"
    mail["Subject"] = "Encrypted illustrated review"
    mail["Message-ID"] = "<sealed-conversation@example.test>"
    mail["Date"] = "Tue, 13 Oct 2026 10:30:00 +0000"
    mail.set_content("Please review these original illustrations.\n")
    mail.add_alternative('<html><body><p>Original illustrated review</p>'
                         '<img src="cid:photo-0@example.test">'
                         '<img src="assets/photo-1.png"></body></html>', subtype="html")
    rich = mail.get_payload()[1]
    expected = {}
    for index, size in enumerate((1_100_000, 1_200_000)):
        raw = synthetic_png(size, ordinal * 10 + index)
        name = f"photo-{index}.png"
        expected[name] = raw
        rich.add_related(raw, maintype="image", subtype="png", filename=name,
                         cid=f"<photo-{index}@example.test>", disposition="inline")
        if index == 1:
            rich.get_payload()[-1]["Content-Location"] = "assets/photo-1.png"
    expected["review.pdf"] = (f"%PDF-1.4\n% Synthetic account {ordinal}\n%%EOF\n").encode()
    mail.add_attachment(expected["review.pdf"], maintype="application", subtype="pdf", filename="review.pdf")
    raw = mail.as_bytes()
    source, downloads = gmail_from_wire(dict(id=MESSAGE, threadId="vault-source-thread", fixtureRaw=encode(raw)), 99)
    source.pop("raw")
    source["labelIds"] = ["INBOX", "UNREAD"]
    html = next(part.get_payload(decode=True).decode() for part in BytesParser(policy=policy.default).parsebytes(raw).walk()
                if part.get_content_type() == "text/html")
    small_raw = ("From: maya@example.test\r\nSubject: Small encrypted original\r\n"
                 "Content-Type: text/plain; charset=utf-8\r\n\r\nExactly retained small original.\r\n").encode()
    small, _ = gmail_from_wire(dict(id=SMALL, threadId="vault-small-thread", fixtureRaw=encode(small_raw)), 100)
    return source, small, downloads, expected, raw, small_raw, html


def run(binary, directory, parent_env):
    # Imported lazily because the full daemon harness calls this module.
    from vault_daemon import PASSWORD, displayed_recovery, prompt, require

    root = Path(directory) / "conversation-paths"
    root.mkdir(mode=0o700)
    env = dict(parent_env, HOME=str(root / "home"), XDG_CONFIG_HOME=str(root / "config"),
               XDG_CACHE_HOME=str(root / "cache"))
    env.pop("XDG_RUNTIME_DIR", None)
    for key in ("HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        Path(env[key]).mkdir(mode=0o700)
    fixture = LifecycleFixture(root)
    oracles = {}
    for ordinal, account in enumerate(ACCOUNTS):
        large, small, downloads, expected, raw, small_raw, html = source_mail(account, ordinal)
        fixture.sources[account]["messages"] = [large, small]
        fixture.downloads[account] = downloads
        fixture.save(account)
        oracles[account] = dict(files=expected, raw=raw, small=small_raw, html=html)
    require(oracles[ACCOUNTS[0]]["files"]["photo-0.png"] != oracles[ACCOUNTS[1]]["files"]["photo-0.png"],
            "account-isolation fixture must contain different bytes under the same IDs")

    vault = root / "sealed"
    backend = root / "ipc" / "socket"
    prompt(binary, ["vault", "init", "--fixtures", "--vault-dir", str(vault)], env,
           [(b"New vault password: ", PASSWORD), (b"Confirm password: ", PASSWORD),
            (b"Confirm recovery key: ", displayed_recovery)])
    daemon = None
    serial = 0

    def control(verb):
        result = subprocess.run([str(binary), "vault", verb, "--socket", str(backend)], env=env,
                                capture_output=True, timeout=15)
        require(result.returncode == 0, f"conversation service {verb} exited: {result.stderr.decode()}")
        response = json.loads(result.stdout)
        require(response["ok"], f"conversation service {verb} refused")
        return response["data"]

    def start():
        child = subprocess.Popen([str(binary), "vault", "serve", "--fixtures", "--vault-dir", str(vault),
                                  "--socket", str(backend), "--fixture-root", str(fixture.root)],
                                 env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 10
            while not backend.exists():
                require(child.poll() is None, "conversation service exited before binding")
                require(time.monotonic() < deadline, "conversation service failed to bind")
                time.sleep(.02)
            require(not control("status")["unlocked"], "new conversation service retained an unlocked key")
            prompt(binary, ["vault", "unlock", "--socket", str(backend)], env,
                   [(b"Vault password: ", PASSWORD)])
            require(control("status")["unlocked"], "conversation service failed to unlock")
            return child
        except BaseException:
            child.kill()
            child.wait()
            raise

    def request(command, account=ACCOUNTS[0], ok=True, **fields):
        nonlocal serial
        serial += 1
        value = dict(id=f"sealed-conversation-{serial}", cmd=command, account=account, **fields)
        result = subprocess.run([str(binary), "cli", "--backend", str(backend)], env=env,
                                input=json.dumps(value).encode() + b"\n", capture_output=True, timeout=60)
        require(bool(result.stdout.strip()), f"missing encrypted {command} response: {result.stderr.decode()}")
        response = json.loads(result.stdout)
        require(response.get("id") == value["id"] and response.get("account") == account,
                f"encrypted {command} lost request/account identity")
        # Never print a multi-MiB successful body in a failure diagnostic.
        require(response["ok"] == ok,
                f"encrypted {command} unexpected success={response['ok']}: {response.get('error', {}).get('code')}")
        return response["data"] if ok else response["error"]

    def fresh_capture(account, command, **params):
        hold, entered = fixture.root / "conversation.hold", fixture.root / "conversation.entered"
        hold.write_text("Synthetic descriptor-only FULL gate.\n")
        entered.unlink(missing_ok=True)
        fixture.sources[account]["sync"]["fixtureProgress"] = dict(
            phase="bodies", completed=0, fixtureHold=hold.name, fixtureEntered=entered.name)
        fixture.save(account)
        result, failures = [], []

        def worker():
            try:
                result.append(request(command, account, **params))
            except BaseException as error:
                failures.append(error)

        thread = threading.Thread(target=worker)
        thread.start()
        try:
            deadline = time.monotonic() + 10
            while not entered.exists():
                require(thread.is_alive(), f"encrypted {command} failed before fresh FULL gate: {failures}")
                require(daemon.poll() is None and time.monotonic() < deadline, "encrypted FULL did not reach its gate")
                time.sleep(.005)
            fixture.sources[account]["sync"].pop("fixtureProgress")
            fixture.save(account, downloads=True)
        finally:
            hold.unlink(missing_ok=True)
            thread.join(timeout=65)
        require(not thread.is_alive(), "encrypted conversation request did not terminate")
        if failures:
            raise failures[0]
        return result[0]

    def check_parts(parts, expected):
        require(len(parts) == len(expected) and {part["filename"] for part in parts} == set(expected),
                "encrypted conversation lost or invented a file")
        for part in parts:
            raw = expected[part["filename"]]
            require(part["size"] == len(raw), "encrypted conversation changed decoded file size")
            if part.get("blobId"):
                require(not part["data"] and part["blobId"] == hashlib.sha256(raw).hexdigest(),
                        "encrypted blob does not identify the expected account's exact bytes")
            else:
                require(decode(part["data"]) == raw, "encrypted inline file changed bytes")

    def save_sent(account, sent, expected, prefix, outgoing_ids=None):
        message = request("mail.read", account, messageId=sent["messageId"], cacheOnly=True)
        check_parts(message["attachments"], expected)
        retrieval_ids = [part["id"] for part in message["attachments"]]
        require(all(retrieval_ids) and len(set(retrieval_ids)) == len(retrieval_ids),
                "encrypted Sent parts lack unique retrieval identities")
        if outgoing_ids is not None:
            require(not set(retrieval_ids) & outgoing_ids, "synthetic Sent reused an outgoing/source retrieval identity")
        for index, part in enumerate(message["attachments"]):
            destination = root / f"{prefix}-{index}.bin"
            require(bool(part["id"]), f"encrypted Sent attachment lacks a retrieval identity: {prefix}, {part['filename']}, blob={part.get('blobId')}")
            receipt = request("mail.attachment-save", account, messageId=message["id"],
                              attachmentId=part["id"], path=str(destination))
            require(receipt["saved"] and destination.read_bytes() == expected[part["filename"]],
                    "encrypted Sent attachment save changed the exact file")
            require(stat.S_IMODE(destination.stat().st_mode) == 0o600, "explicit attachment export is not private")
        return message

    drafts, delivered = [], []
    try:
        daemon = start()
        for account_index, account in enumerate(ACCOUNTS):
            oracle = oracles[account]
            source = request("mail.read", account, messageId=MESSAGE)
            require(not source["bodyCacheError"] and all(not part["data"] and not part.get("blobId")
                                                        for part in source["attachments"]),
                    "encrypted source bypassed descriptor-only attachment downloads")
            fixture.save(account, downloads=True)
            for mode in ("text", "formatted", "reply", "reply-all", "original"):
                params = dict(messageId=MESSAGE, bodyFormat="markdown" if mode in ("formatted", "reply-all") else "plain")
                command = "mail.reply" if mode.startswith("reply") else "mail.forward"
                if mode in ("formatted", "reply", "reply-all"):
                    params["preserveFormatting"] = True
                    if mode == "reply-all":
                        params["all"] = True
                    draft = fresh_capture(account, command, **params)
                    require(draft["original"]["bodyHtml"] == oracle["html"], "encrypted original HTML changed")
                    images = {name: raw for name, raw in oracle["files"].items() if name.endswith(".png")}
                    check_parts(draft["original"]["resources"], images)
                    require(all(part.get("blobId") for part in draft["original"]["resources"]),
                            "large encrypted related resources did not exercise backing-file hydration")
                    files = {"review.pdf": oracle["files"]["review.pdf"]} if mode == "formatted" else {}
                    expected = files | images
                elif mode == "original":
                    fixture.message(MESSAGE, account)["raw"] = encode(oracle["raw"])
                    fixture.save(account)
                    draft = request(command, account, **params, original=True)
                    fixture.message(MESSAGE, account).pop("raw")
                    fixture.save(account, downloads=True)
                    files = expected = {"original.eml": oracle["raw"]}
                else:
                    draft = request(command, account, **params)
                    files = expected = oracle["files"]
                    require(all(part.get("blobId") for part in draft["attachments"]),
                            "large encrypted forward did not exercise backing-file hydration")
                check_parts(draft["attachments"], files)
                require(not draft["bcc"], "encrypted conversation inferred blind recipients")
                if command == "mail.forward":
                    require(not any(draft[name] for name in ("to", "cc", "threadId", "inReplyTo", "references")),
                            "encrypted forward retained source recipients/threading")
                else:
                    require(draft["threadId"] == "vault-source-thread" and
                            draft["inReplyTo"] == "<sealed-conversation@example.test>",
                            "encrypted reply lost its exact source thread")
                if account_index == 0 and mode == "text":
                    foreign = copy.deepcopy(draft)
                    foreign.pop("id", None)
                    require(request("draft.create", ACCOUNTS[1], ok=False, draft=foreign)["code"] == "AttachmentHandleNotFound",
                            "encrypted blob handle became usable in another account")
                draft["to"] = [{"address": "recipient@example.test"}]
                draft["bodyText"] = "Reviewed synthetic mail."
                draft = request("draft.update", account, draftId=draft["id"], draft=draft)
                drafts.append((account, mode, draft, expected))

        small = request("mail.forward", messageId=SMALL, original=True)
        check_parts(small["attachments"], {"original.eml": oracles[ACCOUNTS[0]]["small"]})
        require(not small["attachments"][0].get("blobId"), "small RAW case missed the portable representation")
        small["to"] = [{"address": "recipient@example.test"}]
        small = request("draft.update", draftId=small["id"], draft=small)
        drafts.append((ACCOUNTS[0], "small-original", small, {"original.eml": oracles[ACCOUNTS[0]]["small"]}))

        # Compare identical public projections across restart. draft.read now
        # decorates the stored DTO with its Gmail continuity digest.
        snapshots = []
        for account, mode, draft, expected in drafts:
            saved = request("draft.read", account, draftId=draft["id"])
            stored = dict(saved)
            digest = stored.pop("contentDigest")
            require(len(digest) == 64 and all(c in "0123456789abcdef" for c in digest),
                    "draft read did not expose a bounded content digest")
            require(stored == draft, f"encrypted {mode} stored payload changed: {changed_fields(draft, stored)}")
            snapshots.append((account, mode, saved, expected))
        drafts = snapshots
        control("stop")
        require(daemon.wait(timeout=10) == 0, "encrypted conversation stop failed")
        daemon = start()
        for index, (account, mode, draft, expected) in enumerate(drafts):
            reopened = request("draft.read", account, draftId=draft["id"])
            require(reopened == draft,
                    f"encrypted {mode} draft changed after daemon restart: {changed_fields(draft, reopened)}")
            operation = f"sealed-conversation-send-{index}"
            sent = request("draft.send", account, draftId=draft["id"], operationId=operation)
            require(sent["outcome"] == "applied", f"encrypted {mode} send was not applied")
            require(request("draft.send", account, draftId=draft["id"], operationId=operation) == sent,
                    "encrypted send retry changed its durable receipt")
            outgoing_ids = {part["id"] for part in draft["attachments"]}
            if draft.get("original"):
                outgoing_ids.update(part["id"] for part in draft["original"]["resources"])
            message = save_sent(account, sent, expected, f"sent-{index}", outgoing_ids)
            delivered.append((account, sent, expected, message["attachments"]))

        # Re-forward already backed Sent mail and save it as a separate draft.
        # This covers the existing-handle route in addition to fresh downloads.
        account, sent, expected, _ = delivered[0]
        forwarded = request("mail.forward", account, messageId=sent["messageId"])
        check_parts(forwarded["attachments"], expected)
        forwarded_read = request("draft.read", account, draftId=forwarded["id"])
        require({key: value for key, value in forwarded_read.items() if key != "contentDigest"} == forwarded,
                "re-forwarded encrypted stored fields changed before restart")
        control("stop")
        require(daemon.wait(timeout=10) == 0, "encrypted Sent restart stop failed")
        daemon = start()
        for index, (account, sent, expected, attachments) in enumerate(delivered):
            message = save_sent(account, sent, expected, f"cold-sent-{index}")
            require(message["attachments"] == attachments, "encrypted Sent ownership changed after restart")
        require(request("draft.read", account=ACCOUNTS[0], draftId=forwarded["id"]) == forwarded_read,
                "re-forwarded encrypted files did not survive restart")
        for account in ACCOUNTS:
            wanted = sum(item[0] == account for item in drafts)
            require(request("cache.stats", account)["fixtureSends"] == wanted,
                    "encrypted send/restart duplicated or omitted a provider submission")
    finally:
        if daemon is not None:
            if daemon.poll() is None:
                try:
                    control("stop")
                except Exception:
                    daemon.terminate()
                try:
                    daemon.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    daemon.kill()
                    daemon.wait()
            require(daemon.returncode == 0, "encrypted conversation service exited unexpectedly: " +
                    daemon.stderr.read().decode(errors="replace"))
    print("PASS encrypted connected conversations: 11 reply/forward/RAW drafts, restart/send/retrieve, two-account isolation")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="omagma-vc-", dir="/private/tmp" if os.uname().sysname == "Darwin" else "/tmp") as temporary:
        run(args.binary.resolve(), Path(temporary).resolve(), dict(os.environ))


if __name__ == "__main__":
    main()
