# Memory footprint

The motivation for Omagma was a single Gmail tab observed using roughly **2 GB of RAM** on its author's desktop. That is an individual observation, not a universal Gmail requirement or a controlled comparison: Omagma shows a bounded recent-mail list and snippets, and opens the full Gmail application when needed.

## Terminal modes, 0.2.2

Cache-first runtime source `c5d1473b996fcbec43e7405b103fb76fe104253b` was measured on 2026-10-05 with exact Zig 0.17.0, native Linux x86_64 static-musl Safe. The original three-account workloads, 100 warm-ups, 1,000 measured cycles and 60-second quiet intervals retain their acceptance thresholds.

| Whole terminal process | Settled RSS / PSS | OS peak RSS | Warm RSS/PSS/private growth | Quiet CPU |
| --- | ---: | ---: | ---: | ---: |
| Agent CLI | 8,840 / 8,828 KiB | 12,784 KiB | 0 KiB | 0 ticks |
| TUI | 11,744 / 11,732 KiB | 15,016 KiB | 0 KiB | 0 ticks |

Rounded decimal footprints are about **9 MB for the CLI and 12 MB for the TUI**, with workload peaks around **13–16 MB**. Capped-heap peaks were 4,657,857 and 5,410,258 bytes, with zero allocation refusals. The TUI emitted no bytes during its quiet minute. These are whole terminal processes; the terminal emulator, external editor and separately running bar are excluded. [Cache-first qualification](evidence/terminal-0.2.2.md) records exact executable identities.

A separate maximum-cache stress seeded 2,000 metadata records averaging 1,528 bytes, added 100 and deleted ten. It retained the exact newest 2,000 within **3,344,073 disk bytes**, with preserved body hashes and no orphan files. Its peak capped heap was **43,959,024 bytes** and whole-process OS peak RSS **43,176 KiB**, approximately **44 MB**. This deliberately larger workload is separate from settled small-message memory; the 64 MiB heap ceiling and 16 MiB fixed-storage reservation are allocation accounting, not resident-memory totals.

The new terminal features settle roughly 2–4 MB above the previous local workload. Both versions use the same exact compiler, and their separate process lifetimes do not establish an isolated compiler effect. Historical tables stay attached to their original versions. The optional cache timer is a short native one-shot; it has no resident cache process between runs.

## Terminal modes, 0.2.1

The incoming-header compatibility patch at source `858ce32d21625a136fbed102d265e97bb95b0a48` was measured separately on 2026-10-05, using native Linux x86_64 static-musl Safe and exact Zig 0.17.0. The original three-account fixture workload, 100 warm-up cycles, 1,000 measured cycles and 60-second quiet intervals were unchanged.

| Whole terminal process | Settled RSS | Settled PSS | OS peak RSS | Warm RSS/PSS growth | Quiet CPU |
| --- | ---: | ---: | ---: | ---: | ---: |
| Agent CLI | 6,932 KiB (6.8 MiB) | 6,932 KiB | 10,644 KiB (10.4 MiB) | 0 KiB | 0 ticks |
| TUI | 8,180 KiB (8.0 MiB) | 8,172 KiB | 12,032 KiB (11.8 MiB) | 0 KiB | 0 ticks |

Rounded decimal footprints are approximately **7 MB for the CLI and 8–9 MB for the TUI**, with workload peaks around 11 MB and 12–13 MB. Terminal heap peaks were 6,692,585 and 7,619,937 bytes respectively, with no rejected allocations. The TUI emitted no output during its quiet minute. These are whole Omagma terminal processes; the bar, terminal emulator and external editor remain separate processes. The 64 MiB terminal heap ceiling and 16 MiB fixed backend/HTTP reservation are separate accounting bounds, already represented by their touched pages in process RSS/PSS. [Patch qualification](evidence/terminal-0.2.1.md) records exact executable identities.

The observed footprints remain close to the previous release below. These are separate process lifetimes, not an isolated compiler comparison; both terminal releases use the same exact Zig 0.17.0 compiler. Existing acceptance thresholds were unchanged.

