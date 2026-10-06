# Agent instructions

## Installing or configuring omagma

When the user asks to install omagma on their Omarchy desktop, connect Gmail accounts or fix setup, read and follow [the setup workflow](skills/omagma-setup/SKILL.md). This is the installation entry point; it does not require installing the skill into an agent's global skills directory. Prefer a complete matching bundle from [the latest release](https://github.com/technologylab-ai/omagma/releases/latest), verify its `SHA256SUMS` entry and probe the included backend with `--version` before consent. End users do not need Zig. Build from source only if a compatible asset is unavailable, using the declared compiler pin.

Use [agent setup](docs/AGENT-SETUP.md) for the handoff and [account setup](docs/SETUP.md) / [bar installation](docs/INSTALL.md) for details. Prepare installation and private configuration while the user completes Google registration or consent, and tell them exactly when a browser click is needed. Verify the installed binary, authorization status, mail access and profile links for setup. Fixture tests, automated GUI checks and resource/release qualification belong to development tasks. Static backend bundles still need the installed desktop host, Chrome, keyring and system CA certificates.

## Developing omagma

Use Zig **0.17.0 exactly**, the pin in `build.zig.zon`. An Omarchy system compiler may still be 0.16.x: use the official archive matching the task's OS/CPU, prepend its extracted directory to the task's `PATH`, and check `zig version`. Keep the global compiler unchanged so nested tools inherit the correct task-local compiler. Use `-Doptimize=debug` for correctness and `-Doptimize=safe` for release/memory checks.

For local interface iterations, build into a separate development prefix, run focused checks for the changed behavior, and atomically replace the installed executable when the user requests a local update. Keep the application version unchanged. Do not run memory soaks, collect release evidence, or publish a release unless the task calls for qualification or publication. Release qualification remains a separate workflow.

Use `zig build test -Doptimize=debug -Dtest-filter="local UI:"` for the account/help regressions, and `python3 tests/terminal_local_ui.py --binary /path/to/development/omagma` for the corresponding owned-PTY interactions. Omit the filter for full correctness qualification.

All project-authored runtime helpers outside QML/JavaScript must be Zig. Python and Node.js support tests and release packaging, not runtime helpers. Keep the bar's read-only Gmail behavior. Terminal modes may use pinned libvaxis, bounded private persistence and explicitly scoped write capabilities; follow [the terminal implementation](docs/TERMINAL-IMPLEMENTATION.md). [Release instructions](docs/RELEASING.md) describe version-driven Linux musl packaging; changing the package version drives a new release without replacing an existing one.

Preserve the bounded design: at most three configured accounts, 30 rows per account, one network worker, one pending job flag per account, bounded frames and a 64-entry UI request ledger. Replace snapshots instead of appending history. Check generations and the active handshake’s account identities. Keep bar mail strings plain text. Terminal HTML-only mail may use the bounded native semantic reader; render sanitized literal spans, never execute markup, controls or remote resources.

Keep OAuth tokens out of argv, logs, IPC and repository files. Use Secret Service for refresh tokens. The bar does not persist mail. Terminal modes may cache mail and drafts under explicit memory/disk quotas. Do not add shell runtime scripts, unbounded pagination, browser scraping or a unified unread total. Use fixtures for write acceptance until the user provides a dedicated test mailbox; development authorization is not permission to send production mail or change production contacts.

Use synthetic fixtures first. `tests/ui_gui.py` forces the offscreen Qt platform; automated tests must not map windows, grab the user’s keyboard or edit an installed desktop configuration. Real account, authorization and desktop installation checks need explicit user direction. Do not change package-owned Omarchy files.

Before heavy builds or runtime measurement suites on a shared host, follow the [cooperative host measurement lock](docs/VERIFICATION.md#cooperative-host-measurement-lock). Acquire the host-local directory atomically; hold it through child cleanup, and release only your verified ownership token. Keep lightweight editing available while another owner is active.

Run the checks appropriate to the change, as described in [verification](docs/VERIFICATION.md). `debug` checks correctness; `safe` additionally establishes release memory evidence. Receipts must use binary-reported compiler/mode information. Preserve failed measurements and existing acceptance thresholds. State the test platform and distinguish RSS, PSS and application-owned allocation limits. Historical evidence retains its actual compiler version; qualify 0.17.0 separately.

Public examples and captures use fictional accounts and synthetic mail. Never commit tokens, OAuth client downloads, private configurations, real messages or identifiers, personal paths, installation backups, raw local receipts or screenshots containing real mail. Keep public documentation generic and link only public artifacts.
