#!/usr/bin/env python3
"""Literal privacy boundaries for reviewed synthetic examples and raster assets."""
import hashlib
import contextlib
import io
import json
import unittest
from unittest import mock

import publication_check as check


def email(domain, local=b"person"):
    return local + b"@" + domain


class PublicationPrivacy(unittest.TestCase):
    def test_reserved_roots_and_true_subdomains(self):
        for domain in (b"example.com", b"harbor.example.net", b"deep.cedar.example.org",
                       b"mail.example.test", b"test.example", b"test.invalid", b"b.c"):
            with self.subTest(domain=domain):
                self.assertFalse(check.private_email("examples/synthetic.txt", email(domain)))
                self.assertFalse(check.private_email("examples/synthetic.txt", email(domain.upper())))

    def test_suffix_lookalikes_and_unrelated_accounts_rejected(self):
        for domain in (b"notexample.com", b"example.org.company.test", b"examplex.net",
                       b"company.test", b"library.exam", b"private.example.test.company.test", b"private.b.c"):
            with self.subTest(domain=domain):
                self.assertTrue(check.private_email("examples/synthetic.txt", email(domain)))

    def test_reviewed_video_excerpt_is_exact_and_path_scoped(self):
        excerpt = email(b"library.exam", b"holds") + "…".encode()
        self.assertFalse(check.private_email("video/capture/tape.py", b'Pane: "' + excerpt + b'"'))
        self.assertTrue(check.private_email("README.md", excerpt))
        self.assertTrue(check.private_email("video/capture/tape.py", email(b"library.exam", b"holds")))
        self.assertTrue(check.private_email("video/capture/tape.py", email(b"library.exam", b"another") + "…".encode()))
        self.assertTrue(check.private_email("video/capture/tape.py", excerpt + b" " + email(b"company.test")))

    def test_reviewed_master_requires_the_independent_fixed_digest(self):
        name = "video/assets/omagma-logo-master.png"
        data = (check.ROOT / name).read_bytes()
        # Fixed reviewer identity, rather than computing the accepted digest
        # from the candidate and testing it against itself.
        self.assertEqual(hashlib.sha256(data).hexdigest(),
                         "6ca7de5cc234de73567f6a1812e6161c7b9d45742d6047cd1c23101e7041c9b3")
        self.assertTrue(check.reviewed_raster(name, data))
        self.assertFalse(check.reviewed_raster(name, data + b"unreviewed change"))
        self.assertFalse(check.reviewed_raster("video/assets/other-logo.png", data))
        self.assertFalse(check.reviewed_raster("video/private.png", data))

    def test_private_paths_and_credential_rules_remain_active(self):
        path = b"/" + b"home/" + b"synthetic-user/project/"
        self.assertIsNotNone(check.FORBIDDEN_PATH.search(path))
        secret = b"ya" + b"29." + b"A" * 30
        self.assertTrue(any(pattern.search(secret) for pattern in check.SECRET_PATTERNS))

    def test_embedded_mail_logo_is_exact_approved_public_asset(self):
        approved = (check.ROOT / "assets/omagma-logo.png").read_bytes()
        embedded = (check.ROOT / "src/terminal/omagma-logo.png").read_bytes()
        self.assertEqual(embedded, approved)
        self.assertEqual(hashlib.sha256(embedded).hexdigest(),
                         "e2e844a35476454f11b513404041135327fec6354f7b6e7e0269a32fdf56d3c4")
        for name in ("assets/omagma-logo.png", "src/terminal/omagma-logo.png"):
            with self.subTest(name=name):
                self.assertTrue(check.reviewed_raster(name, embedded))
                self.assertFalse(check.reviewed_raster(name, embedded + b"unreviewed change"))
        self.assertFalse(check.reviewed_raster("src/terminal/other-logo.png", embedded))
        self.assertFalse(check.reviewed_raster("src/terminal/private.png", embedded))

    def test_reviewed_attachment_bytes_are_independently_synthetic(self):
        png = bytes.fromhex(
            "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
            "0000000d49444154081d63f8cfc0f01f000580023f49c2dbb40000000049454e44ae426082")
        for account in ("personal", "work", "optional"):
            marker = email(b"example.com", account.encode())
            payloads = {
                "image": png + b"\0" + marker,
                "unicode": b"\0\xff\x80\r\nLiteral caf\xc3\xa9 file for " + marker + b"\0\n",
            }
            for kind, expected in payloads.items():
                name = f"tests/fixtures/terminal/attachment-lifecycle/payloads/{account}-{kind}.bin"
                with self.subTest(name=name):
                    data = (check.ROOT / name).read_bytes()
                    self.assertEqual(data, expected)
                    self.assertTrue(check.reviewed_binary_fixture(name, data))
                    self.assertFalse(check.reviewed_binary_fixture(name, data + b"unreviewed change"))
                    self.assertFalse(check.reviewed_binary_fixture("tests/fixtures/other.bin", data))

    def test_staged_binary_gate_rejects_changed_and_unreviewed_artifacts(self):
        name = "tests/fixtures/terminal/attachment-lifecycle/payloads/work-image.bin"
        data = (check.ROOT / name).read_bytes()
        for candidate, payload, accepted in (
                (name, data, True),
                (name, data + b"unreviewed change", False),
                (name, b"replacement text", False),
                ("tests/fixtures/other.bin", data, False)):
            with self.subTest(name=candidate, accepted=accepted):
                output = io.StringIO()
                with mock.patch.object(check.subprocess, "check_output", return_value=candidate.encode() + b"\0"), \
                        mock.patch.object(check, "staged", return_value=payload), \
                        contextlib.redirect_stdout(output):
                    result = check.main()
                report = json.loads(output.getvalue())
                self.assertEqual(result, 0 if accepted else 1)
                self.assertEqual(report["passed"], accepted)


if __name__ == "__main__":
    unittest.main()
