# omagma

Gmail in the Omarchy bar, your terminal, and agent workflows. Check recent Inbox messages from up to three separate accounts, then open Gmail in each account’s configured Chrome profile.

![omagma showing fictional accounts and messages](docs/images/omagma.png)

Each account keeps its own unread count and message list. The dropdown shows read and unread messages with sender, subject, time and a plain-text snippet. It keeps the selected account between openings and distinguishes loading, cached data, disconnected accounts and a verified empty Inbox.

The backend is Zig; the bar UI is Quickshell QML. Bar mail stays in a bounded memory cache of at most 30 messages per account. The bar does not persist mail. Background refresh is optional: the default is manual refresh, and `refreshIntervalSeconds: 300` enables a five-minute interval even while the dropdown is closed.

Omagma started because a single Gmail tab was using roughly **2 GB of RAM** on the author's desktop. Omagma's backend and UI together measured approximately **31 MB for three connected accounts** in v0.2.2 on Linux x86_64. This includes the backend and Omagma's attributed UI share; Chrome and unrelated shell widgets are excluded. These observations are not a controlled browser benchmark. See [memory measurements](docs/MEMORY.md) for the accounting and version details.

## Install

[Download the latest release](https://github.com/technologylab-ai/omagma/releases/latest). Choose the complete Linux **x86_64** or **arm64** plugin bundle and verify it with the release’s `SHA256SUMS`. The bundle includes the UI and a static musl backend; **Zig is not needed to install it**.

Requires Omarchy with its Quickshell plugin host, Google Chrome, an unlocked Secret Service keyring with `secret-tool`, and system CA certificates. Static linking applies to the backend; these desktop services are still required. The ARM backend has its own build/test checks; ARM desktop integration is not claimed as tested.

Follow [bundle verification and bar installation](docs/INSTALL.md), then [account and OAuth setup](docs/SETUP.md). The plugin ID is `io.github.technologylab_ai.omagma`. This release uses your own Google Desktop OAuth client; connect accounts with the included CLI. There is no Connect action in the dropdown yet.

To have an agent install it, point the agent at this repository and say **“Install omagma on my Omarchy.”** [AGENTS.md](AGENTS.md) routes installation requests to the [setup workflow](skills/omagma-setup/SKILL.md), including account configuration and browser consent. No separate skill installation is needed. The [agent setup guide](docs/AGENT-SETUP.md) also explains optional skill discovery.

## Terminal and agent client

**The TUI and CLI are experimental.** Use fixtures to explore write workflows, and review permissions and recovery behavior before using a live account. The existing read-only bar remains separate.

`omagma tui` opens a Vim-oriented, account-separated mail client: complete messages and threads, search and pagination, local drafts, replies/reply-all, contacts, attachments, archive/Trash/restore, and invitation replies. The split composer keeps the mail context visible; `$EDITOR` temporarily takes over the terminal and returns afterward. **No tmux is required.** Calendar views and permanent deletion are excluded.

Startup shows available disk-cached mail immediately, with a colored fetch status while Gmail updates in the background. Cached mail remains navigable and downloaded bodies remain readable during refresh. The cache keeps the newest messages within a fixed per-account count and byte limit, evicting the oldest tail. See [cache-first startup](docs/TUI-CACHE.md).

Choose a reader beside or below the message list with `v`; Omarchy's current theme supplies the colors. HTML-only mail uses a native formatted text view with headings, emphasis, lists, quotes and readable tables. A supplied plain-text alternative takes precedence; remote images and other resources never load. `/` searches cached metadata immediately, while `\` explicitly searches Gmail. The CLI has the same choice through `--cached` and `--server`. An optional [five-minute user timer](docs/TERMINAL-BACKGROUND.md) keeps the terminal cache ready even when the TUI is closed.

`omagma cli` / `omagma agent` provide a JSONL interface; one-shot `mail`, `draft`, `contacts`, `invitations`, `operation` and `cache` commands use the same executor. Fetch beyond the bar's 30 messages using explicit continuation cursors. The terminal cache defaults to **2,000 message metadata entries and 256 MiB of disk per account**. Terminal heap allocations are capped at 64 MiB, in addition to the existing 16 MiB fixed backend storage reservation. Local v0.2.3 x86_64 synthetic measurements settled around **9 MB for the agent CLI and 12 MB for the TUI**, with workload peaks around **13–15 MB**, using three accounts and 1,000 cycles. A separate 2,000-message stress peaked around **44 MB**. An extreme 2 MiB HTML message settled around **29 MB**, with a **39 MB** process high-water mark. These are whole terminal process measurements; see [memory measurements](docs/MEMORY.md) for workload and accounting. Allocation ceilings are separate from resident memory.

Try the TUI and agent client without Google credentials or desktop installation. Fixture mode enables mock sends, mailbox changes, contacts and RSVP; it never contacts Google:

```sh
omagma tui --fixtures
omagma mail list --fixtures --account personal@example.com --limit 100
omagma cli --fixtures
```

Use [the terminal guide](docs/TERMINAL.md) for keys, commands and capabilities, or give your agent [the CLI contract](docs/AGENT-CLI.md). Existing bar credentials allow read-only mail access. Sending, changing mail, contacts and RSVP require **separate terminal authorization**; the bar keeps its read-only grant. Write workflows are qualified with synthetic fixtures. Initial live write acceptance requires an explicitly provided dedicated test mailbox; development authorization does not permit production writes.

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
- [Memory measurements](docs/MEMORY.md), [terminal qualification](docs/evidence/terminal-0.2.0.md), [HTML-reader checkpoint](docs/evidence/terminal-0.2.3.md), [cache-first qualification](docs/evidence/terminal-0.2.2.md), [incoming-header patch qualification](docs/evidence/terminal-0.2.1.md), [Zig 0.17 qualification](docs/evidence/zig-0.17.0.md) and [historical Zig 0.16 evidence](EVIDENCE.md)
- [Distribution](docs/DISTRIBUTION.md) and [compiler findings for wiki review](docs/ZIG017-WIKI-FOLLOWUP.md)
- [Building and publishing releases](docs/RELEASING.md)
- Social images: [Inbox view](docs/images/omagma-social.png) · [Mail preview and emoji](docs/images/omagma-social-preview.png)

MIT licensed. Copyright technologylab.ai. Static distributions include [third-party notices](LICENSES), including Zig, musl, libvaxis, zigimg and uucode.
