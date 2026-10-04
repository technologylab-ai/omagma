# Agent instructions

## Installing or configuring omagma

When the user asks to install omagma on their Omarchy desktop, connect Gmail accounts or fix setup, read and follow [the setup workflow](skills/omagma-setup/SKILL.md). This is the installation entry point; it does not require installing the skill into an agent's global skills directory. Prefer a complete matching bundle from [the latest release](https://github.com/technologylab-ai/omagma/releases/latest), verify its `SHA256SUMS` entry and probe the included backend with `--version` before consent. End users do not need Zig. Build from source only if a compatible asset is unavailable, using the declared compiler pin.

Use [agent setup](docs/AGENT-SETUP.md) for the handoff and [account setup](docs/SETUP.md) / [bar installation](docs/INSTALL.md) for details. Continue fixture-backed preparation while the user completes Google registration or consent, and tell them exactly when a browser click is needed. Static backend bundles still need the installed desktop host, Chrome, keyring and system CA certificates.

## Developing omagma

Use Zig **0.16.0 exactly**, the current tested pin in `build.zig.zon`. All project-authored runtime helpers outside QML/JavaScript must be Zig. Python and Node.js support tests and release packaging, not runtime helpers. Keep the dependency-free Zig build and the read-only Gmail behavior. [Release instructions](docs/RELEASING.md) describe version-driven Linux musl packaging; changing the package version drives a new release without replacing an existing one.

Preserve the bounded design: at most three configured accounts, 30 rows per account, one network worker, one pending job flag per account, bounded frames and a 64-entry UI request ledger. Replace snapshots instead of appending history. Check generations and the active handshake’s account identities. Treat all mail-derived UI strings as plain text.

Keep OAuth tokens out of argv, logs, IPC and repository files. Use Secret Service for refresh tokens. Do not add mail persistence, shell runtime scripts, unbounded pagination, browser scraping or a unified unread total.

Use synthetic fixtures first. `tests/ui_gui.py` forces the offscreen Qt platform; automated tests must not map windows, grab the user’s keyboard or edit an installed desktop configuration. Real account, authorization and desktop installation checks need explicit user direction. Do not change package-owned Omarchy files.

Run the checks appropriate to the change, as described in [verification](docs/VERIFICATION.md). Debug builds establish correctness; ReleaseSafe builds establish memory evidence. Preserve failed measurements and retain the existing acceptance thresholds. State the test platform and distinguish RSS, PSS and application-owned allocation limits.

Public examples and captures use fictional accounts and synthetic mail. Never commit tokens, OAuth client downloads, private configurations, real messages or identifiers, personal paths, installation backups, raw local receipts or screenshots containing real mail. Keep public documentation generic and link only public artifacts.
