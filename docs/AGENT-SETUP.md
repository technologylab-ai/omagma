# Agent-assisted setup

**Give your agent a public URL:** [this website](https://technologylab-ai.github.io/omagma/)
or [the GitHub repository](https://github.com/technologylab-ai/omagma).
The agent fetches the setup instructions, downloads and verifies the matching
release, and prepares local files while guiding you through Google Console and
consent one step at a time. You provide feedback after each Google step and
approve access in your browser. No checkout or folder preparation is needed
before asking the agent to install Omagma.

The root `AGENTS.md` directs installation/onboarding requests to `skills/omagma-setup/SKILL.md`. The agent can follow that workflow directly; installing it as a global skill is optional.

> Read AGENTS.md at https://github.com/technologylab-ai/omagma/blob/main/AGENTS.md and fetch its linked setup workflow and account guide yourself. Follow skills/omagma-setup/SKILL.md and docs/SETUP.md. Download and verify the latest complete Omagma bundle for my Linux architecture, then install its Omarchy bar plugin and Omagma launcher entry, and offer to make Super+Shift+E open Omagma instead of HEY. Help me map my Gmail accounts to their existing Chrome profiles. Walk me through Google Console and OAuth one small step at a time, waiting for my feedback before the next Google step. Reuse my existing project and configuration where available, keep downloaded credentials private, and open consent in the correct profile for each account. Verify mail access and profile links, then give me launch and reconnect instructions.

Add your account addresses, existing Chrome profile directories, and whether you want five-minute background refresh. Provide a downloaded Google OAuth registration JSON's local path when available; do not paste its contents or account tokens into chat. The agent can prepare and validate local configuration while you approve Google consent in Chrome.

The preferred installation needs no Zig compiler. On Mac, use `brew install renerocksai/tap/omagma`; the [Mac guide](MACOS.md) also covers verified Apple Silicon/Intel bundles. Linux x86_64 and arm64 bundles include the static musl backend and bar UI. Only the Linux bar requires Omarchy/Quickshell. Live mail uses Chrome and an unlocked platform keyring. ARM backend build/test checks do not establish ARM desktop integration.

If no compatible release asset exists, use a source checkout with exact Zig **0.17.0**. Omarchy may still ship 0.16.x: download the verified 0.17.0 archive matching the host OS/CPU from [the versioned release directory](https://ziglang.org/download/0.17.0/), extract it, prepend its directory to the task's `PATH`, and confirm `zig version`. Keep the system compiler unchanged, follow [the source-build instructions](DEVELOPMENT.md#build-from-source) using `safe`, and verify the resulting binary's version.

## Optional setup skill

The repository and complete bundle include [omagma-setup](../skills/omagma-setup/SKILL.md). An agent can read it directly. To make it discoverable in Codex, ask your agent to link it into your skills directory after installing the release bundle:

```sh
mkdir -p ~/.codex/skills
ln -s /absolute/path/to/omagma/skills/omagma-setup ~/.codex/skills/omagma-setup
```

Restart your agent session after installation and ask it to use `$omagma-setup`. Other agents that support `SKILL.md` can use the same instructions. The skill stays in the omagma folder and refers to the included project docs. It does not grant permission to modify unrelated desktop settings or bypass Google consent.

Source builds use the compiler pin declared in `build.zig.zon`; complete release bundles need no compiler.

## Terminal client and agents

For `omagma tui`, the JSONL agent client, cached full mail, drafts and scoped write setup, read [account permissions](SETUP.md#full-tuicli-permissions), [TERMINAL.md](TERMINAL.md) and [AGENT-CLI.md](AGENT-CLI.md). Full access uses `gmail.modify` and `contacts` with per-account terminal consent. A fresh terminal-only installation needs one registration; if the bar already works, use a different registration and preserve its read-only grant. Existing bar credentials remain read-only. Install and authorize the requested interfaces; sending mail or changing contacts requires the user's separate request or explicit interaction.

For a fresh Mac/Linux terminal installation, or full access alongside an existing bar, use:

> Read AGENTS.md at https://github.com/technologylab-ai/omagma/blob/main/AGENTS.md and fetch its linked setup workflow and account guide yourself. Install Omagma’s experimental TUI and CLI on my computer; prefer brew install renerocksai/tap/omagma on macOS, or download and verify the matching Linux bundle. Follow skills/omagma-setup/SKILL.md and the full TUI/CLI permissions section of docs/SETUP.md. Reuse my existing Google project and private configuration where available. For terminal-only setup, use one Google OAuth registration without creating a bar setup; if I already use the bar, preserve it and use a different terminal registration. Walk me through Gmail/People APIs, scopes and the registration JSON one step at a time, waiting for my feedback. Open each account’s consent sequentially in its existing Chrome profile. Confirm grants and mail/contact reads without sending or changing data, then give me launch and reconnect instructions.
