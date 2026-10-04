# omagma

A small Gmail dropdown for the Omarchy bar. Check recent Inbox messages from up to three separate accounts, then open Gmail in each account’s configured Chrome profile.

![omagma showing fictional accounts and messages](docs/images/omagma.png)

Each account keeps its own unread count and message list. The dropdown shows read and unread messages with sender, subject, time and a plain-text snippet. It keeps the selected account between openings and distinguishes loading, cached data, disconnected accounts and a verified empty Inbox.

The backend is Zig; the UI is Quickshell QML. Mail stays in a bounded memory cache of at most 30 messages per account. There is no local mail database. Background refresh is optional: the default is manual refresh, and `refreshIntervalSeconds: 300` enables a five-minute interval even while the dropdown is closed.

Omagma started because a single Gmail tab was using roughly **2 GB of RAM** on the author's desktop. Omagma's backend and UI together measured approximately **31 MB for three connected accounts** in v0.1.1 on Linux x86_64. This excludes Chrome and the shared Omarchy shell; it is a measured footprint, not a memory guarantee or a controlled browser benchmark. See [memory measurements](docs/MEMORY.md) for the accounting and version details.

## Install

[Download the latest release](https://github.com/technologylab-ai/omagma/releases/latest). Choose the complete Linux **x86_64** or **arm64** plugin bundle and verify it with the release’s `SHA256SUMS`. The bundle includes the UI and a static musl backend; **Zig is not needed to install it**.

Requires Omarchy with its Quickshell plugin host, Google Chrome, an unlocked Secret Service keyring with `secret-tool`, and system CA certificates. Static linking applies to the backend; these desktop services are still required. The ARM backend has its own build/test checks; ARM desktop integration is not claimed as tested.

Follow [bundle verification and bar installation](docs/INSTALL.md), then [account and OAuth setup](docs/SETUP.md). The plugin ID is `io.github.technologylab_ai.omagma`. This release uses your own Google Desktop OAuth client; connect accounts with the included CLI. There is no Connect action in the dropdown yet.

To have an agent install it, point the agent at this repository and say **“Install omagma on my Omarchy.”** [AGENTS.md](AGENTS.md) routes installation requests to the [setup workflow](skills/omagma-setup/SKILL.md), including account configuration and browser consent. No separate skill installation is needed. The [agent setup guide](docs/AGENT-SETUP.md) also explains optional skill discovery.

## Build from source

If a compatible release asset is unavailable, build from a source checkout with **Zig 0.17.0 exactly**. Omarchy may still ship Zig 0.16.x. Download the exact 0.17.0 archive for your OS and CPU from [the versioned Zig release directory](https://ziglang.org/download/0.17.0/), verify its published checksum/signature, and extract it into a task-owned directory. Keep the system compiler unchanged. Before shared-host builds or runtime tests, follow the [measurement reservation protocol](docs/VERIFICATION.md#cooperative-host-measurement-lock).

```sh
omagma_zig_dir=/absolute/path/to/extracted-zig-0.17.0
export PATH="$omagma_zig_dir:$PATH"
zig version
zig build -Doptimize=safe
```

Confirm `zig version` prints exactly `0.17.0` before building; nested build/test tools must inherit this task's `PATH`. Release bundles still need no compiler.

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
- [Memory measurements](docs/MEMORY.md), [Zig 0.17 qualification](docs/evidence/zig-0.17.0.md) and [historical Zig 0.16 evidence](EVIDENCE.md)
- [Distribution](docs/DISTRIBUTION.md) and [compiler findings for wiki review](docs/ZIG017-WIKI-FOLLOWUP.md)
- [Building and publishing releases](docs/RELEASING.md)
- Social images: [Inbox view](docs/images/omagma-social.png) · [Mail preview and emoji](docs/images/omagma-social-preview.png)

MIT licensed. Copyright technologylab.ai. Static distributions include [Zig and musl notices](LICENSES).
