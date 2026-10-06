# Native macOS terminal client

Omagma's experimental CLI and TUI run natively on macOS. The Omarchy bar remains
a Linux desktop integration. The terminal uses the same separate accounts,
bounded cache, local drafts, attachment limits and operation receipts as Linux.
See [terminal mail](TERMINAL.md) and the [agent CLI](AGENT-CLI.md).

## Build and try it

Source builds need Xcode Command Line Tools and **Zig 0.17.0 exactly**. Download
the official archive matching the Mac's CPU from [Zig downloads](https://ziglang.org/download/),
verify its SHA256 or signature, prepend its extracted directory to this shell's
`PATH`, and check `zig version`. Keep the system compiler unchanged.

```sh
zig version
zig build -Doptimize=safe -j2
zig-out/bin/omagma --version
zig-out/bin/omagma tui --fixtures
```

The fixture preview uses fictional mail and contacts without Google access.
The resulting binary uses macOS system libc, Security and CoreFoundation; it
does not require Quickshell, Omarchy, tmux or a Python runtime for ordinary use.
Binary packaging and a Homebrew formula are separate follow-up work.

## Connect your account

Follow [Google account setup](SETUP.md) and
[full terminal permissions](SETUP.md#full-tuicli-permissions). The Google OAuth
registration is the same kind used on Linux; select **Desktop app** where the
Console asks for the application type. Consent happens in the configured Chrome
profile. Each account has its own terminal grant and credential identity.

Default Chrome locations are `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`
and `$HOME/Library/Application Support/Google/Chrome`. Override `chrome` and
`chromeUserData` in your private configuration if your installation differs.
Configure the actual profile directory for each account; display labels are not
profile directory names. Keep the account configuration, registration JSON and
cache outside Git.

Native Keychain credentials are stored separately for the read-only bar namespace
and terminal namespace. Terminal identity includes the account, Google client
and grant. Revoking one account does not clear another account or its read-only
credentials. No refresh token is passed through command-line arguments or the
JSONL/UI protocol. A private exec worker contains synchronous Keychain calls so
the parent can enforce its deadline and reap the child.

Keychain access does not display unlock or permission dialogs. Unlock the relevant
keychain explicitly if Omagma reports `KeyringUnavailable`, then retry the
requested operation. Normal mail reads remain read-only; sending, contact edits
and mailbox changes still require the account's explicit capabilities.

`omagma cache-refresh` can run a read-only cache update. The supplied systemd
timer is for Linux; this change does not install a Mac background service.

## Native verification

Developer checks use fictional provider data, owned PTYs and a temporary synthetic
keychain, with no real OAuth/mail/profile changes. Run them under the cooperative
[host reservation](VERIFICATION.md#cooperative-host-measurement-lock):

```sh
zig build test probes -Doptimize=debug -j2
zig build -Doptimize=debug -j2
zig-out/bin/omagma probe-keyring
python3 tests/terminal_macos.py --binary zig-out/bin/omagma
python3 tests/launch_macos.py --binary zig-out/bin/omagma
python3 tests/terminal_integration.py --binary zig-out/bin/omagma --build-mode debug
```

Repeat the appropriate checks with `-Doptimize=safe` and `--build-mode safe`.
The Mac PTY harness keeps its session owner alive until terminal settings have
been verified, then reaps the guardian/editor/TUI. The detached-launch witness
checks literal arguments, an independent session, closed unrelated descriptors,
null standard streams and exec failure without opening any desktop application.

Local qualification covers native Apple Silicon on macOS 26.6.2 with SDK 27.0.
The proposed CI also runs native Apple Silicon and Intel macOS checks plus Linux
static-musl regression checks. Intel runtime results require that CI; a cross
build alone does not establish them. No Mac Omarchy bar, real Google consent,
live send/contact operations or Mac memory baseline is claimed by these fixture
checks. Historical Linux evidence keeps its original platform and version.
