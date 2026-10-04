---
name: omagma-setup
description: Install the omagma Omarchy bar plugin, configure separate Gmail accounts and Chrome profiles, and guide browser OAuth consent or reconnection. Use for omagma setup and onboarding, not general Gmail administration.
---

# Set up omagma

Work from an extracted complete omagma release or source checkout. Resolve this skill directory's real path before locating the omagma root (`../..`), or use the user's supplied folder. Read `AGENTS.md`, `README.md`, `docs/SETUP.md`, `docs/INSTALL.md` and `docs/PRIVACY.md`. The app folder, private account config and downloaded Google client JSON are separate resources.

## Prepare the installation

- Prefer a complete bundle from `https://github.com/technologylab-ai/omagma/releases/latest`. Map Linux `uname -m` values `x86_64` to the x86_64 bundle and `aarch64`/`arm64` to arm64. Download `omagma-VERSION-linux-ARCH.tar.gz` and `SHA256SUMS` from the same release. Verify the selected bundle's checksum before extraction. Raw `omagma-linux-ARCH` assets contain only the backend and are insufficient for a new bar installation.
- Extract into a new persistent versioned directory and locate its top-level `omagma/`. Run its `zig-out/bin/omagma --version` and check the reported `omagma VERSION` before consent or desktop activation. Link the absolute `omagma/` folder as the user plugin. Inspect an existing plugin path before updating it; prepare the new folder before changing an installed symlink, and preserve private configuration and credentials.
- End users do not need Zig. Static musl linking applies to the backend; check that the Omarchy/Quickshell host, Chrome, Secret Service/`secret-tool` and system CA certificates are available. ARM backend build/test checks do not establish ARM desktop integration.
- If a compatible asset is unavailable, obtain a source checkout and read `.minimum_zig_version` in `build.zig.zon`, currently exactly **0.17.0**. Omarchy may still ship 0.16.x. Download and verify the 0.17.0 archive matching the host OS/CPU from `https://ziglang.org/download/0.17.0/`, extract it into a task-owned directory, prepend that directory to the task's `PATH`, and confirm `zig version`. Nested Python/build commands must inherit this `PATH`; leave the global compiler unchanged and do not substitute master or another release. Follow `docs/VERIFICATION.md` for cooperative host reservation before heavy builds/runtime suites. Verify `debug` correctness and build `safe` (`-Doptimize=safe`) for this fallback.
- Use fixtures and `--dry-run-open` until consent is available. Continue independent preparation while the user handles Google setup. Available source-checkout UI harnesses run offscreen; release installation does not require a compiler or development test tools.
- Inspect the existing Omarchy/Quickshell installation and user configuration. For a requested installation, add only omagma's user plugin and bar entry, backing up the affected config and preserving unrelated settings. Never edit package-owned Omarchy files. Prefer installed Omarchy commands; follow any applicable local desktop instructions.
- Request only missing account addresses, enabled/optional choices, Chrome profile directories, OAuth client file location and background-refresh preference. Use the user's existing answers. Named profile directories such as `Profile 1` are distinct from Chrome display names; this build rejects `Default`, so use an existing named profile or help the user create one if necessary. Inspect existing profile metadata locally if needed; do not publish it or create a separate browser data directory.
- Resolve the private config location from `XDG_CONFIG_HOME` when set, otherwise `$HOME/.config`, or use the user's existing explicit config location. Create its `omagma/config.json` from the example with real addresses and existing profile directories, mode 0600 in a mode-0700 directory. Set the bar entry's `configPath` to this tested absolute filename so onboarding and the service read the same file. Keep the downloaded client JSON private and outside Git. Configure `refreshIntervalSeconds` as integer `0` (disabled) or `60..86400`; `300` enables five-minute refresh while closed.
- Enable only the accounts the user requested. For a first-account setup, configure that one slot or leave every other slot disabled; do not activate the example's second account implicitly.

## Connect accounts

The current app has a CLI entry point for consent and does not bundle a shared OAuth client. One Google Desktop-app client can cover multiple organizations with an External audience, while every account has a separate grant. The backend requests only Gmail read-only scope and checks the actual Gmail identity before storing the refresh token.

If no suitable client exists, guide the user through Google Cloud project/Gmail API, consent configuration and Desktop client download using `docs/SETUP.md`. Do not claim a service-account key or another application's tokens replace this flow. Consult current primary Google documentation before making policy promises. External Testing Gmail grants expire after seven days; publishing status, public verification and Workspace policy are separate issues. Report actual console/policy errors without widening scope.

Use the verified included binary's absolute path; extraction does not put `omagma` on PATH. A source fallback uses its tested `safe` binary. Resolve the config filename prepared above. For each enabled account, run:

```sh
"/absolute/path/to/omagma/zig-out/bin/omagma" auth --account ACCOUNT_ADDRESS --config "/absolute/private/path/config.json"
```

Explain which configured Chrome profile opens and which exact account to select. Tell the user to approve read-only Gmail access. After the page says authorization was received, tell them they can close that tab; also verify the CLI finishes successfully. Do not claim a callback page alone proves identity verification or token storage. Authorize accounts sequentially so the user knows which tab needs attention. Close agent-owned setup/test tabs when no longer needed; never close unrelated browsing tabs.

A successful consent does not refresh an already disconnected daemon automatically. Manually refresh that account while the popup is open, or restart the omagma service after onboarding/config changes. The installed binary path must point to the verified release backend or tested source fallback.

## Verify and hand off

- Use offscreen fixtures for automated GUI tests. Never run rapid visible open/close tests or steal typing focus. Explain any necessary user click and keep intentional visible checks brief.
- Confirm real recent mail retrieval independently per account, then have the user check a message/Inbox destination in its configured Chrome profile. Dry-run argv cannot prove Chrome selected the expected Google session.
- Check bounded storage, one refresh worker and no work for disabled/disconnected accounts. Automatic refresh is opt-in: a positive interval continues while closed; zero cancels on close. Do not describe zero-idle results from timer-disabled fixtures as proof of enabled background behavior.
- Keep live receipts, mailbox text, local paths and screenshots with real accounts in ignored local notes. Read-only snapshot stdout contains mail display text and must not be recorded publicly. Credentials never belong in command arguments, chat, Git or reports.
- Finish with the bar launch action, configured refresh behavior, account-specific reconnection command, any remaining Google setup gate and where private configuration/backups live. Stop and report an actual blocked account while continuing independent accounts; do not repeat a rejected consent indefinitely.
