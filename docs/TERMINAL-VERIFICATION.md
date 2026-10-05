# Terminal and agent verification

The terminal expansion is verified with fictional accounts and a mock provider before live authorization. This document records test contracts and remaining gates; it does not claim that unfinished tests passed. Existing bar memory thresholds and historical evidence remain unchanged.

## Fixture corpus

[The terminal fixtures](../tests/fixtures/terminal/README.md) contain 96 messages per account, eight pages per account, three-message threads, nested MIME, HTML-only messages, external body attachments, contacts and recurring invitations. The same opaque identifiers occur in all three accounts with different account-specific content. This makes routing by message ID alone fail visibly.

Provider fixtures follow the documented Gmail distinction between ID-only list responses and full message resources. Pagination tests follow returned tokens rather than treating `resultSizeEstimate` as an exact count. [Gmail list reference](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list), [message resource reference](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages).

## Behavioral gates

| Area | Required observable result |
| --- | --- |
| Account identity | Every CLI request names an account and every reply preserves it; identical IDs never expose another account's data |
| Pagination and search | More than 30 messages can be reached without duplicates; page tokens reject another account, query or stale cache generation |
| Bounded cache | Published metadata, body, disk and runtime limits hold across pagination, replacement, eviction and restart; clearing one account preserves the others |
| Reading | Complete decoded text and thread context are available; reading does not silently modify unread state |
| MIME | Quoted-printable, base64, charset and multipart behavior matches independent decoded expectations; external body parts are fetched correctly |
| HTML | Plain alternatives are preferred; HTML-only mail produces readable text without running script or loading remote resources |
| Attachments | Bytes match the expected digest; traversal filenames cannot escape the chosen destination |
| Terminal safety | Mail cannot inject cursor controls, clipboard OSC sequences, terminal hyperlinks or shell commands |
| Replies | Reply-To takes precedence; reply-all removes self and duplicates and never promotes Bcc; valid thread headers are retained |
| Drafts and editor | Create/update/read remain account-specific; editor argv is parsed safely, child failure preserves the draft, and editor content never becomes a shell command |
| Send | Explicit operation identity; replay is deduplicated, content conflicts are rejected, and unknown outcomes never trigger automatic resend |
| Labels and trash | Remote rejection restores the original state; trash can be restored; permanent deletion remains unsupported |
| Contacts | Search and writes stay account-specific; stale versions fail without overwriting a newer contact |
| Invitations | Reply status is accepted/tentative/declined; UID, organizer, sequence and recurring instance survive; only the selected attendee replies |
| Permissions | Missing read/write/send/contacts/RSVP capability rejects the operation before its provider side effect |
| CLI framing | JSON-lines output stays machine-readable, bounded and credential-free under malformed input and backpressure |
| TUI lifecycle | Split panes, focus, scrolling and editing work in an isolated PTY; terminal settings are restored after success, error, EOF and interruption |

