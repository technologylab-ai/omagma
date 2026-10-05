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

Use exact Zig 0.17.0. Correctness receipts identify the binary-reported `debug` or `safe` mode; memory receipts identify `safe`. Python/Node and PTYs are development tools only. All runtime helpers remain Zig.

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

### Final source qualification

On 2026-10-05, Omagma 0.2.0 at source revision `7568a2467b5a93142259bc50057a177c3acf7150` passed the following suites with exact Zig 0.17.0. Each receipt verifies the binary's own compiler, optimization mode and SHA-256.

| Suite | Debug | Safe |
| --- | ---: | ---: |
| CLI behavior | 42/42 | 42/42 |
| Isolated PTY workflows | 19/19 | 19/19 |
| Independent loopback wire checks | 7/7 | 7/7 |

The Debug binary SHA-256 is `79d85ca3a22ccd4d80f2ffbcdf57e688876c6d32c279a831b98767ab22100e65`; the stripped Safe binary SHA-256 is `046b6bd5ee929c6a47b576c091b6266316bce591e978fd09719cc3540b341279`. Local receipts are named `terminal-queue-{cli,pty,wire}-{debug,safe}.json` under ignored `tests/results/`. The fixture checker separately passed 12 checks; six helper checks verify the bounded terminal cell model. That model checks current rendered field positions and the renderer's escape sequences, and is not a complete terminal emulator.

CLI checks cover three-account pagination, a decoded body at the 2 MiB limit, MIME refusal without damaging another cached message, cache identity and mock/live namespace isolation, lowered limits after restart, and machine-readable framing under oversized input and stdout backpressure. Draft, send and RSVP receipts survive restart and cache clearing. An uncertain payload submitted with a new operation ID returns the original receipt without another provider call or recovery draft; that draft cannot be changed or discarded. Sent unread/star/trash state agrees across reads, lists and threads, then survives clearing, restart and restoration.

File checks reject symlinks, public permissions, FIFOs and directories used as cache index/lock files. All four CLI file-input options reject FIFOs and leaf symlinks promptly. The atomic replacement check independently verifies that old and new logical file bytes count toward the quota. Its additional 1 ms directory-size samples can miss a short transient; sampling is not the sole quota oracle.

PTY checks cover editor save, cancellation and failure; terminal restoration; explicit send review; uncertain-send reopening; contacts; account/page navigation; long RSVP identity review; and draft retention on SIGTERM. Long Unicode fields preserve the exact expected 2,349-byte draft, and eight deliberately fragmented UTF-8 inputs preserve every code point. Attachment tests compare bytes and digest, preserve outgoing attachments through save, refuse overwrites and relative incoming destinations, and reject FIFO attachment/editor readback without blocking. Every case exits cleanly with terminal settings restored; only explicit confirmation submits synthetic mail.

The loopback peer compares the complete 131,072-byte POST JSON and headers with an independent oracle. It accepts a 614,424-byte response, rejects redirect forwarding and declared/chunked responses above 3 MiB, and observes zero TCP connections for an oversized outgoing request. Stalled and trickled responses both hit the internal 10,000 ms deadline: observed wall time was 10.01–10.02 seconds in Debug and 10.006–10.008 seconds in Safe. These checks use a fixed synthetic bearer and no Google endpoint.

### Memory and quiet windows

Both sequential Safe acceptance runs passed after 100 warmup cycles and 1,000 measured cycles. CLI cycles issue eight page requests and a full read, with periodic complete-thread reads; TUI cycles switch accounts, page forward/back, select a message and reload. All three fictional accounts are exercised. Each workload is followed by 60 seconds without commands or keys.

| Observation | CLI | TUI |
| --- | ---: | ---: |
| Warm median RSS / PSS (KiB) | 7,000 / 7,000 | 8,536 / 8,528 |
| Warm RSS / PSS / private growth (KiB) | 0 / 0 / 0 | 0 / 0 / 0 |
| Sampled peak RSS / PSS (KiB) | 10,672 / 10,672 | 12,076 / 12,068 |
| OS RSS high-water (KiB) | 10,768 | 12,400 |
| Maximum observed threads | 1 | 5 |
| Terminal heap peak (bytes) | 7,235,433 | 7,617,129 |
| Rejected allocations | 0 | 0 |
| Quiet duration (seconds) | 60.0009 | 60.0013 |
| Quiet CPU, percent of one core | 0 | 0 |

Warm first/last-quarter RSS and PSS medians must grow by at most 4 MiB, and quiet CPU must remain below 0.5% of one core. Both passed without changing thresholds. The TUI emitted no bytes during its quiet window. Receipts are `terminal-queue-cli-safe-measure.json` and `terminal-queue-tui-safe-measure.json`; process sampling is every 50 ms and CPU is measured in Linux process clock ticks.

The 64 MiB ceiling applies to the capped terminal heap. The existing 16 MiB fixed backend/HTTP reservation is reported separately. Linux RSS/PSS sample the whole process, including resident fixed storage, stacks and libraries; the heap meter does not count those globals. These runs set no absolute RSS/PSS ceiling and do not reuse the bar's qualification.

### Preserved failures

Earlier failed receipts and escaped synthetic VT captures remain unchanged in ignored local results. Application fixes addressed an `O_PATH` directory passed to `fchmod`, editor job-control restoration and readback ownership, and an unnecessary immutable-body rewrite that exceeded the atomic replacement quota. The long-field test independently found one emoji dropped across a 1,024-byte input boundary; the bounded UTF-8 carry adapter now passes the unchanged exact-content oracle. Its first queue implementation then caused a startup stack-probe fault from a large initialization temporary. In-place initialization and small entries owning capped heap text corrected that fault; the final 19-case suites pass in both modes. Two harness waits were also corrected to wait for loaded search results and the actual pane instead of matching help text. None of these failures justified weakening acceptance limits.

Live gates remain separate: authorization upgrades, real Gmail paging/MIME/thread behavior, People read/write conflicts, actual send outcomes and delivery of invitation replies. Fixture tests cannot establish provider deduplication or successful recipient delivery. No real mailbox, contact or invitation is changed by these tests.
