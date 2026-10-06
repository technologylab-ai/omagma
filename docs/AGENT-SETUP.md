# Agent-assisted setup

**Recommended for Google/OAuth setup:** point your coding agent at
[this repository](https://github.com/technologylab-ai/omagma) or its complete
[release bundle](https://github.com/technologylab-ai/omagma/releases/latest).
The agent can prepare installation and private configuration while walking you
through Google Console and consent one step at a time. You provide feedback
after each Google step and approve access in your browser.

The root `AGENTS.md` directs installation/onboarding requests to `skills/omagma-setup/SKILL.md`. The agent can follow that workflow directly; installing it as a global skill is optional.

> Read AGENTS.md and follow skills/omagma-setup/SKILL.md and docs/SETUP.md. Download and verify the latest complete Omagma bundle for my Linux architecture, then install its Omarchy bar plugin. Help me map my Gmail accounts to their existing Chrome profiles. Walk me through Google Console and OAuth one small step at a time, waiting for my feedback before the next Google step. Reuse my existing project and configuration where available, keep downloaded credentials private, and open consent in the correct profile for each account. Verify mail access and profile links, then give me launch and reconnect instructions.

Add your account addresses, existing Chrome profile directories, and whether you want five-minute background refresh. Provide a downloaded Google OAuth registration JSON's local path when available; do not paste its contents or account tokens into chat. The agent can prepare and validate local configuration while you approve Google consent in Chrome.

The preferred installation needs no Zig compiler. Static musl backends are published for Linux x86_64 and arm64; use the complete bundle so the UI and instructions are included. Omarchy/Quickshell, Chrome, the keyring and system CA certificates must already be available. ARM backend build/test checks do not establish ARM desktop integration.

If no compatible release asset exists, use a source checkout with exact Zig **0.17.0**. Omarchy may still ship 0.16.x: download the verified 0.17.0 archive matching the host OS/CPU from [the versioned release directory](https://ziglang.org/download/0.17.0/), extract it, prepend its directory to the task's `PATH`, and confirm `zig version`. Keep the system compiler unchanged, follow [the source-build instructions](DEVELOPMENT.md#build-from-source) using `safe`, and verify the resulting binary's version.

## Optional setup skill

The repository and complete bundle include [omagma-setup](../skills/omagma-setup/SKILL.md). An agent can read it directly. To make it discoverable in Codex, link it into your skills directory from the extracted folder or checkout:

```sh
mkdir -p ~/.codex/skills
ln -s /absolute/path/to/omagma/skills/omagma-setup ~/.codex/skills/omagma-setup
```

Restart your agent session after installation and ask it to use `$omagma-setup`. Other agents that support `SKILL.md` can use the same instructions. The skill stays in the omagma folder and refers to the included project docs. It does not grant permission to modify unrelated desktop settings or bypass Google consent.

Source builds use the compiler pin declared in `build.zig.zon`; complete release bundles need no compiler.

## Terminal client and agents

For `omagma tui`, the JSONL agent client, cached full mail, drafts and scoped write setup, read [account permissions](SETUP.md#full-tuicli-permissions), [TERMINAL.md](TERMINAL.md) and [AGENT-CLI.md](AGENT-CLI.md). Full access uses `gmail.modify` and `contacts` with a separate Google OAuth registration and per-account terminal consent. Existing bar credentials remain read-only. Install and authorize the requested interfaces; sending mail or changing contacts requires the user's separate request or explicit interaction.

If the bar already works and you want to enable full terminal access, use:

> Read AGENTS.md and follow skills/omagma-setup/SKILL.md and the full TUI/CLI permissions section of docs/SETUP.md. Enable full terminal access for my configured accounts using a separate Google OAuth registration in my existing Google project. Walk me through People API, Data access scopes and creating/downloading the terminal registration one step at a time, waiting for my feedback. Prepare the private registration JSON and open each account's consent sequentially in its configured Chrome profile. Confirm the grants and mail/contact reads, then tell me how to restart the TUI and reconnect later.
