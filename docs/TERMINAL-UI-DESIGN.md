# Terminal UI design

Developer reference for the current terminal layout, rendering and ownership contracts. Start with [development](DEVELOPMENT.md); user controls and setup belong in [the terminal guide](TERMINAL.md) and [account permissions](SETUP.md#full-tuicli-permissions). The TUI and CLI remain experimental. Current source includes changes after the published v0.2.3 checkpoint; dated [verification](TERMINAL-VERIFICATION.md) qualifies only its named artifacts. Development uses fictional mail and isolated PTYs, while the bar retains its separate read-only behavior.

## Terminal backend

Omagma uses libvaxis's low-level renderer, input decoder, Unicode grapheme layout and clipped child windows. The structure follows Omajot's separation of terminal lifecycle, state, navigation and drawing at revision `c7c1ffd082f77f47640990e7c01ed2d3ec6748b4`. Omajot's external editor takes over the whole terminal; it does not embed an editor in a note pane.

The project-owned Linux input adapter reuses the pinned parser, fixed queue and capability dispatcher. It passes only a complete UTF-8 prefix to the parser, retaining up to three trailing bytes between 1,024-byte reads, so grapheme lookahead cannot discard a fragmented codepoint. Incomplete control sequences share the bounded buffer and fail visibly if they exceed it. The 512 queued events hold small descriptors and own at most 1,024 bytes of key text each through the bounded UI allocator. Consumption transfers that allocation to the consumer until its next event; failed pushes release it. The heap loop initializes in place. Stop joins the input task and drains queued text, preventing stale keys after editor return. Dependency and reference sources are unchanged. The independent split-input witness is recorded in the [dependency finding](ZIG017-WIKI-FOLLOWUP.md#pinned-libvaxis-incomplete-utf-8-input-dependency-finding).

The dependency graph is pinned for exact Zig **0.17.0**:

| Package | Immutable revision |
| --- | --- |
| libvaxis | `6fd944a27fb3d6f596e981076381a3131f2448b4` |
| zigimg | `c701c9f99779d7ddf594dcc6da8f858fd277d61f` |
| uucode | `ea62149739404a73c202b48a33bf6dd2af4bd9b0` |

The libvaxis package hash is `vaxis-0.6.0-BWNV_MafDAAEzkVUvrW9NFUqnnMUoeHqrs2mecnD6D7w`. Upstream licenses are retained in `LICENSES/`. The user's request to reuse libvaxis permits this pinned terminal dependency. It does not change the bar's provider or credential scope. [Pinned package graph](https://github.com/rockorager/libvaxis/blob/6fd944a27fb3d6f596e981076381a3131f2448b4/build.zig.zon), [low-level example](https://github.com/rockorager/libvaxis/blob/6fd944a27fb3d6f596e981076381a3131f2448b4/examples/vaxis.zig).

## Layout

At 120 columns and above, navigation can remain alongside mail/reader panes. Horizontal splitting requires at least 80 available columns; below layout uses stacked panes when there are at least 48 columns and 16 content rows. Otherwise the focused pane uses the available space, and narrow navigation takes over when focused. `v` chooses right/below, `:split` sets bounded ratios, and `z` expands the reader. Below 30 columns or 10 rows, a resize message replaces the layout while quit remains available. Rendering is bounded to 240 columns by 80 rows.

The palette follows the current Omarchy theme, with semantic accent/selection, sender and muted metadata roles. `NO_COLOR` uses terminal-default colors, bold and reverse video. No icon font or image protocol is required. Configured accounts remain distinct; navigation wraps full addresses and the header identifies the selected account. There is no unified account or unread total.

Illustrative layout, not a runtime capture:

```text
 omagma   work@example.com   |   Inbox   |   Reader right   ·   Mock
 Up to date · Synced 2026-01-05 10:42 CET
┌ Accounts / mailboxes ┐┌ Mail · 1/32 ↓ ───────────┐┌ Message · 50% · 1–8/16 ───────────┐
│ personal@example.com ││ ● A quieter launch      ││ A quieter launch            │
│ work@example.com     ││ Morgan — Review tomorrow││ From: Morgan                │
│ optional@example.com ││                         ││ To: work@example.com        │
│                      ││   Workshop notes        ││ 2026-01-05 10:42 CET        │
│ Inbox                ││ Avery — Updated notes   ││                             │
│ Sent                 ││                         ││ Let's keep the launch small.│
│ Drafts               ││ ● Lunch next week?      ││                             │
│ Archive              ││ Casey — Tuesday works   ││                             │
│ Trash · Spam         ││                         ││                             │
│ All Mail · Unread    ││                         ││                             │
│ Contacts · Labels    ││                         ││                             │
└──────────────────────┘└─────────────────────────┘└─────────────────────────────┘
 j/k Mail  h/l Pane  / Cache  \ Gmail  c Compose  v Layout  ? Help  q Quit
 Ready
```

Mail windows contain up to 32 rows and are replaced rather than appended. Two content rows per card use one separating row only between cards, so 5/8-row interiors fit 2/3 complete cards. The title reports selected/current-window count and only known newer/older arrows, never a Gmail total. Reaching a boundary scrolls through adjacent cached windows before requesting a missing older provider page. Explicit continuation controls remain available. Refresh preserves the selected ID where possible. The reader first loads the selected message, then Enter opens its chronological thread. It displays decoded full text, From/To/Cc, local time, numbered attachments and invitation cues. Reading does not implicitly mark mail read. Remote images do not load.

`:save-attachment NUMBER /absolute/literal/path` retrieves a numbered attachment from the displayed message or thread. Numbering follows the displayed chronological cards. The request captures its account, message and attachment identities before starting the worker. The rest of the command is a literal destination path, including spaces; quotes, variables and shell expressions are not interpreted. Decoded base64url bytes must match both declared and displayed sizes, within 2 MiB. The worker creates a mode-0600 file exclusively, refusing existing files or leaf symlinks. It never derives an output path from the attachment's filename. Success or failure remains visible without replacing the reader or local draft.

## Loading, status and view identity

The global frame uses four rows: mode/account header, colored sync state, one
context-sensitive shortcut line, and action/error status. Compact fitting drops
brand/Experimental/layout decoration before account or Mock identity. Synced
time is a fixed local timestamp rather than a frozen relative age. The Linux
timezone snapshot is loaded once at startup from `TZ`/`TZDIR` or
`/etc/localtime`; bounded native TZif transitions and POSIX footer rules apply
the offset at each displayed instant, independent of linked libc. Unavailable
local rules produce an explicitly labeled UTC fallback. Backend/cache/CLI
epochs and scheduling clocks remain unchanged. Unknown
send/RSVP outcomes and completed action notices remain protected; obsolete
view-local hints/errors clear when their owner mode/account/selection changes.
Known errors use plain labels, with stable diagnostic codes available in Help.
Status storage is UTF-8-safe and bounded to 256 bytes.

Cached mail remains navigable during refresh. An uncached incoming window keeps
the old focused card and reader while showing provisional metadata beneath it.
`loading.zig` owns 32 immutable row slots with bounded copied subject/sender/
snippet/date fields and 512-byte body excerpts. Missing metadata animates until
actual callbacks publish it; body-ready publications replace pending excerpts.
Counters report real completed/known batch units rather than estimated mailbox
size. Provisional IDs never receive mouse hits before the authoritative window
commits. Account/query/selection generations and worker joining protect every
mailbox replacement. The read-only network worker never blocks the main input
handler or account-scoped contact/cache navigation.

### Display timezone bounds

The source-only display helper accepts IANA names, absolute TZif paths and
explicit POSIX rules in `TZ`; an explicitly empty `TZ` means UTC. Sync and
single-message metadata use full stamps with an abbreviation (CET/CEST, for
example). Lists and compact thread-card headings use `MM-DD HH:MM`, with the
same conversion. Fractional offsets and local date rollover apply consistently.
Snapshot files
are capped at 128 KiB, 4,096 transitions and 256 local types. Lookup performs no
per-frame file reads or TZif parsing, and does not mutate libc timezone globals.
Unsupported/malformed zones, leap-clock TZif data and unspecified tail ranges
visibly use `UTC (TZ unavailable)`. Changing the system zone while the TUI is
running requires restarting it. Cache/JSON epochs, deadlines and RFC/iTIP wire
dates retain their existing UTC meaning.

## HTML-only body layout

`html_document.zig` filters semantic blocks and styled spans; `html_view.zig`
wraps them with libvaxis grapheme widths and clips drawing to the viewport.
Headings, emphasis, lists, quotes, code and bounded data tables use Omarchy
colors rather than mail-authored CSS. Layout tables flatten. Remote resources,
script execution and terminal hyperlinks are unsupported.

Preparation owns a document arena per displayed message; a separate layout
arena is reused until the pane width or terminal width method changes. Scrolling
and color reloads reuse the document/layout. Structural and layout budgets refuse
excess complexity with the existing complete plain conversion as fallback.

MIME records which nonempty alternative supplied `bodyText`, preserving the
plain-text converter and reply behavior. An old cache without provenance is
eligible for styled HTML only when its stored text equals the sanitized legacy
HTML conversion. This cannot resolve an old plain alternative identical to that
conversion, but requires no network request or cache rewrite. Full-body hashes
remain valid; new metadata strips body provenance with the body itself.

## Mouse input

The renderer records a bounded map of visible hit rectangles each frame. Mouse
reports use SGR cell coordinates, matching the layout even when the physical
terminal is wider than the 240-column application viewport. Wrapped accounts,
mailbox rows, two-line message cards and contact rows share their drawn bounds;
separators, borders and empty areas have no action.

Unmodified left presses use the existing cache-first keyboard actions. Wheel
navigation follows the hovered pane. Modified/right clicks and idle motion do
not change the view. Ordinary selection clicks do not send or mutate mail;
the label picker's explicit Add/Remove buttons invoke its capability-checked
label operation, just like Enter/`-`. Attachment controls change only the local
draft or open an explicit save prompt.
Tracking uses 1002 button-motion plus 1006 cell coordinates, with focus reports.
After disabling 1003 any-motion, Omagma reasserts 1002 for multiplexers whose
single tracking mode is cleared by 1003l. Tracking is disabled while the external
editor owns the terminal, restored on return, then disabled on exit. `--no-mouse` disables tracking and
ignores injected mouse reports as well.

## Keys and text input

| Keys | Browsing action |
| --- | --- |
| `j` / `k`, Down / Up | Move or scroll the focused pane |
| `h` / `l`, Left / Right, Tab / Shift+Tab | Change pane focus |
| `gg` / `G`, Home / End | First/last loaded item or reader position |
| Ctrl+D / Ctrl+U, PageDown / PageUp | Move by half a page |
| Enter | Open mailbox, thread, draft or contact |
| `[` / `]` | Explicit previous/next window; automatic boundary scrolling also uses cached neighbors |
| `/`, `\` | Search retained cache / search Gmail on the server |
| `1` / `2` / `3` | Select an existing configured account |
| `J` / `K` in reader | Next/previous mail, including cached-window boundaries |
| `{` / `}`, `t`, `Q` / `S` | Thread card navigation/fold, quote/signature fold |
| `L` / `B` | Links / received-file picker |
| Space / Ctrl+A, Ctrl+Z | Select one/window, selective undo |
| `z` | Expand/restore reader |
| `c`, `r`, `R`, `F` | Compose, reply, reply-all, forward with bounded attachments |
| `a` | Contacts; `n` creates and `e` edits |
| `s`, `u` | Toggle star or unread |
| `x`, `D`, `U` | Archive, confirm Trash, restore |
| `m` | Pick an existing label; `/` filters, Enter adds and `-` removes |
| `I` | Review an invitation reply |
| `o` | Open selected mail in its configured browser profile |
| Ctrl+R, Ctrl+L | Refresh, redraw |
| `?`, Escape / `q` | Help, back; quit from the mailbox screen |
| Ctrl+C | Cancel active work; quit when idle |

The provider checks capabilities and returns visible rejection errors. Legacy and enhanced keyboard input accept shifted `R`, `G`, `D`, `U` and `I`. `gg` clears on an unrelated key or after 750 ms. Help uses grouped key/action rows, fits the usual terminal height and scrolls with `j`/`k`, arrows, PageUp/PageDown or Ctrl+U/Ctrl+D when narrower; Home/End reach its ends. Mouse interaction is supported: click accounts, mailboxes, messages and contacts, and scroll the pane under the pointer with the wheel. Incoming provisional loading rows stay noninteractive until committed. Selection clicks never send mail or apply mailbox/contact changes; `--no-mouse` keeps mouse handling in the terminal.

Compose starts in normal mode. Tab/Shift+Tab focuses fields and controls;
`j`/`k` selects To/Cc/Bcc/Subject/body. `i` or Enter enters text insertion in a
field, Enter activates a focused control, and Escape returns to normal mode.
Arrow movement and deletion operate on grapheme boundaries. The body wraps and
follows the caret using visual rows, including a paragraph with no newline.
Recipient and subject fields scroll horizontally while editing, preserving
their labels and visible caret. At 90 columns or more, the form shares the
screen with the selected preview. From initially uses the selected account;
verified send-as aliases remain within that account and can be chosen
explicitly. The contact picker adds one address to the selected recipient field,
using To when opened from subject/body.

Fresh TUI compose/reply/reply-all/forward drafts use Markdown, while reopened
drafts retain their persisted format and older drafts remain plain. Ctrl+T
changes format without rewriting source. Normal compose `p` selects the rendered
outgoing preview, original reply/forward context or plain alternative. Below
90 columns it opens the preview full-screen; Escape/`q` returns to source. One
retained preview per draft revision shares the native backend renderer; raw HTML
and remote images stay inert. Known fenced languages receive bounded lexical
colouring. The embedded approved logo, volcano emoji and public-link footer are
generated content, with no remote fetch. CLI source keeps its plain default and
can explicitly select Markdown and request `draft.preview`.

Normal compose `A` opens the compact file popup with a literal path field.
Tab/Shift+Tab traverses its controls and Enter activates the focused control;
Ctrl+F completes the path. Only regular files qualify; there are up to 16
attachments, at most 2 MiB of combined attachment bytes and a 3 MiB serialized
request cap. A shared file helper opens with Linux `O_NONBLOCK|O_NOFOLLOW` and
validates the same descriptor before reading, rejecting FIFOs, devices and leaf
symlinks. The CLI's attachment/body/draft/contact file options use the same
helper; explicit stdin remains a stream. Paths are not shell commands or
expanded variables. Attachments use their basename and `application/octet-stream`;
review lists names and sizes. Existing attachments survive draft editing and
`$EDITOR` return. `:detach NUMBER` removes a one-based attachment before saving
or submission.

Native path completion scans at most 4096 directory entries and retains at most 64 matching regular files/directories. Hidden entries appear only for a dotted prefix; symlinks and special files are excluded. Ctrl+F extends a common prefix or cycles a chosen path, Ctrl+Shift+F cycles backward, and Ctrl+U clears the path. Directory names retain a trailing slash; no input variable or shell syntax is expanded. Received-save defaults use XDG user-dirs Downloads or literal HOME/Downloads and a sanitized, fresh collision name. Default directories are created owner-only only after explicit Save. Parent directory descriptors are opened one component at a time without following symlinks; mode 0600 exclusive file creation and cleanup use that checked descriptor.

Composer normal-mode preview scrolling and L/B pickers preserve its mode, account, body and outgoing files. Insert mode leaves those letters as text. A preview action that interrupts an in-flight local autosave queues a new local save rather than dropping the dirty revision. Body caret measurement and painting share the same complete-text word-wrap walker, including the virtual caret's width.

Bracketed paste inserts data into the active field and cannot invoke navigation, commands or submission. Mail and locally edited text pass through a renderer filter for C0/C1, Escape and bidi controls. Only the renderer emits terminal control sequences. An individual displayed grapheme is bounded to 128 bytes. Draft bodies are bounded to 2 MiB; headers, recipients and requests use the shared operation limits.

## Drafts, contacts and explicit submission

The shared recipient/threading planner creates replies and reply-all drafts. The UI edits To/Cc/Bcc, subject and body without duplicating its address or self-alias rules. Escape or `q` from normal compose saves the local draft and returns to the mailbox. After a 1.5-second idle debounce (or 10 seconds of continuous edits), autosave writes a local recovery revision without blocking input or sending mail. It retains incomplete recipient text, restores it on reopen, and requires validated fields before review/submission. Autosave completion updates only identity/revision state and cannot overwrite newer input.

Ctrl+S or `:send` saves a draft and opens **Review send**. Review exposes account,
From, recipients, subject, format, thread context, attachments and the outgoing
rendered body; its explicit `y` submits. Markdown submission uses the reviewed
HTML plus semantic plain alternative, retaining the source in its saved draft.
Editor save, ordinary Enter, paste, preview/format changes and navigation never
send. Explicit save/review owns a fixed validated revision; mutations to that
pending review are rejected. Debounced autosave instead permits continued
editing and queues newer local revisions. Fixture submission says **Saved by mock
provider**. Successful submission does not assert recipient delivery.

An unknown or interrupted submission retains its operation identity and original recovery draft. The form is protected from edits or retry, and `q` returns to mail without rewriting it. Reopening a saved draft checks the operation journal before enabling review; `:receipt` checks again. Stable error codes explain rejection or uncertainty without exposing raw provider responses. RSVP submission also blocks duplicate status keys while busy, retains the inspected message identity and protects an interrupted result. The backend journal remains authoritative across process restarts.

Contacts are account-scoped. Search matches names and addresses; create/update is supported, deletion is not. The current count names available cached entries, and both rows of the selected name/address card share a highlight. The two-field Name/Email form creates or edits a contact and sends its expected etag. A rejected or conflicting write preserves the attempted form. There is no cross-account fallback.

Invitation review keeps its captured account, attendee and organizer in a fixed header. Event, start, UID and recurrence details scroll with `j`/`k`, arrows, PageUp/PageDown or Ctrl+D/Ctrl+U; Home/End reach the ends. The response controls remain visible. If the terminal cannot fit the identity header and controls, confirmation is blocked until it is resized. The shared `invitation.inspect` operation validates the account and its verified aliases, so preview and submission use the same invitation rules. Submission uses the retained inspected account/message, sends an RSVP email and makes no claim to update Google Calendar.

## External editor

There is **no tmux dependency or launch**. The built-in split composer is available now. `$EDITOR` uses full-terminal takeover and restoration. `editor-mode=auto|takeover` selects this path; `embedded` returns `EmbeddedEditorDeferred` before entering raw mode.

The pinned graph exports a PTY-backed `vaxis.widgets.Terminal`, but source inspection found defects that prevent using it as the default arbitrary editor pane:

* `Terminal.resize` replaces screen storage without resetting its backing-screen pointer.
* `Screen.Cursor.uri` and `uri_id` default to undefined although printing reads them.
* Its process-global SIGCHLD handler locks a terminal map and calls `waitpid(-1)`, risking unrelated-child reaping, blocking and registration races.
* Teardown terminates one PID and awaits a reader without a clear bounded process-group lifecycle.
* OSC/APC/CSI and per-cell grapheme storage lack the application's explicit caps; raw control logging can expose private editor data.
* Enhanced key encoding treats nonzero Kitty flags as unreachable, and the input union does not provide a complete paste contract.

These findings require a separate terminal isolation effort. This implementation does not vendor or repair that VT engine, add libghostty, or imply embedded compatibility from the existence of a PTY. [Pinned widget](https://github.com/rockorager/libvaxis/blob/6fd944a27fb3d6f596e981076381a3131f2448b4/src/widgets/terminal/Terminal.zig), [VT example](https://github.com/rockorager/libvaxis/blob/6fd944a27fb3d6f596e981076381a3131f2448b4/examples/vt.zig).

Resolve nonempty `$EDITOR`, then `$VISUAL`, then a discovered `nvim`, `vi` or `nano`. Parse bounded quoted arguments directly; append the private body file as one argv element. There is no shell evaluation or command substitution. Malformed commands produce a visible error. Omagma-authored runtime helpers remain Zig.

The editor gets an owner-only random directory and mode-0600 body file. Nonblocking readback validates the opened descriptor and rejects symlinks, nonregular files, extra links, oversized content, invalid UTF-8 and NUL; a FIFO substitution cannot stall restoration. Stop/join TUI input, reset terminal features/alternate screen and restore original termios before spawning. The owned editor process group gets foreground control of the existing TTY. Parent Ctrl+C/Ctrl+backslash handling leaves those keys to the editor. After exec, the parent temporarily uses kernel `SIG_IGN` for SIGTTOU while restoring foreground ownership; a caught no-op does not satisfy the background-process rule. The child retains its normal disposition. Wait for that exact child, restore foreground control, raw mode, alternate screen and detected features, then query size and redraw. Returned body ownership transfers directly into the draft before fallible restoration. [Foreground process-group rules](https://man7.org/linux/man-pages/man3/tcsetpgrp.3.html).

Normal and nonzero editor exits reload bounded text and save the local draft, returning to compose without submission. Termination cancels/reaps the owned child group and retains readback text when valid. Transient files are removed on successful readback; rejected readback preserves the owner-only recovery file. External editor memory is measured separately from Omagma.

## Operations and ownership

The entry point is:

```zig
pub fn run(io: std.Io, allocator: std.mem.Allocator,
    client: types.Client, options: types.Options,
    environ: *const std.process.Environ.Map) !html_view.Stats
```

`Client.call` accepts canonical JSON and returns a caller-owned response. The UI owns focus, loaded views, editing buffers and terminal lifecycle. The common layer owns identities, MIME, cache, pagination, recipients, drafts, contacts and provider side effects. [Operation contract](TERMINAL-VERIFICATION.md).

One owned worker calls the client. There is one coalesced pending list/read request and one pending compose intent, rather than an unbounded action queue. A queued reply captures its account and original message ID, even if the cursor subsequently moves. Account/query/page generations reject old views; selection generations reject old previews. Account changes cannot interrupt a pending mutation. Completion notifications coalesce when the event queue already wakes the UI. Shutdown cancels and joins work before freeing its state, saving valid active draft edits on EOF or termination.

Separate arenas own account, list, selected reader, contact, job and frame data. Replacing a view resets its arena; the frame arena resets every render. Persistent text never points into render or input scratch. Dynamic terminal allocation uses the supplied 64 MiB bounded allocator. The existing 16 MiB fixed backend/HTTP reservation is accounted separately; all top-level mutable UI globals are declared through `reservation_bytes`. The bar's memory results do not qualify this new terminal client.

The outer UI blocks while idle and redraws on input, resize or worker completion. During active read-only loading, one owned finite timer wakes at 180 ms for placeholders; it stops and joins on completion, cancellation, view replacement or shutdown. Autosave has a separate finite debounce wait while a dirty draft is active. It installs/uninstalls the pinned resize handler explicitly. Normal exit, error, input EOF, termination and editor return restore original termios and terminal features. Panic recovery uses the application's compatible Zig 0.17 `FullPanic` wrapper. No detached tasks outlive the application and no `Io.Timeout.none.sleep` is used.

## Verification

Use fictional fixtures and private PTYs only, with current-cell reconstruction rather than historical escape-stripped output. Verify more than 30 reachable rows, pagination, account/search isolation, chronological full bodies, inert mail controls, recipient fields, contacts, explicit submission and unknown/rejected outcomes. Exercise long wrapped bodies and long Unicode headers with a visible caret, attachment digests and refusal to overwrite, wide, medium, narrow and very small sizes, repeated Unicode resizes, and exact termios restoration on quit, errors and signals.

Editor qualification checks quoted direct argv, controlling-TTY foreground ownership, save, nonzero exit, cancellation, file bounds, owned-child cleanup and no automatic send through persisted fixture counters. Keep live mail, desktop surfaces and installed configuration outside these tests. Acquire the [cooperative host reservation](VERIFICATION.md#cooperative-host-measurement-lock) before builds or runtime suites. Runtime evidence must identify the actual binary, exact compiler and optimize mode; source inspection and compilation alone do not establish these behaviors.
