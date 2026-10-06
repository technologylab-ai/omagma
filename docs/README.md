# Omagma documentation

Start with installation and account setup, then choose the bar, terminal or
agent guide. The bar is read-only; the experimental TUI and CLI can use an
account grant for sending and mailbox/contact changes. The bar runs on Linux
Omarchy; the TUI and CLI run on Linux and macOS.

These guides describe Omagma’s current features. Dated evidence reports retain
the versions and revisions that were measured.

## Get started

1. [Install on Linux](INSTALL.md) or [macOS](MACOS.md): choose Homebrew on Mac
   or a matching verified bundle, then install the requested interface.
2. [Connect accounts and permissions](SETUP.md): Chrome profiles, read-only bar
   access, full TUI/CLI access, Google Console steps and per-account consent.
3. [Ask an agent to install it](AGENT-SETUP.md): a ready-to-use request and the
   included [setup skill](../skills/omagma-setup/SKILL.md).

## Everyday use

The [feature catalogue](FEATURES.md) lists the main capabilities first, then
smaller reading, composition, organization and agent workflow details.

| Guide | What you will find |
| --- | --- |
| [macOS installation](MACOS.md) | Homebrew, native release bundles, Keychain and Chrome defaults |
| [Bar dropdown](UI.md) | Account switching, mail links and refresh status |
| [Terminal mail](TERMINAL.md) | Reading, search, compose/reply, contacts, attachments, labels and keyboard/mouse controls |
| [Agent CLI](AGENT-CLI.md) | Structured commands, account selection, cache/server search, drafts, receipts and CLI/TUI coverage |
| [Bar background refresh](BACKGROUND-REFRESH.md) | Configure periodic checking while the dropdown is closed |
| [Terminal background cache](TERMINAL-BACKGROUND.md) | Optional five-minute cache fetching while the TUI is closed |
| [Terminal cache](TUI-CACHE.md) | Startup, loading states, retention, cached search and clearing mail |

## Privacy and distribution

- [Privacy and credentials](PRIVACY.md): tokens, cached mail, browser routing
  and the separate bar/terminal grants.
- [Memory](MEMORY.md): what the published measurements include, with dates,
  versions and workload limits.
- [Distribution and Google registration](DISTRIBUTION.md): user-supplied OAuth
  registrations and the distinction between testing, publishing and verification.
- [License notices](../LICENSES/README.md): bundled third-party licenses.

## Development and reference

[Developing Omagma](DEVELOPMENT.md) is the entry point for source builds, local
changes, tests and release qualification. These tasks are separate from normal
installation and account onboarding.

| Reference | Purpose |
| --- | --- |
| [Agent development rules](../AGENTS.md#developing-omagma) | Compiler, ownership, privacy and local iteration rules |
| [Backend transport](TRANSPORT.md) / [bar protocol](PROTOCOL.md) | Backend and UI integration contracts |
| [Terminal implementation](TERMINAL-IMPLEMENTATION.md) | Module ownership and terminal runtime architecture |
| [Terminal provider](TERMINAL-PROVIDER-DESIGN.md) | Gmail/People operations and capability/credential design |
| [Terminal UI](TERMINAL-UI-DESIGN.md) | Rendering, input, composition and lifecycle design |
| [Bar verification](VERIFICATION.md) / [terminal verification](TERMINAL-VERIFICATION.md) | Developer correctness and resource checks |
| [Release maintenance](RELEASING.md) | Version-driven Linux/macOS bundles and publication |
| [Zig wiki follow-up](ZIG017-WIKI-FOLLOWUP.md) | Curator notes distinguishing compiler findings from application bugs |

## Historical evidence

These reports retain their actual versions, source revisions, platforms and
failed/passed checks. They are reference material rather than installation
steps or claims about a later development build.

- [Zig 0.16 baseline](../EVIDENCE.md) and [Zig 0.17 migration](evidence/zig-0.17.0.md)
- [Initial terminal release](evidence/terminal-0.2.0.md)
- [Incoming-header patch](evidence/terminal-0.2.1.md)
- [Cache-first release](evidence/terminal-0.2.2.md)
- [HTML reader](evidence/terminal-0.2.3.md) and [mouse support](evidence/terminal-0.2.3-mouse.md)
- [Terminal features and native Linux/macOS release](evidence/terminal-0.2.4.md)
