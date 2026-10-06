#!/usr/bin/env python3
"""Explicit ephemeral CI only: a temporary default Keychain, restored in finally.

Never run this on a user's Mac. No existing Keychain item is read or written.
Application runtime sources/binaries are unchanged; a test Zig entrypoint calls
those same production functions and checks the selected private default path.
"""
from __future__ import annotations
import argparse
import ctypes
import os
import platform
from pathlib import Path
import subprocess
import sys
import tempfile
from terminal_integration import ROOT, require


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ephemeral-default', action='store_true', required=True)
    parser.add_argument('--build-mode', choices=('debug', 'safe'), required=True)
    args = parser.parse_args()
    require(sys.platform == 'darwin' and os.environ.get('CI') == 'true' and os.environ.get('GITHUB_ACTIONS') == 'true'
            and os.environ.get('RUNNER_TEMP'), 'ephemeral GitHub macOS CI plus explicit opt-in required')
    require(subprocess.check_output(['zig', 'version'], text=True).strip() == '0.17.0', 'exact compiler required')
    sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    with tempfile.TemporaryDirectory(prefix='omagma-default-keychain-', dir=os.environ['RUNNER_TEMP']) as temporary:
        directory = Path(temporary); directory.chmod(0o700)
        binary = directory / 'keyring-default-probe'
        target = {'arm64': 'aarch64', 'x86_64': 'x86_64'}[platform.machine()] + '-macos.13.0'
        subprocess.run(['zig', 'build-exe', '-target', target, '-mcpu=baseline', '-O' + args.build_mode, '-lc', '-lproc', '-framework', 'Security', '-framework', 'CoreFoundation',
                        '-F' + sdk + '/System/Library/Frameworks', '-L' + sdk + '/usr/lib', '-femit-bin=' + str(binary),
                        '--dep', 'keyring', '-Mroot=' + str(ROOT / 'tests/probes/keyring_default_macos.zig'),
                        '-target', target, '-mcpu=baseline', '-O' + args.build_mode, '-Mkeyring=' + str(ROOT / 'src/keyring.zig')], check=True, timeout=180)
        library = ctypes.CDLL('/System/Library/Frameworks/Security.framework/Security')
        cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        ptr = ctypes.c_void_p
        library.SecKeychainCopyDefault.argtypes = [ctypes.POINTER(ptr)]
        library.SecKeychainSetDefault.argtypes = [ptr]
        library.SecKeychainCreate.argtypes = [ctypes.c_char_p, ctypes.c_uint32, ctypes.c_char_p, ctypes.c_ubyte, ptr, ctypes.POINTER(ptr)]
        library.SecKeychainDelete.argtypes = [ptr]
        library.SecKeychainSetUserInteractionAllowed.argtypes = [ctypes.c_ubyte]
        cf.CFRelease.argtypes = [ptr]
        require(library.SecKeychainSetUserInteractionAllowed(0) == 0, 'cannot suppress native setup dialogs')
        original, private = ptr(), ptr()
        original_status = library.SecKeychainCopyDefault(ctypes.byref(original))
        require(original_status == 0 and original.value, 'CI runner default Keychain metadata unavailable')
        before_search = subprocess.check_output(['/usr/bin/security', 'list-keychains', '-d', 'user'], timeout=5)
        path = directory / 'fixture.keychain'
        password = b'synthetic-keychain-pass-not-a-user-password'
        selected = False
        try:
            require(library.SecKeychainCreate(os.fsencode(path), len(password), password, 0, None, ctypes.byref(private)) == 0 and private.value,
                    'private CI Keychain creation failed')
            require(library.SecKeychainSetDefault(private) == 0, 'private CI default selection failed')
            selected = True
            result = subprocess.run([str(binary), 'run', str(path)], capture_output=True, timeout=90)
            require(result.returncode == 0 and not result.stderr and result.stdout.startswith(b'PASS production default dispatch:'),
                    'production default dispatch failed: ' + result.stderr.decode(errors='replace')[-600:])
            print(result.stdout.decode().strip())
        finally:
            restore_status = library.SecKeychainSetDefault(original) if selected else 0
            delete_status = library.SecKeychainDelete(private) if private.value else 0
            if private.value:
                cf.CFRelease(private)
            cf.CFRelease(original)
            require(restore_status == 0, 'original default Keychain restoration failed')
            require(delete_status == 0, 'private CI Keychain deletion failed')
        require(subprocess.check_output(['/usr/bin/security', 'list-keychains', '-d', 'user'], timeout=5) == before_search,
                'CI Keychain search list changed')
    print('PASS ephemeral CI default restored/private Keychain deleted;no live credentials')


if __name__ == '__main__':
    main()
