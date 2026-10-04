# omagma

A small Gmail dropdown for the Omarchy bar. Check recent Inbox messages from up to three separate accounts, then open Gmail in each account’s configured Chrome profile.

![omagma showing fictional accounts and messages](docs/images/omagma.png)

Each account keeps its own unread count and message list. The dropdown shows read and unread messages with sender, subject, time and a plain-text snippet. It keeps the selected account between openings and distinguishes loading, cached data, disconnected accounts and a verified empty Inbox.

The backend is Zig; the UI is Quickshell QML. Mail stays in a bounded memory cache of at most 30 messages per account. There is no local mail database. Background refresh is optional: the default is manual refresh, and `refreshIntervalSeconds: 300` enables a five-minute interval even while the dropdown is closed.

## Build and setup

Requires **Zig 0.16.0 exactly**, Omarchy with its Quickshell plugin host, Google Chrome, and an unlocked Secret Service keyring with `secret-tool`. Python 3 and Node.js are used for development tests.

```sh
zig build -Doptimize=ReleaseSafe
```

Start with [account and OAuth setup](docs/SETUP.md), then [add the bar widget](docs/INSTALL.md). The plugin ID is `io.github.technologylab_ai.omagma`. This release uses your own Google Desktop OAuth client; connect accounts with the CLI. There is no Connect action in the dropdown yet.

To have an agent install it, point the agent at this repository and say **“Install omagma on my Omarchy.”** [AGENTS.md](AGENTS.md) routes installation requests to the [setup workflow](skills/omagma-setup/SKILL.md), including account configuration and browser consent. No separate skill installation is needed. The [agent setup guide](docs/AGENT-SETUP.md) also explains optional skill discovery.

For a synthetic test without Gmail, credentials or desktop installation:

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

MIT licensed. Copyright technologylab.ai.
