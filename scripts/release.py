#!/usr/bin/env python3
"""Build and package a stripped, static musl backend with the Quickshell plugin."""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
TARGETS = {"x86_64": ("x86_64-linux-musl", 62), "arm64": ("aarch64-linux-musl", 183)}


def package_versions():
    zon = (ROOT / "build.zig.zon").read_text()
    values = []
    for field in ("version", "minimum_zig_version"):
        match = re.search(r"\." + field + r'\s*=\s*"([^"\n]+)"', zon)
        if not match or not re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", match[1]):
            raise ValueError(f"Invalid {field} in build.zig.zon")
        values.append(match[1])
    return tuple(values)


def distribution_licenses():
    return b"omagma\n======\n" + (ROOT / "LICENSE").read_bytes() + b"\n\nZig\n===\n" + (ROOT / "LICENSES/zig.txt").read_bytes() + b"\n\nmusl\n====\n" + (ROOT / "LICENSES/musl.txt").read_bytes()


def verify_binary(path, arch):
    """Reject the wrong architecture, dynamic dependencies and debug information."""
    data = Path(path).read_bytes()
    if len(data) < 64 or data[:7] != b"\x7fELF\x02\x01\x01":
        raise ValueError("Expected a little-endian ELF64 binary")
    elf_type, machine = struct.unpack_from("<HH", data, 16)
    if elf_type != 2 or machine != TARGETS[arch][1]:
        raise ValueError("Wrong ELF architecture or executable type")
    phoff, shoff = struct.unpack_from("<QQ", data, 32)
    phsize, phcount, shsize, shcount, shstrings = struct.unpack_from("<HHHHH", data, 54)
    if phsize < 56 or phoff + phsize * phcount > len(data):
        raise ValueError("Invalid ELF program headers")
    for index in range(phcount):
        offset = phoff + index * phsize
        kind = struct.unpack_from("<I", data, offset)[0]
        if kind == 3:  # PT_INTERP
            raise ValueError("Binary requires a dynamic loader")
        if kind == 2:  # PT_DYNAMIC
            location, size = struct.unpack_from("<QQ", data, offset + 8)[0], struct.unpack_from("<Q", data, offset + 32)[0]
            if location + size > len(data) or size % 16:
                raise ValueError("Invalid ELF dynamic section")
            for entry in range(location, location + size, 16):
                if struct.unpack_from("<q", data, entry)[0] == 1:  # DT_NEEDED
                    raise ValueError("Binary requires a shared library")
    if shcount:
        if shsize < 64 or shstrings >= shcount or shoff + shsize * shcount > len(data):
            raise ValueError("Invalid ELF section headers")
        string_header = shoff + shstrings * shsize
        start, size = struct.unpack_from("<QQ", data, string_header + 24)
        if start + size > len(data):
            raise ValueError("Invalid ELF section names")
        strings = data[start:start + size]
        for index in range(shcount):
            name_offset = struct.unpack_from("<I", data, shoff + index * shsize)[0]
            name = strings[name_offset:].split(b"\0", 1)[0]
            if name.startswith((b".debug", b".zdebug")) or name == b".symtab":
                raise ValueError("Release binary still contains debug symbols")
    if re.search(rb"/home/[A-Za-z0-9_-]+/|/tmp/codex-[A-Za-z0-9_-]+", data):
        raise ValueError("Release binary embeds a private build path")
    return {"arch": arch, "static": True, "stripped": True, "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest()}


def tracked_files():
    # A release must correspond to the privacy-audited Git index. Untracked and
    # ignored files (credentials, screenshots, caches) can never enter the bundle.
    if subprocess.run(["git", "diff", "--quiet"], cwd=ROOT).returncode:
        raise ValueError("Stage or commit tracked changes before packaging")
    subprocess.run(["python3", "tests/publication_check.py"], cwd=ROOT, check=True)
    listing = subprocess.check_output(["git", "ls-files", "--stage", "-z"], cwd=ROOT)
    files = []
    for entry in listing.split(b"\0"):
        if not entry:
            continue
        metadata, name = entry.decode().split("\t", 1)
        mode, _oid, stage = metadata.split()
        if mode not in {"100644", "100755"} or stage != "0":
            raise ValueError("Release tree contains a symlink, submodule or unresolved conflict")
        path = Path(name)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError("Invalid tracked release path")
        files.append((name, 0o755 if mode == "100755" else 0o644))
    return sorted(files)


def make_bundle(path, binary, files, version):
    epoch = int(os.environ.get("SOURCE_DATE_EPOCH") or subprocess.check_output(
        ["git", "log", "-1", "--format=%ct"], cwd=ROOT, text=True).strip())
    # Normalize metadata and ordering so rebuilding the same inputs gives the
    # same archive, without user names, group names or machine paths.
    with path.open("wb") as output, gzip.GzipFile(fileobj=output, mode="wb", filename="", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
            for name, mode in files + [("zig-out/bin/omagma", 0o755)]:
                data = binary.read_bytes() if name == "zig-out/bin/omagma" else (ROOT / name).read_bytes()
                if name == "manifest.json":
                    manifest = json.loads(data)
                    manifest["version"] = version
                    data = (json.dumps(manifest, indent=2) + "\n").encode()
                member = tarfile.TarInfo("omagma/" + name)
                member.size, member.mode, member.mtime = len(data), mode, epoch
                archive.addfile(member, io.BytesIO(data))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=TARGETS)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist")
    parser.add_argument("--print-version", action="store_true")
    parser.add_argument("--print-zig-version", action="store_true")
    parser.add_argument("--check-binary", type=Path)
    args = parser.parse_args()
    version, zig_version = package_versions()
    if args.print_version or args.print_zig_version:
        print(zig_version if args.print_zig_version else version)
        return
    if not args.arch:
        parser.error("--arch is required")
    if args.check_binary:
        print(json.dumps(verify_binary(args.check_binary, args.arch)))
        return
    files = tracked_files()
    actual_zig = subprocess.check_output(["zig", "version"], text=True).strip()
    if actual_zig != zig_version:
        raise ValueError(f"Use Zig {zig_version}; found {actual_zig}")
    prefix = ROOT / (".verification-release-" + args.arch)
    subprocess.run(["zig", "build", "-Dtarget=" + TARGETS[args.arch][0], "-Dcpu=baseline",
                    "-Doptimize=ReleaseSafe", "-Dstrip=true", "--prefix", str(prefix)], cwd=ROOT, check=True)
    binary = prefix / "bin/omagma"
    report = verify_binary(binary, args.arch)
    if platform.machine() in ({"x86_64", "AMD64"} if args.arch == "x86_64" else {"aarch64", "arm64"}):
        actual_version = subprocess.check_output([str(binary), "--version"], text=True, timeout=5).strip()
        if actual_version != "omagma " + version:
            raise ValueError("Binary version differs from build.zig.zon")
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    raw = output / ("omagma-linux-" + args.arch)
    shutil.copyfile(binary, raw)
    raw.chmod(0o755)
    bundle = output / f"omagma-{version}-linux-{args.arch}.tar.gz"
    make_bundle(bundle, binary, files, version)
    (output / "LICENSES.txt").write_bytes(distribution_licenses())
    checksums = "".join(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + path.name + "\n" for path in (raw, bundle))
    (output / ("SHA256SUMS-" + args.arch)).write_text(checksums)
    print(json.dumps({"version": version, "zig": zig_version, "bundle": bundle.name, "binary": report}, indent=2))


if __name__ == "__main__":
    main()
