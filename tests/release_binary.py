#!/usr/bin/env python3
"""Literal ELF/Mach-O packaging oracles; no compiler, provider or desktop needed."""
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from release import artifact_names, is_native, verify_binary


def aligned_command(command, fields, string=b""):
    body = fields + string
    size = (8 + len(body) + 7) & ~7
    return struct.pack("<II", command, size) + body + b"\0" * (size - 8 - len(body))


def macho(cpu=0x0100000C, subtype=0, minimum=0x000D0000, platform=1,
          libraries=(b"/usr/lib/libSystem.B.dylib",), extra=(), flags=0x200000,
          payload=b"\0" * 64):
    commands = [aligned_command(0xE, struct.pack("<I", 12), b"/usr/lib/dyld\0"),
                struct.pack("<6I", 0x32, 24, platform, minimum, 0x001B0000, 0)]
    for name in libraries:
        commands.append(aligned_command(0xC, struct.pack("<4I", 24, 0, 0x10000, 0x10000), name + b"\0"))
    commands.extend(extra)
    entry = 32 + sum(map(len, commands)) + 24
    commands.append(struct.pack("<IIQQ", 0x80000028, 24, entry, 0))
    command_bytes = b"".join(commands)
    # Independently written Mach-O constants/layout; neither writer nor
    # expectations are derived from release.py's target/version tables.
    return struct.pack("<8I", 0xFEEDFACF, cpu, subtype, 2, len(commands), len(command_bytes), flags, 0) + command_bytes + payload


def elf(machine=62, program=None):
    data = bytearray(64)
    data[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HH", data, 16, 2, machine)
    struct.pack_into("<QQ", data, 32, 64, 0)
    struct.pack_into("<5H", data, 54, 56, 1 if program else 0, 64, 0, 0)
    if program:
        data += struct.pack("<IIQQQQQQ", program, 4, 120, 0, 0, 16, 16, 8)
        data += struct.pack("<qQ", 1, 1)
    return bytes(data)


class ReleaseBinary(unittest.TestCase):
    def verify(self, data, arch="arm64", os_name="macos"):
        with tempfile.TemporaryDirectory(prefix="omagma-release-format-") as directory:
            path = Path(directory) / "synthetic-binary"
            path.write_bytes(data)
            return verify_binary(path, arch, os_name)

    def test_native_baseline_deployment_metadata(self):
        arm = self.verify(macho())
        self.assertEqual(arm["minimumOS"], "13.0.0")
        self.assertEqual(arm["sdkVersion"], "27.0.0")
        self.assertFalse(arm["static"])
        self.assertTrue(arm["cpuBaseline"])
        intel = self.verify(macho(cpu=0x01000007, subtype=3), "x86_64")
        self.assertEqual(intel["arch"], "x86_64")

    def test_wrong_arch_subtype_platform_minimum_and_pie_rejected(self):
        for data in (macho(cpu=0x01000007, subtype=3), macho(subtype=2),
                     macho(platform=2), macho(minimum=0x000C0000), macho(flags=0)):
            with self.subTest(data=data[:32]), self.assertRaises(ValueError):
                self.verify(data)
        with self.assertRaises(ValueError):
            self.verify(macho(cpu=0x01000007, subtype=8), "x86_64")

    def test_system_dependency_only_and_no_loader_search_environment(self):
        libraries = (b"/usr/lib/libSystem.B.dylib",
                     b"/System/Library/Frameworks/Security.framework/Versions/A/Security",
                     b"/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
                     b"/usr/lib/libobjc.A.dylib")
        self.assertEqual(len(self.verify(macho(libraries=libraries))["systemLibraries"]), 4)
        for name in (b"@rpath/libfoo.dylib", b"/opt/homebrew/lib/libfoo.dylib",
                     b"/usr/local/lib/libfoo.dylib", b"/usr/lib/libUnreviewed.dylib", b"/usr/lib/libproc.dylib"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.verify(macho(libraries=(libraries[0], name)))
        for command in (0x8000001C, 0x27):
            with self.subTest(command=command), self.assertRaises(ValueError):
                self.verify(macho(extra=(aligned_command(command, struct.pack("<I", 12), b"/tmp/route\0"),)))

    def test_debug_segment_and_private_paths_rejected(self):
        debug = struct.pack("<II16sQQQQ4I", 0x19, 72, b"__DWARF", 0, 0, 0, 0, 0, 0, 0, 0)
        with self.assertRaises(ValueError):
            self.verify(macho(extra=(debug,)))
        # Keep the independently chosen malformed bytes, but do not put a
        # contiguous private-looking absolute path in the public source tree.
        for path in (b"/" + b"Users/" + b"build-user/work/src/main.zig",
                     b"/" + b"home/" + b"build-user/project/",
                     b"/" + b"tmp/" + b"omagma-macos-build/src/main.zig",
                     b"/" + b"private/" + b"var/folders/ab/build/"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.verify(macho(payload=path))
        self.assertEqual(self.verify(macho(payload=b"/tmp/omagma-keychain-probe-{s}\0"))["minimumOS"], "13.0.0")

    def test_truncated_inconsistent_and_fat_binaries_rejected(self):
        original = macho()
        malformed = bytearray(original)
        struct.pack_into("<I", malformed, 20, 8)  # sizeofcmds cannot fit ncmds.
        bad_size = bytearray(original)
        struct.pack_into("<I", bad_size, 36, 9)  # 64-bit commands must be aligned.
        for data in (b"\xca\xfe\xba\xbe" + original, original[:40], malformed, bad_size):
            with self.subTest(length=len(data)), self.assertRaises(ValueError):
                self.verify(data)

    def test_linux_contract_and_dynamic_rejection_unchanged(self):
        self.assertTrue(self.verify(elf(), "x86_64", "linux")["static"])
        self.assertTrue(self.verify(elf(machine=183), "arm64", "linux")["stripped"])
        for data in (elf(machine=183), elf(program=3), elf(program=2)):
            with self.assertRaises(ValueError):
                self.verify(data, "x86_64", "linux")
        self.assertEqual(artifact_names("0.2.4", "arm64"),
                         ("omagma-linux-arm64", "omagma-0.2.4-linux-arm64.tar.gz", "SHA256SUMS-arm64"))
        self.assertEqual(artifact_names("0.2.4", "arm64", "macos"),
                         ("omagma-macos-arm64", "omagma-0.2.4-macos-arm64.tar.gz", "SHA256SUMS-macos-arm64"))

    def test_architecture_match_alone_cannot_run_foreign_os_binary(self):
        with patch("release.platform.machine", return_value="arm64"), patch("release.platform.system", return_value="Linux"):
            self.assertTrue(is_native("arm64"))
            self.assertFalse(is_native("arm64", "macos"))
        with patch("release.platform.machine", return_value="x86_64"), patch("release.platform.system", return_value="Darwin"):
            self.assertTrue(is_native("x86_64", "macos"))
            self.assertFalse(is_native("x86_64"))


if __name__ == "__main__":
    unittest.main()
