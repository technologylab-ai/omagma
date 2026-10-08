# Terminal mail implementation

Developer reference for the current source tree. Start with [development](DEVELOPMENT.md)
for local builds and focused checks; ordinary use is covered by [the terminal guide](TERMINAL.md)
and [account setup](SETUP.md#full-tuicli-permissions). The TUI and CLI remain experimental.
Current source is newer than the published v0.2.3 checkpoint; a new release
qualifies its own candidate and does not replace that checkpoint. Dated results
below identify their own artifacts and do not qualify every current change.

## Current implementation

The desktop bar retains its read-only API, account separation, 30-message
snapshots and existing memory gates. New terminal modes have separate bounded
storage and explicit capabilities. Tests use fictional accounts; no production
mailbox or contact is changed during development.

The implementation uses exact Zig 0.17.0 and pinned libvaxis, taking
layout and terminal lifecycle lessons from Omajot. `omagma tui` provides Vim
navigation, full mail and bounded thread reading, separate local/server search,
cache-first scrolling, contacts, drafts, replies, reply-all, forwarding and review
before sending. The reader can be right, below or expanded. A built-in split composer
keeps the mail context visible. `$EDITOR` runs with terminal takeover and restores
the TUI afterward. New TUI compositions opt into Markdown; saved drafts retain
their interpretation. A shared native renderer derives bounded HTML and plain
alternatives from exact draft source for preview and send review. Ctrl+T changes
format, normal compose `p` selects outgoing/original/plain context, and only
explicit `y` in review submits. The CLI defaults to Plain and supports explicit
format selection and local `draft.preview`. No tmux is required. The upstream embedded VT widget has
process lifecycle and parser issues described in [the UI reference](TERMINAL-UI-DESIGN.md#external-editor);
embedded arbitrary-editor panes are not implemented.

`omagma cli` (also `omagma agent`) reads JSON requests, one per line. Every mail
operation explicitly names its account. One-shot `mail`, `contacts` and
`invitations` commands use the same executor. Local drafts and cache are private,
account-scoped files. Defaults are the newest 2,000 metadata entries and 256 MiB of disk per
account, with hard limits of 10,000 and 1 GiB. One response page contains at most
100 messages; the TUI replaces 32-row windows. Missing recent bodies are prefetched
with a default head of 32, configurable from 0 to 64, within those same quotas.
An individual decoded body is at most 2 MiB. Terminal heap allocations have a
64 MiB limit, alongside the existing 16 MiB fixed backend reservation. Std and
terminal runtime overhead are separate.

Cached lists and bodies remain usable during the one owned network worker's
refresh. Account/request-scoped progress reports actual metadata/body batches;
32 immutable preview slots expose completed metadata and body excerpts without
borrowing provider scratch. Missing rows animate with finite 180 ms waits only
while loading. Provisional rows become interactive only after the view commits.
The optional native background one-shot uses the same disk cache and per-account
refresh lease, with read-only bar credentials, and exits between timer runs.

The composer saves private recovery drafts after a short pause, including
incomplete recipient text. Such drafts require a validated update before send.
Verified same-account aliases and configured signatures are explicit draft
state. Bulk triage handles at most 100 IDs with per-message outcomes and bounded
selective undo; it never batches sends or retries uncertain mutations automatically.
Labels can be listed, filtered and applied/removed. Account-scoped custom label
creation, renaming and reviewed deletion share the executor and operation
journal, separately from message assignment; system definitions are protected.
Contacts support read/search/create/update, not
deletion. Calendar views are unsupported; invitations use reviewed RSVP email.

Sending and RSVP require an operation identity. An uncertain remote outcome is
recorded and never automatically retried. Contact writes compare versions.
Trash is reversible; permanent deletion is unsupported. Reading does not mark
mail read. Mail is data: no terminal controls, remote HTML content or shell
commands are executed.

The mock provider supports all workflows before permission upgrades. Live send,
mail modification and People access require a separately scoped grant, preserving
the installed bar's existing read-only grant. A dedicated test mailbox is required
for developer live-write qualification, not for normal installation or user-authorized
mail use. Fixture success does not establish recipient delivery.

Source ownership is separated among shared executor/persistence/CLI, provider/MIME/
recipient/invitation modules, and libvaxis TUI/editor. [Provider design](TERMINAL-PROVIDER-DESIGN.md),
[UI design](TERMINAL-UI-DESIGN.md) and [verification](TERMINAL-VERIFICATION.md) describe
the contracts and remaining qualification boundaries.

## Historical release checkpoints

Version 0.2.0 expands the completed 0.1.1 release. Runtime source is
`7568a2467b5a93142259bc50057a177c3acf7150`; [qualification](evidence/terminal-0.2.0.md)
records exact artifacts and results. Version 0.2.1 at
`858ce32d21625a136fbed102d265e97bb95b0a48` separates incoming address-header bounds
from the sending envelope; its [patch qualification](evidence/terminal-0.2.1.md)
preserves the original release evidence. [Cache-first 0.2.2](evidence/terminal-0.2.2.md)
and [the published 0.2.3 mouse/HTML checkpoint](evidence/terminal-0.2.3-mouse.md)
retain their exact compiler, source, artifact and platform identities. New local
interface checks do not replace those release or memory measurements.
