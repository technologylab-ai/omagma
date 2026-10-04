# Exact Zig 0.17.0 migration

Migration qualification on 2026-10-05 (Europe/Vienna; receipts use UTC). Application version **0.1.1**, from the completed **v0.1.0** release at `851ee30c5953a28fe0535fea03737ce85ec745fd`. The source port is `b9dfde6acd84dc32f74490890f45764067c64659` on `upgrade-zig-0.17.0`. Subsequent documentation/media changes preserve those runtime sources. The [0.16 evidence](../../EVIDENCE.md), release tag and published assets remain unchanged; these are separate new measurements.

## Source and build identity

- Exact compiler: Zig **0.17.0**, official release source `7647adab80dd088f4de3610fd245915a912eb6ad`. Installed `lang.zig` and `mem.zig` hashes match the immutable [wiki source record](https://github.com/technologylab-ai/zigllmwiki/blob/04f0aa6a69fa94bba9791ffb7b02968d1aa14217/sources/zig-0.17.0-stdlib.md).
- Read-only migration guide/runbook: zigllmwiki `04f0aa6a69fa94bba9791ffb7b02968d1aa14217`. Official [0.17 release notes](https://ziglang.org/download/0.17.0/release-notes.html) were reviewed after installed source.
- Checked compiler archive metadata follows Omajot `c7c1ffd082f77f47640990e7c01ed2d3ec6748b4`; [metadata](../../.github/zig-release.json) and [installer](../../.github/install_zig.py) verify official URL, size, SHA-256 and executable version. No download-index entry is required.
- The task selected the exact compiler on `PATH`, including nested Python builds. The system compiler was left unchanged. No external Zig dependencies were introduced.
- Canonical compiler options are `debug` and `safe`. Harness input aliases are normalized, but receipts validate the tested binary's `build-info` compiler, application version and actual optimization mode. Bundles require no installed compiler.

| Audited exact stdlib file | SHA-256 |
| --- | --- |
| `lib/std/http/Client.zig` | `dc88cb35d6edab886d08761431b6955a52822e5f166756ec4d0f5c2ad70be2db` |
| `lib/std/os/linux.zig` | `34f8a2301eb7f01c4747d70440c773790284dd074861086aab52bdaac75090a0` |
| `lib/std/posix.zig` | `73e710180ab3c8979a9055386efd0fb94176e84f2e5fd371858335511206a55b` |
| `lib/std/c.zig` | `b1046cea3ed2f6310ba251b74da05faa323222779942ec7d11285979d48d71db` |
| `lib/std/Io/Threaded.zig` | `1a770001e309f24c8c58a9fdb3c095994c454cbfa9dba9d4f1dede2f134eeac7` |

## Migration findings

The build guard/package now require exact 0.17.0. `run.addPassthruArgs()` replaces `b.args`, with a native `zig build run -- build-info` check. `zig build probes` compiles all three active standalone entry points in both modes: auth/launch, HTTP transport and callback-budget. The old callback-budget feasibility file depended on an engine outside Omagma's graph; its replacement exercises the actual dependency-free OAuth parser, reserved storage and finite loopback lifecycle.

Both application `@bitCast` uses were audited by intent. The launch handshake receives four bytes written with `std.mem.asBytes(&pid)`; it now decodes with explicit native `readInt(i32, ..., std.lang.Endian.native)`. Literal bytes have independent endian-selected numeric expectations, including invalid PID rejection. The fcntl flags are a packed `u32` on both supported architectures; `@backingInt` now states that scalar flag intent. Independent Linux flag expectations are `0`, `0x400`, `0x800` and `0xc00`. No application `@bitCast` remains. These tests do not qualify a big-endian deployment.

**Keep the Authorization workaround.** Exact `std/http/Client.zig` `sendHead` (lines 985–1084) emits the standard authorization override but still omits `privileged_headers`. The transport retains its override, Google-host allowlist and rejected redirects. A loopback server checks the literal synthetic bearer on the wire and verifies that redirects receive no forwarded request.

**The close_range flag layout is fixed.** `std/os/linux.zig:2034` adds the leading reserved bit: `CLOEXEC` has backing value 4, and `UNSHARE | CLOEXEC` is 6, matching Linux UAPI. Its adjacent numeric comments remain stale. The port replaces the old numeric syscall workaround with the typed API. Independent kernel checks prove that the flagged descriptor stays open before exec (`F_GETFD == 1`, successful byte I/O), disappears after exec (`EBADF`), and an unflagged descriptor survives as a positive control.

That new kernel probe found a **pre-existing static-musl error-decoding defect**. `std.posix.errno` resolves to `std.c.errno` when libc is linked (`posix.zig:27,36,298`); `c.zig:76` recognizes the libc `-1`/thread-local-errno convention. Raw `std.os.linux` calls return negative errno values, such as `-9` for `EBADF`. The first musl probe incorrectly saw success through the libc decoder, while a libc-free diagnostic passed. All Omagma raw Linux syscall checks now explicitly use `linux.errno` (`linux.zig:1042`), with invalid-FD numeric/kernel tests. The original failure and narrower libc-free result are retained in local notes, not presented as passing musl evidence.

A Safe standalone callback check also exposed a synthetic-peer race: the client closed after only the HTTP status line while the server was still writing. The fixture now drains the bounded reply through EOF before closing. Callback parsing, allowed connection count and application deadlines were preserved. Final checks exercise wrong-state rejection followed by a successful callback, stalled read cancellation, listener closure and one-time completion.

Runtime sleeps are finite. Worker event waits are cancellation-capable or explicitly woken on owner shutdown, then joined. No known `Threaded` infinite-sleep crash witness was executed. Experimental standard Dispatch/Uring/Kqueue constructors are outside the Linux Threaded graph. No libvaxis/uucode dependency was added; the general rule to retain borrowed storage until completion still applies.

## Local Linux x86_64 qualification

Native Linux x86_64, Omarchy 4.0.4, kernel `7.2.5-3-omarchy`. Static baseline-musl backend built with exact 0.17.0; Quickshell 0.3.1 and Qt 6.11.2. The cooperative host reservation was held through builds, warmups, quiet intervals and owned child cleanup. Synthetic Qt checks run offscreen; no test popup or keyboard capture was mapped to the desktop.

| Gate | Result |
| --- | --- |
| Debug and Safe unit correctness | 25/25 in each mode |
| Debug and Safe integration | 13/13 in each mode: account isolation, cancellation, owner exit, backpressure, background scheduling and bounded snapshots |
| Debug and Safe transport | 13/13 in each mode: loopback bounds, bearer wire checks, rejected redirects, finite 10-second deadlines and credential-free Google TLS/401 |
| All active standalone probes | Both modes compiled and executed; launch/exec failure, kernel descriptor inheritance, OAuth callback/parser/storage and credential-free TLS |
| Isolated Secret Service | Synthetic store/lookup/clear, oversized helper output, finite helper timeout, pipe cleanup and child reaping; release binary plus both standalone modes |
| Model | Validation, plain text, account/generation isolation and 1,000 replacements |
| Safe backend soak | 1,000 cycles, 90 rows; peak RSS 11,624 KiB; warm median growth 0 KiB; 60-second idle with zero CPU ticks/jobs/events |
| Safe closed-background soak | 1,001 completed jobs; 90 rows; one active worker, at most two observed pending jobs; peak RSS 11,624 KiB; warm median growth 0 KiB |
| Safe offscreen UI qualification | 1,000 measured cycles; all 1,204 views destroyed; 90 retained rows; added closed PSS 15,514 KiB; warm PSS/private growth −324/−328 KiB; zero UI/backend CPU time during 60 seconds idle |

The first full offscreen UI soak completed all 1,000 measured cycles and destroyed all 1,204 views, but **failed the unchanged 20 MiB closed-UI PSS gate**: added PSS was 21,453 KiB. Warm PSS declined by 206 KiB and private memory by 208 KiB; the failure happened before the quiet interval. This is a failed acceptance run, preserved under a distinct `zig017` receipt. The UI and asset sources match v0.1.0.

Two serial matched diagnostics then used the archived 0.16 release and current 0.17 binary with identical QML, inherited environment, 200 warmups and 100 cycles. Added PSS was 10,577/10,051 KiB respectively, with all 304 views destroyed. The failed baseline had 30,004 KiB anonymous PSS, while the matched baselines had 43,436/43,440 KiB. Anonymous/private initialization variation dominates the apparent shift; its cause is unproven. These diagnostics are explicitly non-acceptance (one second quiet) and do not establish a compiler regression.

After that diagnosis, one full unmodified harness run passed: 1,000 cycles, 60 seconds quiet, added PSS 15,514 KiB, added private memory 13,236 KiB, stable warm memory and all views destroyed. Its baseline PSS was 53,381 KiB. Both full receipts remain distinct; no threshold, fixture, workload or UI source was changed to pass. Memory attribution varies between processes, and the passing run is a dated workload result rather than a universal guarantee.

Native Ubuntu 24.04 x86_64 and arm64 backend jobs passed in [branch verification run 37238990205](https://github.com/technologylab-ai/omagma/actions/runs/37238990205), at the exact source-port revision above. Publication was skipped on the migration branch. Actual downloaded release checks and installed-plugin qualification remain to be recorded.

Downloaded synthetic hosted receipts verify actual `0.17.0` / `safe` identity on both platforms. Each platform passed 25 Debug and 25 Safe unit tests, all active probes, 13 integration and 13 transport cases in each mode, isolated Secret Service, archive/static-executable checks and both backend memory workloads. The x86_64 1,000-cycle backend peak RSS was 11,600 KiB with zero warm growth; arm64 was 6,136 KiB with 36 KiB warm growth. Each completed its 60-second quiet interval with zero CPU time, jobs or snapshot events. Background peak RSS was 11,604 KiB on x86_64 and 6,136 KiB on arm64, with warm growth 0/32 KiB respectively; at most one active and two pending jobs, 90 rows retained. ARM results qualify the backend on native Linux ARM, not the Omarchy desktop UI.

These are workload measurements, not a process hard limit. The application-owned 16 MiB reservation remains separate from standard runtime/libc allocations, thread stacks and external processes. Whole backend RSS must stay below 64 MiB; added closed UI PSS below 20 MiB; warm median growth below 2 MiB; quiet CPU below 0.5% of one core. Thresholds and application deadlines were not relaxed. The accelerated background soak is not a 60-second quiet-CPU claim.

Private raw receipts, credentials, account/profile settings and real mail remain excluded from Git and release archives. Archive contents are the privacy-audited tracked tree with normalized metadata, plus the static stripped backend and matching manifest/application version. See [reproduction commands](../VERIFICATION.md) and [release maintenance](../RELEASING.md).
