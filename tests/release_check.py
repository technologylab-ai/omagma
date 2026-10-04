#!/usr/bin/env python3
"""Verify release checksums, archive contents and the native packaged executable."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from release import TARGETS, distribution_licenses, package_versions, verify_binary  # noqa: E402


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=TARGETS, required=True)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    version, _compiler = package_versions()
    directory = args.output_dir.resolve()
    raw = directory / ("omagma-linux-" + args.arch)
    bundle = directory / f"omagma-{version}-linux-{args.arch}.tar.gz"
    checksum_file = directory / ("SHA256SUMS-" + args.arch)
    if not checksum_file.exists():
        checksum_file = directory / "SHA256SUMS"
    checksums = {}
    for line in checksum_file.read_text().splitlines():
        digest, name = line.split("  ", 1)
        require(len(digest) == 64 and name == Path(name).name and name not in checksums, "Invalid checksum entry")
        checksums[name] = digest
    for path in (raw, bundle):
        require(checksums.get(path.name) == hashlib.sha256(path.read_bytes()).hexdigest(), "Release checksum mismatch")
    report = verify_binary(raw, args.arch)
    require((directory / "LICENSES.txt").read_bytes() == distribution_licenses(), "Binary distribution license notices differ")
    tracked = set(subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT, text=True).strip("\0").split("\0"))
    expected = {"omagma/" + name for name in tracked} | {"omagma/zig-out/bin/omagma"}
    required = {"AGENTS.md", "README.md", "BarWidget.qml", "Service.qml", "manifest.json", "Model.mjs",
                "docs/INSTALL.md", "docs/SETUP.md", "skills/omagma-setup/SKILL.md", "assets/magma.svg", "LICENSES/zig.txt", "LICENSES/musl.txt"}
    require(required <= tracked, "Bundle lacks an installation or runtime file")
    with tarfile.open(bundle) as archive:
        members = archive.getmembers()
        require(len(members) == len(expected) and {m.name for m in members} == expected, "Bundle differs from the audited tracked tree")
        for member in members:
            require(member.isfile() and not Path(member.name).is_absolute() and ".." not in Path(member.name).parts, "Unsafe archive member")
            require(member.uid == member.gid == 0 and not member.uname and not member.gname, "Archive embeds user or group metadata")
            data = archive.extractfile(member).read()
            name = member.name.removeprefix("omagma/")
            if name == "zig-out/bin/omagma":
                require(data == raw.read_bytes() and member.mode == 0o755, "Packaged executable differs from the raw artifact")
            elif name == "manifest.json":
                manifest = json.loads((ROOT / name).read_text())
                manifest["version"] = version
                require(json.loads(data) == manifest, "Plugin manifest version or contents differ")
            else:
                require(data == (ROOT / name).read_bytes(), "Packaged source differs from the verified tree")
        native = platform.machine() in ({"x86_64", "AMD64"} if args.arch == "x86_64" else {"aarch64", "arm64"})
        if native:
            with tempfile.TemporaryDirectory(prefix="omagma-release-test-") as temporary:
                archive.extractall(temporary, filter="data")
                binary = Path(temporary) / "omagma/zig-out/bin/omagma"
                env = os.environ.copy()
                env.pop("HOME", None)
                actual = subprocess.check_output([str(binary), "--version"], env=env, text=True, timeout=5).strip()
                require(actual == "omagma " + version, "Extracted binary cannot report its package version")
                budget = json.loads(subprocess.check_output([str(binary), "budget"], text=True, timeout=5))
                require(budget["reservationBytes"] == 16 * 1024 * 1024, "Release changed the application memory reservation")
                require(budget["assignedBytes"] + budget["unassignedBytes"] == budget["reservationBytes"], "Invalid reservation accounting")
    print(json.dumps({"passed": True, "version": version, "files": len(expected), "nativeSmokeTest": native, "binary": report}, indent=2))


if __name__ == "__main__":
    main()
