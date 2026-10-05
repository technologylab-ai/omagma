#!/usr/bin/env python3
"""Check synthetic fixtures against independent MIME and semantic expectations."""
from __future__ import annotations

import base64
from email import policy
from email.parser import BytesParser
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests/fixtures/terminal"


def load(name):
    return json.loads((FIXTURES / name).read_text())


def decode(data):
    if not re.fullmatch(r"[A-Za-z0-9_-]*", data):
        raise ValueError("invalid base64url alphabet")
    return base64.b64decode(data + "=" * (-len(data) % 4), altchars=b"-_", validate=True)


def leaves(part):
    if part.get("parts"):
        for child in part["parts"]:
            yield from leaves(child)
    else:
        yield part


def normalized(value):
    return value.replace("\r\n", "\n")


class FixtureCheck(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = load("manifest.json")
        cls.accounts = {address: load(f"accounts/{address.split('@')[0]}.json")
                        for address in cls.manifest["accounts"]}

    def test_more_than_thirty_with_exact_pagination(self):
        for address, account in self.accounts.items():
            messages = account["messages"]
            self.assertEqual(len(messages), 96)
            ids = [m["id"] for m in messages]
            self.assertEqual(len(set(ids)), 96)
            page_ids = []
            cursor = ""
            for page in account["pages"]:
                self.assertEqual(page["pageToken"], cursor)
                self.assertLessEqual(len(page["response"]["messages"]), 12)
                self.assertTrue(all(set(m) == {"id", "threadId"} for m in page["response"]["messages"]))
                page_ids += [m["id"] for m in page["response"]["messages"]]
                cursor = page["response"].get("nextPageToken", "")
            self.assertEqual(page_ids, ids)
            self.assertEqual(cursor, "")
            self.assertEqual([int(m["internalDate"]) for m in messages],
                             sorted((int(m["internalDate"]) for m in messages), reverse=True))

    def test_identifiers_collide_but_account_content_does_not(self):
        values = list(self.accounts.values())
        self.assertEqual([m["id"] for m in values[0]["messages"]], [m["id"] for m in values[1]["messages"]])
        self.assertEqual([m["threadId"] for m in values[0]["messages"]], [m["threadId"] for m in values[2]["messages"]])
        for address, account in self.accounts.items():
            self.assertEqual(account["account"], address)
            self.assertTrue(all(address.split("@")[0] in m["snippet"] for m in account["messages"]))

    def test_independent_mime_decoding(self):
        expected = self.manifest["bodyExpected"]
        for address, account in self.accounts.items():
            key = address.split("@")[0]
            by_id = {m["id"]: m for m in account["messages"]}
            for message_id, case in self.manifest["caseByMessageId"].items():
                if case not in expected:
                    continue
                raw = FIXTURES / "mime" / f"{key}-{message_id[-3:]}-{case}.eml"
                parsed = BytesParser(policy=policy.default).parsebytes(raw.read_bytes())
                candidates = [p for p in parsed.walk() if p.get_content_type() == "text/plain"]
                self.assertEqual(normalized(candidates[0].get_content()), expected[case])
                part = next(p for p in leaves(by_id[message_id]["payload"]) if p["mimeType"] == "text/plain")
                body = part["body"]
                if "attachmentId" in body:
                    body = account["externalBodies"][body["attachmentId"]]
                charset = "iso-8859-1" if case == "latin1" else "utf-8"
                decoded = decode(body["data"])
                self.assertEqual(len(decoded), body["size"])
                self.assertEqual(normalized(decoded.decode(charset)), expected[case])

    def test_attachment_is_synthetic_and_traversal_is_explicit(self):
        oracle = self.manifest["attachmentExpected"]
        for account in self.accounts.values():
            message = next(m for m in account["messages"] if m["id"] == "shared-msg-003")
            attachment = next(p for p in leaves(message["payload"]) if p["filename"])
            data = decode(attachment["body"]["data"])
            self.assertEqual(attachment["filename"], "../../escape.txt")
            self.assertEqual(len(data), oracle["size"])
            self.assertEqual(hashlib.sha256(data).hexdigest(), oracle["sha256"])

    def test_thread_headers_preserve_account_identity(self):
        for address, account in self.accounts.items():
            groups = {}
            for message in account["messages"]:
                groups.setdefault(message["threadId"], []).append(message)
            self.assertEqual(len(groups), 32)
            for messages in groups.values():
                self.assertEqual(len(messages), 3)
                headers = [{h["name"].lower(): h["value"] for h in m["payload"]["headers"]} for m in messages]
                self.assertEqual(len({h["subject"] for h in headers}), 1)
                self.assertTrue(any(address in h["from"] for h in headers))

    def test_controls_are_encoded_mail_data(self):
        account = next(iter(self.accounts.values()))
        message = next(m for m in account["messages"] if m["id"] == "shared-msg-007")
        data = decode(message["payload"]["body"]["data"])
        self.assertIn(b"\x1b]52;", data)
        self.assertIn(b"\x1b]8;", data)
        self.assertIn(b"\x00", data)
        self.assertNotIn(b"\x1b", json.dumps(message).encode())

    def test_reply_expectations_remove_bcc_self_and_duplicates(self):
        for address, expected in self.manifest["replyAllExpected"].items():
            recipients = expected["to"] + expected["cc"]
            self.assertEqual(len(set(recipients)), len(recipients))
            self.assertNotIn(address, recipients)
            self.assertNotIn("hidden@example.org", recipients)
            self.assertEqual(expected["to"], ["replies@example.org"])

    def test_encoded_display_name_keeps_recipient_grammar(self):
        expected = self.manifest["displayNameExpected"]
        for address, account in self.accounts.items():
            key = address.split("@")[0]
            raw = (FIXTURES / "mime" / f"{key}-012-encoded-display-name.eml").read_bytes()
            parsed = BytesParser(policy=policy.default).parsebytes(raw)
            self.assertEqual(parsed["From"].addresses[0].display_name, expected["name"])
            self.assertEqual(parsed["From"].addresses[0].addr_spec, address)
            self.assertEqual([a.addr_spec for a in parsed["To"].addresses], expected["to"])
            message = next(m for m in account["messages"] if m["id"] == expected["messageId"])
            header = next(h["value"] for h in message["payload"]["headers"] if h["name"].lower() == "from")
            self.assertIn("=?utf-8?B?", header)

    def test_incoming_address_regressions_have_independent_mailbox_oracles(self):
        fixture = load("inbound-addresses.json")
        self.assertTrue(fixture["synthetic"])
        self.assertEqual(set(fixture["accounts"]), set(self.accounts))
        long_addresses = []
        for account, cases in fixture["accounts"].items():
            wide = cases["manyRecipients"]
            raw = f"{wide['headerName']}: {wide['headerValue']}\r\n\r\n".encode()
            parsed = BytesParser(policy=policy.default).parsebytes(raw)
            actual = [mailbox.addr_spec for mailbox in parsed["To"].addresses]
            self.assertEqual(actual, wide["expectedAddresses"])
            self.assertEqual(len(actual), 34)
            self.assertEqual(len(set(actual)), 34)
            self.assertIn(account, actual)
            self.assertGreater(len(actual) - 1, fixture["outgoingRecipientLimit"])
            long = cases["longReplyTo"]
            raw = f"{long['headerName']}: {long['headerValue']}\r\n\r\n".encode()
            parsed = BytesParser(policy=policy.default).parsebytes(raw)
            actual = [mailbox.addr_spec for mailbox in parsed["Reply-To"].addresses]
            self.assertEqual(actual, long["expectedAddresses"])
            local, domain = actual[0].split("@")
            self.assertEqual(len(local.encode()), 65)
            self.assertEqual(domain, "example.org")
            self.assertLessEqual(len(actual[0]), 254)
            self.assertGreater(len(local), fixture["outgoingLocalPartLimit"])
            long_addresses.append(actual[0])
        self.assertEqual(len(set(long_addresses)), 3)

    def test_contact_source_etags_are_account_specific(self):
        etags = []
        for address in self.accounts:
            contacts = load(f"contacts/{address.split('@')[0]}.json")
            self.assertEqual(contacts["account"], address)
            first = contacts["connections"][0]
            self.assertEqual(first["resourceName"], "people/shared-contact-001")
            source = first["metadata"]["sources"][0]
            self.assertEqual(source["type"], "CONTACT")
            etags.append(source["etag"])
        self.assertEqual(len(set(etags)), 3)

    def test_rsvp_preserves_identity_and_sequence(self):
        for address in self.accounts:
            key = address.split("@")[0]
            request = (FIXTURES / "calendar" / f"{key}-recurring-request.ics").read_text()
            for status in ["accepted", "tentative", "declined"]:
                reply = (FIXTURES / "calendar" / f"{key}-reply-{status}.ics").read_text()
                self.assertIn("METHOD:REPLY", reply)
                self.assertEqual(reply.count("ATTENDEE;"), 1)
                self.assertIn(f"PARTSTAT={status.upper()}:mailto:{address}", reply)
                for prefix in ["UID:", "ORGANIZER:", "SEQUENCE:", "RECURRENCE-ID:"]:
                    original = next(line for line in request.splitlines() if line.startswith(prefix))
                    self.assertIn(original, reply.splitlines())

    def test_regeneration_is_deterministic(self):
        spec = importlib.util.spec_from_file_location("terminal_fixture_generator", FIXTURES / "generate.py")
        generator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(generator)
        with tempfile.TemporaryDirectory(prefix="omagma-fixture-rebuild-") as directory:
            generator.ROOT = Path(directory)
            generator.main()
            for regenerated in generator.ROOT.rglob("*"):
                if regenerated.is_file():
                    relative = regenerated.relative_to(generator.ROOT)
                    self.assertEqual(regenerated.read_bytes(), (FIXTURES / relative).read_bytes(), str(relative))

    def test_public_fixture_privacy(self):
        address = re.compile(rb"\b[A-Za-z0-9][A-Za-z0-9._%+-]{0,253}@([A-Za-z0-9.-]+\.[A-Za-z]{1,})")
        for path in FIXTURES.rglob("*"):
            if not path.is_file() or "__pycache__" in path.parts:
                continue
            data = path.read_bytes()
            data.decode("utf-8")
            self.assertNotIn(b"/home/", data, str(path.relative_to(ROOT)))
            self.assertNotIn(b"BEGIN PRIVATE KEY", data)
            self.assertTrue(all(domain.lower() in {b"example.com", b"example.org", b"example.net"}
                                for domain in address.findall(data)), str(path.relative_to(ROOT)))


if __name__ == "__main__":
    unittest.main()
