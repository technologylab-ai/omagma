# Zig 0.17.0 findings for the Zig LLM Wiki

Durable curator handoff, 2026-10-05. Keep this file in the repository across agent compaction. It records candidate lessons; the referenced wiki and other projects were treated as read-only. Do not infer that a candidate has already been incorporated upstream.

## Exact identities

- Omagma source port: `b9dfde6acd84dc32f74490890f45764067c64659`, application 0.1.1. Runtime sources remain identical in subsequent evidence-only revisions.
- Preserved baseline: Omagma v0.1.0, `851ee30c5953a28fe0535fea03737ce85ec745fd`, exact Zig 0.16.0. Published assets and old evidence are unchanged.
- Exact Zig release/source: **0.17.0**, `7647adab80dd088f4de3610fd245915a912eb6ad`.
- Wiki guide/runbook/source record consumed at `04f0aa6a69fa94bba9791ffb7b02968d1aa14217`.
- Checked archive/installer reference: Omajot `c7c1ffd082f77f47640990e7c01ed2d3ec6748b4`.
- Detailed audit hashes and new qualification: [0.17 migration evidence](evidence/zig-0.17.0.md). Historical receipts stay with their original version.

## Project bug, not a Zig 0.17 gotcha: errno decoding

**Omagma used the wrong error decoder. Do not list this as a Zig 0.17-specific change or stdlib defect.** A general syscall-layer lesson may be useful separately. Static musl is not a host-glibc dependency, but linking libc changes which implementation `std.posix.errno` aliases. Exact `std/posix.zig:27,36,298` selects `std.c` when `builtin.link_libc` is true. `std/c.zig:76` expects libc's `-1` result plus thread-local errno. Raw `std.os.linux` syscalls instead return negative error numbers; `linux.fcntl(-1, F_GETFD, 0)` returns raw `-9` for Linux `EBADF`.

Using `std.posix.errno` on that raw result reports success in the musl-linked build. Use **`std.os.linux.errno` for raw Linux calls**, regardless of libc linkage; `std/os/linux.zig:1042` decodes the raw range. Use the libc-compatible decoder only for libc-compatible calls. This is a pre-existing Omagma bug revealed by the stronger migration probe, **not an identified Zig 0.17 regression**.

Proofs: `src/platform.zig` raw-errno unit test and `closeRangeProbe`; `src/daemon.zig` invalid-fcntl test. Both Debug and Safe static-musl native tests pass. The first native musl FD probe failed, while a libc-free diagnostic passed; neither that narrow diagnostic nor earlier successful-path tests qualified error handling in the linked build. All application raw Linux checks were corrected. No std.Io/allocation/locking was introduced after fork.

Useful wiki targets: POSIX/raw-syscall mapping, libc-linking qualification, migration checklist. Require invalid-descriptor/error-path tests in addition to successful syscalls, on the actual linked artifact.

## Candidate 2: close_range layout fixed, adjacent comments stale

Exact `std/os/linux.zig:2034` now has a leading `_0: u1`, so named `UNSHARE` is bit 1 (2) and `CLOEXEC` is bit 2 (4). The nearby comments still say `0x1`/`0x2`. Linux UAPI has `CLOSE_RANGE_UNSHARE = 1U << 1` and `CLOSE_RANGE_CLOEXEC = 1U << 2`.

Omagma can remove its 0.16 numeric-flag workaround and use the typed 0.17 API. The regression probe checks literal backing values 4/6, then independent kernel behavior: only a newly duplicated descriptor is marked, `F_GETFD == 1`, byte I/O still succeeds before exec, the descriptor becomes `EBADF` after exec, and an unflagged high descriptor survives with `F_GETFD == 0`. Both native x86_64 Debug/Safe probes pass; hosted ARM evidence is tracked in the migration evidence.

Useful wiki target: release-source audit notes. Do not mechanically copy stale numeric comments, or remove a workaround solely because the compiler version changed. Recheck representation against kernel behavior. The initial probe also exposed the Omagma errno bug rather than a kernel/flag failure.

## Candidate 3: privileged_headers omission still needs a workaround

Exact `std/http/Client.zig:985–1084` `sendHead` emits the standard authorization override and ordinary extra headers, but still does not emit `privileged_headers`. Omagma retains `.headers.authorization = .override(...)`, its strict Google-host allowlist, and `.redirect_behavior = .unhandled`.

