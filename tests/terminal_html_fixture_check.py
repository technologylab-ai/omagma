#!/usr/bin/env python3
"""Pure fictional HTML fixture checks; no native binary or mailbox access."""
import base64
from html.parser import HTMLParser
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent / "probes"))
from html_fixture import ACCOUNTS, HTML_ROOT, MANIFEST, HtmlFixture, document, substitute


class HtmlFixtureCheck(unittest.TestCase):
    def test_gmail_plain_preference_and_cross_account_literals(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = HtmlFixture(Path(temporary), "legacy")
            for account in ACCOUNTS:
                source = fixture.data[account]["baseline"]
                html = next(m for m in source["messages"] if m["id"] == MANIFEST["htmlMessageId"])["payload"]
                raw = base64.urlsafe_b64decode(html["body"]["data"] + "=" * (-len(html["body"]["data"]) % 4))
                self.assertEqual(raw.decode(), document("legacy", account))
                self.assertEqual(len(raw), html["body"]["size"])
                self.assertIn(account, raw.decode())
                preferred = next(m for m in source["messages"] if m["id"] == MANIFEST["plainPreferredMessageId"])["payload"]
                self.assertEqual(preferred["mimeType"], "multipart/alternative")
                self.assertEqual([p["mimeType"] for p in preferred["parts"]], ["text/plain", "text/html"])

    def test_legacy_literal_matches_independent_structure(self):
        class Text(HTMLParser):
            def __init__(self): super().__init__(); self.parts = []
            def handle_data(self, text): self.parts.append(text)
        for account in ACCOUNTS:
            parser = Text(); parser.feed(document("legacy", account))
            expected = substitute(MANIFEST["legacyTextTemplate"], account).splitlines()
            self.assertEqual(parser.parts, [expected[0], expected[1], expected[2][2:]])
            self.assertNotEqual(substitute(MANIFEST["plainMismatchTemplate"], account), "\n".join(expected))

    def test_limits_and_json_escaped_control_fixture(self):
        self.assertEqual(len(document("large", ACCOUNTS[0]).encode()), 2 * 1024**2)
        self.assertEqual(document("depth", ACCOUNTS[0]).count("<div>"), 129)
        source = (HTML_ROOT / "safety.json").read_bytes()
        self.assertNotIn(b"\x1b", source)
        self.assertIn(b"\\u001b", source)
        decoded = json.loads(source)["document"]
        self.assertIn("\x1b]52;", decoded)
        self.assertIn("\u202e", decoded)
        for path in HTML_ROOT.iterdir():
            self.assertNotIn(b"/home/", path.read_bytes())


if __name__ == "__main__":
    unittest.main()
