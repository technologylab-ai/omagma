#!/usr/bin/env python3
"""Audit the staged publication tree without printing sensitive matching values."""
from __future__ import annotations

import json
import hashlib
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
# Exact upstream license notice retains required public author attribution.
PUBLIC_LICENSES = {'LICENSES/uucode-LICENSE_Bjoern_Hoehrmann.txt': 'de219cece932aad5a817bf763393d8d149d378a15d2ad5320e3331eac07626dd'}
IGNORED_PARTS = {".local-notes", ".zig-cache", "zig-pkg", "zig-out", "dist", "node_modules", "__pycache__"}
PUBLIC_GIFS = {"docs/images/omagma-fetch.gif"}


def validate_gif(data):
    """Structure/metadata gate only; every rendered frame needs visual review.

    GIF89a block lengths follow https://www.w3.org/Graphics/GIF/spec-gif89a.txt.
    Only ordinary graphic controls and the fixed NETSCAPE loop payload qualify.
    """
    if len(data) > 8 * 1024**2 or len(data) < 14 or data[:6] not in (b"GIF87a", b"GIF89a"):
        raise ValueError("invalid or oversized GIF")
    width = int.from_bytes(data[6:8], "little")
    height = int.from_bytes(data[8:10], "little")
    if not (0 < width <= 4096 and 0 < height <= 4096 and width * height <= 4_000_000):
        raise ValueError("GIF dimensions exceed reviewed bounds")
    offset = 13
    frames = 0
    loop_seen = False

    def take(count):
        nonlocal offset
        if offset + count > len(data):
            raise ValueError("truncated GIF")
        block = data[offset:offset + count]
        offset += count
        return block

    def subblocks():
        blocks = []
        while True:
            size = take(1)[0]
            if size == 0:
                return blocks
            blocks.append(take(size))

    if data[10] & 0x80:
        take(3 * (1 << ((data[10] & 7) + 1)))
    while offset < len(data):
        marker = take(1)[0]
        if marker == 0x3B:
            if offset != len(data) or frames == 0:
                raise ValueError("GIF has trailing bytes or no frames")
            return {"width": width, "height": height, "frames": frames}
        if marker == 0x21:
            extension = take(1)[0]
            if extension == 0xF9:
                if take(1) != b"\x04":
                    raise ValueError("invalid GIF graphic control")
                control = take(4)
                if control[0] & 0xE0 or (control[0] >> 2) & 7 > 3 or take(1) != b"\x00":
                    raise ValueError("invalid GIF graphic control")
            elif extension == 0xFF:
                size = take(1)[0]
                identifier = take(size)
                blocks = subblocks()
                if loop_seen or identifier != b"NETSCAPE2.0" or len(blocks) != 1 or len(blocks[0]) != 3 or blocks[0][0] != 1:
                    raise ValueError("GIF application metadata requires review")
                loop_seen = True
            else:
                # Comments, plain text, XMP and arbitrary app blocks can carry
                # personal metadata even when the displayed pixels look safe.
                raise ValueError("GIF text/comment metadata requires review")
        elif marker == 0x2C:
            descriptor = take(9)
            left = int.from_bytes(descriptor[0:2], "little")
            top = int.from_bytes(descriptor[2:4], "little")
            columns = int.from_bytes(descriptor[4:6], "little")
            rows = int.from_bytes(descriptor[6:8], "little")
            if columns == 0 or rows == 0 or left + columns > width or top + rows > height or descriptor[8] & 0x18:
                raise ValueError("invalid GIF image rectangle")
            if descriptor[8] & 0x80:
                take(3 * (1 << ((descriptor[8] & 7) + 1)))
            if not 2 <= take(1)[0] <= 8:
                raise ValueError("invalid GIF LZW size")
            subblocks()
            frames += 1
            if frames > 120:
                raise ValueError("GIF frame count exceeds reviewed bounds")
        else:
            raise ValueError("invalid GIF block marker")
    raise ValueError("GIF trailer missing")


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
        if path.suffix == ".gif":
            if name not in PUBLIC_GIFS:
                issues.append({"file": name, "reason": "unreviewed animation artifact staged"})
            try:
                validate_gif(data)
            except ValueError as error:
                issues.append({"file": name, "reason": str(error)})
            continue
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
        if PUBLIC_LICENSES.get(name) != hashlib.sha256(data).hexdigest() and any(domain.lower() not in EXAMPLE_DOMAINS and not domain.lower().endswith((b".example", b".invalid")) for domain in EMAIL.findall(data)):
            issues.append({"file": name, "reason": "nonfictional literal email address"})
    result = {"filesChecked": len(names), "passed": bool(names) and not issues, "issues": issues,
              "scope": "Staged text, artifact paths and PNG/GIF metadata; every screenshot/animation frame requires visual review."}
    print(json.dumps(result, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
