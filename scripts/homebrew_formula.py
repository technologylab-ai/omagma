#!/usr/bin/env python3
"""Generate the tap formula only from a complete, published Omagma release.

This is release tooling, not an installed runtime dependency. A local checksum
or asset directory is an optimization only: it must match the published files.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import tarfile
import tempfile
import urllib.request

REPOSITORY = "technologylab-ai/omagma"
PLATFORMS = (("macos", "arm64"), ("macos", "x86_64"),
             ("linux", "arm64"), ("linux", "x86_64"))
MAX_ASSET = 256 * 1024 * 1024


def validate_version(version):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("A stable numeric release version is required")
    return version


def names_for(version):
    validate_version(version)
    return {"LICENSES.txt"} | {
        name for os_name, arch in PLATFORMS for name in
        (f"omagma-{os_name}-{arch}", f"omagma-{version}-{os_name}-{arch}.tar.gz")}


def parse_checksums(raw, version):
    sums = {}
    for line in raw.decode("ascii").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_.-]+)", line)
        if not match or match[2] in sums or match[1] == "0" * 64:
            raise ValueError("Malformed, duplicate or placeholder checksum")
        sums[match[2]] = match[1]
    if set(sums) != names_for(version):
        raise ValueError("Published checksums do not cover the complete four-platform release")
    return sums


def fetch_small(url, limit):
    request = urllib.request.Request(url, headers={"User-Agent": "omagma-release-tooling",
                                                  "Accept": "application/vnd.github+json"})
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token and url.startswith(f"https://api.github.com/repos/{REPOSITORY}/"):
        # urllib's unredirected headers are excluded from redirect requests.
        # Read authentication must never reach the public asset/CDN download.
        request.add_unredirected_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request, timeout=60) as response:
        raw = response.read(limit + 1)
    if len(raw) > limit:
        raise ValueError("Published metadata exceeds its size bound")
    return raw


def published_assets(metadata, version):
    base = f"https://github.com/{REPOSITORY}/releases/download/v{version}/"
    if (metadata.get("tag_name") != "v" + version or metadata.get("draft") is not False
            or metadata.get("prerelease") is not False
            or metadata.get("html_url") != f"https://github.com/{REPOSITORY}/releases/tag/v{version}"):
        raise ValueError("Expected the exact published stable release")
    assets = {}
    for item in metadata.get("assets", []):
        name = item.get("name")
        if not isinstance(name, str) or name in assets or item.get("browser_download_url") != base + name:
            raise ValueError("Invalid or duplicate published asset identity")
        size = item.get("size")
        if type(size) is not int or not 0 < size <= MAX_ASSET:
            raise ValueError("Invalid published asset size")
        assets[name] = item
    if set(assets) != names_for(version) | {"SHA256SUMS"}:
        raise ValueError("The release is not a complete four-platform publication")
    return assets


def verify_bundle(path, version, os_name, arch, raw_hash):
    binary_name, manifest_name = "omagma/zig-out/bin/omagma", "omagma/manifest.json"
    found = set()
    unpacked = 0
    with tarfile.open(path, "r:gz") as archive:
        for index, member in enumerate(archive):
            parts = PurePosixPath(member.name)
            unpacked += member.size
            if (index >= 4096 or unpacked > 512 * 1024 * 1024 or not member.isfile()
                    or parts.is_absolute() or ".." in parts.parts or parts.parts[0] != "omagma"
                    or member.uid or member.gid or member.uname or member.gname):
                raise ValueError("Bundle violates the normalized release contract")
            if member.name in {binary_name, manifest_name}:
                if member.name in found:
                    raise ValueError("Bundle duplicates a required runtime file")
                found.add(member.name)
                with archive.extractfile(member) as content:
                    if member.name == binary_name:
                        digest = hashlib.file_digest(content, "sha256").hexdigest()
                        if digest != raw_hash or member.mode != 0o755:
                            raise ValueError("Bundle backend differs from the published raw artifact")
                    else:
                        if member.size > 16384 or json.loads(content.read()).get("version") != version:
                            raise ValueError("Bundle manifest does not match the published version")
    if found != {binary_name, manifest_name}:
        raise ValueError(f"Missing {os_name}/{arch} bundle runtime or manifest")


def verified_bundle(item, digest, directory, local_assets=None):
    name = item["name"]
    path = directory / name
    if local_assets is not None:
        path = local_assets / name
        if not path.is_file() or path.is_symlink():
            raise ValueError("Local release bundle is missing or is a symlink")
    else:
        request = urllib.request.Request(item["browser_download_url"],
                                         headers={"User-Agent": "omagma-release-tooling"})
        with urllib.request.urlopen(request, timeout=180) as response, path.open("xb") as output:
            count = 0
            while chunk := response.read(512 * 1024):
                count += len(chunk)
                if count > item["size"]:
                    raise ValueError("Published bundle exceeds its declared size")
                output.write(chunk)
    with path.open("rb") as content:
        actual = hashlib.file_digest(content, "sha256").hexdigest()
    if path.stat().st_size != item["size"] or actual != digest:
        raise ValueError("Bundle checksum or size differs from the published release")
    return path


def formula_revision(version, sums, previous=None):
    """Keep regenerated formulae stable and make same-version asset fixes upgradeable."""
    validate_version(version)
    if previous is None:
        return 0
    if len(previous.encode()) > 65536:
        raise ValueError("Existing formula exceeds its size bound")
    versions = re.findall(r'^  version "([0-9]+\.[0-9]+\.[0-9]+)"$', previous, re.M)
    if len(versions) != 1:
        raise ValueError("Existing formula has an unknown version")
    old_version = versions[0]
    if tuple(map(int, old_version.split('.'))) > tuple(map(int, version.split('.'))):
        raise ValueError("Refusing a formula version downgrade")
    if old_version != version:
        return 0
    revisions = re.findall(r'^  revision (.*)$', previous, re.M)
    if len(revisions) > 1 or (revisions and not re.fullmatch(r'[0-9]{1,6}', revisions[0])):
        raise ValueError("Existing formula has an unknown revision")
    revision = int(revisions[0]) if revisions else 0
    entries = re.findall(r'^      url "([^"\n]+)"\n      sha256 "([0-9a-f]{64})"$', previous, re.M)
    base = f"https://github.com/{REPOSITORY}/releases/download/v{version}/"
    expected = {base + f"omagma-{version}-{os_name}-{arch}.tar.gz":
                sums[f"omagma-{version}-{os_name}-{arch}.tar.gz"] for os_name, arch in PLATFORMS}
    if len(entries) != 4 or len(dict(entries)) != 4 or set(dict(entries)) != set(expected):
        raise ValueError("Existing formula has an unknown four-platform asset inventory")
    return revision + (dict(entries) != expected)


def render_formula(version, sums, revision=0):
    validate_version(version)
    if type(revision) is not int or not 0 <= revision <= 999999:
        raise ValueError("Invalid formula revision")
    # Validate the complete inventory even when called directly by unit tests.
    parse_checksums("".join(f"{sums[name]}  {name}\n" for name in sorted(sums)).encode(), version)
    base = f"https://github.com/{REPOSITORY}/releases/download/v{version}"
    platform_blocks = []
    for os_name in ("macos", "linux"):
        lines = [f"  on_{os_name} do"]
        if os_name == "macos":
            lines.append("    depends_on macos: :ventura")
        for arm, arch in ((True, "arm64"), (False, "x86_64")):
            name = f"omagma-{version}-{os_name}-{arch}.tar.gz"
            lines.extend([f"    on_{'arm' if arm else 'intel'} do",
                          f'      url "{base}/{name}"', f'      sha256 "{sums[name]}"', "    end"])
        lines.append("  end")
        platform_blocks.append("\n".join(lines))
    platforms = "\n\n".join(platform_blocks)
    revision_line = f"  revision {revision}\n" if revision else ""
    return f'''# Generated from verified published v{version} assets by scripts/homebrew_formula.py.
# Regenerate for the next release; do not edit checksum entries by hand.
require "json"
require "shellwords"

class Omagma < Formula
  desc "Account-separated Gmail terminal client and agent CLI"
  homepage "https://technologylab-ai.github.io/omagma/"
  version "{version}"
{revision_line}  license "MIT"

{platforms}

  def install
    bin.install "zig-out/bin/omagma"
    doc.install "README.md", "AGENTS.md", "docs", "skills"
    pkgshare.install "examples", "LICENSE", "LICENSES"
    cp_r pkgshare/"examples", doc
  end

  def caveats
    <<~TEXT
      Start the terminal client with: omagma tui
      Account setup: https://technologylab-ai.github.io/omagma/docs/setup/
      Agent setup: https://technologylab-ai.github.io/omagma/docs/agent-setup/
      Installed skill: #{{opt_prefix}}/share/doc/omagma/skills/omagma-setup/SKILL.md
      Fictional example: #{{opt_prefix}}/share/omagma/examples/config.json

      Keep your own account configuration and OAuth downloads outside the keg.
      Connecting Gmail needs Google Chrome, system CA certificates and your
      explicit Google consent. macOS uses the native Keychain; Linux needs
      secret-tool and a running Secret Service. The Omarchy bar uses the Linux
      plugin bundle. Installation creates no accounts and grants no mail access.
    TEXT
  end

  test do
    %w[CONFIG CACHE DATA STATE].each do |kind|
      ENV["XDG_#{{kind}}_HOME"] = (testpath/kind.downcase).to_s
    end
    ENV["XDG_RUNTIME_DIR"] = (testpath/"runtime").to_s
    (testpath/"runtime").mkpath
    (testpath/"runtime").chmod 0700
    %w[DISPLAY WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE DBUS_SESSION_BUS_ADDRESS].each {{ |key| ENV.delete(key) }}
    config = testpath/"fictional-config.json"
    config.write JSON.generate(accounts: [{{address: "personal@example.com", profile: "Profile 1", enabled: true, required: true}}])
    config.chmod 0600
    common = ["--fixtures", "--config", config.to_s, "--cache-dir", (testpath/"mail-cache").to_s,
              "--cache-messages", "3",
              "--account", "personal@example.com"]
    list = JSON.parse(shell_output(Shellwords.join([bin/"omagma", "mail", "refresh", *common,
                                                   "--limit", "3", "--prefetch-bodies", "3"])))
    assert_equal true, list.fetch("ok")
    assert_equal "personal@example.com", list.fetch("account")
    assert_equal %w[demo-96 demo-95 demo-94], list.fetch("data").fetch("messages").map {{ |mail| mail.fetch("id") }}
    body = JSON.parse(shell_output(Shellwords.join([bin/"omagma", "mail", "read", *common,
                                                   "--message-id", "demo-96", "--cached"])))
    assert_equal true, body.fetch("ok")
    assert_match "Hello from personal@example.com!", body.fetch("data").fetch("bodyText")
    stats = JSON.parse(shell_output(Shellwords.join([bin/"omagma", "cache", "stats", *common, "--cached"])))
    assert_equal true, stats.fetch("ok")
    assert_equal 0, stats.fetch("data").fetch("fixtureSends")
    assert_equal 3, stats.fetch("data").fetch("metadataEntries")
  end
end
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--checksums", type=Path, help="Must equal the published SHA256SUMS")
    parser.add_argument("--asset-dir", type=Path, help="Local bundles must match published metadata and hashes")
    parser.add_argument("--output", type=Path, help="Write only after all published bundle checks pass")
    args = parser.parse_args()
    version = validate_version(args.version)
    metadata = json.loads(fetch_small(f"https://api.github.com/repos/{REPOSITORY}/releases/tags/v{version}", 1024 * 1024))
    assets = published_assets(metadata, version)
    raw = fetch_small(assets["SHA256SUMS"]["browser_download_url"], 65536)
    if len(raw) != assets["SHA256SUMS"]["size"]:
        raise ValueError("Published checksum file size differs")
    if args.checksums is not None and args.checksums.read_bytes() != raw:
        raise ValueError("Local checksums differ from the published release")
    sums = parse_checksums(raw, version)
    with tempfile.TemporaryDirectory(prefix="omagma-formula-assets-") as temporary:
        for os_name, arch in PLATFORMS:
            name = f"omagma-{version}-{os_name}-{arch}.tar.gz"
            path = verified_bundle(assets[name], sums[name], Path(temporary), args.asset_dir)
            verify_bundle(path, version, os_name, arch, sums[f"omagma-{os_name}-{arch}"])
    previous = None
    if args.output is not None:
        if args.output.is_symlink():
            raise ValueError("Refusing a symlink formula")
        if args.output.exists():
            previous = args.output.read_text()
    formula = render_formula(version, sums, formula_revision(version, sums, previous))
    if args.output is None:
        print(formula, end="")
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode="w", dir=args.output.parent, prefix=".omagma-formula-",
                                         delete=False) as temporary:
            temporary.write(formula)
            pending = Path(temporary.name)
        try:
            pending.chmod(0o644)
            pending.replace(args.output)
        finally:
            pending.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
