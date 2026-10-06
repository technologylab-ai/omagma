# Terminal and agent verification

Developer qualification reference, not an installation checklist. Start with [development](DEVELOPMENT.md) for focused local checks; users connect their own accounts through [setup](SETUP.md#full-tuicli-permissions). Fixtures, Python/Node, isolated PTYs and offscreen GUI tests are development tools only. The TUI/CLI remain experimental. Source changes after published v0.2.4 require their own candidate correctness checks; they do not inherit earlier release/memory results. [Native Linux/macOS release 0.2.4](evidence/terminal-0.2.4.md) records its final artifacts and deployment checks. [cache-first 0.2.2](evidence/terminal-0.2.2.md), [HTML 0.2.3](evidence/terminal-0.2.3.md) and [mouse/release 0.2.3](evidence/terminal-0.2.3-mouse.md) retain exact checkpoint identities. Existing bar thresholds and all dated evidence remain unchanged.

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
| Labels and trash | Per-message outcomes expose rejection/uncertainty; selective undo restores only touched labels; trash is reversible; permanent deletion and label-definition CRUD remain unsupported |
| Contacts | Read/search/create/update stay account-specific; stale versions fail without overwriting a newer contact; deletion is unsupported |
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

The following is the broader correctness qualification inventory. For a reversible local UI change, select the focused suites that exercise it and stop when those checks pass; [development](DEVELOPMENT.md) covers that shorter loop. Reserve heavy workloads before running them:

```sh
python3 tests/terminal_fixture_check.py
python3 tests/terminal_cache_fixture_check.py
python3 tests/terminal_status_screen.py
python3 tests/terminal_reader.py
python3 tests/terminal_html_screen.py
python3 tests/terminal_html_fixture_check.py
python3 tests/terminal_repaint_screen.py
python3 tests/terminal_mouse_screen.py
python3 tests/terminal_cache.py --binary zig-out/bin/omagma --build-mode debug
python3 tests/terminal_ui.py --binary zig-out/bin/omagma --build-mode debug
python3 tests/terminal_cache_max.py --binary zig-out/bin/omagma --build-mode debug
python3 tests/terminal_background.py --binary zig-out/bin/omagma --build-mode debug
python3 tests/terminal_integration.py --binary zig-out/bin/omagma --build-mode debug
python3 tests/terminal_pty.py --binary zig-out/bin/omagma --build-mode debug
python3 tests/terminal_transport.py --binary zig-out/bin/omagma --build-mode debug
```

`tests/terminal_html.py --binary PATH --build-mode debug|safe` checks native HTML-only rendering with fictional mail, MIME alternative preference, legacy cache compatibility, responsive tables/styles, control filtering and retained parse/layout reuse. It uses owned PTYs and no installed desktop window.

`tests/terminal_repaint.py` checks physical clearing and reflow with preserved terminal cells; `tests/terminal_mouse.py` checks actual SGR clicks, wheel navigation, contacts, disabled mouse and editor lifecycle. Both use owned isolated PTYs, with no desktop focus changes.

Repeat correctness suites with a separately built Safe executable. Cache checks use held-provider barriers to prove that local reads and navigation finish before a delayed network reply. UI checks inspect current terminal cells, pane geometry, theme colors, search provenance and Back behavior. The maximum-cache workload seeds 2,000 metadata records and verifies exact newest-tail retention, immutable-body hashes, quota accounting and capped-heap behavior after additions and deletions. Background checks use isolated native one-shots rather than installing a user timer; they cover lease coalescing, age policy, read-only access, cancellation and unsafe lock-file rejection.

## Focused local-source regressions

These owned-PTY/backend checks cover the post-release source features. Select
only the cases relevant to a change and use the explicitly built local binary:

```sh
python3 tests/terminal_wishlist_backend.py --binary /path/to/local/omagma
python3 tests/terminal_cache_windows.py --binary /path/to/local/omagma
python3 tests/terminal_scroll_progress.py --binary /path/to/local/omagma
python3 tests/terminal_loading.py --binary /path/to/local/omagma
python3 tests/terminal_local_ui.py --binary /path/to/local/omagma
python3 tests/terminal_polish_status.py --binary /path/to/local/omagma
python3 tests/terminal_polish_reader.py --binary /path/to/local/omagma
python3 tests/terminal_polish_compose.py --binary /path/to/local/omagma
```

Held fixture checkpoints prove cached navigation/contact access while real
synthetic metadata/body batches remain incomplete. Current-cell reconstruction
checks provisional-row ownership, actual fractions, bounded animation, compact
row capacity, word wrapping/caret placement, Back/search restoration and
attachment path completion. A passing Linux PTY does not establish a physical
Mac touchpad gesture, compositor placement or remote terminal integration.
Source-only documentation changes need link/privacy/syntax checks, not these
runtime suites.

## Release resource qualification

Run memory/quiet gates when qualifying a release or investigating a resource
regression, not after every local visual edit. Use a separately identified Safe
artifact and hold the cooperative reservation through all cleanup:

```sh
python3 tests/terminal_measure.py --binary /path/to/safe/omagma --kind cli
python3 tests/terminal_measure.py --binary /path/to/safe/omagma --kind tui
```

Developer live-write qualification uses a dedicated disposable test mailbox,
separate explicit authorization and private receipts. Normal users need neither
a test mailbox nor fixture qualification to authorize/use their own accounts.
Fixture success cannot establish recipient delivery, Google grant policy,
Calendar state or provider-side idempotency.

## Historical qualification records

The sections below preserve their recorded release checkpoints. Later source
changes, deployment and tests do not retroactively change these results or the
pending-state statements that were true at each checkpoint.

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

### 0.2.1 incoming-address patch qualification

The bounded live read-only check of downloaded 0.2.0 exposed two incoming-header failures: a delivered Reply-To with a 65-byte ASCII local part and a To header with more than 32 participants. Fictional regressions independently failed before the patch. Version 0.2.1 separates incoming header storage from outgoing envelope limits: bounded incoming lists preserve up to 1,024 participants per header within the existing header byte budgets, and addresses up to 254 bytes, while outgoing envelopes retain 32 recipients and a 64-byte local-part limit. Reading an address does not permit sending to it; an oversized reply-all is refused explicitly.

On 2026-10-05, source revision `858ce32d21625a136fbed102d265e97bb95b0a48` passed 45/45 CLI cases, 19/19 isolated PTY cases and 7/7 loopback wire checks in both Debug and Safe, using exact Zig 0.17.0 on Linux x86_64. The fixture checker passed 13 checks and the terminal cell model passed six. The Debug SHA-256 is `f6c6106fef5b1817ac8b572f981f7fe0f5d7a5062407f7f60a3970998be35723`; Safe is `4e936b367cdd6dd9ed5eac71ead732cb3b5f301cc047753ad8d5144b58b6e511`. Receipts are named `terminal-v021-{cli,pty,wire}-{debug,safe}.json`; all earlier receipts remain unchanged.

Three added CLI cases use [fictional incoming headers](../tests/fixtures/terminal/inbound-addresses.json) in temporary copies of the existing corpus. They prove that 34 recipients and a 65-byte Reply-To local part remain intact across list/read/thread operations in three accounts. An ordinary reply selects one valid sender, oversized reply-all fails without truncation, and an invalid outgoing Reply-To fails without an orphan draft. Separate boundary checks accept 32 outgoing recipients and a 64-byte local part, then reject 33/65 before any provider call or submission journal entry. The default 96-message/account corpus and measurement workload are unchanged.

Both Safe 1,000-cycle acceptance runs, with 100 warmup cycles and separate 60-second quiet windows, passed unchanged thresholds:

| Observation | CLI | TUI |
| --- | ---: | ---: |
| Warm median RSS / PSS (KiB) | 6,932 / 6,932 | 8,180 / 8,172 |
| Warm RSS / PSS / private growth (KiB) | 0 / 0 / 0 | 0 / 0 / 0 |
| Sampled peak RSS / PSS (KiB) | 10,628 / 10,628 | 11,728 / 11,720 |
| OS RSS high-water (KiB) | 10,644 | 12,032 |
| Maximum observed threads | 1 | 5 |
| Terminal heap peak (bytes) | 6,692,585 | 7,619,937 |
| Rejected allocations | 0 | 0 |
| Quiet duration (seconds) | 60.0007 | 60.0006 |
| Quiet CPU, percent of one core | 0 | 0 |

The TUI emitted no bytes during its quiet window. These observations retain the separate 64 MiB terminal heap ceiling and 16 MiB fixed reservation accounting described above; they establish no absolute RSS/PSS ceiling. Local receipts are `terminal-v021-cli-safe-measure.json` and `terminal-v021-tui-safe-measure.json`.

An explicitly authorized private live read-only smoke against this Safe binary then passed for all three configured accounts: two pages totaling 40 messages each, mismatched account/query cursor refusal, one full message and its thread, and consistent unread state across reads. It used existing bar read-only credentials with an absent terminal grant registry and an isolated temporary cache. It issued no mutation or explicit attachment-download commands; decoding may fetch required external MIME body parts. All children were joined/reaped and the temporary mail cache was removed. Only anonymous counts, fixed status codes, build identity and the binary hash were retained in an owner-only private receipt. Failed 0.2.0 live receipts remain preserved privately; no mail, account identities or raw headers are published. This limited smoke does not exhaust Gmail MIME/thread variants or qualify terminal write permissions.

Live gates remain separate: authorization upgrades, real Gmail paging/MIME/thread behavior, People read/write conflicts, actual send outcomes and delivery of invitation replies. Fixture tests cannot establish provider deduplication or successful recipient delivery. No real mailbox, contact or invitation is changed by these tests.

### 0.2.1 native CI and downloaded release

[Release CI run 37258436358](https://github.com/technologylab-ai/omagma/actions/runs/37258436358) passed native Linux x86_64 and arm64 qualification with exact Zig 0.17.0. The v0.2.1 publication/tag revision is `b8d25227681090a9be0d8364330e8115bb672ffb`; its runtime remains the qualified `858ce32d21625a136fbed102d265e97bb95b0a48` source described above. Publication changes did not alter runtime bytes.

| Native CI platform | Debug | Safe |
| --- | --- | --- |
| Linux x86_64 | 45/45 CLI, 19/19 PTY, 7/7 wire | 45/45 CLI, 19/19 PTY, 7/7 wire |
| Linux arm64 | 45/45 CLI, 19/19 PTY, 7/7 wire | 45/45 CLI, 19/19 PTY, 7/7 wire |

Both native platforms also passed separate Safe CLI and TUI 1,000-cycle/60-second quiet gates with unchanged thresholds. All four workloads had zero warm RSS/PSS/private growth, zero quiet CPU and no rejected allocations. The TUI quiet windows emitted no bytes. [The memory table](MEMORY.md#terminal-modes-021) records those CI process lifetimes separately from the local measurements.

The actual downloaded [v0.2.1](https://github.com/technologylab-ai/omagma/releases/tag/v0.2.1) x86_64 raw executable passed **45/45 CLI, 19/19 PTY and 7/7 wire checks** in Safe mode. Its SHA-256 is `4e936b367cdd6dd9ed5eac71ead732cb3b5f301cc047753ad8d5144b58b6e511`, identical to both the locally qualified and native CI Safe executables. The published arm64 Safe SHA-256 is `6922dd901dda3b3d11becce72e8105ce12f7429b1739ea57fc569c07a76cf582`, matching its native CI receipts. Both architectures passed downloaded checksum/static/bundle/version checks. Native arm64 PTY coverage does not qualify arm64 desktop integration.

Downloaded receipts are `terminal-v021-downloaded-{cli,pty,wire}.json`; all previous receipts remain unchanged. A separate preflight receipt preserves the raw download's initial missing execute permission, corrected by adding owner execute permission without changing its bytes. Every owned test child, editor and HTTP peer thread was joined/reaped. No additional soak or private terminal live read was needed for the byte-identical x86_64 executable. Desktop deployment is pending at this checkpoint; release publication and artifact qualification do not claim installation.
