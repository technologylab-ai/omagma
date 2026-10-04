# omagma

A small Gmail dropdown for the Omarchy bar. Check recent Inbox messages from up to three separate accounts, then open Gmail in each account’s configured Chrome profile.

![omagma showing fictional accounts and messages](docs/images/omagma.png)

Each account keeps its own unread count and message list. The dropdown shows read and unread messages with sender, subject, time and a plain-text snippet. It keeps the selected account between openings and distinguishes loading, cached data, disconnected accounts and a verified empty Inbox.

The backend is Zig; the UI is Quickshell QML. Mail stays in a bounded memory cache of at most 30 messages per account. There is no local mail database. Background refresh is optional: the default is manual refresh, and `refreshIntervalSeconds: 300` enables a five-minute interval even while the dropdown is closed.

## Install

[Download the latest release](https://github.com/technologylab-ai/omagma/releases/latest). Choose the complete Linux **x86_64** or **arm64** plugin bundle and verify it with the release’s `SHA256SUMS`. The bundle includes the UI and a static musl backend; **Zig is not needed to install it**.

Requires Omarchy with its Quickshell plugin host, Google Chrome, an unlocked Secret Service keyring with `secret-tool`, and system CA certificates. Static linking applies to the backend; these desktop services are still required. The ARM backend has its own build/test checks; ARM desktop integration is not claimed as tested.

Follow [bundle verification and bar installation](docs/INSTALL.md), then [account and OAuth setup](docs/SETUP.md). The plugin ID is `io.github.technologylab_ai.omagma`. This release uses your own Google Desktop OAuth client; connect accounts with the included CLI. There is no Connect action in the dropdown yet.

To have an agent install it, point the agent at this repository and say **“Install omagma on my Omarchy.”** [AGENTS.md](AGENTS.md) routes installation requests to the [setup workflow](skills/omagma-setup/SKILL.md), including account configuration and browser consent. No separate skill installation is needed. The [agent setup guide](docs/AGENT-SETUP.md) also explains optional skill discovery.

## Build from source

If a compatible release asset is unavailable, build from a source checkout with **Zig 0.16.0 exactly**, the current tested compiler pin:

```sh
zig build -Doptimize=ReleaseSafe
```

Python 3 and Node.js are development tools. For a synthetic test without Gmail, credentials or desktop installation:

```sh
node tests/ui_model.mjs
python3 tests/ui_gui.py --binary zig-out/bin/omagma
```

The UI harness runs offscreen and closes its processes when finished. See [verification](docs/VERIFICATION.md) for backend tests and memory checks.

## Details

- [UI behavior](docs/UI.md) and [background refresh](docs/BACKGROUND-REFRESH.md)
- [Privacy and credentials](docs/PRIVACY.md)
- [Bounded transport](docs/TRANSPORT.md) and [IPC protocol](docs/PROTOCOL.md)
- [Measured evidence](EVIDENCE.md) and [distribution](docs/DISTRIBUTION.md)
- [Building and publishing releases](docs/RELEASING.md)

MIT licensed. Copyright technologylab.ai. Static distributions include [Zig and musl notices](LICENSES).
