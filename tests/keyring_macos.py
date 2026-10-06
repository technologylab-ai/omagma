#!/usr/bin/env python3
"""Native private-Keychain, upgrade and positive-acknowledgement qualification.

Never reads the login keychain. Every item belongs to an owned temporary keychain
with a fictional account; only the stable Apple security executable reads data.
"""
from __future__ import annotations
import argparse
import ctypes
import json
import hashlib
import os
import shutil
from pathlib import Path
import subprocess
import platform
import sys
import tempfile
import time
from terminal_integration import require


def security_windows():
    """Read window IDs only; no screenshot, input, accessibility or user text."""
    cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    ptr = ctypes.c_void_p
    cf.CFStringCreateWithCString.argtypes = [ptr, ctypes.c_char_p, ctypes.c_uint32]
    cf.CFStringCreateWithCString.restype = ptr
    cf.CFArrayGetCount.argtypes = [ptr]; cf.CFArrayGetCount.restype = ctypes.c_long
    cf.CFArrayGetValueAtIndex.argtypes = [ptr, ctypes.c_long]; cf.CFArrayGetValueAtIndex.restype = ptr
    cf.CFDictionaryGetValue.argtypes = [ptr, ptr]; cf.CFDictionaryGetValue.restype = ptr
    cf.CFStringGetCString.argtypes = [ptr, ctypes.c_void_p, ctypes.c_long, ctypes.c_uint32]
    cf.CFNumberGetValue.argtypes = [ptr, ctypes.c_int, ctypes.c_void_p]
    cf.CFRelease.argtypes = [ptr]
    cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    cg.CGWindowListCopyWindowInfo.restype = ptr
    owner_key = cf.CFStringCreateWithCString(None, b'kCGWindowOwnerName', 0x08000100)
    number_key = cf.CFStringCreateWithCString(None, b'kCGWindowNumber', 0x08000100)
    windows = cg.CGWindowListCopyWindowInfo(17, 0)
    require(windows is not None, 'native window list unavailable for no-dialog gate')
    result = set()
    try:
        for index in range(cf.CFArrayGetCount(windows)):
            row = cf.CFArrayGetValueAtIndex(windows, index)
            owner = cf.CFDictionaryGetValue(row, owner_key)
            number = cf.CFDictionaryGetValue(row, number_key)
            if not owner or not number:
                continue
            buffer = ctypes.create_string_buffer(256)
            if not cf.CFStringGetCString(owner, buffer, len(buffer), 0x08000100):
                continue
            if buffer.value.lower() not in {b'securityagent', b'security', b'authorizationhost', b'coreservicesuiagent'}:
                continue
            value = ctypes.c_int64()
            require(cf.CFNumberGetValue(number, 4, ctypes.byref(value)) != 0, 'invalid native window ID')
            result.add(value.value)
    finally:
        cf.CFRelease(windows); cf.CFRelease(owner_key); cf.CFRelease(number_key)
    return result


def run(binary, *arguments, success=True):
    started = time.monotonic()
    result = subprocess.run([str(binary), *arguments], stdin=subprocess.DEVNULL,
                            capture_output=True, timeout=15)
    require(time.monotonic() - started < 15, 'keychain operation exceeded parent deadline')
    if success:
        require(result.returncode == 0 and not result.stderr, 'native Keychain positive acknowledgement failed: ' + result.stderr.decode(errors='replace')[-800:])
        if result.stdout:
            value = json.loads(result.stdout)
            require(set(value) == {'ok', 'probe', 'childPeakRssBytes'} and value['ok'] is True and value['probe'] == 'probe-keyring', 'native keychain leaked output')
    else:
        require(result.returncode != 0 and not result.stdout, 'failed native worker was masked as successful absence')
    return result


def upgrade_case(binary, upgraded):
    require(hashlib.sha256(binary.read_bytes()).digest() != hashlib.sha256(upgraded.read_bytes()).digest(),
            'upgrade witness needs distinct creator/upgraded binary images')
    with tempfile.TemporaryDirectory(prefix='omagma-keychain-upgrade-', dir='/tmp') as temporary:
        directory = Path(temporary); directory.chmod(0o700)
        created = False
        try:
            run(binary, 'probe-keyring-upgrade', 'create', str(directory)); created = True
            run(upgraded, 'probe-keyring-upgrade', 'check', str(directory))
            run(binary, 'probe-keyring-upgrade', 'verify', str(directory))
            run(upgraded, 'probe-keyring-upgrade', 'clear', str(directory))
            run(binary, 'probe-keyring-upgrade', 'absent', str(directory))
            # A missing private keychain must surface failure, not exit0 absence.
            run(upgraded, 'probe-keyring-upgrade', 'check', str(directory / 'absent'), success=False)
        finally:
            if created:
                run(upgraded, 'probe-keyring-upgrade', 'delete', str(directory))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--upgrade-binary', required=True, type=Path)
    parser.add_argument('--homebrew-resign', action='store_true', help='verify exact Homebrew re-signing while preserving each executable name')
    args = parser.parse_args()
    require(sys.platform == 'darwin', 'native Keychain qualification requires macOS')
    binary, upgraded = args.binary.resolve(), args.upgrade_binary.resolve()
    before = security_windows()
    before_search = subprocess.check_output(['/usr/bin/security', 'list-keychains', '-d', 'user'], timeout=5)
    raw_name = 'omagma-macos-' + {'arm64': 'arm64', 'x86_64': 'x86_64'}[platform.machine()]
    with tempfile.TemporaryDirectory(prefix='omagma-keychain-alias-', dir='/tmp') as temporary:
        aliases = Path(temporary)
        raw_alias = aliases / raw_name
        shutil.copy2(upgraded, raw_alias)
        require(raw_alias.read_bytes() == upgraded.read_bytes(), 'public raw alias changed binary bytes')
        # Exercise the caller's actual artifact and a byte-identical public raw
        # filename. A successful bin/omagma check cannot qualify a renamed raw.
        for index, candidate in enumerate((upgraded, raw_alias)):
            if args.homebrew_resign:
                signed_directory = aliases / f'signed-{index}'
                signed_directory.mkdir(mode=0o700)
                copied = signed_directory / candidate.name
                shutil.copy2(candidate, copied)
                subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(copied)],
                               check=True, capture_output=True, timeout=10)
                candidate = copied
            upgrade_case(binary, candidate)
    run(binary, 'probe-keyring')
    run(upgraded, 'probe-keyring')
    for executable in (binary, upgraded):
        # The hidden worker cannot be called directly as a token API.
        result = subprocess.run([str(executable), 'keychain-worker', 'lookup', 'bar',
                                 'synthetic-probe-do-not-use@example.invalid', '', ''],
                                input=b'OMAGMA-KEYCHAIN1\n', capture_output=True, timeout=5)
        require(result.returncode != 0 and not result.stdout and b'PrivateKeychainParentRequired' in result.stderr,
                'direct worker bypassed parent/private-pipe guard')
    require(subprocess.check_output(['/usr/bin/security', 'list-keychains', '-d', 'user'], timeout=5) == before_search, 'synthetic probe changed user keychain search list')
    require(not (security_windows() - before), 'Keychain operation mapped a security/unlock dialog')
    print('PASS macOS Keychain:positive ACK, isolated account/client/grant,4096-byte boundary, Debug→Safe/public-raw alias upgrade/update/clear, locked refusal/no new dialog, parent guard, cleanup')


if __name__ == '__main__':
    main()
