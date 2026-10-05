# Terminal mouse qualification, 0.2.3

Dated 2026-10-05. This records completed combined correctness checks and compilation. All 22 local combined gates passed; native release CI, publication and deployment are **pending**. The TUI and agent CLI remain experimental. The [pre-mouse HTML evidence](terminal-0.2.3.md) retains its original source and executable identities and is not mouse qualification.

## Source and executable identity

Runtime source: `a94d29d07d2370d140bb13bef21840ead90b6c65`. Test-only follow-up: `049ce53`. Package and manifest version: **0.2.3**. Exact compiler: **Zig 0.17.0**. Local execution: native Linux x86_64, baseline CPU, static musl.

- Debug SHA-256: `ff814bb2b010442e628e7320c33539897f4aa6686f4bf70d6aa6a0d951f7c0e7`.
- Safe SHA-256: `d3e2b67b194409543dcb09e2b0ae7a13fbce22297a0e5ba4d0e08e240bd79487`.

Debug and Safe each passed **240 unit executions**: 129 main, 41 codec and 70 provider. The no-TUI build passed **205 unit executions**; active main/probe entry points compiled. These are local compilation and focused-check results, not a completed release gate.

## Mouse behavior and boundaries

Mouse reporting is enabled by default and uses SGR cell coordinates. Clicks select accounts, folders and mail, open Contacts or local contact details, and select a recipient in the composer picker. The wheel acts on the pane under the pointer: mail/Contacts selection and reader scrolling remain distinct. `--no-mouse` leaves handling to the terminal and ignores injected mouse reports while retaining keyboard navigation.

Hit targets come from the current bounded layout and visible rows. Borders, blank separators, release/motion reports, unsupported buttons and modified clicks do not trigger selection actions. A click cannot submit, discard or trash mail, apply a contact change, or bypass an explicit confirmation. No continuous idle-pointer tracking is enabled. Reporting is disabled while an external editor owns the terminal, restored on return, and disabled on exit; terminal attributes are restored.

The existing account isolation, private cache policy, capability checks and explicit mutation review remain in force. Mouse support does not add a provider permission, consent flow or network worker.

## Completed focused checks

All checks used fictional accounts and isolated PTYs/caches. The mouse receipts identify the two binaries above and record zero provider mutations, zero fixture sends, unchanged contact state and operation journals, preserved immutable body hashes, and restored terminal state.

| Focused suite | Debug | Safe | Receipt filenames |
| --- | ---: | ---: | --- |
| Actual SGR mouse workflows | 5/5 | 5/5 | `mouse-fifth-debug.json`, `mouse-fifth-safe.json` |
| Layout, theme, cached navigation and Back/search | 5/5 | 5/5 | `ui-mouse-help-debug.json`, `ui-mouse-help-safe.json` |
| Editor/lifecycle PTY workflows | 19/19 | 19/19 | `pty-mouse-help-debug.json`, `pty-mouse-help-safe.json` |

The five mouse workflows establish:

1. Account, sender-row, mailbox and Contacts clicks work from disk cache while the original remote refresh remains held. Invalid reports leave selection unchanged.
2. Mail-row wheel movement and reader-only scrolling work in right/below layouts at 160×40, 100×30, 70×30 and 251×40. Reader scrolling keeps the same complete message; cell coordinates remain correct beyond the logical 240-column screen bound.
3. Clicking a contact's email row opens local fields. A picker click adds a recipient without reviewing or submitting a draft.
4. `--no-mouse` never enables reporting, ignores injected reports and preserves keyboard navigation.
5. External-editor handoff disables reporting and uses the cooked terminal. Return restores reporting, a subsequent composer-field click works, and exit restores terminal attributes.

The focused UI/PTY checks also retain the existing cached-reader, responsive layout, search/Back, editor cancellation, unsent-draft recovery, attachment, UTF-8 and FIFO safeguards. They do not establish new production write acceptance.

## Preserved failures and scope of findings

Earlier development receipts `mouse-first-debug.json` through `mouse-fourth-debug.json` preserve the held-fixture and mouse-layout failures. The first combined run, `mouse-final-v023-1-driver.json`, also remains failed rather than being relabeled after its UI/help oracle correction. The subsequent focused checks use the unchanged behavioral assertions and explicit fixture/terminal observations. Mouse helper and test-oracle issues are application/test findings, not demonstrated Zig compiler regressions.

Earlier HTML, cache and memory evidence is unchanged. In particular, the pre-mouse 235-unit binaries and their 1,000-cycle memory results cannot be attributed to the mouse binaries.

## Combined acceptance and release status

The **22-job** combined run `mouse-final-v023-2-driver.json` passed and reaped
all owned children. Existing workloads, application deadlines, allocator caps
and memory-growth/quiet-CPU thresholds remain unchanged. Native x86_64/ARM
release CI, downloaded artifact verification, publication and deployment remain
pending at this checkpoint; previous published artifacts remain immutable.

## Combined correctness and large-body gate

Both modes passed the complete combined workflow suites on these executables:
48 CLI, 12 cache, 5 UI, 1 maximum-cache, 6 background, 19 editor/lifecycle PTY,
7 wire, 7 HTML, 3 physical repaint and 5 mouse cases. Receipt prefix is
`mouse-final-v023-2`; the first interrupted combined run remains preserved.
The app runtime remains `a94d29d`; help scrolling changed test code only.

The exact 2 MiB HTML Safe gate completed 100 warmups, 1,000 measured navigation
cycles and 60.001 quiet seconds. It reached the complete fallback tail and
retained one document build, one layout attempt and one complexity fallback.
Heap peak was 56,049,942 bytes, rejected allocations 0; warm RSS/PSS growth -4 KiB,
OS RSS high-water 37,396 KiB and quiet CPU/output 0. Navigation took 101.0338 seconds.
The ordinary Safe CLI/TUI gates each completed 100 warmups, 1,000 cycles and
60 quiet seconds. CLI settled at 9,084/9,076 KiB RSS/PSS with 12,872 KiB OS RSS
high-water and 4,698,191-byte heap peak. TUI settled at 11,640/11,632 KiB with
14,864 KiB high-water and 5,273,534-byte heap peak. Both had zero warm growth,
quiet CPU ticks and rejected allocations; TUI emitted no quiet bytes.
The unchanged 2,000-message stress had 43,408 KiB OS RSS peak, 44,214,520-byte
heap peak and 1.477-second Safe refresh. The 64 MiB terminal heap and separate
16 MiB fixed reservation remain distinct from whole-process RSS/PSS.

## Local release bundles

Both architecture bundles passed normalized archive/privacy/checksum/version and
static ELF checks. Each contains 248 public tracked/bundle files, with private
configuration, credentials, caches and raw receipts excluded. The x86_64 native
smoke matches the qualified Safe SHA above. The cross-built arm64 SHA is
`60a189e11692461c85b0b0a8b3464f0bfe157fbb8a2d26ae315083998b99ab75`;
its local check reports `nativeSmokeTest:false`. Native ARM CI and publication
remain pending; cross-compilation is not desktop or native runtime evidence.
