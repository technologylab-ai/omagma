# Omagma 0.2.5 release qualification

Dated 2026-10-07. This release includes the complete current application, with
live cache adoption, accumulated per-account arrival cards, whole-cache `gg`
navigation and improved mail rendering. The TUI and CLI remain experimental.
Existing releases and dated evidence are unchanged.

## Published identity

Source and tag: `7042569d9112e81420a4e6ff6a089759cb67e895`. Package and manifest:
**0.2.5**. Compiler: exact **Zig 0.17.0**, source
`7647adab80dd088f4de3610fd245915a912eb6ad`. Published executables use **Safe**
optimization and baseline CPUs. Linux binaries are static musl; native Mac
binaries target macOS 13.0 and use system libraries.

| Published executable | SHA-256 |
| --- | --- |
| Linux x86_64 | `dbf57aca3c570f918135e72909921b17d474d2c5b24ab33db83923a696f58cc0` |
| Linux arm64 | `5257936b7f47972ca94da69bd3060d6ddee128838d9c7caa9661b5518166f1ed` |
| macOS Intel | `787709f2b24fbe51e7df79361bff40c87cee6df36395921395ad074892c53ed0` |
| macOS Apple Silicon | `3882898464c183edfa83842bfee5cc1da3ff02c46cc3c0deaadd0f0553af951b` |

