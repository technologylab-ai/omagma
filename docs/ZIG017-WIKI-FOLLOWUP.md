# Zig 0.17.0 findings for the Zig LLM Wiki

Durable curator handoff, 2026-10-05. Keep this file in the repository across agent compaction. It records candidate lessons; the referenced wiki and other projects were treated as read-only. Do not infer that a candidate has already been incorporated upstream.

Audience: wiki curators and developers, not installers. [Development](DEVELOPMENT.md)
and [the documentation index](README.md#development-and-reference) provide the
current workflow. The dated identities, measurements, failures and classifications
below are historical records; later local UI work does not relabel them or
establish new release/resource qualification. In particular, the errno mistake
remains an Omagma bug, and a candidate is not proof of a compiler regression.

## Exact identities

- Omagma source port: `b9dfde6acd84dc32f74490890f45764067c64659`, application 0.1.1. Runtime sources remain identical in subsequent documentation/media revisions.
- Published v0.1.1 source: `9fbe044fe43d456c99b652960a9b0902671e28d4`; [native release CI](https://github.com/technologylab-ai/omagma/actions/runs/37240727720). The actual downloaded x86_64 release was checked and deployed; later documentation preserves the published assets.
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

Native hosted x86_64 and ARM backend jobs passed at the source-port revision in branch verification run `37238990205`, then again in release run `37240727720`. The first full offscreen UI soak failed its unchanged 20 MiB added-PSS gate (21,453 KiB), despite stable warm memory and complete view destruction. Matched diagnostics found no compiler-linked increase (10,577 KiB with 0.16 versus 10,051 KiB with 0.17) and a large baseline anonymous-memory shift. Its cause remains unproven; this is **not an established Zig 0.17 regression**. After diagnosis, one full unmodified 1,000-cycle/60-second run passed with 15,514 KiB added PSS, declining warm memory and zero quiet CPU. The failed receipt is preserved and the diagnostic runs are not labeled acceptance.

Actual downloaded x86_64 release: checksum/static/version checks, 13 integration and 13 transport cases, callback, full backend and background soaks passed; peak backend RSS 11,636 KiB, warm growth zero and 60-second quiet CPU zero. Authorized live three-account read-only fetches passed without new consent; the downloaded backend is installed, shell ready, account/client/bar settings unchanged. Exact asset hashes and hosted/desktop measurements are in [migration evidence](evidence/zig-0.17.0.md). ARM backend qualification is separate from ARM desktop qualification. This Linux-only application makes no macOS/Windows runtime or experimental std.Io backend claim.

## Post-release terminal work (0.2.0 development)

The 0.1.1 graph and evidence above is immutable. Terminal work adds pinned libvaxis `6fd944a27fb3d6f596e981076381a3131f2448b4`, zigimg `c701c9f99779d7ddf594dcc6da8f858fd277d61f` and uucode `ea62149739404a73c202b48a33bf6dd2af4bd9b0`. Only Unicode grapheme APIs are used; the optional casing borrowing issue is not exercised. LLVM selection follows reference build guidance; no non-LLVM compiler crash witness has been established here.

Two development failures are application findings, **not Zig 0.17 regressions**: opening a default O_PATH directory and calling fchmod violated std.Io.Dir.setPermissions' documented iterate=true precondition; external editor foreground restoration used a no-op SIGTTOU handler where orphaned background job control required kernel SIG_IGN. The latter also exposed a readback owner deferred until after a fallible terminal-restoration step. Independent fixture/PTY regressions qualify the fixes; failed private receipts are retained. Broader terminal qualification is recorded separately, not substituted for the released bar receipts.

### Linked-libc foreground process-group wrappers: pre-existing std gap

Compiling the actual x86_64 static-musl TUI on exact 0.17.0 exposed another source/API issue: `std.posix.tcgetpgrp` and `tcsetpgrp` select `std.c` when libc is linked, but `std/c.zig` declares neither function. Exact 0.17 source `7647adab80dd088f4de3610fd245915a912eb6ad`, `std/posix.zig:1197–1230`, calls the raw-Linux-style two-argument pointer signatures. Compilation fails with “struct 'c' has no member named 'tcgetpgrp'” and the corresponding `tcsetpgrp` error. The actual executable, rather than unit tests that leave editor code unanalyzed, revealed the failure.

The installed exact 0.16.0 source has the same calls at `std/posix.zig:1195–1228` and also lacks these `std.c` declarations. This source comparison identifies a **pre-existing std gap**, not a demonstrated 0.17 migration regression. Adding libc declarations with the raw syscall pointer signatures would also be incorrect: libc `tcgetpgrp(fd)` returns a PID, while `tcsetpgrp(fd, pid)` takes a scalar PID. Linux-only code can instead use the native ioctl wrappers with the raw Linux errno decoder. Qualify foreground restoration through an independent PTY and child lifecycle, not a cast or inverse wrapper test. Final implementation and runtime results are recorded in [terminal evidence](evidence/terminal-0.2.0.md).

### Pinned libvaxis incomplete UTF-8 input: dependency finding

This is a finding in libvaxis revision `6fd944a27fb3d6f596e981076381a3131f2448b4`, **not a demonstrated Zig 0.17 compiler regression**. Its `Loop.zig` reads 1,024 bytes at a time and preserves parser results with `n == 0`, but handles `InvalidUTF8` by discarding the remaining batch. `Parser.zig`'s `parseGround` uses `uucode.utf8.Iterator` and grapheme lookahead; an incomplete codepoint is not returned as the incomplete-result case. A larger buffer merely moves the failure boundary. [Pinned input loop](https://github.com/rockorager/libvaxis/blob/6fd944a27fb3d6f596e981076381a3131f2448b4/src/Loop.zig), [pinned parser](https://github.com/rockorager/libvaxis/blob/6fd944a27fb3d6f596e981076381a3131f2448b4/src/Parser.zig).

An independent synthetic PTY exercised a single-line Unicode body and compared its persisted bytes after editing. The expected body was 2,349 bytes / 1,269 codepoints; the actual body was 2,345 bytes / 1,268 codepoints, missing one `👋`. Its UTF-8 offset was 1,020 within the body; two preceding navigation bytes placed its first byte at input offset 1,022, crossing the 1,024-byte read boundary. Current-cell caret checks and terminal restoration passed, so visual plausibility alone did not qualify preservation. The failed receipt and escaped output remain private and unchanged.

The project-owned `src/terminal/input.zig` adapter reuses the public pinned parser, queue and capability dispatcher without modifying dependency caches or other projects. It gives the parser only the complete UTF-8 prefix, holding zero to three trailing bytes for the next read. Incomplete control sequences have a 1,024-byte bound; malformed input cannot cause an unbounded accumulation or retry loop. Queued key text also has owned storage rather than relying on the upstream rotating cache's lifetime. Unit gates cover every split of two-, three- and four-byte codepoints, complete-prefix grapheme lookahead and the original 1,024-byte witness. Independent PTY gates force fragmented reads of accented text, combining marks, CJK, emoji and ZWJ sequences and require exact persisted bytes. Actual qualification belongs to the new terminal evidence; compilation and source inspection alone do not establish the fix.

The first adapter implementation introduced an application stack failure before terminal rendering: each of 512 queue entries contained a 1,024-byte text array, and `Loop.init` returned the whole loop by value even though its destination was heap allocated. Independent Debug disassembly measured a 625,872-byte `terminal.tui.run` frame and an 832,736-byte `terminal.cli.run` frame; the fixture died in `stack_probe` before input. The large frames are proven; their combination exceeding a bounded runtime task stack is the inferred crash mechanism because core collection was disabled. This is an Omagma ownership/stack bug, not a compiler regression. Queue entries now hold small descriptors with bounded allocator-owned text, initialized in place. Failed pushes release allocations; consumption transfers ownership until the next event, and stop joins and drains before editor return. The corrected artifact passed startup and all 19 independent PTY cases in both Debug and Safe, including exact preservation of the 2,349-byte body and eight forced UTF-8 fragment cases. Stack limits stayed unchanged. Compiler/source and final release identities are recorded in [terminal qualification evidence](evidence/terminal-0.2.0.md).

### Removed deprecated Allocator.dupeZ: exact std API change

Unlike the error-decoder bug above, this is an independently checked 0.16-to-0.17 API removal. Installed exact 0.16.0 `lib/std/mem/Allocator.zig:459–467` defines `dupeZ` as a deprecated wrapper for `dupeSentinel(T, m, 0)`. Exact 0.17.0 source `7647adab80dd088f4de3610fd245915a912eb6ad`, `lib/std/mem/Allocator.zig:480–500`, retains `dupe` and `dupeSentinel` but has no `dupeZ`; compiling the user-selected-file helper reported “no field or member function named 'dupeZ'”. Use `allocator.dupeSentinel(u8, path, 0)` to obtain the owned sentinel-terminated path, then free it normally. The replacement already existed in 0.16.

The inspected std file SHA-256 is `f6ad8a10185701ef1399350f127692ed5e89141773ea3c7e5ccc54a652120397` for installed 0.16.0 and `25099a1aaed1fe80b811e1eaedf8c3e2059a3fe7b6c29db868a68da3085b7997` for exact 0.17.0. The removed wrapper is established by those sources; the versioned release notes do not explicitly mention `dupeZ`. Omagma's prior released graph did not call it; the new native file helper exposed the obsolete API assumption during terminal development. Lexical shadowing and catches containing errors outside an inferred error set are separate application compile mistakes, not compiler regressions.

### Subsequent application compatibility patch

Source `858ce32d21625a136fbed102d265e97bb95b0a48` (0.2.1) separates incoming address-header bounds from outgoing SMTP/composer validation. Live read failures on long Reply-To local parts and more than 32 incoming recipients were caused by shared application validation, not a Zig 0.17 change. Do not promote these to migration gotchas. The same exact compiler and pinned dependency revisions remain in use. Debug/Safe each passed 141 unit executions and 45 CLI, 19 PTY and seven wire cases; separate 1,000-cycle terminal memory runs passed unchanged gates. [Patch qualification](evidence/terminal-0.2.1.md) retains its own executable identities and receipts rather than relabeling earlier measurements.

Published [v0.2.1](https://github.com/technologylab-ai/omagma/releases/tag/v0.2.1) at `b8d25227681090a9be0d8364330e8115bb672ffb` passed [native Linux x86_64/arm64 release CI](https://github.com/technologylab-ai/omagma/actions/runs/37258436358). The actual downloaded x86_64 static-musl artifact, SHA-256 `4e936b367cdd6dd9ed5eac71ead732cb3b5f301cc047753ad8d5144b58b6e511`, passed its own 45 CLI / 19 PTY / seven wire checks, 13 bar integration / 13 HTTPS transport cases and callback probe. It was installed and its running executable identity verified after a supported plugin rescan, preserving private settings and the shell PID. All three accounts passed limited read-only acceptance using existing grants; live writes and ARM desktop integration remain unqualified. This adds application evidence, without changing the exact Zig source identity or promoting application/harness defects to compiler gotchas. Historical releases and failed receipts remain preserved.

## Cache-first terminal work, 0.2.2

Source `ce410a5a29fbe94cb693e48c98a04ef49ee3b01b` adds cache-first navigation, bounded Gmail history synchronization, reader layouts and optional one-shot background cache refresh. It keeps exact Zig source `7647adab80dd088f4de3610fd245915a912eb6ad` and the existing dependency pins and HTTP/kernel workarounds. No new compiler API regression was established.

Relevant general ownership lessons are distinct from migration gotchas: copying a mutable JSON ordered map by value aliases its backing storage; an initialized HTTP transport with self-borrowed context needs stable in-place storage; an arena retained across many cache commits plus repeated complete entry-array copies can exhaust a fixed heap despite bounded final cache size. Independent narrow-query, immutable-body and 2,000-record stress checks qualify the application fixes. The large-cache Safe case used 41,945,834 capped-heap bytes with no allocation refusals and separate 44,720 KiB whole-process peak RSS.

The incoming-header count and `BodySizeMismatch` behavior belong to Omagma's MIME validation, not Zig. The former now accepts up to 256 headers under unchanged byte limits. The latter's exact private cause remains unproven and its leaf-integrity checks stay in place. [Cache-first qualification](evidence/terminal-0.2.2.md) records these separately; do not relabel old receipts or promote application failures to compiler findings.

### Incoming Gmail size metadata: application compatibility

Runtime `de3cd1c50a4f028d24df0e3b498e5de52fb9a682` follows the initial cache-first candidate. A private read-only same-message diagnostic found a complete, valid inline text payload larger than the provider's declared byte count. Synthetic literal UTF-8 fixtures independently reproduced the refusal on the old executable. The narrow compatibility change accepts fully decoded inline plain/HTML leaves whose actual length is at least the declared length, under unchanged actual-data budgets. External/named/disposition attachments, calendar/non-leaf parts, negative or over-budget declarations, and short/empty data remain strict.

This belongs to Omagma's incoming-data policy, **not Zig 0.17 or musl error handling**. [Google documents](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages.attachments) an exact decoded-byte count; tolerance is justified by observed inconsistent metadata, rather than claimed API semantics. Code shares the attachment predicate with storage classification to avoid a policy bypass. The independently reproduced failure, current source and validation are recorded in [0.2.2 evidence](evidence/terminal-0.2.2.md).

### Cache-index CPU work: application performance

The native ARM Debug maximum-cache gate at publication `95b733e7ff3ed3e814fbfa345f3ccf3893837033` hit the existing 30-second refresh deadline; the source-derived hotspot was repeated parsing and sorting of a multi-megabyte index during 100 full-body commits. Runtime `c5d1473b996fcbec43e7405b103fb76fe104253b` borrows unescaped strings only from a store-owned immutable buffer, skips sorting already ordered rows, and inserts/repositions one row in sorted order. Lifetime, tie ordering, body-hash and eviction tests qualify those ownership changes. No deadline, quota, workload, atomic-save or locking rule was relaxed.

This is an application performance finding with architecture-specific evidence, not a compiler regression. The failed native run remains preserved; local Debug/Safe timing is separate from subsequent native ARM qualification. [Cache-first evidence](evidence/terminal-0.2.2.md) records exact source revisions and results.

Published [v0.2.2](https://github.com/technologylab-ai/omagma/releases/tag/v0.2.2), runtime `c5d1473b996fcbec43e7405b103fb76fe104253b` / tag `e91e1e86f759e18c931f2172b66ddb206ed8ff32`, passed [native x86_64 and arm64 CI](https://github.com/technologylab-ai/omagma/actions/runs/37313908584). ARM's unchanged Debug large-cache gate completed in 22.73 seconds within the 30-second deadline after the application optimization; the earlier timeout remains preserved. Actual downloaded x86_64 bytes were verified and tested separately before installation, with existing credentials/profile settings preserved. The optional native read-only user timer is enabled without a resident cache daemon. These add application/platform evidence and no new established Zig/compiler/musl regression. [Current qualification](evidence/terminal-0.2.2.md) separates source identities, hosted ARM backend tests and x86_64 desktop deployment.

## Local TUI polish follow-up, 2026-10-06

The local interface work reconfirmed the guide's existing array-repetition lesson: a standalone `[_]u8{42} ** 3` test passes with exact 0.16.0 and is rejected by exact 0.17.0. A typed `@splat` preserves repeated-element meaning. This is already documented in the wiki migration guide; it is corroboration, not a new upstream candidate. Compiler/source identity remains `7647adab80dd088f4de3610fd245915a912eb6ad`.

The status-buffer bound, shared wrapping/caret layout, whitespace lookahead and compact-list capacity fixes belong to Omagma. Incremental loading uses request-scoped copies and cancellation-aware finite animation waits. None of these establishes a Zig/compiler/libc defect. This local iteration does not replace historical release evidence or claim new release, memory, ARM or desktop-platform qualification.

## Native macOS / owned-child cancellation follow-up, 2026-10-06

The native port's base checkpoint is `86392435bf6052ed4bab0397d4da98744e8cfe32`. Follow-up runtime qualification is recorded separately from that checkpoint's passed native resource receipts; no older receipt is relabelled.

### General POSIX lesson, present in both exact 0.16 and 0.17

Exact Zig 0.17.0 source revision remains `7647adab80dd088f4de3610fd245915a912eb6ad`. `std/Io/Threaded.zig` has `childWaitPosix` at15665, an unconditional deferred `childCleanupPosix` at15666, and cleanup at15788–15801 that closes pipes and clears `child.id`. `Canceled` can return when starting the blocking syscall or checking cancellation after `EINTR`; a successful `wait4` finishes and returns the status. Consequently a canceled wait can lose the application's cleanup handle while its direct child is still live or unreaped.

Exact installed 0.16.0 source has the same contract at `std/Io/Threaded.zig:15241–15242` and15364–15377. This is **not an established Zig 0.17 migration regression**. Installed source-file SHA256 identities are:

- `0.16.0` `std/Io/Threaded.zig`: `eb7bbb4ddf590ec3d0d2a1ee5c3845ef4984d9e440965a3e7c920cd0c906df94`.
- `0.17.0` `std/Io/Threaded.zig`: `1a770001e309f24c8c58a9fdb3c095994c454cbfa9dba9d4f1dede2f134eeac7`.

Omagma's `platform.waitOwned` captures the still-owned PID and restores it only on `Canceled`, while retaining normal successful-wait behavior. `platform.killOwned` sends `SIGKILL` before std's uncancelable reap so a child that ignores `SIGTERM` cannot defeat the owner's finite deadline. Shared launch handshakes, keyring helpers, the native system reader and terminal editor use the adapter. No application allocation, lock or std.Io operation was introduced after fork.

The independent executable probe first receives a native PID and stdout EOF from a child that deliberately stays alive and ignores TERM. A100ms deadline cancels the actual std wait. The control loses `child.id` while an independent `WNOHANG == 0` proves the direct child still lives; the adapter retains ownership. Both paths are force-killed and independently require `ECHILD` after reap. This witnesses the OS lifetime contract rather than mirroring a mock's implementation. Native Debug/Safe and Linux qualification results belong to the eventual final port evidence.

### Application port findings, not compiler gotchas

The first native Keychain adapter incorrectly interpreted exit1 as absence, hiding store/probe failures. Exact positive acknowledgements and an independent failure-refutation witness correct that application error. The secret limit remains4096bytes;8192bytes is only the oversize-generator input, not a changed allowance.

Ad-hoc binary upgrades change the legacy Keychain creator identity. Omagma uses scoped native Security APIs for create/update and trusts the creator plus Apple's signed `/usr/bin/security` for stable private-pipe reads and deletion fallback. An independent exact Homebrew re-sign witness refuted native terminal-item deletion even after read/update passed; scoped signed-tool deletion and native exact-item absence verification address that application distribution boundary. This is a macOS distribution/API lesson within the same per-user boundary as Linux Secret Service, not a Zig compiler defect. Known locked keychains fail before the system reader; a lock change during handoff can still produce an OS prompt, so user documentation does not promise a universal no-dialog guarantee. Native upgrade/read/update/item-clear/absence/isolation tests and source review establish this port's behavior; they do not qualify an Omarchy bar on macOS.

The native resource harness initially treated Darwin's `rusage_info_v4` CPU counters as nanoseconds. A separate 0.100-second CPU workload refuted that assumption: these counters use Mach absolute-time ticks, which require `mach_timebase_info` conversion. Test revision `a58b45f0554de9b55fde226b462a94ab03674a7b` corrects the conversion and retains the independent CPU control. Earlier raw receipts remain unchanged; zero counter deltas remain zero after conversion. This is an application measurement error and a Darwin testing lesson, **not a Zig 0.17 compiler or libc regression**.

### Native delete acknowledgement output: application bug

Candidate `80332934766f9f45af2ba4c92d466d53b27c8bf4` passed same-name native upgrades but failed published raw filename upgrades on both native Mac CI architectures. A local independent byte comparison reproduced the same failure: `bin/omagma` succeeded while the byte-identical `omagma-macos-arm64` reached the signed deletion fallback after native status `-25244`. Private numeric diagnostics found the stock tool's human metadata output filled Omagma's 256-byte capture, triggering its own output-bound rejection before checking exit/absence. This is **Omagma output handling, not a Zig 0.17, SDK or Keychain trust regression**.

The deletion helper now discards human stdout/stderr. It still requires the finite owned child wait to succeed and verifies the exact service/account key is absent with native UI-suppressed lookup plus unlocked-state checking before ACK. No scope, ACL, token limit or application reservation was widened. The upgrade test independently copies a byte-identical public raw filename and exercises both ordinary and exact Homebrew re-sign variants without renaming the re-signed executable to hide the boundary. Failed and successful receipts retain their original source/binary identities.

The correction and independent raw-filename regression are in `a82e3a0f4d88b0db1ee4d0093dba5a0dbab0eaa0`. Repackaging that revision preserved the exact measured Linux static executable, SHA-256 `5483e981701fb06b34f6a69d6f47b6c4fd236862ba87df4c031129553578dc03`; native Mac bytes are qualified separately.

## Owned task cancellation follow-up, 2026-10-07

This is an application lifetime lesson, **not a new Zig 0.17 regression**. Both
exact 0.16 and 0.17 Threaded implementations acknowledge cancellation once:
`Thread.checkCancel` transitions `canceling` to `canceled`, returns `Canceled`,
then later checks in the `canceled` state return normally. `Syscall.start`
subsequently treats that thread as uncancelable unless cancellation is rearmed.
The exact 0.17 source is `std/Io/Threaded.zig:908–933,1365–1368,2381–2397`,
revision `7647adab80dd088f4de3610fd245915a912eb6ad`. The unchanged-contract
0.16/0.17 file identities are respectively
`eb7bbb4ddf590ec3d0d2a1ee5c3845ef4984d9e440965a3e7c920cd0c906df94` and
`1a770001e309f24c8c58a9fdb3c095994c454cbfa9dba9d4f1dede2f134eeac7`.

Omagma's watcher caught canceled cache probes as ordinary errors and continued
its loop. A normalized JSON error could obscure the same cancellation. A
controlled stamp/read wait acknowledged the real cancellation request; the
old owner join then exceeded an eight-second diagnostic watchdog. The fixed
watcher joins promptly for raw stamp/read cancellation and encoded error
responses. It records independent owner shutdown intent, terminates on
`Canceled`, and propagates cancellation across internal cached calls. A void
progress callback that catches cancellation rearms it for its caller; a
canceled animation post exits its task. Finite waits and joined ownership stay
intact. Public CLI error framing and write/uncertain-send safeguards remain
separate from those internal lifetime signals.

The independent held-refresh PTY gate keeps the provider blocked at body
31/32, sends one mailbox `q`, and requires the original five-second clean exit,
full terminal restoration, no sends, no checkpoint advancement, released
refresh ownership and no surviving session children. Debug and Safe local
checks pass in approximately 0.05 seconds; these are focused checks, not a
replacement for the final release's platform and memory qualification.