The loopback transport peer checks the literal fake bearer on the wire, the missing-bearer response, and rejected bearer redirects with no forwarded request. Both Debug and Safe transport suites pass, including a separate credential-free Google TLS request returning 401. These synthetic headers are not real OAuth credentials and the TLS check does not read mail.

Useful wiki target: std.http client authorization/header behavior and exact-version workaround qualification. The source finding existed in 0.16 and remains in exact 0.17; do not mark it fixed based on an unchanged public field declaration.

## Candidate 4: retain native-memory meaning in PID handshakes

Omagma's forked sender writes four bytes using `std.mem.asBytes(&pid)`. That is a native object-representation contract. Replace the old array-to-i32 `@bitCast` with `std.mem.readInt(i32, bytes, std.lang.Endian.native)`. The test uses literal `[0x12,0x34,0x56,0x78]` and independent expected numbers `0x78563412`/`0x12345678`, plus zero/negative rejection. No cast-and-inverse oracle is used.

The other application cast was a packed fcntl flag value; the exact release defines `linux.O` with **u32**, not signed backing, on both supported architectures. `@backingInt` expresses that scalar intent; literal flags 0/0x400/0x800/0xc00 are tested. No application `@bitCast` remains. This reinforces the existing guide's classification lesson; it does not establish native big-endian application support.

## Candidate 5: bounded synthetic peers must complete the intended protocol

One Safe callback probe returned `CallbackConnectionsExhausted`. The synthetic client read only the response status line before closing; the callback server was still writing headers/body. This can reset the connection and turn a valid parsed callback into a response-write error. The fixture now drains the bounded reply through EOF before closing. The final wrong-state-then-valid, stalled-client timeout, listener closure and one-time-completion checks pass in both modes.

This is a harness/ownership lesson, **not a demonstrated compiler regression**. The old fixture source already used status-line-only consumption; a matched old-compiler failure comparison was not run. Production callback parsing, its two-connection limit and deadlines remain unchanged. Useful wiki target: peer lifetime, protocol completion and watchdog/deadline separation. Do not increase deadlines or retry the suite until it happens to pass.

## Existing guide lessons revalidated

- `addPassthruArgs()` works; `zig build run -- build-info` verifies actual forwarding.
- Actual modes are `debug`/`safe`. Read tested binary identity; a caller's display label or PATH alone cannot prove the artifact's compiler/mode. Memory gates reject Debug/fast binaries.
- Checked exact official archive metadata avoids the missing 0.17 download-index entry. Both supported release CI architectures use native compilers and verify size/hash/version.
- All active entry points/probes must compile. A historical callback feasibility file still imported an engine absent from the current dependency graph; it now uses actual Omagma OAuth with no external dependencies.
- Infinite sleeps were audited; no application `Io.Timeout.none.sleep` call exists. No known Threaded panic witness was rerun. Event waits and finite deadlines were checked through cancellation/owner-exit tests. Experimental Dispatch/Uring/Kqueue constructors and uucode casing are outside this graph.
- Keep std runtime/libc memory separate from the application-owned reservation, and remeasure the actual release. Do not relabel old receipts or relax acceptance gates.

## Qualification and remaining boundaries

Native Linux x86_64 local: 25/25 unit tests in both modes; 13/13 integration and 13/13 transport in both; all active probes; isolated synthetic Secret Service; model tests; Safe 1,000-cycle backend and 1,001-job closed-background gates. Safe backend peak RSS 11,624 KiB, warm growth 0 KiB, 60-second quiet CPU 0 ticks. New receipts use `zig017` names and remain private; public summaries contain no mail/account data.

Native hosted x86_64 and ARM backend jobs passed at the source-port revision in branch verification run `37238990205`. The first full offscreen UI soak failed its unchanged 20 MiB added-PSS gate (21,453 KiB), despite stable warm memory and complete view destruction. Matched diagnostics are investigating baseline initialization variation; this is **not an established Zig 0.17 regression**. The failed receipt is preserved. Final UI acceptance, actual downloaded release and installed-plugin results are added when complete in [migration evidence](evidence/zig-0.17.0.md). ARM backend qualification is separate from ARM desktop qualification. This Linux-only application makes no macOS/Windows runtime or experimental std.Io backend claim.