Threaded sending requires the target thread ID and compliant reply headers with a matching subject. A missing original Message-ID must not produce a fabricated successful thread association. [Gmail threading guide](https://developers.google.com/workspace/gmail/api/guides/threads).

Contact updates must compare the contact source etag, preserving concurrent edits. RSVP examples use iTIP `METHOD:REPLY`, the replying attendee, the original UID/organizer and unchanged sequence; a recurring instance keeps its recurrence ID. [People update reference](https://developers.google.com/people/api/rest/v1/people/updateContact), [RFC 5546, section 3.2.3](https://www.rfc-editor.org/rfc/rfc5546.html#section-3.2.3).

## Execution and evidence

Use exact Zig 0.17.0. Correctness receipts identify the binary-reported `debug` mode; memory receipts identify `safe`. Python/Node and PTYs are development tools only. All runtime helpers remain Zig.

The agent CLI contract is one structured request and reply per line. Requests include `account`, `cmd`, optional `id` and command fields; replies include `version: 1`, the same account/id, `ok` and either `data` or `error: {code, message}`. The canonical invocation is `omagma cli --fixtures --fixture-root tests/fixtures/terminal --cache-dir <isolated-directory>`, with `omagma agent` as an alias. CLI mutations that send mail or RSVP require an operation ID and report `applied`, `rejected` or `unknown`.

Fixtures and temporary cache/editor directories are isolated from the user's HOME, XDG configuration, session bus and graphical display. PTY tests spawn their own terminal session and never send input to a user's terminal or desktop. Heavy builds, runtime tests and measurements require the [cooperative host lock](VERIFICATION.md#cooperative-host-measurement-lock), held until all owned children are reaped. Keep receipts under ignored `tests/results/` and preserve failures.

Development commands, after the appropriate build and host-lock reservation:

```sh
python3 tests/terminal_fixture_check.py
python3 tests/terminal_integration.py --binary zig-out/bin/omagma --build-mode debug
python3 tests/terminal_pty.py --binary zig-out/bin/omagma --build-mode debug
python3 tests/terminal_transport.py --binary zig-out/bin/omagma --build-mode debug
python3 tests/terminal_measure.py --binary zig-out/bin/omagma --kind cli
python3 tests/terminal_measure.py --binary zig-out/bin/omagma --kind tui
```

The fixture-only checker has passed 12 independent checks. A Debug build passed 28 CLI behavioral cases, including account isolation, configured cache eviction, corruption rejection, stdout backpressure, oversized-frame recovery and persisted operation deduplication. The initial failed startup receipt and subsequent passing receipts remain in ignored local results. The cache startup failure came from using an `O_PATH` directory descriptor with `fchmod`; opening that directory with `iterate = true` corrected the application.

The current Debug and Safe binaries both passed all 38 CLI cases. Checks cover strict input types, a valid decoded body at the 2 MiB limit, oversized quoted replies without orphan drafts, malformed MIME that preserves another valid cache entry, malformed reply identity, one-shot commands using the shared executor, readable sent mail across restart and cache clearing, and bounded binary draft attachments. Uncertain direct sends retain immutable recovery drafts and operation receipts through restart and cache clearing; completed drafts can be discarded. An identical uncertain payload submitted under a new operation ID returns the original receipt without another journal entry, recovery draft or provider call, including after restart. Unread/star/trash changes to sent mail agree across full reads, folder lists and threads, then survive cache clearing, restart and restoration.

The first twelve-case PTY run passed nine cases. External editor save and save-error failed on terminal restoration with `ProcessOrphaned`; a 66-byte readback allocation remained owned on that early error path. Corrected job-control handling and result ownership now pass both workflows, including complete terminal restoration and independently read persisted Unicode content. The mail-control case found an async search wait race in the harness, corrected to wait for the loaded mailbox before Enter. Failed receipts and escaped synthetic terminal output remain preserved.

The current thirteen-case PTY workflows pass in Debug and Safe. Debug ran twelve passing cases plus a targeted successful uncertainty-reopen case after correcting a harness predicate that incorrectly matched the mailbox footer's “Compose” help text; Safe passed all thirteen in one run. Gates cover editor save/error/cancellation, interruption, attachment review/persistence/detach, send review cancellation and explicit mock submission, contact creation, RSVP review cancellation, account/page navigation and active draft retention on SIGTERM. Reopening an uncertain submission retains the same durable receipt and blocks a fresh send review. The next fifteen-case suite adds long-field caret rendering and incoming attachment saving, with complete help text checked during navigation; these new checks await the next source snapshot.

Six independent development helper tests verify the terminal cell model, which checks current rendered composer field positions rather than retained output history. The model covers the escape sequences used by the renderer; it is not a complete terminal emulator. Receipts identify the actual backend compiler, mode and hash; syntax checks are not runtime acceptance.

The separate Safe measurement harness performs 1,000 complete pagination/full-read cycles or 1,000 TUI account/page/navigation/reload cycles, followed by 60 seconds without commands or key input. It samples Linux RSS, PSS, private memory, thread count and process CPU, requiring warm RSS/PSS median growth no greater than 4 MiB and idle CPU below 0.5% of one core. Actual terminal heap high-water is recorded against its 64 MiB ceiling; the existing 16 MiB fixed backend/HTTP reservation is reported separately. Linux RSS/PSS cover the whole process, including touched fixed storage, stacks and library allocations. The heap meter does not account for those fixed globals. The harness sets no arbitrary absolute RSS/PSS limit and does not reuse the bar's memory evidence. Measurement execution is pending correctness qualification and the coordinated Safe build.

Three additional CLI checks await the next snapshot: mock/live cache namespace separation for the same fictional account, finite refusal of symlink/public-mode/FIFO/directory index and lock files, and atomic replacement that includes both old and new logical file bytes in the configured quota. A sampled directory-size watcher complements the deterministic old-plus-new refusal check; its 1 ms samples can miss short transients and are reported with that limitation.

The terminal wire harness uses a separate loopback peer and a fixed synthetic bearer. It compares the complete 128 KiB POST JSON and HTTP headers with an independent oracle, accepts a valid response above the bar's 512 KiB cap, verifies redirects are never forwarded, measures the internal 10-second deadline with stalled and trickled responses, rejects declared and streamed responses over 3 MiB, and requires an oversized outgoing request to be refused before any TCP connection. It uses no Google endpoint or user token. Runtime qualification awaits the terminal probe modes in the next build.

Live gates remain separate: authorization upgrades, real Gmail paging/MIME/thread behavior, People read/write conflicts, actual send outcomes and delivery of invitation replies. Fixture tests cannot establish provider deduplication or successful recipient delivery. No real mailbox, contact or invitation is changed by these tests.
