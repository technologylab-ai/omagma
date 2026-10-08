# Omagma 0.2.6 release qualification

Dated 2026-10-08. Markdown mail, native file picking, invitation replies and
terminal quality-of-life changes are published. The TUI and CLI remain
experimental. Earlier releases and dated measurements remain unchanged.

## Published identity

Source and tag: `8639d60778641af2d612be32af48fc1ec07f84c2`. Package and
manifest: **0.2.6**. Compiler: exact **Zig 0.17.0**, source
`7647adab80dd088f4de3610fd245915a912eb6ad`. Executables use Safe optimization
and baseline CPUs. Linux is static musl; Mac targets macOS 13.0 and links only
system libraries.

| Published executable | SHA-256 |
| --- | --- |
| Linux x86_64 | `1d693cf3472857275396b6850a629fbb1c0bd3192b96be59d43f0bede2442a56` |
| Linux arm64 | `ac9dcf67963d3e7f58cc744e0ece9875a3a9b5dba1ac640706c21921f5aa2dc1` |
| macOS Intel | `3114337a8ee37cffba758d0155300b5a5be71b2a3aede10608437c955e069685` |
| macOS Apple Silicon | `c9c5beabb842f661041a298b0cc2fbf7fa6c8a706368007bbd1e23a946f63508` |

[Release CI 37713475060](https://github.com/technologylab-ai/omagma/actions/runs/37713475060)
passed on native Ubuntu 24.04 x86_64/arm64 and macOS 15 Intel/Apple Silicon.
The [release](https://github.com/technologylab-ai/omagma/releases/tag/v0.2.6)
was published at 02:14:14 UTC after all four jobs passed. Ten assets include
four executables, four complete bundles, licenses and a nine-entry checksum
inventory. The automatic Homebrew update and matching Pages deployment passed.
Existing release assets were not replaced.

## Correctness

Each Linux architecture passed **478/478** tests in Debug and Safe. Each Mac
architecture passed **475/480**, with five platform skips, in both modes.
All active standalone probes compiled. Linux receipts include 13 bar integration,
13 HTTP/HTTPS, 48 CLI, 20 PTY, seven wire, eight HTML, five UI, five mouse and
three repaint cases per mode, plus cache, background and current-feature suites.

Mac Debug and packaged Safe checks passed 48 CLI, seven wire and nine guardian
cases, command guidance/parity, Markdown workflows, detached lifecycle, private
Keychain upgrade/re-signing and credential-free HTTPS. These platform scopes
are separate; native ARM backend qualification does not establish ARM Omarchy
desktop integration.

Current-feature checks cover exact Markdown/plain source and alternatives,
reply/forward threading, confirmation and uncertain-send replay, binary files,
case-insensitive completion, Tab controls, native cursor placement, readable
errors, invitations, account isolation and owner cancellation. Synthetic tests
use fictional accounts and isolated stores, without production mail or desktop
input.

## Safe resources

Every terminal workload below uses three fictional accounts, **100 warm-ups,
1,000 measured cycles and 60 quiet seconds**. RSS is the complete Omagma process;
the emulator, editor, Chrome and separate bar are excluded. Darwin physical
footprint is separate from Linux PSS.

| Platform / workload | Settled RSS / PSS or footprint (KiB) | Warm growth (KiB) | Peak owned heap (bytes) |
| --- | ---: | ---: | ---: |
| Linux x86_64 CLI | 8,460 / 8,452 | 0 / 0 | 4,855,873 |
| Linux x86_64 TUI | 11,400 / 11,392 | 24 / 24 | 5,663,844 |
| Linux arm64 CLI | 6,732 / 6,724 | 0 / 0 | 5,105,375 |
| Linux arm64 TUI | 9,792 / 9,784 | 40 / 40 | 5,787,905 |
| Mac Intel CLI | 7,940 / 5,912 | 0 / 0 | 4,855,910 |
| Mac Intel TUI | 11,764 / 8,932 | 0 / 0 | 6,797,812 |
| Mac Apple Silicon CLI | 8,592 / 6,416.8125 | 0 / 0 | 5,451,826 |
| Mac Apple Silicon TUI | 14,224 / 11,489.375 | 96 / 144.125 | 6,530,113 |

All refused zero allocations. CLI quiet CPU was zero. TUI quiet CPU was at most
0.04077% of one core, with zero quiet output. Limits remain a 64 MiB owned heap,
at most 4 MiB warm process growth and less than 0.5% quiet CPU. The fixed 16 MiB
backend reservation is accounting, not an amount added to resident memory.

Separate Markdown CLI/TUI lifecycle gates passed on all four platforms under
the same limits. Markdown TUI settled RSS was 12,968/10,876 KiB on Linux
x86_64/arm64 and 12,280/14,880 KiB on Mac Intel/Apple Silicon; its largest
observed owned heap was 6,865,375 bytes. Matched CLI controls prove zero retained
preview allocation growth after request arenas, before session cleanup.

The separate 2 MiB incoming HTML workload passed on Linux: settled RSS/PSS
29,844/29,836 KiB on x86_64 and 20,472/20,464 KiB on arm64. Owned peaks were
56,749,470/49,853,592 bytes; no refusals or quiet output occurred. Backend-only
and accelerated background gates passed with sampled RSS peaks 10,384/6,744
KiB, one worker and bounded pending work. No new attributed Qt bar measurement
is inferred from these terminal/backend figures.

## Actual downloads and deployment

The published Linux x86_64 binary and bundle were independently downloaded,
checksum verified and compared with all **381** normalized bundle members at
the exact tagged source. The executable is stripped, has no ELF `PT_INTERP` or
`DT_NEEDED`, matches the bundled bytes and reports 0.2.6 / Zig 0.17.0 / Safe.
The bundle SHA-256 is
`f7bd5dacdb872954e212efa7ce1d7a54c0ac3da4517df91eb0ba3716392df753`.

Those actual bytes passed bar integration, HTTP/HTTPS, CLI/wire, Markdown
compose/reply/forward, file-picker keyboard, command guidance and forwarding
checks. Atomic installation and supported plugin rescan loaded that exact
binary, preserving private settings and the existing shell/TUI processes. The
five-minute cache timer remains active. Existing TUI sessions use it on restart.

The actual published Apple Silicon executable passed the same checksum/source
inventory, native Mach-O/system-library/version checks, CLI/wire/Markdown,
nine guardian cases and credential-free HTTPS on native macOS 26.6.2. Its
bundle SHA-256 is
`86e73c5e3db83123f400e539c72d64137e2c6484bb7f518235ca2893094bd549`.
The preferred Homebrew installation upgraded to byte-identical published
0.2.6; `brew test`, installed guardian/basic lifecycle, legacy draft/recovery
and isolated Keychain upgrade checks passed. Older Cellars and private settings
were preserved. No live consent or production mutation was needed.

Earlier failed/canceled receipts remain private with their original identities.
Corrections addressed test filesystem portability, partial VT-frame readiness
and transient allocation attribution; no release limit or deadline was relaxed.
These are application/testing lessons, not established Zig 0.17 regressions.

The social film uses synthetic mail and real fixture screenshots, including
ten files matching its visible filter. Its reproducible source is under
`video/short026`; output movies, music and raw receipts are excluded from Git.
