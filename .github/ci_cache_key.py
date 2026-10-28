#!/usr/bin/env python3
"""Compiler/dependency cache identity independent of the package version."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def cache_key(root=ROOT, sdk=""):
    # The parent package's version changes at every release. Only dependency
    # pins belong in this shared content-addressed compilation cache identity.
    zon = (root / "build.zig.zon").read_text()
    pins = re.findall(r'\.(url|hash)\s*=\s*"([^"\n]+)"', zon)
    if not pins:
        raise ValueError("No pinned Zig dependencies found")
    compiler = json.loads((root / ".github/zig-release.json").read_text())
    material = json.dumps({"compiler": compiler, "dependencies": sorted(pins), "sdk": sdk}, sort_keys=True)
    return hashlib.sha256(material.encode()).hexdigest()


def app_cache_key(root=ROOT, paths=None):
    """Identify compiled app/probe inputs independently of CI/Python harness edits."""
    if paths is None:
        paths = subprocess.check_output([
            "git", "ls-files", "-z", "--", "build.zig", "build.zig.zon", "src",
            "web-demo", "assets", "tests/probes", "scripts/release.py",
        ], cwd=root).decode().strip("\0").split("\0")
    digest = hashlib.sha256()
    for name in sorted(paths):
        digest.update(name.encode() + b"\0")
        digest.update(hashlib.sha256((root / name).read_bytes()).digest())
    return digest.hexdigest()


def main():
    sdk = ""
    if sys.platform == "darwin":
        sdk = subprocess.check_output(["/usr/bin/xcrun", "--show-sdk-version"], text=True, timeout=10).strip()
        sdk += "\n" + subprocess.check_output(["/usr/bin/xcodebuild", "-version"], text=True, timeout=10).strip()
    value = cache_key(sdk=sdk)
    app_value = app_cache_key()
    if os.environ.get("GITHUB_OUTPUT"):
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write(f"key={value}\n")
            output.write(f"app_key={app_value}\n")
    print(json.dumps({"key": value, "app_key": app_value}, sort_keys=True))


if __name__ == "__main__":
    main()
