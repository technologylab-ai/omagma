# Omagma on macOS

The experimental TUI and agent CLI run natively on Apple Silicon and Intel Macs.
The bar widget remains a Linux Omarchy integration. Mac terminal use needs no
Omarchy, Quickshell, tmux, Python runtime or Zig compiler.

## Install with Homebrew

Homebrew is the preferred Mac installation:

```sh
brew install renerocksai/tap/omagma
omagma --version
```

If an `omagma` command already exists, inspect it before replacing or upgrading
it. Homebrew verifies its selected release download. Then [connect your Google
accounts](SETUP.md#full-tuicli-permissions), or give your agent the public
[setup URL](AGENT-SETUP.md) and ask it to guide you one step at a time. The agent
fetches the instructions and prepares local files itself; you do not need a
source checkout.

For a fresh terminal-only installation, use one Google OAuth registration,
leave `oauthClientFile` absent or empty, and authorize with `--client-file`.
There is no bar registration or read-only bar setup prerequisite. If you already
have a read-only registration in the configuration, preserve it and use a
different registration for broader terminal permissions.

After the account is connected:

```sh
omagma tui
omagma mail list --account personal@example.com --limit 30
```

Use your configured account in place of the fictional example. Reading does not
mark mail read. Sending or changing mailbox/contact data requires your own
explicit action and the account's requested capabilities.

## Manual release bundle

If Homebrew is unavailable, download `SHA256SUMS` and the matching archive from
[the same latest release](https://github.com/technologylab-ai/omagma/releases/latest):

| `uname -m` | Bundle |
| --- | --- |
| `arm64` | `omagma-VERSION-macos-arm64.tar.gz` |
| `x86_64` | `omagma-VERSION-macos-x86_64.tar.gz` |

`VERSION` is the release number without `v`. Mac binaries target macOS 13.0 and
later and use system libraries. A deployment target is not evidence of testing
on that oldest OS; native test-platform details belong to
[developer qualification](DEVELOPMENT.md#native-macos-checks). The dated Linux
bar memory measurements do not measure the Mac client.

Select only your archive's checksum line: Apple's `shasum` does not support the
Linux `--ignore-missing` option. In the download directory, choose your actual
filename and run:

```sh
omagma_bundle=omagma-VERSION-macos-arm64.tar.gz
awk -v selected="$omagma_bundle" '$2 == selected { print; count++ } END { if (count != 1) exit 1 }' SHA256SUMS > omagma-selected.sha256
shasum -a 256 --check omagma-selected.sha256
```

The selection must succeed and the archive must report `OK`. Stop if either
command fails. Checksums detect corrupt or mismatched downloads; they are not a
separate signature.

Extract into a persistent versioned directory and verify the executable before
consent:

```sh
omagma_release_dir="$HOME/.local/share/omagma/releases/${omagma_bundle%.tar.gz}"
mkdir -p "$omagma_release_dir"
tar -xzf "$omagma_bundle" -C "$omagma_release_dir"
"$omagma_release_dir/omagma/zig-out/bin/omagma" --version
mkdir -p "$HOME/.local/bin"
ln -s "$omagma_release_dir/omagma/zig-out/bin/omagma" "$HOME/.local/bin/omagma"
```

Inspect an existing `omagma` command or symlink before changing it. Ensure
`$HOME/.local/bin` is on PATH or invoke the verified executable by its absolute
path. The archive includes the audited source/docs tree; its Linux QML and
systemd files do not need installing on a Mac. Raw `omagma-macos-arm64` and
`omagma-macos-x86_64` executables are also available with `LICENSES.txt`.

## Accounts, Chrome and Keychain

Private configuration is at `$HOME/.config/omagma/config.json`, or
`$XDG_CONFIG_HOME/omagma/config.json` when set. The terminal cache defaults to
`$HOME/.cache/omagma/terminal`, with `XDG_CACHE_HOME` honored. Use mode `0700`
for directories and `0600` for config and downloaded registration files. Keep
these files outside the release directory and Git; cache and drafts are private
plaintext, not application-encrypted storage.

Omitting `chrome` and `chromeUserData` uses the native defaults:

- Executable: `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`
- Data directory: `$HOME/Library/Application Support/Google/Chrome`

Override them only when your existing Chrome installation differs. Use the
actual named profile directory from `chrome://version`, such as `Profile 1`,
for each account. Display labels are not directory names; `Default` is rejected
to avoid ambiguous routing. Never put unexpanded `$HOME` or `~` inside JSON.

Refresh tokens use the current default user Keychain, normally your login
keychain. Terminal identity includes the account, Google registration and grant.
A binary upgrade retains those identities. Keychain access does not open unlock
or permission dialogs: unlock the relevant keychain explicitly if Omagma
reports `KeyringUnavailable`, then retry. See [privacy and credential handling](PRIVACY.md).

Follow [account setup](SETUP.md) for Google Console, per-account consent and
reconnection. An agent can verify status and real mail/contact reads after
consent; installation needs no test send, contact edit, fixture suite or GUI
qualification.

## Upgrade, remove and background fetching

```sh
brew update
brew upgrade omagma
```

For a manual installation, verify a new versioned bundle first, then update the
existing command symlink. Keep private config, grants, cache and Chrome profiles.
Restart an open TUI after an upgrade or permission change.

`brew uninstall omagma`, or removing the manual executable/symlink, leaves
private configuration, cached mail and credentials intact. Use the documented
[disconnect/revoke actions](PRIVACY.md#disconnect-or-remove) when you also want
to remove credentials; uninstalling is not Google-side revocation.

Mac installation does not create a background service. The supplied five-minute
systemd timer is Linux-only. `omagma cache-refresh` is an explicit read-only
cache update and requires a configured read-only grant even on a terminal-only
installation; this optional background path is separate from interactive full
terminal access. See [background cache](TERMINAL-BACKGROUND.md).

## Source builds

Release/Homebrew installation needs no compiler. Source development requires
Xcode Command Line Tools and exactly Zig 0.17.0 selected on the task's PATH;
[development](DEVELOPMENT.md#build-from-source) explains the native SDK and
baseline targets. Keep developer fixtures and qualification separate from
ordinary account setup.
