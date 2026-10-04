# Agent-assisted setup

Ask a coding agent to work from this checkout:

The root `AGENTS.md` directs installation/onboarding requests to `skills/omagma-setup/SKILL.md`. The agent can follow that workflow directly; installing it as a global skill is optional.

> Read AGENTS.md, docs/SETUP.md, docs/INSTALL.md and docs/PRIVACY.md. Build and test omagma, then install its user-owned Omarchy bar plugin. Help me map each Gmail account to its existing Chrome profile and configure private OAuth credentials. Use fixtures while I complete Google setup. Tell me when I need to click something, and keep automated UI tests offscreen. Preserve unrelated desktop settings and give me the final launch and reconnect instructions.

Add your account addresses, existing Chrome profile directories, and whether you want five-minute background refresh. Provide a downloaded OAuth client JSON's local path when available; do not paste its contents or account tokens into chat. The agent can prepare and validate local configuration while you approve Google consent in Chrome.

## Optional setup skill

The repository includes [omagma-setup](../skills/omagma-setup/SKILL.md). An agent can read it directly. To make it discoverable in Codex, link it into your skills directory from the checkout:

```sh
mkdir -p ~/.codex/skills
ln -s /absolute/path/to/omagma/skills/omagma-setup ~/.codex/skills/omagma-setup
```

Restart your agent session after installation and ask it to use `$omagma-setup`. Other agents that support `SKILL.md` can use the same instructions. The skill stays in the checkout and refers to the maintained project docs. It does not grant permission to modify unrelated desktop settings or bypass Google consent.

The compiler version remains the actual tested pin in `build.zig`. When porting to a newer Zig version, update the implementation, checks and documentation together.
