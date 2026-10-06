#!/usr/bin/env python3
"""Package static Linux-musl or native macOS terminal executables and audited sources."""
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
MACOS_MINIMUM = (13, 0, 0)
MACOS_TARGETS = {"x86_64": ("x86_64-macos.13.0", 0x01000007, 3),
                 "arm64": ("aarch64-macos.13.0", 0x0100000C, 0)}
SYSTEM_DYLIBS = frozenset({
    "/usr/lib/libSystem.B.dylib", "/usr/lib/libobjc.A.dylib",
    "/System/Library/Frameworks/Security.framework/Versions/A/Security",
    "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
})


def is_native(arch, os_name="linux"):
    system = "Darwin" if os_name == "macos" else "Linux"
    machines = {"x86_64", "AMD64"} if arch == "x86_64" else {"aarch64", "arm64"}
    return platform.system() == system and platform.machine() in machines


def artifact_names(version, arch, os_name="linux"):
    return (f"omagma-{os_name}-{arch}", f"omagma-{version}-{os_name}-{arch}.tar.gz",
            f"SHA256SUMS-{arch}" if os_name == "linux" else f"SHA256SUMS-{os_name}-{arch}")


def reject_private_paths(data):
    # A literal owned runtime template (e.g. keychain-probe-{s}) is not a
    # private build path. Reject concrete workspace/source paths instead.
    if re.search(rb"/(?:home|Users)/[^/\x00\s]+/|/(?:private/)?tmp/codex-[A-Za-z0-9_-]+|/(?:private/)?tmp/omagma-[A-Za-z0-9_-]+/|/private/var/folders/", data):
        raise ValueError("Release binary embeds a private build path")


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
    parts = [b"omagma\n======\n", (ROOT / "LICENSE").read_bytes()]
    for path in sorted((ROOT / "LICENSES").iterdir()):
        if path.suffix in {".txt", ".md"}:
            parts.extend([b"\n\n" + path.name.encode() + b"\n" + b"=" * len(path.name) + b"\n", path.read_bytes()])
    return b"".join(parts)



