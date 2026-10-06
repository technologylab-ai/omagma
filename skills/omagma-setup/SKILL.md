---
name: omagma-setup
description: Install the omagma Omarchy plugin or terminal client, connect separate Gmail accounts and Chrome profiles, and enable TUI/CLI permissions or reconnect accounts. Use for user installation and onboarding, not development or general Gmail administration.
---

# Set up omagma

Start from the user's website or GitHub URL. Fetch the installation section of
[AGENTS.md](https://github.com/technologylab-ai/omagma/blob/main/AGENTS.md),
[README.md](https://github.com/technologylab-ai/omagma/blob/main/README.md)
and this setup workflow through their public URLs when local files are absent.
Resolve relative guide links against the public repository or documentation URL.
Download and verify the selected release yourself, then use its extracted
`omagma/` folder as the local root. The user does not need to clone the repository
or prepare a folder before starting. If the user already supplied a local
bundle or checkout, resolve the skill's real directory and use that root. Use `docs/INSTALL.md` for the bar, `docs/SETUP.md` for accounts,
and `docs/SETUP.md#full-tuicli-permissions` for TUI/CLI permissions. Development and
release qualification have their own instructions in `AGENTS.md`.

## Install

- Prefer the matching Linux x86_64 or arm64 bundle from
  `https://github.com/technologylab-ai/omagma/releases/latest`. Verify its entry
  in the same release's `SHA256SUMS`, extract into a persistent versioned
  directory, and check the included `zig-out/bin/omagma --version`. A complete
  bundle includes the bar UI, assets and docs; a raw backend suffices for
  terminal-only use with its accompanying license notices.
- Release installation needs no Zig compiler. Check the requested interface's
  dependencies: Omarchy/Quickshell for the bar; a UTF-8 terminal for the TUI;
  Secret Service/`secret-tool`, CA certificates and Chrome for live Gmail.
- If a matching release is unavailable, use the source-build instructions in
  [DEVELOPMENT.md](../../docs/DEVELOPMENT.md#build-from-source) and the exact
  compiler pin in `build.zig.zon`. Select that
  compiler through task-local `PATH`, keep the system compiler unchanged,
  build `safe`, and check the resulting executable's version.
- For a requested bar installation, inspect the existing user plugin and bar
  entry before updating them. Back up affected settings, preserve unrelated
  desktop configuration, and use the included plugin directory. Follow local
  desktop instructions; never edit package-owned Omarchy files.
- For terminal-only setup, put the verified backend on the user's PATH using
  `docs/INSTALL.md#optional-terminal-command`. Inspect an existing `omagma`
  command before changing it.

## Configure accounts

- Reuse the user's existing choices and private config. Ask only for missing
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
  use `docs/TERMINAL-BACKGROUND.md` when requested.

## Connect the requested permissions

`docs/SETUP.md` has both permission sets and Console steps. The bar uses
`gmail.readonly`. Full TUI/CLI features use a **different Google OAuth registration
in the same project**, with Gmail API and People API enabled.

Recommend agent-guided Google setup. Give one small Console step at a time,
wait for the user's feedback, then adapt the next step to their screen. Reuse
an existing project, audience and branding when available. Prepare independent
local work while the user completes Google steps; the user approves consent.
Keep the detailed Console procedure in `docs/SETUP.md`.

For all currently implemented terminal features, request
`mail-read,mail-send,mail-modify,contacts-read,contacts-write,calendar-rsvp`.
The backend maps these six local capabilities to only `gmail.modify` and
`contacts`. Keep the original bar registration/config entry. Create a new
Google OAuth registration for terminal permissions; copying or renaming an
existing registration JSON does not create another registration. TUI and CLI
share the terminal grant.

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

Check authorization status and show the user real mail for each requested
account. Check requested contacts access with a read, too. Use reads for setup
verification; a test send or contact/mail mutation needs its own user request.
Have them open a message/Inbox link to confirm its Chrome profile.
Explain any browser click in advance and keep the verification brief. Restart
an already open TUI after its grant changes; refresh or restart a disconnected
bar service after onboarding.

Summarize the launch command/bar action, account/profile mapping, permissions,
background behavior and reconnection command. Keep credentials and real mail
out of public artifacts. Installation does not imply permission to send mail
or edit contacts; those actions require the user's own request or explicit
interaction. UI conveniences and CLI coverage are in
`docs/AGENT-CLI.md#cli-and-tui-coverage`.
