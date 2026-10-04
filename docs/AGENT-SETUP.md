# Agent-assisted setup

Ask a coding agent to use this repository or its complete [release bundle](https://github.com/technologylab-ai/omagma/releases/latest):

The root `AGENTS.md` directs installation/onboarding requests to `skills/omagma-setup/SKILL.md`. The agent can follow that workflow directly; installing it as a global skill is optional.

> Read AGENTS.md and follow skills/omagma-setup/SKILL.md. Download the latest complete omagma bundle for my Linux architecture, verify SHA256SUMS and run the included backend’s --version, then install its user-owned Omarchy bar plugin. Help me map each Gmail account to its existing Chrome profile and configure private OAuth credentials. Use fixtures while I complete Google setup. Tell me when I need to click something, and keep automated UI tests offscreen. Preserve unrelated desktop settings and give me the final launch and reconnect instructions.

Add your account addresses, existing Chrome profile directories, and whether you want five-minute background refresh. Provide a downloaded OAuth client JSON's local path when available; do not paste its contents or account tokens into chat. The agent can prepare and validate local configuration while you approve Google consent in Chrome.

The preferred installation needs no Zig compiler. Static musl backends are published for Linux x86_64 and arm64; use the complete bundle so the UI and instructions are included. Omarchy/Quickshell, Chrome, the keyring and system CA certificates must already be available. ARM backend build/test checks do not establish ARM desktop integration.

If no compatible release asset exists, use a source checkout with exact Zig **0.17.0**. Omarchy may still ship 0.16.x: download the verified 0.17.0 archive matching the host OS/CPU from [the versioned release directory](https://ziglang.org/download/0.17.0/), extract it, prepend its directory to the task's `PATH`, and confirm `zig version` before invoking any build or nested Python tool. Keep the system compiler unchanged. Use `-Doptimize=debug` and `-Doptimize=safe` for the appropriate checks, under the [shared-host reservation protocol](VERIFICATION.md#cooperative-host-measurement-lock).

## Optional setup skill

The repository and complete bundle include [omagma-setup](../skills/omagma-setup/SKILL.md). An agent can read it directly. To make it discoverable in Codex, link it into your skills directory from the extracted folder or checkout:

```sh
mkdir -p ~/.codex/skills
ln -s /absolute/path/to/omagma/skills/omagma-setup ~/.codex/skills/omagma-setup
```

Restart your agent session after installation and ask it to use `$omagma-setup`. Other agents that support `SKILL.md` can use the same instructions. The skill stays in the omagma folder and refers to the included project docs. It does not grant permission to modify unrelated desktop settings or bypass Google consent.

Source and release builds use the actual tested pin declared in `build.zig.zon`. When porting to a newer Zig version, update the implementation, checks and documentation together. [Release maintenance](RELEASING.md) explains version-driven publication.
