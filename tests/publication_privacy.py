#!/usr/bin/env python3
"""Literal privacy boundaries for reviewed synthetic examples and raster assets."""
import hashlib
import unittest

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


if __name__ == "__main__":
    unittest.main()