Native [v0.2.1 release CI run 37258436358](https://github.com/technologylab-ai/omagma/actions/runs/37258436358) measured the same Safe workloads independently on Linux x86_64 and arm64 runners. Each used 100 warm-ups, 1,000 measured cycles and a 60-second quiet interval. The runtime source remains `858ce32d21625a136fbed102d265e97bb95b0a48`; publication/tag revision `b8d25227681090a9be0d8364330e8115bb672ffb` records the release without changing it.

| Native CI process | Settled RSS / PSS | OS peak RSS | Terminal heap peak | Warm RSS/PSS growth | Quiet CPU |
| --- | ---: | ---: | ---: | ---: | ---: |
| x86_64 agent CLI | 6,908 / 6,908 KiB | 12,304 KiB | 6,692,585 bytes | 0 KiB | 0 ticks |
| x86_64 TUI | 8,644 / 8,636 KiB | 14,252 KiB | 7,621,981 bytes | 0 KiB | 0 ticks |
| arm64 agent CLI | 6,252 / 6,252 KiB | 10,032 KiB | 6,725,051 bytes | 0 KiB | 0 ticks |
| arm64 TUI | 7,856 / 7,852 KiB | 11,628 KiB | 7,645,603 bytes | 0 KiB | 0 ticks |

All four gates passed with zero private-memory growth and no rejected allocations; both TUIs emitted no quiet-window bytes. These are whole-process measurements on native CI hosts, with the same separate 64 MiB heap and 16 MiB fixed-storage accounting as the local results. Runner and process-lifetime differences affect high-water RSS, so the tables do not establish an architecture cost or an absolute RSS limit. The downloaded x86_64 release is byte-identical to the locally and natively qualified Safe executable and passed its own 45 CLI, 19 PTY and seven wire checks. No additional soak was needed for identical bytes. Terminal measurements do not include a desktop deployment or establish arm64 desktop behavior.

## Preserved terminal modes, 0.2.0

On 2026-10-05, native Linux x86_64 static-musl Safe builds from source `7568a2467b5a93142259bc50057a177c3acf7150` passed separate 1,000-cycle CLI and TUI measurements. Each used three fictional accounts with 96 messages each, after 100 warm-up cycles, followed by a 60-second quiet interval.

| Whole terminal process | Settled RSS | Settled PSS | OS peak RSS | Warm RSS/PSS growth | Quiet CPU |
| --- | ---: | ---: | ---: | ---: | ---: |
| Agent CLI | 7,000 KiB (6.8 MiB) | 7,000 KiB | 10,768 KiB (10.5 MiB) | 0 KiB | 0 ticks |
| TUI | 8,536 KiB (8.3 MiB) | 8,528 KiB | 12,400 KiB (12.1 MiB) | 0 KiB | 0 ticks |

These numbers include the complete Omagma terminal process: touched storage, heap, stacks, runtime and executable pages. The terminal emulator, separately running bar, Chrome and an active external editor are separate processes. The CLI traversed eight pages and read a full message on every cycle; the TUI changed accounts, paged, selected messages and reloaded. Peak measurements and settled memory describe this workload, not a guarantee for every message or editor.

The terminal allocator peaked at 7,235,433 bytes for CLI and 7,617,129 bytes for TUI, with no rejected allocations. Its **64 MiB heap ceiling** is separate from the **16 MiB fixed backend/HTTP reservation**. The whole-process RSS/PSS measurements include their touched pages; summing allocation ceilings does not predict resident memory. See [terminal qualification](TERMINAL-VERIFICATION.md) for reproduction and limits. Historical bar measurements below retain their original version and accounting.

## Final mouse runtime, 0.2.3

On 2026-10-05, source `a94d29d07d2370d140bb13bef21840ead90b6c65` passed the
combined local Linux x86_64 static-musl Safe gates with mouse enabled. Each
ordinary CLI/TUI workload used 100 warmups, 1,000 cycles and 60 quiet seconds.

| Whole process | Settled RSS / PSS (KiB) | OS peak RSS (KiB) | Warm growth | Heap peak (bytes) |
| --- | ---: | ---: | ---: | ---: |
| Agent CLI | 9,084 / 9,076 | 12,872 | 0 KiB | 4,698,191 |
| TUI | 11,640 / 11,632 | 14,864 | 0 KiB | 5,273,534 |

Both had zero quiet CPU and refused allocations; the TUI emitted no quiet bytes.
The exact 2 MiB HTML fallback had 37,396 KiB process high-water, 56,049,942-byte
heap peak, no warm growth, no refused allocations and zero quiet CPU/output.
These measurements exclude the emulator, bar, Chrome and external editor.
[Final mouse evidence](evidence/terminal-0.2.3-mouse.md) identifies the exact
executables and workload. The pre-mouse checkpoint below remains unchanged.

## HTML-reader checkpoint, 0.2.3

The pre-mouse source `e4f852512646ce7cb4931677d391d3a49b82faeb` passed separate
Linux x86_64 static-musl Safe gates on 2026-10-05: 100 warmups, 1,000 measured
cycles and 60 quiet seconds. These receipts precede the mouse implementation;
its qualification remains separate.

| Whole process workload | Settled RSS / PSS (KiB) | OS RSS high-water (KiB) | Warm growth (KiB) | Capped heap peak (bytes) |
| --- | ---: | ---: | ---: | ---: |
| Agent CLI, three fictional accounts | 9,016 / 9,008 | 12,868 | 0 | 4,698,191 |
| Ordinary TUI, three fictional accounts | 11,628 / 11,620 | 14,500 | 40 | 5,273,534 |
| TUI, exact 2 MiB HTML fallback | 27,896 / 27,888 | 38,540 | -4 | 56,049,942 |

All gates had zero rejected allocations and zero quiet CPU ticks; both TUIs
emitted no quiet bytes. The boundary HTML exceeds the rich-layout line cap, so
this case establishes complete plain fallback and reachable tail. It does not
claim formatted rendering of all 2 MiB. The separate 2,000-message cache stress
had 43,464 KiB OS peak RSS and 44,214,520-byte heap peak.

Rounded whole-process totals are about 9 MB CLI, 12 MB ordinary TUI and 29 MB settled
for the boundary body, with respective high-water marks about 13/15/39 MB. These
include touched storage, runtime and stacks, excluding the terminal emulator,
bar, Chrome and external editor. The 64 MiB heap cap and 16 MiB fixed reservation
are separate accounting; they must not be added to RSS/PSS. See the
[HTML checkpoint evidence](evidence/terminal-0.2.3.md) for exact executable
identities and preserved failures. Existing bar measurements below remain at
their original versions.

## Three-account bar measurement, v0.2.2

On 2026-10-05, the installed downloaded **v0.2.2 / Zig 0.17.0** static-musl backend with three connected accounts used **15,380 KiB PSS** (15,392 KiB RSS), stable over five samples. The unchanged Quickshell UI's full offscreen lifecycle measurement attributed **14,433 KiB PSS** after 1,000 cycles and 200 warm-ups. Together this estimates **29,813 KiB: 29.1 MiB / 30.5 MB**, rounded to **31 MB** for Omagma's backend and attributed UI share.

This is a combined estimate from separate live-backend and synthetic UI lifetimes, excluding Chrome and unrelated shell widgets. The UI receipt keeps its predecessor executable identity in [current qualification](evidence/terminal-0.2.2.md); the component bytes are unchanged. The running installed backend is the published x86_64 artifact, SHA-256 `597009ad9dc3616c8f5473cc70f411ce280b7e640c86c50def0f6caaf02b712d`. It was verified after rescan without replacing the desktop shell or account/profile settings.

The five-minute terminal-cache timer returns after each update and has **no resident cache process between runs**. An open TUI or a running cache one-shot is a separate process from the bar; terminal measurements above do not include the emulator/editor. Workload, process lifetime and Qt baseline differences explain why these observations do not isolate a compiler effect. Earlier version measurements below remain unchanged.

## Three-account bar measurement, v0.2.1

On 2026-10-05, the installed downloaded **v0.2.1 / Zig 0.17.0** static-musl backend with three connected accounts and five-minute background refresh used **15,472 KiB PSS** (15,480 KiB RSS), stable across five samples. A separate full offscreen UI qualification with 90 rows attributed **12,476 KiB PSS** after 1,000 open/close cycles and 200 warm-ups. Together:

| Component | Attributed PSS |
| --- | ---: |
| Running backend | 15,472 KiB |
| Warm, closed Omagma UI over Quickshell baseline | 12,476 KiB |
| Approximate Omagma total | **27,948 KiB: 27.3 MiB / 28.6 MB** |

The README rounds this estimate to **29 MB**. It includes the complete backend and Omagma's attributed UI share, excluding Chrome and unrelated shell widgets. Combining a live backend sample with a separate synthetic UI baseline is an estimate, not a direct isolated desktop-process total. The actual installed executable SHA-256 is `4e936b367cdd6dd9ed5eac71ead732cb3b5f301cc047753ad8d5144b58b6e511`. A separate downloaded-artifact live read-only test fetched 30 messages per account and passed a 60-second quiet interval with zero CPU ticks, added jobs or events; its backend PSS was 15,232 KiB. The plugin reload preserved the shell PID, private account/profile settings and closed popup.

The changed totals across versions include process-lifetime and UI-baseline variation. They do not isolate a compiler effect, and allocation ceilings still do not predict resident memory. Historical measurements remain attached to their actual versions.

## Preserved three-account bar measurement, v0.1.1

On 2026-10-05, the installed **v0.1.1 / Zig 0.17.0** static-musl backend with three connected accounts and five-minute background refresh used **14,444 KiB PSS** (14,452 KiB RSS), stable across five samples. A separate full offscreen UI qualification with 90 rows attributed **15,514 KiB PSS** after 1,000 open/close cycles. Together:

| Component | Attributed PSS |
| --- | ---: |
| Running backend | 14,444 KiB |
| Warm, closed Omagma UI over Quickshell baseline | 15,514 KiB |
| Approximate Omagma total | **29,958 KiB: 29.3 MiB / 30.7 MB** |

The README at that release rounded this total to **31 MB**. The then-installed executable was the actual downloaded x86_64 release, SHA-256 `36d6c76847b44dbc4e4aac8255af75901ee6b3d17e6c20e1259a7a00c6d37e75`. An independent read-only live test fetched 30 messages per account using existing grants and passed a 60-second manual-probe quiet interval. It measured 15,712 KiB backend PSS, illustrating variation between process lifetimes.

## Preserved historical measurement

On 2026-10-04, the installed static-musl **v0.1.0 / Zig 0.16.0** backend with three connected accounts used **12,184 KiB PSS** (12,192 KiB RSS). A separate synthetic UI lifecycle measurement with the production logo and 90 retained rows attributed **16,068 KiB PSS** to Omagma over the Quickshell baseline. Together these give an approximate Omagma footprint of **28,252 KiB: 27.6 MiB, or 28.9 MB**, roughly **30 MB**.

That estimate includes the backend and Omagma's share of the UI. It is not the added cost of a second or third account. Omagma shares Quickshell with the rest of the bar, so UI attribution uses a baseline rather than assigning the whole desktop shell to one plugin. Chrome, other bar plugins and temporary keyring helper processes are excluded. The popup was closed after warm lifecycle use; opening it creates a temporary view.

RSS counts shared pages in full; PSS apportions them among processes. Combining RSS from the whole shell with the backend would describe the shell and its other widgets too. The application-owned 16 MiB storage reservation is a separate allocation bound, not the measured total process memory.

The historical release remains at `851ee30c5953a28fe0535fea03737ce85ec745fd`. Private receipts are retained locally; only anonymized counts and memory totals are published. See [historical evidence](../EVIDENCE.md) and [reproduction and acceptance gates](VERIFICATION.md).

## Zig 0.17 qualification

The compiler port has separate [dated evidence](evidence/zig-0.17.0.md). Its native x86_64 Safe synthetic backend peak RSS was 11,624 KiB with 90 rows; the actual downloaded release's soak reached 11,636 KiB, the same peak as the historical 0.16 static release soak. Matched old/new UI diagnostics showed no compiler-linked increase. An earlier UI attribution gate failed and is preserved in the evidence: baseline initialization varies, so individual measurements are not guarantees.

The roughly 29 MB v0.1.0, 31 MB v0.1.1 and 29 MB v0.2.1 estimates come from different process lifetimes and UI baseline runs. They do not isolate the compiler's effect. Historical measurements remain attached to their actual version.
