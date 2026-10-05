# Cache-first experimental terminal qualification, 0.2.2

Dated 2026-10-05. Earlier releases, their assets, dated evidence and failed private receipts remain unchanged. The TUI and agent CLI are explicitly experimental. Development write acceptance uses fictional accounts and fixtures; no production send, contact change or invitation reply is authorized by this qualification.

## Source and bounded behavior

Runtime source: `ce410a5a29fbe94cb693e48c98a04ef49ee3b01b`. Package and manifest version: **0.2.2**. Exact compiler: **Zig 0.17.0**, source `7647adab80dd088f4de3610fd245915a912eb6ad`. Local execution: native Linux x86_64, baseline CPU, static musl.

- Debug SHA-256: `b441b708991bfc6883d2513b95b4b2213f3d9a76a357d268bd7df9a4253f7b01`.
- Stripped Safe SHA-256: `5f21430d926f338f580d2ccc19c30cb7b63eb876360f917253a3bfcfb90d6ec0`.

Cached lists and downloaded bodies are available before a network update completes. Gmail history updates use short local commits and a separate refresh lease, with bounded resync after an expired checkpoint. A narrow folder/search projection cannot replace the whole account cache. Refresh retains immutable body hashes, advances the checkpoint only after required commits, and records message-specific body refusals separately from systemic failures.

The default retains the newest **2,000 messages and at most 256 MiB per account**, including whole-body tail eviction. Heap allocations remain capped at 64 MiB; the existing fixed backend/HTTP reservation remains 16 MiB. Neither ceiling predicts resident memory. Incoming MIME permits up to 256 headers within unchanged 8 KiB per-value and 32 KiB aggregate byte limits. Body size checks remain enforced.

Reader right/below preference, Omarchy palette loading, cached Contacts navigation, context-aware Back, and separate cache/Gmail search are qualified through isolated terminal cells. Local search is a partial metadata subset with its own cursor provenance. The built-in composer remains split; an external editor temporarily takes over the terminal. No tmux is required.

The optional native five-minute user timer shares cache policy and refresh leases with terminal clients. It uses non-unlocking, read-only bar credentials and leaves no resident cache process between runs. The bar keeps its independent 30-row memory-only cache.

## Synthetic correctness

Debug and Safe each passed **190 unit executions** (98 main, 29 codec, 63 provider); all active standalone probes and full executables compiled.

| Suite | Debug | Safe |
| --- | ---: | ---: |
| CLI, including one-shot search flags | 47/47 | 47/47 |
| Held-provider cache/navigation | 12/12 | 12/12 |
| Responsive layouts, theme, Contacts and Back/search | 5/5 | 5/5 |
| Maximum-cache workload | 1/1 | 1/1 |
| Native background/lease/cancellation | 6/6 | 6/6 |
| Existing isolated editor/lifecycle PTY workflows | 19/19 | 19/19 |
| Independent loopback transport | 7/7 | 7/7 |

One-shot checks prove that `--cached` adds zero provider calls and `--server` reaches uncached older mail; mixed modes and a server flag on a non-search command are rejected before provider access. Held-refresh barriers independently establish cached full reads and threads, selection retention and immediate Contacts access. Back checks cover search, expanded reader, normal/insert compose, help and unsent drafts. Header fixtures accept 96 synthetic delivered headers while refusing 257 headers or aggregate byte overflow.

The Safe maximum-cache case seeded 2,000 records averaging 1,528 bytes, then added 100 messages and deleted ten. It retained exactly the newest 2,000, evicted the remaining 90 from the tail, validated 102 body references with preserved hashes and found no orphan body files. Peak capped heap was **41,945,834 bytes**, with zero refused allocations. Whole-process OS peak RSS was **44,720 KiB**; disk use was **3,344,073 bytes**, separately below the 256 MiB quota. The fixture completed in 2.69 seconds. This is a deliberately larger metadata workload, not the settled-memory soak below.

The unchanged UI model passed 1,000 snapshot replacements. Pure fixture, terminal cell, cache-fixture, status-color and wrapped-reader helpers passed 13, six, five, three and five checks respectively.

## Preserved failures and findings

The initial responsive reader check failed at 82 columns by 24 rows: geometry was correct, but redundant header blank lines pushed all body text below the visible pane. Compact segment spacing and omission of only empty Cc fixed the unchanged body-identity assertion. Full recipients and body newlines remain preserved.

Earlier cache tests found mutable request-map aliasing, narrow-resync replacement, tail reinsertion after byte pressure, and fixture remote mutation state lost after mail eviction. Independent regressions were preserved and passed after ownership, retention and separate fixture-provider state fixes. A large-cache audit also prompted phase-owned storage arenas and amortized entry capacity before the full-size gate passed. These are application defects and ownership lessons, not demonstrated Zig 0.17 regressions.

A previously reported `BodySizeMismatch` has no established private-message cause. Container-empty versus declared-size semantics remain under investigation; leaf decoded-size integrity was not relaxed. Stored body refusal reasons now remain message-specific and visible without automatic repeated preview requests. Compiler and dependency findings remain in [the durable wiki follow-up](../ZIG017-WIKI-FOLLOWUP.md).

## Safe memory and quiet windows

The unchanged CLI and TUI gates each passed 100 warm-ups, 1,000 measured cycles and a 60-second quiet interval. Both had zero warm RSS/PSS/private growth, zero quiet CPU ticks and zero refused allocations; the TUI emitted no unsolicited bytes.

| Whole process | Settled RSS / PSS (KiB) | OS peak RSS (KiB) | Capped heap peak (bytes) |
| --- | ---: | ---: | ---: |
| CLI | 8,792 / 8,784 | 12,560 | 4,304,957 |
| TUI | 10,036 / 10,028 | 13,176 | 5,410,258 |

The unchanged limits are 4 MiB warm median growth and 0.5% of one core while quiet. These measurements include touched fixed storage, heap, runtime and stacks; terminal emulator/editor and the bar are separate. [Memory accounting](../MEMORY.md) preserves previous versions and the larger-cache workload separately.

## Bar and desktop-host regression

Both modes passed the existing 13 integration and 13 HTTPS transport checks, launch/callback/FD probes and isolated synthetic Secret Service lifecycle. The keyring probe also exercised the new non-unlocking automatic lookup on its own synthetic session bus.

Safe bar memory passed 1,000 cycles and 60 quiet seconds: OS peak RSS **12,952 KiB**, zero warm growth, zero CPU ticks and no unsolicited snapshots/jobs. The accelerated closed-background test passed 1,000 added jobs with one worker, at most two pending flags and 90 retained rows; peak RSS was **13,068 KiB**, with zero warm growth.

The unchanged Qt UI passed its full offscreen lifecycle gate: 200 warm-ups, 1,000 open/close cycles and a 60-second quiet interval. Attributed closed UI PSS was **14,233 KiB** over a **69,563 KiB** baseline, with declining warm PSS (**−2,297 KiB**) and zero GUI/backend quiet CPU. The existing 20 MiB attributed-PSS, 2 MiB growth and 0.5% quiet-CPU limits were unchanged. No desktop window was mapped or user input captured.
