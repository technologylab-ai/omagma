# Terminal mouse qualification, 0.2.3

Dated 2026-10-05. This records completed combined correctness checks and compilation. All 22 local combined gates passed. Native x86_64 and ARM release CI, publication, downloaded-artifact qualification and the installed x86_64 check are complete. The TUI and agent CLI remain experimental. The [pre-mouse HTML evidence](terminal-0.2.3.md) retains its original source and executable identities and is not mouse qualification.

## Source and executable identity

Runtime source: `a94d29d07d2370d140bb13bef21840ead90b6c65`. Test-only follow-up: `049ce53`. Package and manifest version: **0.2.3**. Exact compiler: **Zig 0.17.0**. Local execution: native Linux x86_64, baseline CPU, static musl.

- Debug SHA-256: `ff814bb2b010442e628e7320c33539897f4aa6686f4bf70d6aa6a0d951f7c0e7`.
- Safe SHA-256: `d3e2b67b194409543dcb09e2b0ae7a13fbce22297a0e5ba4d0e08e240bd79487`.

Debug and Safe each passed **240 unit executions**: 129 main, 41 codec and 70 provider. The no-TUI build passed **205 unit executions**; active main/probe entry points compiled. The completed combined and native release gates are recorded below.

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
and memory-growth/quiet-CPU thresholds remain unchanged. Native x86_64/ARM release CI and the downloaded-artifact/deployment checks below completed afterward; previous published artifacts remain immutable.

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
its local check reports `nativeSmokeTest:false`. Native ARM CI and publication completed as recorded below; cross-compilation alone is not desktop or native runtime evidence.

## Native CI and published artifacts

[Release CI 37359163295](https://github.com/technologylab-ai/omagma/actions/runs/37359163295)
passed all jobs on native Ubuntu 24.04 x86_64 and arm64. Both architectures
passed Debug/Safe correctness, HTML 7, repaint 3 and mouse 5 workflows, isolated
keyring/transport checks, and unchanged Safe 1000-cycle/60-second CLI/TUI/HTML,
backend and background memory gates. No production credentials were used.

The [v0.2.3 release](https://github.com/technologylab-ai/omagma/releases/tag/v0.2.3)
is published at tag/publication commit
`8117727e5091760c170a6d8f3ffcb82acab71cd4`; runtime remains `a94d29d`.
Its x86_64 Safe SHA matches local qualification above; ARM Safe SHA is
`60a189e11692461c85b0b0a8b3464f0bfe157fbb8a2d26ae315083998b99ab75`.
Both actual downloaded bundles passed checksums, normalized/privacy-audited
contents, manifest/backend version agreement and static ELF checks, with no
PT_INTERP or DT_NEEDED. ARM desktop integration is still not claimed.

| Native CI process | Settled RSS / PSS (KiB) | OS RSS peak (KiB) | Heap peak (bytes) |
| --- | ---: | ---: | ---: |
| x86_64 CLI | 9,060 / 9,052 | 13,124 | 4,698,191 |
| x86_64 TUI | 11,624 / 11,616 | 14,792 | 5,275,468 |
| arm64 CLI | 6,336 / 6,332 | 10,032 | 4,947,693 |
| arm64 TUI | 8,828 / 8,824 | 11,664 | 5,485,194 |

All four ordinary gates had zero warm growth, rejected allocations and quiet
CPU. Both TUI quiet windows emitted zero bytes. The exact 2 MiB HTML gates passed
1,000/60 on both architectures: x86_64 heap 56,049,942/HWM 38,204 KiB, arm64
heap 49,286,766/HWM 33,480 KiB, no rejected allocations and zero quiet CPU/output.
Warm RSS growth was -4/24 KiB respectively, below the unchanged 4 MiB threshold.
These process lifetimes do not isolate architecture or compiler costs.

## Actual x86_64 download and installation

The downloaded x86_64 executable passed 48 CLI, 12 cache, 5 UI, 6 background, 19 PTY,
7 wire, 7 HTML, 3 repaint, 5 mouse, 13 bar integration, 13 HTTP/HTTPS and callback checks.
All owned children were reaped. The first aggregate driver incorrectly expected
9 jobs after three suites were added; its failed summary remains preserved.
An independent audit validated all 12 actual job receipts and executable/mode/
compiler/count identities without relabeling that original or repeating suites.
No repeated 1,000-cycle soak was necessary for identical qualified bytes.

On 2026-10-05, those downloaded bytes were installed atomically and the plugin
rescanned. The existing shell instance remained running and the old backend
was reaped. The CLI and running service report 0.2.3/Safe/exact Zig 0.17.0.
Protected account/profile configuration, shell settings, existing grant/UI files
and user timer units remained unchanged. The five-minute cache timer stayed
enabled/active; no new consent or production mutation was issued. The popup
was closed after verification and no synthetic window/input was mapped to the
desktop. Native ARM backend coverage remains separate from ARM desktop behavior.
