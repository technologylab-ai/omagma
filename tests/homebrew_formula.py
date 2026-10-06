#!/usr/bin/env python3
"""Offline release-tooling oracles; no formula is written to a public tap."""
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import homebrew_formula as formula  # noqa: E402


VERSION = "0.2.4"


def checksums():
    return {name: hashlib.sha256(name.encode()).hexdigest() for name in formula.names_for(VERSION)}


def metadata():
    base = "https://github.com/technologylab-ai/omagma/releases/"
    return {"tag_name": "v0.2.4", "html_url": base + "tag/v0.2.4", "draft": False, "prerelease": False,
            "assets": [{"name": name, "size": 123, "browser_download_url": base + "download/v0.2.4/" + name}
                       for name in formula.names_for(VERSION) | {"SHA256SUMS"}]}


class FormulaTests(unittest.TestCase):
    def test_read_token_never_follows_redirects_or_asset_requests(self):
        with patch.dict("os.environ", {"GH_TOKEN": "synthetic-read-token", "GITHUB_TOKEN": ""}), \
                patch.object(formula.urllib.request, "urlopen") as open_url:
            open_url.return_value.__enter__.return_value.read.return_value = b"{}"
            formula.fetch_small("https://api.github.com/repos/technologylab-ai/omagma/releases/tags/v0.2.4", 4096)
            original = open_url.call_args.args[0]
            self.assertEqual("Bearer synthetic-read-token", original.get_header("Authorization"))
            redirected = formula.urllib.request.HTTPRedirectHandler().redirect_request(
                original, None, 302, "Found", {}, "https://unrelated.example.org/no-token")
            self.assertIsNone(redirected.get_header("Authorization"))
            formula.fetch_small("https://github.com/technologylab-ai/omagma/releases/download/v0.2.4/SHA256SUMS", 4096)
            self.assertIsNone(open_url.call_args.args[0].get_header("Authorization"))

    def test_complete_checksums_and_nonplaceholder_inventory(self):
        rows = checksums()
        raw = "".join(f"{value}  {key}\n" for key, value in rows.items()).encode()
        self.assertEqual(rows, formula.parse_checksums(raw, VERSION))
        for invalid in (raw + raw.splitlines()[0] + b"\n", raw.replace(next(iter(rows.values())).encode(), b"0" * 64),
                        b"\n".join(raw.splitlines()[:-1]) + b"\n", raw + b"bad  ../../secret\n"):
            with self.subTest(invalid=invalid[-100:]), self.assertRaises(ValueError):
                formula.parse_checksums(invalid, VERSION)

    def test_only_complete_published_stable_release(self):
        self.assertEqual(10, len(formula.published_assets(metadata(), VERSION)))
        for key, bad in (("draft", True), ("prerelease", True), ("tag_name", "v0.2.3")):
            value = metadata()
            value[key] = bad
            with self.subTest(key=key), self.assertRaises(ValueError):
                formula.published_assets(value, VERSION)
        value = metadata()
        value["assets"].pop()
        with self.assertRaises(ValueError):
            formula.published_assets(value, VERSION)
        value = metadata()
        value["assets"][0]["browser_download_url"] = "https://unrelated.example.org/package"
        with self.assertRaises(ValueError):
            formula.published_assets(value, VERSION)

    def test_version_rejects_script_or_path_injection(self):
        for version in ("../0.2.4", '0.2.4"', "0.2.4\nputs 1", "0.2.4-rc1"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                formula.validate_version(version)

    def test_normalized_bundle_binds_backend_and_manifest(self):
        binary = b"An independent fictional binary payload."
        digest = hashlib.sha256(binary).hexdigest()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bundle.tar.gz"
            with tarfile.open(path, "w:gz") as archive:
                for name, data, mode in (("omagma/zig-out/bin/omagma", binary, 0o755),
                                         ("omagma/manifest.json", b'{"version":"0.2.4"}\n', 0o644)):
                    member = tarfile.TarInfo(name)
                    member.size, member.mode = len(data), mode
                    archive.addfile(member, io.BytesIO(data))
            formula.verify_bundle(path, VERSION, "macos", "arm64", digest)
            with self.assertRaises(ValueError):
                formula.verify_bundle(path, VERSION, "macos", "arm64", "f" * 64)
            with self.assertRaises(ValueError):
                formula.verify_bundle(path, "0.2.5", "macos", "arm64", digest)

    def test_formula_uses_bundles_and_private_real_cli_oracles(self):
        rendered = formula.render_formula(VERSION, checksums())
        self.assertEqual(4, rendered.count('url "https://github.com/technologylab-ai/omagma/releases/download/v0.2.4/omagma-0.2.4-'))
        for expected in ('depends_on macos: :ventura', 'bin.install "zig-out/bin/omagma"',
                         'config.chmod 0600', '"--fixtures", "--config", config.to_s',
                         '"--cache-dir"', '"--cache-messages", "3"', '"--prefetch-bodies", "3"',
                         '%w[demo-96 demo-95 demo-94]', '"Hello from personal@example.com!"',
                         'fetch("fixtureSends")', 'pkgshare.install "examples", "LICENSE", "LICENSES"'):
            self.assertIn(expected, rendered)
        self.assertNotIn("--version", rendered)
        self.assertNotIn('ENV["HOME"]', rendered)
        self.assertIn("Agent setup: https://technologylab-ai.github.io/omagma/docs/agent-setup/", rendered)
        for prohibited in ('depends_on "python', 'depends_on "node', 'depends_on "qt', 'depends_on "tmux'):
            self.assertNotIn(prohibited, rendered)
        result = subprocess.run(["ruby", "-c"], input=rendered, text=True, capture_output=True)
        self.assertEqual(0, result.returncode, result.stderr)


if __name__ == "__main__":
    unittest.main()
