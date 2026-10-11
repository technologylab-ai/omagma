# Omagma on macOS

The experimental TUI and agent CLI run natively on Apple Silicon and Intel Macs.
The bar widget remains a Linux Omarchy integration. Mac terminal use needs no
Omarchy, Quickshell, tmux, Python runtime or Zig compiler.

## Choose Interactive or Agent-enabled setup

For first-time Mac onboarding, choose the variant before connecting accounts.
An agent starting from the repository URL should ask you this once and preserve
your explicit choice during repairs.

| Variant | Credential storage | Intended use |
| --- | --- | --- |
| **Interactive (default)** | Native Keychain (`credentialStore: "keyring"`) | TUI and CLI in a local unlocked terminal |
| **Agent-enabled** | Private owner-only, **unencrypted token files** (`credentialStore: "file"`) | The same TUI and CLI binary, including agent subprocesses |

Agent-enabled storage avoids Keychain audit-session restrictions. Your agent's
sandbox must still allow access to the selected config, grants, cache and
credential files and Google network access. Choosing the file store does not
automatically grant those permissions.

For a fresh Agent-enabled setup, add these fields to your private account
configuration **before** consent; authorization stores new credentials there
directly. Merge the fields into the existing config rather than replacing it:

```json
{
  "credentialStore": "file",
  "credentialDirectory": "/absolute/private/path/omagma-credentials"
}
```

`credentialDirectory` must be an absolute canonical private directory, with
mode `0700`; token files use `0600`. JSON does not expand `~` or `$HOME`.
Fresh authorization or migration can create the leaf credential directory and
account subdirectories when existing ancestors are safe. Unexpected existing
owners, modes, ACLs or symlinks are refused rather than repaired automatically.
Keep the directory outside Git and shared folders. These files contain grants
that can authorize mailbox/contact access; anyone able to read them can use
that authority. Interactive setup can omit `credentialStore`, which defaults
to `keyring`. See [privacy](PRIVACY.md#credentials-and-consent).

For existing authorized accounts, inspect the selected store and migrate from
a context that can access the source, normally your local unlocked Mac terminal:

```sh
omagma credentials status --json --config /absolute/private/config.json
omagma credentials migrate --to file \
  --directory /absolute/private/path/omagma-credentials \
  --config /absolute/private/config.json
```

Migration uses the existing registration and grants without another Google
sign-in. It verifies private destination copies before atomically switching the
config. For a file target, omitting `--directory` selects `credentials` under
the canonical config directory. Status does not create credential directories.
**Source copies are retained.** Later migrations respect the current store and
grant registry rather than restoring locally revoked credentials from retained
copies. Preserve a custom `--grant-file` when you use one. To switch back, use
`omagma credentials migrate --to keyring` with
the same config/grant options from a context with access to both stores.
Restart open Omagma sessions after switching, then [verify actual agent CLI
access](AGENT-CLI.md#verify-agent-access). Switching back does not remove or
encrypt retained file copies.

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
source checkout. Installing the executable does not create account configuration
or authorize Google access. Before first use, the setup workflow prepares
`~/.config/omagma/config.json` and connects the requested accounts. A
`FileNotFound` error on a fresh `omagma tui` launch can mean that this configuration
has not been created yet.

Homebrew includes the setup guides and skill under
`$(brew --prefix omagma)/share/doc/omagma`. To register the bundled skill with
Codex or Claude Code, follow [optional setup skill](AGENT-SETUP.md#optional-setup-skill).

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

## Accounts and Chrome

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

### Interactive Keychain access

With the default `keyring` store, refresh tokens use the current default user
Keychain, normally your login keychain. Terminal identity includes the account,
Google registration and grant.
A binary upgrade retains those identities. Native checks suppress their own UI
and refuse a known locked keychain. Apple's signed Keychain tool provides stable
reads and a deletion fallback across re-signed upgrades; tokens stay on private
pipes. A lock-state change during handoff or an edited item ACL can still produce
an operating-system permission request. Cancel it to refuse the operation;
blocked helpers are canceled at a finite deadline. Unlock the relevant keychain
explicitly if Omagma reports `KeyringUnavailable`, then retry. See
[privacy and credential handling](PRIVACY.md).

In Keychain Access, select **login** and choose **Unlock Keychain “login”**
if it is locked. Alternatively, run this in Terminal on the Mac and enter the
Keychain password at the hidden prompt, normally your Mac login password:

```sh
security unlock-keychain ~/Library/Keychains/login.keychain-db
```

Do not put that password in a command argument or send it to an agent. A remote
SSH login or agent subprocess can have a different security/audit session and
refuse Keychain access while the desktop sees it as unlocked. An unlocked
interactive TUI does not prove that another context can read the same items.
For Interactive use, unlock and retry in the terminal where you run Omagma.
For agent use, follow the migration route above from a context able to access
the existing Keychain credentials. Neither route requires another Google
sign-in merely to change local credential storage.

When using credentials imported from another computer, macOS may also ask you
to approve the first read of an **Omagma account credential** by its signed
`security` tool. Approve that specific item locally if you want to use it.
This Keychain approval is separate from Google consent and does not require
reauthorizing the Gmail account.

Follow [account setup](SETUP.md) for Google Console, per-account consent and
reconnection. Agent-enabled setup verifies status and real mail/contact reads
through CLI subprocesses in the intended agent context after consent or
migration. Installation needs no test send, contact edit, fixture suite or GUI
qualification.

## Upgrade, remove and background fetching

The TUI checks for releases daily and opens a guide from **Upgrade available**
or `:updates`. Homebrew notices wait for the tap's package and respect pinned
installs. Save work and close Omagma before upgrading, then verify the version
and reopen. [Updates](UPDATES.md) covers dismissal, manual checks and the CLI.

```sh
brew update
brew upgrade renerocksai/tap/omagma
omagma --version
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