def verify_binary(path, arch, os_name="linux"):
    """Reject the wrong architecture, dynamic dependencies and debug information."""
    if os_name == "macos":
        return verify_macho(path, arch)
    if os_name != "linux" or arch not in TARGETS:
        raise ValueError("Unsupported release platform")
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
    reject_private_paths(data)
    return {"arch": arch, "static": True, "stripped": True, "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest()}


def version_tuple(packed):
    return packed >> 16, (packed >> 8) & 255, packed & 255


def verify_macho(path, arch):
    """Read the thin Mach-O ABI directly; never rely on a host otool summary."""
    if arch not in MACOS_TARGETS:
        raise ValueError("Unsupported release architecture")
    data = Path(path).read_bytes()
    if len(data) < 32 or data[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("Expected a thin little-endian Mach-O64 executable")
    cpu, subtype, kind, count, command_bytes, flags, reserved = struct.unpack_from("<7I", data, 4)
    if cpu != MACOS_TARGETS[arch][1] or subtype != MACOS_TARGETS[arch][2] or kind != 2:
        raise ValueError("Wrong Mach-O architecture, baseline CPU or executable type")
    if not flags & 0x200000 or reserved or not count or count > 4096 or command_bytes > len(data) - 32:
        raise ValueError("Invalid Mach-O executable header or missing PIE")
    end = 32 + command_bytes
    offset = 32
    minimum = sdk = None
    libraries = set()
    loader = entry = False
    def command_string(start, size, field):
        string_offset = struct.unpack_from("<I", data, start + field)[0]
        if string_offset < field + 4 or string_offset >= size:
            raise ValueError("Invalid Mach-O load-command string")
        value = data[start + string_offset:start + size]
        if b"\0" not in value:
            raise ValueError("Unterminated Mach-O load-command string")
        return value.split(b"\0", 1)[0].decode("ascii")
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError("Truncated Mach-O load command")
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or size % 8 or offset + size > end:
            raise ValueError("Invalid Mach-O load command size")
        if command in {0x8000001C, 0x27}:  # LC_RPATH / LC_DYLD_ENVIRONMENT
            raise ValueError("Release Mach-O contains loader search paths or environment")
        if command in {0xC, 0x80000018, 0x8000001F, 0x80000023, 0x20}:
            if size < 24:
                raise ValueError("Truncated Mach-O dylib command")
            name = command_string(offset, size, 8)
            if name not in SYSTEM_DYLIBS:
                raise ValueError("Release Mach-O requires a non-system dependency")
            libraries.add(name)
        elif command in {0xD, 0xF}:
            raise ValueError("Release Mach-O declares a dylib or loader identity")
        elif command == 0xE:  # LC_LOAD_DYLINKER
            if size < 16 or loader or command_string(offset, size, 8) != "/usr/lib/dyld":
                raise ValueError("Invalid Mach-O system loader")
            loader = True
        elif command in {0x32, 0x24}:  # LC_BUILD_VERSION / LC_VERSION_MIN_MACOSX
            if minimum is not None:
                raise ValueError("Duplicate Mach-O deployment version")
            if command == 0x32:
                if size < 24:
                    raise ValueError("Truncated Mach-O build version")
                platform_id, minos, sdkos, tools = struct.unpack_from("<4I", data, offset + 8)
                if platform_id != 1 or size != 24 + tools * 8:
                    raise ValueError("Wrong Mach-O platform or build version size")
            else:
                if size != 16:
                    raise ValueError("Invalid Mach-O minimum-version command")
                minos, sdkos = struct.unpack_from("<II", data, offset + 8)
            minimum, sdk = version_tuple(minos), version_tuple(sdkos)
        elif command == 0x80000028:  # LC_MAIN
            if size != 24 or entry:
                raise ValueError("Invalid Mach-O entry point")
            entry_offset = struct.unpack_from("<Q", data, offset + 8)[0]
            if not 0 < entry_offset < len(data):
                raise ValueError("Mach-O entry point is outside the executable")
            entry = True
        elif command == 0x19:  # LC_SEGMENT_64
            if size < 72:
                raise ValueError("Truncated Mach-O segment")
            segment = data[offset + 8:offset + 24].split(b"\0", 1)[0]
            file_offset, file_size = struct.unpack_from("<QQ", data, offset + 40)
            sections = struct.unpack_from("<I", data, offset + 64)[0]
            if size != 72 + sections * 80 or file_offset + file_size > len(data):
                raise ValueError("Invalid Mach-O segment bounds")
            if segment == b"__DWARF":
                raise ValueError("Release Mach-O still contains debug information")
            for index in range(sections):
                name = data[offset + 72 + index * 80:offset + 88 + index * 80].split(b"\0", 1)[0]
                if name.startswith((b"__debug", b"__zdebug")):
                    raise ValueError("Release Mach-O still contains debug information")
        elif command == 0x2:  # LC_SYMTAB: undefined imports are valid; STABS are not.
            if size != 24:
                raise ValueError("Invalid Mach-O symbol table")
            symbols, number, strings, string_size = struct.unpack_from("<4I", data, offset + 8)
            if symbols + number * 16 > len(data) or strings + string_size > len(data):
                raise ValueError("Invalid Mach-O symbol/string bounds")
            for index in range(number):
                if data[symbols + index * 16 + 4] & 0xE0:
                    raise ValueError("Release Mach-O still contains debug symbols")
        offset += size
    if offset != end or not entry or not loader or "/usr/lib/libSystem.B.dylib" not in libraries:
        raise ValueError("Incomplete Mach-O executable load commands")
    if minimum != MACOS_MINIMUM or sdk is None or sdk < minimum:
        raise ValueError("Release Mach-O deployment minimum or SDK differs from the contract")
    reject_private_paths(data)
    return {"arch": arch, "os": "macos", "format": "Mach-O64", "static": False,
            "stripped": True, "cpuBaseline": True, "minimumOS": ".".join(map(str, minimum)),
            "sdkVersion": ".".join(map(str, sdk)), "systemLibraries": sorted(libraries),
            "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


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
    parser.add_argument("--os", dest="os_name", choices=("linux", "macos"), default="linux")
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
        print(json.dumps(verify_binary(args.check_binary, args.arch, args.os_name)))
        return
    if args.os_name == "macos" and not is_native(args.arch, "macos"):
        raise ValueError("Build macOS release assets on a matching native Mac with Xcode Command Line Tools")
    files = tracked_files()
    actual_zig = subprocess.check_output(["zig", "version"], text=True).strip()
    if actual_zig != zig_version:
        raise ValueError(f"Use Zig {zig_version}; found {actual_zig}")
    prefix = ROOT / (".verification-release-" + ("macos-" if args.os_name == "macos" else "") + args.arch)
    targets = MACOS_TARGETS if args.os_name == "macos" else TARGETS
    subprocess.run(["zig", "build", "-Dtarget=" + targets[args.arch][0], "-Dcpu=baseline",
                    "-Doptimize=safe", "-Dstrip=true", "--prefix", str(prefix)], cwd=ROOT, check=True)
    binary = prefix / "bin/omagma"
    report = verify_binary(binary, args.arch, args.os_name)
    if is_native(args.arch, args.os_name):
        actual_version = subprocess.check_output([str(binary), "--version"], text=True, timeout=5).strip()
        if actual_version != "omagma " + version:
            raise ValueError("Binary version differs from build.zig.zon")
        info = json.loads(subprocess.check_output([str(binary), "build-info"], text=True, timeout=5))
        if info != {"version": version, "zigVersion": zig_version, "optimizeMode": "safe"}:
            raise ValueError("Binary compiler or optimization differs from the release contract")
        report["buildInfo"] = info
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    raw_name, bundle_name, checksum_name = artifact_names(version, args.arch, args.os_name)
    raw = output / raw_name
    shutil.copyfile(binary, raw)
    raw.chmod(0o755)
    bundle = output / bundle_name
    make_bundle(bundle, binary, files, version)
    (output / "LICENSES.txt").write_bytes(distribution_licenses())
    checksums = "".join(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + path.name + "\n" for path in (raw, bundle))
    (output / checksum_name).write_text(checksums)
    print(json.dumps({"version": version, "zig": zig_version, "os": args.os_name, "bundle": bundle.name, "binary": report}, indent=2))


if __name__ == "__main__":
    main()