[Release CI 37642141188](https://github.com/technologylab-ai/omagma/actions/runs/37642141188)
passed on native Ubuntu 24.04 x86_64/arm64 and macOS 15 Intel/Apple Silicon.
The [v0.2.5 release](https://github.com/technologylab-ai/omagma/releases/tag/v0.2.5)
was published on 2026-10-07 after all four required jobs succeeded. It has ten
assets: four raw executables, four complete bundles, `LICENSES.txt` and
`SHA256SUMS`, with nine checksum entries. The automatic Homebrew tap update
also succeeded. No previous release assets were replaced.

## Correctness and current features

Both Linux architectures passed 363 unit tests in each Debug/Safe mode:
229 main, 46 codec and 88 provider. Each Mac architecture passed 360 tests,
with five platform skips in its 365-test graph. All active probes compiled
in both modes; native graphs retain their actual platform differences.

Linux Debug and packaged Safe suites passed 13 bar integration and 13 bounded
HTTP/HTTPS transport cases, 48 CLI operations, seven independent loopback wire
cases, cache/navigation and background activity, maximum-cache stress,
19 editor/PTY workflows, repaint, mouse and HTML cases. Focused acceptance
also covers attachments, compose/reply/reply-all, bulk actions and undo,
recipient completion, local timezone/DST, incremental loading and wheel
pagination. Synthetic stores, mail and credentials remain isolated.

Both native Mac architectures passed Debug and packaged Safe CLI/wire,
owned-terminal/editor restoration, detached lifecycle, Keychain isolation and
upgrade/re-signing, and credential-free HTTPS with system CA certificates.
Their five-case guardian suite runs the same four arrival/navigation cases
and HTML reader UX assertions as Linux.

The new cases establish:

- `gg` reaches the first message across cached windows without provider calls.
  Reader Home scrolls its current body; list Home selects its current window's
  first row. These separate behaviors retain reader reuse and pagination.
- Cache updates preserve the selected message, visible row and reader position
  when reading older windows. A selected provider message outside the cache
  quota suppresses passive replacement rather than silently jumping to the head.
- Arrival counters accumulate separately for each account, appear only on the
  main browse screen and clear on the next interaction. First cache loads,
  older tails and ordinary metadata changes are excluded.
- HTML and plaintext links receive colored compact labels, while `L` retains
  complete safe destinations. Malformed markup, hidden styles, image placeholders,
  literal plaintext/code and legacy-cache provenance have separate assertions.
- One plain `q` during held body 31/32 exits within the original five-second
  budget after a normal cache-observer tick. The terminal is restored, the
  refresh lease is released, no history checkpoint advances, and no sends or
  owned children remain. Debug and Safe run this alongside original exit tests.

## Safe resource gates

Each CLI/TUI workload uses three fictional accounts, 100 warm-ups, 1,000
measured cycles and its own 60-second quiet interval. These are whole-process
measurements, excluding the terminal emulator, editor, Chrome and separate bar.

| Platform / workload | Settled RSS / PSS (KiB) | OS RSS high-water (KiB) | Warm RSS/PSS growth (KiB) | Heap peak (bytes) |
| --- | ---: | ---: | ---: | ---: |
| Linux x86_64 CLI | 8,268 / 8,260 | 12,312 | 0 / 0 | 4,855,873 |
| Linux x86_64 TUI | 11,008 / 11,000 | 14,556 | 0 / 0 | 5,838,433 |
| Linux arm64 CLI | 6,620 / 6,612 | 10,492 | 0 / 0 | 5,105,375 |
| Linux arm64 TUI | 9,500 / 9,492 | 12,532 | 104 / 104 | 5,724,875 |

Mac physical footprint is separate from Linux PSS. Mac peaks below are sampled
RSS peaks, not Linux-style process high-water marks.

| Native Mac workload | Settled RSS / footprint (KiB) | Sampled RSS peak (KiB) | Warm RSS/footprint growth (KiB) | Heap peak (bytes) |
| --- | ---: | ---: | ---: | ---: |
| Intel CLI | 7,900 / 5,916 | 10,868 | 0 / 0 | 4,855,910 |
| Intel TUI | 11,676 / 8,904 | 14,548 | 0 / 0 | 6,614,095 |
| Apple Silicon CLI | 8,576 / 6,416.875 | 11,600 | 0 / 0 | 5,451,826 |
| Apple Silicon TUI | 14,088 / 11,441.4375 | 16,864 | 80 / 128.25 | 6,538,901 |

All CLI quiet intervals observed zero CPU. TUI quiet CPU was 0.016666% of one
core on Linux x86_64, zero on Linux arm64, 0.029323% on Mac Intel and 0.040219%
on Apple Silicon; all emitted zero quiet bytes and refused zero allocations.
The unchanged limits are a 64 MiB application heap, at most 4 MiB warm median
RSS/other-process-metric growth and less than 0.5% of one core while quiet.
The separate 16 MiB fixed backend/HTTP reservation is allocation accounting;
neither allocation bound is added to measured resident memory.

The exact-2-MiB HTML fallback also passed its separate 1,000-cycle/60-second
Linux gates. Settled RSS/PSS was 27,852/27,844 KiB on x86_64 and 20,352/20,344
KiB on arm64; OS RSS high-water was 38,764/34,108 KiB. Warm growth was 4/24 KiB,
with no allocation refusals, 0.016666% quiet CPU and zero quiet output. The
complete body tail stayed reachable with document/layout/fallback counts
**1/1/1** throughout navigation.

Native backend gates passed with peak RSS 9,940/6,644 KiB and warm growth
0/36 KiB on Linux x86_64/arm64. Their quiet minutes had no CPU, new jobs or
events. The separate active-background fixture completed 1,001 jobs, retaining
90 rows with one active and at most two pending jobs; peaks were 9,936/6,636
KiB and warm growth 0/12 KiB. That accelerated scheduler does not establish
another quiet interval. No new Qt host measurement or live ARM desktop
qualification is inferred; earlier dated bar/UI evidence remains unchanged.

## Preserved failures and application findings

Earlier failed workflows and raw private receipts remain attached to their
original artifacts. A fixture privacy mismatch was corrected with a reserved
example domain. Home navigation and startup account-read fences received
independent regressions. A missing cache anchor and a swallowed cancellation
were application lifetime/input defects; neither is a new Zig 0.17 regression.

The cache watcher now uses an independent stop flag, terminates on cancellation
and joins before owner cleanup. Internal cached reads propagate cancellation;
void progress callbacks reassert it for their caller. Both exact 0.16 and 0.17
Threaded sources have the same one-shot cancellation contract. The source
hashes, controlled old/fixed witness and classification are recorded in the
[durable wiki handoff](../ZIG017-WIKI-FOLLOWUP.md). No resource limit, original
deadline or failing assertion was relaxed.

## Actual Linux download and deployment

The published x86_64 raw executable and bundle were downloaded separately from
CI, checksum verified, and compared with all 353 normalized audited bundle
files before later documentation changes. The executable has no ELF
`PT_INTERP` or `DT_NEEDED`, is stripped, matches the bundled executable and
reports application 0.2.5 / exact Zig 0.17.0 / Safe mode.

Those downloaded bytes independently passed 13 bar integration, 13 HTTP/HTTPS,
48 CLI, seven wire, four arrival/navigation, held-provider loading,
single-quit-during-refresh and HTML-reader UX checks on native Linux x86_64.
The exact tested executable was atomically installed, preserving private
account/profile/keyring/cache settings and running user processes. An existing
TUI session picks it up on restart. Fresh native CI resource receipts already
identify these same bytes; downloaded checks do not relabel older local soaks.

## Actual Mac download and Homebrew deployment

The published Apple Silicon executable and bundle were independently downloaded
on native arm64 macOS. Both checksums, system-only Mach-O dependencies,
baseline CPU/minimum OS, exact 353-file normalized archive and reported
0.2.5 / Zig 0.17.0 / Safe identity passed. The bundle SHA-256 is
`294f72c8ff3df71f4745cd60c3d4142bd08e3ab8e02a1e9bf80f8904f9278ed7`.

The actual downloaded executable passed 48 CLI and seven loopback transport
cases, four guardian terminal/lifecycle cases, the five current-feature cases,
cache windows, bulk/undo/search/recovery, detached spawn, isolated Keychain
upgrade from the previously installed executable, and credential-free HTTPS
returning 401. This is native downloaded-artifact evidence, separate from the
Intel and Apple Silicon CI resource measurements. No live account consent,
production mail mutation or calendar access was needed.

The preferred Homebrew installation then upgraded to 0.2.5 on that native
Apple Silicon host. Installed bytes match the published raw executable hash
above; `brew test`, all five installed current-feature cases, guardian
terminal/lifecycle and isolated old-to-new Keychain upgrade checks passed.
Private account/profile/cache settings, user Keychain configuration, other
applications and running user windows were preserved. The automated tap update
was the sole formula publisher. Intel deployment is not inferred from this
Apple Silicon installation; its native CI and resource evidence is separate.

The [social screenshot](../images/omagma-tui-arrivals.png) uses only fictional
accounts and synthetic mail. It shows genuine accumulated arrivals, shortened
colored links, emoji and an image placeholder; no private mail is published.
