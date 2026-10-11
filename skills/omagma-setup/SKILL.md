---
name: omagma-setup
description: Install the omagma Linux Omarchy plugin or Linux/macOS terminal client, connect separate Gmail accounts and Chrome profiles, and enable TUI/CLI permissions or reconnect accounts. Use for user installation and onboarding, not development or general Gmail administration.
---

# Set up omagma

Start from the user's website or GitHub URL. Fetch the installation section of
[AGENTS.md](https://github.com/technologylab-ai/omagma/blob/main/AGENTS.md),
[README.md](https://github.com/technologylab-ai/omagma/blob/main/README.md)
and this setup workflow through their public URLs when local files are absent.
Resolve relative guide links against the public repository or documentation URL.
For a bundle installation, download and verify the selected release yourself,
then use its extracted `omagma/` folder as the local root. Homebrew downloads and
verifies the Mac bundle; its included guides and skill are under
`$(brew --prefix omagma)/share/doc/omagma`. The user does not need to clone the repository
or prepare a folder before starting. If the user already supplied a local
bundle or checkout, resolve the skill's real directory and use that root. Use `docs/INSTALL.md` for the Linux bar, `docs/MACOS.md` for Homebrew/native Mac installation, `docs/SETUP.md` for accounts,
and `docs/SETUP.md#full-tuicli-permissions` for TUI/CLI permissions. Development and
release qualification have their own instructions in `AGENTS.md`.

## Install

- On macOS, prefer `brew install renerocksai/tap/omagma` when Homebrew is available. Check `omagma --version` before consent; inspect an existing installation before upgrading it. If Homebrew is unavailable, download and verify the matching native Mac bundle using `docs/MACOS.md`. Prepare files yourself from the public URL; the user does not need a checkout.
- On Linux, prefer the matching x86_64 or arm64 bundle from
  `https://github.com/technologylab-ai/omagma/releases/latest`. Verify its entry
  in the same release's `SHA256SUMS`, extract into a persistent versioned
  directory, and check the included `zig-out/bin/omagma --version`. A complete
  bundle includes the bar UI, assets and docs; a raw backend suffices for
  terminal-only use with its accompanying license notices.
- Release installation needs no Zig compiler. Check the requested interface's
  dependencies: Omarchy/Quickshell for the bar; a UTF-8 terminal for the TUI;
  Chrome for live Gmail; Secret Service/`secret-tool` on Linux or the default unlocked user Keychain on Mac when using the default `keyring` store. Only the Linux bar requires Omarchy/Quickshell; do not install it for a Mac terminal request.
- If a matching release is unavailable, use the source-build instructions in
  [DEVELOPMENT.md](../../docs/DEVELOPMENT.md#build-from-source) and the exact
  compiler pin in `build.zig.zon`. Select that
  compiler through task-local `PATH`, keep the system compiler unchanged,
  build `safe`, and check the resulting executable's version.
- For a requested bar installation, inspect the existing user plugin and bar
  entry before updating them. Back up affected settings, preserve unrelated
  desktop configuration, and use the included plugin directory. Follow local
  desktop instructions; never edit package-owned Omarchy files.
- A bar installation also links `omagma` into the user's PATH and installs the
  Omagma launcher entry and icon, as described in `docs/INSTALL.md`. Inspect
  existing files first. Offer the optional Super+Shift+E shortcut from
  `docs/INSTALL.md#keyboard-shortcut`, which replaces Omarchy's HEY binding;
  change desktop bindings only after the user agrees.
- For terminal-only setup, put the verified backend on the user's PATH using
  the platform’s installation guide. Inspect an existing `omagma`
  command before changing it.
  On a Linux desktop without Omarchy, create the generic launcher entry from
  `docs/INSTALL.md#other-linux-desktops` only if the user wants one; never
  install the Omarchy `assets/omagma.desktop` there.

## Choose the Mac setup variant

For a new Mac setup, ask which variant the user wants before authorization:

- **Interactive (default):** native Keychain credentials, with TUI/CLI use from
  a local unlocked terminal.
- **Agent-enabled:** the same TUI/CLI executable, with refresh tokens stored in
  private owner-only, **unencrypted files**. This avoids Keychain audit-session
  restrictions for agent subprocesses.

Reuse the user's existing explicit choice during repairs. Inspect their private
config and `omagma credentials status --json`; do not ask again or silently
change the store. Interactive uses `credentialStore: "keyring"` (the default).
Agent-enabled uses `credentialStore: "file"` and `credentialDirectory` set to an
absolute canonical private directory outside Git. Keep the directory mode 0700
and token files 0600; explain that anyone able to read those files can use their
grants. Fresh authorization/migration may create the leaf and account
directories when ancestors are safe; existing unsafe owners, modes, ACLs and
symlinks are refused. Status does not create directories. See
`docs/MACOS.md#choose-interactive-or-agent-enabled-setup`.

For fresh agent-enabled setup, configure the file store before Google consent;
authorization writes directly to that store. For existing grants, use
`omagma credentials migrate --to file --directory /absolute/private/credentials`
with the existing `--config` and, if customized, `--grant-file`. Run migration
from a context able to read the source, normally the user's local unlocked Mac
terminal. It reuses existing grants without another Google sign-in, verifies
private copies before switching the config, and retains source copies. Later
migrations respect the current store/registry and do not restore locally revoked
credentials from retained copies. Omitting `--directory` for a file target uses
the canonical config directory's `credentials` child. Use `--to keyring` to
migrate back. Restart open Omagma sessions after switching.

File storage does not grant sandbox permissions. The intended agent context
still needs access to the selected config, grant registry, cache and credential
files, and network access to Google. Report a denied path or network request
and use the agent's supported permission mechanism; do not instruct the user to
disable the sandbox. Keep tokens out of messages, logs and shared artifacts.

## Configure accounts

- Reuse the user's existing choices and private config. After the Mac variant
  choice, ask only for missing
  account addresses, Chrome profile directories, registration JSON paths and
  background-refresh preference. Configure only requested accounts.
- Store config under `${XDG_CONFIG_HOME:-$HOME/.config}/omagma/config.json`
  unless an explicit existing path is used. Keep the directory 0700 and the
  file 0600. Keep downloaded registration JSON outside Git with file mode 0600.
- Map each account to its existing Chrome profile directory, such as
  `Profile 1`, rather than its display name. `chrome://version` shows the
  profile path. The current build requires distinct named profiles and
  rejects `Default`. Preserve browser data and existing profile settings.
- For the bar, set its `configPath` to the selected config file. Its
  `refreshIntervalSeconds` is 0 or 60..86400; 300 enables five-minute refresh
  while closed. For optional terminal-cache fetching while the TUI is closed,
  use `docs/TERMINAL-BACKGROUND.md` when requested on Linux. Mac installation does not add a background service or use the Linux systemd units.

## Connect the requested permissions

`docs/SETUP.md` has both permission sets and Console steps. The bar uses
`gmail.readonly`. Full TUI/CLI features use a terminal Google OAuth registration
with Gmail API and People API enabled. Fresh terminal-only setup uses one
registration: omit/leave empty the config’s `oauthClientFile` and pass the
terminal JSON through `--client-file`. Do not create a bar setup for this case.
If a read-only registration is already configured, broader terminal access uses
a **different registration in the same project**, preserving its existing grant.

Recommend agent-guided Google setup. Give one small Console step at a time,
wait for the user's feedback, then adapt the next step to their screen. Reuse
an existing project, audience and branding when available. Prepare independent
local work while the user completes Google steps; the user approves consent.
Keep the detailed Console procedure in `docs/SETUP.md`.

For all currently implemented terminal features, request
`mail-read,mail-send,mail-modify,contacts-read,contacts-write,calendar-rsvp`.
The backend maps these six local capabilities to only `gmail.modify` and
`contacts`. Alongside an existing bar, keep the original registration/config
entry and create a different registration for terminal permissions; copying or
renaming its JSON does not create another registration. TUI and CLI share the
terminal grant. Use the guide’s fresh-terminal-only or existing-bar route as appropriate.

Preserve the existing Google audience/publishing choice. For External Testing,
ensure each requested account is a test user. Use current primary Google docs
for policy questions and report actual Workspace/consent errors. A project can
serve multiple organizations, but every account authorizes independently.

Use the verified executable and the existing config path:

```sh
/absolute/path/to/omagma auth --account ACCOUNT --config /private/config.json
/absolute/path/to/omagma terminal-auth authorize --account ACCOUNT \
  --config /private/config.json --client-file /private/terminal-registration.json \
  --capabilities mail-read,mail-send,mail-modify,contacts-read,contacts-write,calendar-rsvp
/absolute/path/to/omagma terminal-auth status --account ACCOUNT --config /private/config.json
```

Choose the bar or terminal authorization command for the user's requested
interface. Run accounts sequentially. Explain which Chrome profile opens,
which Google account to select, and which permissions to approve. For full
access, approve both Gmail and contacts, using Select all if offered; the
consent command has a three-minute deadline. After the
callback page reports success, the user can close it; wait for successful CLI
identity/token verification before declaring the account connected. Close
agent-owned consent tabs when finished, preserving unrelated browser tabs.

## Verify and hand off

Check credential and authorization status and show the user real mail for each
requested account. For agent-enabled setup, run actual CLI subprocesses from
the intended agent context: JSONL `accounts.list`, live `mail.list`, a
`mail.read` using a returned ID when mail exists, and live `contacts.list` when
contacts access was requested. Do not use fixtures or cached-only reads as
evidence of live access. A successful empty mailbox/contact page is valid;
an interactive TUI working in another terminal does not prove agent access.
Follow `docs/AGENT-CLI.md#verify-agent-access` for commands. Keep verification
output private. For Interactive setup, verify reads in the user's local
unlocked terminal and state that agent subprocess access has not been checked.
Use reads for setup verification; a test send or contact/mail mutation needs
its own user request.
Have them open a message/Inbox link to confirm its Chrome profile.
Explain any browser click in advance and keep the verification brief. Restart
an already open TUI after its grant or credential store changes; refresh or restart a disconnected
bar service after onboarding.

Summarize the selected credential variant, launch command/bar action/launcher entry and any shortcut, account/profile mapping, permissions,
background behavior and reconnection command. Keep credentials and real mail
out of public artifacts. Installation does not imply permission to send mail
or edit contacts; those actions require the user's own request or explicit
interaction. UI conveniences and CLI coverage are in
`docs/AGENT-CLI.md#cli-and-tui-coverage`.
