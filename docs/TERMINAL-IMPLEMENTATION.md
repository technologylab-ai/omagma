# Terminal mail implementation

Developer reference for the current source tree. Start with [development](DEVELOPMENT.md)
for local builds and focused checks; ordinary use is covered by [the terminal guide](TERMINAL.md)
and [account setup](SETUP.md#full-tuicli-permissions). The TUI and CLI remain experimental.
Dated results below identify their own artifacts and do not qualify every
current change.

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
the TUI afterward. Received-message viewing uses an owner-only temporary text
snapshot and discards editor changes; compose retains its existing readback.
Reader visual selection owns bounded rendered text for one pinned message,
keeps Unicode graphemes intact and rejoins soft wraps without pane padding.
Mouse drag and keyboard selection use terminal OSC 52 for clipboard writes.
Source, folding and width changes invalidate the projection before copying.
New TUI compositions opt into Markdown; saved drafts retain
their interpretation. A shared native renderer derives bounded HTML and plain
alternatives from exact draft source for preview and send review. Ctrl+T changes
format, normal compose `p` selects outgoing/original/plain context, and only
explicit confirmation in review starts the configured send countdown. The CLI defaults to Plain and supports explicit
format selection and local `draft.preview`. No tmux is required. The upstream embedded VT widget has
process lifecycle and parser issues described in [the UI reference](TERMINAL-UI-DESIGN.md#external-editor);
embedded arbitrary-editor panes are not implemented.

`omagma cli` (also `omagma agent`) reads JSON requests, one per line. Every mail
operation explicitly names its account. One-shot `mail`, `contacts`,
`invitations`, `attachment`, `draft` and `queue` commands use the same executor. Local drafts and cache are private,
account-scoped files. Defaults are the newest 2,000 metadata entries and 256 MiB of disk per
account, with hard limits of 10,000 and 1 GiB. One response page contains at most
100 messages; the TUI replaces 32-row windows. Missing recent bodies are prefetched
with a default head of 32, configurable from 0 to 64, within those same quotas.
Ordinary decoded reader bodies retain their 2 MiB limit. Application allocations reuse a
startup-reserved 72 MiB coalescing pool with a 64 MiB payload ceiling. Separate
fixed reservations provide 16 MiB for one message's decoding workspace, 4 MiB
for IO, 2 MiB for startup/environment data, and the existing 16 MiB backend
storage. Sixteen IO workers and their requested 1 MiB stacks start before the
runtime seals, including the daemon worker. The interactive vault relay uses
the same ceiling: joined tasks can briefly retain their worker slots while an
immediate foreground action starts, so the pool accommodates both. CLI-only
vault relays retain their smaller four-worker pool. Vault controls use the
16-worker ceiling for nested identity and transport deadlines and their
retiring predecessors. No workers are created after startup. Normal read/UI arenas subdivide
and return this reserved storage without an allocator fallback. Native full-source
capture for reply/forward, draft editing/reopening, preview, send staging/submission,
RSVP mail and Gmail draft upload explicitly
use a separate OS-backed operation arena. It can grow beyond 256 MiB when
necessary and is wiped and released on success, failure or joined cancellation;
it never becomes a Session or access-token-cache allocator. Message, attachment,
MIME and disk quotas remain enforced. Native source text/rendering can reach
35 MiB; the final MIME spool is checked against Gmail's exact 35 MiB maximum
before submission. Native ordinary files and included original resources share
1,040 outgoing parts and 25 MiB decoded; up to 1,024 original resources are
retained. The browser demo keeps 16 ordinary outgoing files. Formatted
captures save resources as immutable blobs from the first image, so further
replies exchange handles instead of copying base64 screenshots through JSON.
Native blob metadata uses paged immutable records under the account disk quota;
the legacy 4,096-entry flat map remains readable. Larger
source fetches grow from received bytes, and large native draft/IPC records
have separate serialization ceilings rather than preallocated buffers. The
ordinary reader can retain a source envelope without expanding an oversized
cached body; the compose-source route fetches the complete original by ID.
Selected source/media operations have a cancellable three-minute deadline.
Gmail draft status, takeback and import use the same native draft allowance.
Small imports remain complete editable plain-text copies without an added
footer. When an illustrated remote copy exceeds ordinary file slots, native
import preserves its HTML, plain alternative and related resources as a
protected original below a new editable note, retaining ordinary files
separately. The response marks this mode with `importedOriginal: true`; it does
not claim the remote HTML is editable. The original local draft and remote
Gmail copy remain intact. The final remote-version check precedes publication
of the new local draft and its duplicate-send guard.
Portable/browser body and JSON byte tiers remain unchanged. Production sends render once into a
private MIME spool and stream it to Gmail without another render or JSON/base64
copy. `outgoingTransient` in memory diagnostics reports these allocations
separately; the 64 MiB figure applies to the normal fixed heap, not their sum.
External libc/pthread, Keychain and subprocess internals remain outside this
application-owned guarantee. Reservations describe capacity, not resident RSS
or PSS; demand faults can make reserved pages resident later.

Native account indexes keep compact active draft counts and navigation data.
Exact draft sources and their attachment pins publish as immutable records;
settled sources, receipts and queues move to paged history. The 128-draft and
1,000-operation active bounds protect ongoing work rather than limiting
lifetime use. Unknown, queued and unresolved Gmail/Calendar work stays active.
Explicit settled-source deletion preserves permanent operation fingerprints.
Calendar publishes its active document and settled identity/receipt roots in
one transaction, retaining UID/version and cancellation fences. Migration
inventories also page their authenticated records.

An encrypted stream owns a handle-token lease until finish or abort. Shared
workspace operations fail while that writer is live; nested history reads use
separate bounded, wiped scratch. Source reads can use the ciphertext half while
the writer retains buffered plaintext. Releasing a Store keeps the owner lease
until the stream completes, including across account handoffs.

The shared metadata policy permits 16 KiB subjects plus 16 bytes of prefix
headroom, 1 KiB display names and received addresses, 512-byte outgoing
addresses and filenames, and 128 KiB of aggregate headers. All counts are UTF-8
bytes. Preview snippets are bounded separately at 16 KiB; clipping them leaves
the full body available and reports a warning. Outgoing envelopes remain
limited to 500 recipients natively and 32 in the browser demo. Extended
addresses produce a portable-SMTP warning
in send review; Gmail and downstream delivery may still reject them. Encoded
aggregate header limits are checked before a spool/provider receives any bytes;
combining every individual maximum can still exceed those aggregate limits.

Raw folded headers unfold in one pass into one bounded allocation. Each
provider response has a temporary scope; only owned normalized DTOs survive
it. Metadata batches admit at most 4 MiB of complete DTOs plus bounded identity
placeholders; an exceptional row can be read separately. A per-message decoding
refusal preserves identifiable warnings and good
neighbors without advancing an unverified identity or replacing unknown label
membership. Supported multipart alternatives survive an unsupported sibling
charset. Windows-1251 and ISO-8859-2 join the existing charset set. Thread DTOs
have a 4 MiB aggregate body allowance plus bounded identity placeholders;
individual reads remain available. Index saves target less than 8 MiB by
evicting whole oldest mail entries while retaining complete metadata in kept
rows; the 16 MiB legacy index read bound remains. Drafts and receipts are never
discarded to meet that target. `status:partial` finds warning rows locally.

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
Labels expose complete counts over pinned targets; the TUI stages checked/mixed
membership changes until Apply. Account-scoped custom label
creation, renaming, colors and reviewed deletion share the executor and operation
journal, separately from message assignment; system definitions are protected.
Contacts support read/search/create/update, not
deletion. Native Calendar provides Agenda/Day/Week views
and source-bound invitation Add/Update/Cancel reviews, separately from RSVP
email. Calendar provider,
timezone, persistence and command modules are shared by the native TUI and CLI;
the browser does not yet expose these views. See [permissions](CALENDAR-PERMISSIONS.md)
and [service contracts](CALENDAR-SERVICE.md).

The contextual action palette, rendered-message find and saved/history query
lists stay local and bounded. Unread navigation uses cache predicates and
explicit anchored target selection, including worker-owned body-query pages;
it never implicitly marks mail read. Conversation actions resolve a complete
bounded ID set before reviewed mutation. Native edit undo, verified sender
choice and named recipient insertion share the existing draft model. Contacts
retain all supported addresses and provider version metadata through edits.

Outgoing files use immutable account storage and bounded MIME spooling;
received saves stream into private no-clobber destinations. Multi-file
selection and Save All/selected use explicit file lists. A private sandboxed
browser preview renders outgoing styles and verified inline raster resources
without scripts or remote fetching. The [terminal guide](TERMINAL.md#bounds-and-recovery)
defines current size/count limits.

Sending defaults to a ten-second local cancellation period, configurable from
zero to thirty seconds. A durable queued intent records the operation and
exact draft/account. Explicit processing claims it before submission;
submitting/unknown states never retry automatically. Restart leaves queued
intents paused, with Resume/Cancel available only for the matching open draft.
Normal countdown cancellation retains the draft. The CLI shares these queue
operations; scheduled/background delivery remains a separate feature.

Sending and RSVP require an operation identity. An uncertain remote outcome is
recorded and never automatically retried. Contact writes compare versions.
Trash is reversible; permanent deletion is unsupported. Reading does not mark
mail read. Mail is data: no terminal controls, remote HTML content or shell
commands are executed.

Public release discovery uses `terminal/updates.zig` with the existing owned
worker and HTTP slab, after pending mail work. Its fixed GitHub endpoints have
a separate credential-free request policy, 64 KiB response cap and five-second
deadline per request. A bounded private state file records daily attempts,
last successful metadata, server retry delays, automatic/manual preference and
exact-release dismissal. Checks persist the attempt before waiting and retain
external preference changes on completion. Stable semantic versions and proven
installation ownership determine actionable notices; Homebrew lag and pins
are respected. The guide and `omagma updates` share this state independently
of Gmail configuration and grants. See [updates](UPDATES.md).

The mock provider supports all workflows before permission upgrades. Live send,
mail modification and People access require a separately scoped grant, preserving
the installed bar's existing read-only grant. A dedicated test mailbox is required
for developer live-write qualification, not for normal installation or user-authorized
mail use. Fixture success does not establish recipient delivery.

Source ownership is separated among shared executor/persistence/CLI, provider/MIME/
recipient/invitation modules, and libvaxis TUI/editor. [Provider design](TERMINAL-PROVIDER-DESIGN.md),
[UI design](TERMINAL-UI-DESIGN.md) and [verification](TERMINAL-VERIFICATION.md) describe
the contracts and remaining qualification boundaries.

## Retaining received HTML

Formatted replies and forwards treat the received HTML as mail data. The
outbound assembler locates a safe body insertion point for the separately
rendered note and source header; it does not validate the original against an
HTML conformance checklist or serialize a replacement DOM. Ordinary malformed
tags, repeated wrappers and trailing content belong to the recipient's HTML
recovery rules. Keep original markup, styles, images and links in source order,
including the absence of a doctype when the original uses quirks mode.

Boundary detection still needs bounded token awareness: comments, quoted
attributes, raw-text elements and template contents can contain literal body
tags that are not insertion points. An incomplete tail after a known body
boundary must not become an unrelated HTML validation failure. An unfinished
head that leaves no safe place for the note can fail explicitly. Decoded text,
token, tag, resource, rendering and storage limits remain enforced, and a
recognized CID reference must have its retained image data. Unexpected CSS
syntax does not justify dropping mail or treating every attachment as inline.

[The synthetic compatibility corpus](../tests/fixtures/terminal/html-compatibility/README.md)
records acceptance and boundary cases with primary references. Its independent
Chromium oracle compares original content, root/body attributes, tables,
images, links, styles and compatibility mode after excluding only the generated
note/header. Run `python3 tests/terminal_html_compatibility.py --binary PATH`
under the cooperative host reservation. The browser uses a fresh headless
profile, isolated synthetic drafts and blocked external resources; it does not
use private mail or the user's desktop/browser profile.

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
