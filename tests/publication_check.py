#!/usr/bin/env python3
"""Audit the staged publication tree without printing sensitive matching values."""
from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
EMAIL = re.compile(rb"\b[A-Za-z0-9][A-Za-z0-9._%+-]*@([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{1,})\b")
EXAMPLE_DOMAINS = {b"example.com", b"example.org", b"example.net", b"example.test", b"b.c"}
FORBIDDEN_PATH = re.compile(rb"/home/[A-Za-z0-9_-]+/|/tmp/codex-[A-Za-z0-9_-]+")
SECRET_PATTERNS = [
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(rb"gh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(rb"AIza[A-Za-z0-9_-]{30,}"),
    re.compile(rb"ya29\.[A-Za-z0-9_-]{20,}"),
    re.compile(rb"1//[A-Za-z0-9_-]{30,}"),
    re.compile(rb"[0-9]{8,}-[A-Za-z0-9_-]{10,}\.apps\.googleusercontent\.com"),
]
IGNORED_PARTS = {".local-notes", ".zig-cache", "zig-out", "__pycache__"}


def staged(name):
    return subprocess.check_output(["git", "show", ":" + name], cwd=ROOT)


def main():
    names = subprocess.check_output(["git", "ls-files", "--cached", "-z"], cwd=ROOT).decode().split("\0")
    names = [name for name in names if name]
    issues = []
    for name in names:
        path = Path(name)
        if any(part in IGNORED_PARTS or part.startswith(".verification") for part in path.parts) or name.startswith("tests/results/"):
            issues.append({"file": name, "reason": "local/generated artifact staged"})
            continue
        if path.name.startswith("client_secret") or path.name.startswith("oauth-client") or path.suffix in {".log", ".pyc", ".core"} or path.name.startswith(".env"):
            issues.append({"file": name, "reason": "private/generated filename staged"})
        data = staged(name)
        if path.suffix == ".png":
            if name != "assets/omagma-logo.png" and not name.startswith("docs/images/omagma"):
                issues.append({"file": name, "reason": "unreviewed raster artifact staged"})
            if not data.startswith(b"\x89PNG\r\n\x1a\n"):
                issues.append({"file": name, "reason": "invalid PNG"})
            offset = 8
            while offset + 12 <= len(data):
                size = int.from_bytes(data[offset:offset + 4], "big")
                chunk = data[offset + 4:offset + 8]
                if chunk in {b"tEXt", b"iTXt", b"zTXt", b"eXIf"}:
                    issues.append({"file": name, "reason": "PNG metadata requires review"})
                offset += size + 12
            continue
        try:
            data.decode("utf-8")
        except UnicodeDecodeError:
            issues.append({"file": name, "reason": "unexpected binary artifact staged"})
            continue
        if FORBIDDEN_PATH.search(data):
            issues.append({"file": name, "reason": "personal/local absolute path"})
        if any(pattern.search(data) for pattern in SECRET_PATTERNS):
            issues.append({"file": name, "reason": "credential-like literal"})
        if any(domain.lower() not in EXAMPLE_DOMAINS and not domain.lower().endswith((b".example", b".invalid")) for domain in EMAIL.findall(data)):
            issues.append({"file": name, "reason": "nonfictional literal email address"})
    result = {"filesChecked": len(names), "passed": bool(names) and not issues, "issues": issues,
              "scope": "Staged text, artifact paths and PNG metadata; screenshot content requires visual review."}
    print(json.dumps(result, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
