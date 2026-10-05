# Terminal mail implementation

Version 0.2.0 develops from the completed 0.1.1 release on `feature/terminal-mail-client`.
The desktop bar retains its read-only API, account separation, 30-message
snapshots and existing memory gates. New terminal modes have separate bounded
storage and explicit capabilities. Tests use fictional accounts; no production
mailbox or contact is changed during development.

The first implementation uses exact Zig 0.17.0 and pinned libvaxis, taking
layout and terminal lifecycle lessons from Omajot. `omagma tui` provides Vim
navigation, complete mail and thread reading, search, pagination, contacts,
drafts, replies, reply-all and review before sending. A built-in split composer
keeps the mail context visible. `$EDITOR` runs with terminal takeover and restores
the TUI afterward. No tmux is required. The upstream embedded VT widget has
process lifecycle and parser issues that need a separate bounded adaptation;
adding a second terminal engine is outside this first implementation.

`omagma cli` (also `omagma agent`) reads JSON requests, one per line. Every mail
operation explicitly names its account. One-shot `mail`, `contacts` and
`invitations` commands use the same executor. Local drafts and cache are private,
account-scoped files. Defaults are 2,000 metadata entries and 256 MiB of disk per
account, with hard limits of 10,000 and 1 GiB. One response page contains at most
100 messages; an individual body is at most 2 MiB. Terminal heap allocations have a 64 MiB limit, alongside the existing 16 MiB fixed backend reservation. Std and terminal runtime overhead are separate.

Sending and RSVP require an operation identity. An uncertain remote outcome is
recorded and never automatically retried. Contact writes compare versions.
Trash is reversible; permanent deletion is unsupported. Reading does not mark
mail read. Mail is data: no terminal controls, remote HTML content or shell
commands are executed.

The mock provider supports all workflows before permission upgrades. Live send,
mail modification and People access require a separately scoped grant, preserving
the installed bar's existing read-only grant. A dedicated test mailbox is needed
for live write acceptance; fixture success does not establish recipient delivery.

Implementation ownership: shared executor, persistence and CLI; provider/MIME/
recipient/invitation modules; libvaxis TUI/editor; independent fixture and PTY
verification. Findings and incomplete gates are recorded in the corresponding
terminal design and verification documents.
