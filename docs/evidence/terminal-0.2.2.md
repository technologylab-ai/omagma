# Cache-first experimental terminal qualification, 0.2.2

Dated 2026-10-05. Earlier releases, their assets, dated evidence and failed private receipts remain unchanged. The TUI and agent CLI are explicitly experimental. Development write acceptance uses fictional accounts and fixtures; no production send, contact change or invitation reply is authorized by this qualification.

## Source and bounded behavior

Runtime source: `c5d1473b996fcbec43e7405b103fb76fe104253b`. Package and manifest version: **0.2.2**. Exact compiler: **Zig 0.17.0**, source `7647adab80dd088f4de3610fd245915a912eb6ad`. Local execution: native Linux x86_64, baseline CPU, static musl.

- Debug SHA-256: `42e18effeb671bc8204f0a247f1aa8d53fe0756a75cc44810453471db6a83759`.
- Stripped Safe SHA-256: `597009ad9dc3616c8f5473cc70f411ce280b7e640c86c50def0f6caaf02b712d`.

Cached lists and downloaded bodies are available before a network update completes. Gmail history updates use short local commits and a separate refresh lease, with bounded resync after an expired checkpoint. A narrow folder/search projection cannot replace the whole account cache. Refresh retains immutable body hashes, advances the checkpoint only after required commits, and records message-specific body refusals separately from systemic failures.

The default retains the newest **2,000 messages and at most 256 MiB per account**, including whole-body tail eviction. Heap allocations remain capped at 64 MiB; the existing fixed backend/HTTP reservation remains 16 MiB. Neither ceiling predicts resident memory. Incoming MIME permits up to 256 headers within unchanged 8 KiB per-value and 32 KiB aggregate byte limits. Body size checks remain enforced.

Reader right/below preference, Omarchy palette loading, cached Contacts navigation, context-aware Back, and separate cache/Gmail search are qualified through isolated terminal cells. Local search is a partial metadata subset with its own cursor provenance. The built-in composer remains split; an external editor temporarily takes over the terminal. No tmux is required.

The optional native five-minute user timer shares cache policy and refresh leases with terminal clients. It uses non-unlocking, read-only bar credentials and leaves no resident cache process between runs. The bar keeps its independent 30-row memory-only cache.

## Synthetic correctness

Debug and Safe each passed **209 unit executions** (105 main, 34 codec, 70 provider); all active standalone probes and full executables compiled.

| Suite | Debug | Safe |
| --- | ---: | ---: |
| CLI, including one-shot search flags | 48/48 | 48/48 |
| Held-provider cache/navigation | 12/12 | 12/12 |
| Responsive layouts, theme, Contacts and Back/search | 5/5 | 5/5 |
| Maximum-cache workload | 1/1 | 1/1 |
| Native background/lease/cancellation | 6/6 | 6/6 |
| Existing isolated editor/lifecycle PTY workflows | 19/19 | 19/19 |
| Independent loopback transport | 7/7 | 7/7 |

One-shot checks prove that `--cached` adds zero provider calls and `--server` reaches uncached older mail; mixed modes and a server flag on a non-search command are rejected before provider access. Held-refresh barriers independently establish cached full reads and threads, selection retention and immediate Contacts access. Back checks cover search, expanded reader, normal/insert compose, help and unsent drafts. Header fixtures accept 96 synthetic delivered headers while refusing 257 headers or aggregate byte overflow.

The Safe maximum-cache case seeded 2,000 records averaging 1,528 bytes, then added 100 messages and deleted ten. It retained exactly the newest 2,000, evicted the remaining 90 from the tail, validated 102 body references with preserved hashes and found no orphan body files. Peak capped heap was **43,959,024 bytes**, with zero refused allocations. Whole-process OS peak RSS was **43,176 KiB**; disk use was **3,344,073 bytes**, separately below the 256 MiB quota. The fixture completed in 1.47 seconds. This is a deliberately larger metadata workload, not the settled-memory soak below.

The unchanged UI model passed 1,000 snapshot replacements. Pure fixture, terminal cell, cache-fixture, status-color and wrapped-reader helpers passed 14, six, five, three and five checks respectively.

## Preserved failures and findings

The initial responsive reader check failed at 82 columns by 24 rows: geometry was correct, but redundant header blank lines pushed all body text below the visible pane. Compact segment spacing and omission of only empty Cc fixed the unchanged body-identity assertion. Full recipients and body newlines remain preserved.

Earlier cache tests found mutable request-map aliasing, narrow-resync replacement, tail reinsertion after byte pressure, and fixture remote mutation state lost after mail eviction. Independent regressions were preserved and passed after ownership, retention and separate fixture-provider state fixes. A large-cache audit also prompted phase-owned storage arenas and amortized entry capacity before the full-size gate passed. These are application defects and ownership lessons, not demonstrated Zig 0.17 regressions.

A read-only diagnostic of an exact refused message established an inline HTML body whose valid decoded bytes exceeded Gmail's declared byte count. No message content or identifiers were recorded. The initial candidate and failed private receipts are preserved. A fictional UTF-8 regression reproduced `BodySizeMismatch` on the old executable before the fix. Fully decoded inline plain/HTML leaves now tolerate understated metadata while actual byte limits govern storage. Empty/shorter bodies, external or named/disposition attachments, calendar and non-leaf parts retain strict checks. This is pragmatic provider compatibility, not a change to [Google's documented byte-count contract](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages.attachments). Stored refusal reasons remain message-specific and visible without automatic preview loops. Compiler and dependency findings remain in [the durable wiki follow-up](../ZIG017-WIKI-FOLLOWUP.md).

## Safe memory and quiet windows

The unchanged CLI and TUI gates each passed 100 warm-ups, 1,000 measured cycles and a 60-second quiet interval. Both had zero warm RSS/PSS/private growth, zero quiet CPU ticks and zero refused allocations; the TUI emitted no unsolicited bytes.

| Whole process | Settled RSS / PSS (KiB) | OS peak RSS (KiB) | Capped heap peak (bytes) |
| --- | ---: | ---: | ---: |
| CLI | 8,840 / 8,828 | 12,784 | 4,657,857 |
| TUI | 11,744 / 11,732 | 15,016 | 5,410,258 |

The unchanged limits are 4 MiB warm median growth and 0.5% of one core while quiet. These measurements include touched fixed storage, heap, runtime and stacks; terminal emulator/editor and the bar are separate. [Memory accounting](../MEMORY.md) preserves previous versions and the larger-cache workload separately.

## Bar and desktop-host regression

Both modes passed the existing 13 integration and 13 HTTPS transport checks, launch/callback/FD probes and isolated synthetic Secret Service lifecycle. The keyring probe also exercised the new non-unlocking automatic lookup on its own synthetic session bus.

The predecessor runtime's Safe bar memory passed 1,000 cycles and 60 quiet seconds: OS peak RSS **12,952 KiB**, zero warm growth, zero CPU ticks and no unsolicited snapshots/jobs. The accelerated closed-background test passed 1,000 added jobs with one worker, at most two pending flags and 90 retained rows; peak RSS was **12,952 KiB**, with zero warm growth.

The unchanged Qt UI passed its full offscreen lifecycle gate with predecessor runtime `de3cd1c50a4f028d24df0e3b498e5de52fb9a682` (Safe `ed5665b77fe2f572e08b6496790b444ceb31c8f21aa6177bf50cea13a20f8572`): 200 warm-ups, 1,000 open/close cycles and a 60-second quiet interval. Attributed closed UI PSS was **14,433 KiB** over a **75,647 KiB** baseline, with warm PSS growth (**1,332 KiB**) and zero GUI/backend quiet CPU. The existing 20 MiB attributed-PSS, 2 MiB growth and 0.5% quiet-CPU limits were unchanged. No desktop window was mapped or user input captured.

## Read-only live acceptance

The final Safe executable passed temporary-cache checks for all three configured accounts using existing read-only bar grants. Cached full reads and partial threads were available; the second unchanged-history update added no list, metadata or body fetches. Existing retained body hashes stayed unchanged. The previously reported search/header case also returned a complete first-result body.

All six size-mismatch refusals observed in the initial sample disappeared after the narrowly scoped inline-text fix. One message still exceeded an existing supported-size limit and remained explicitly refused; this qualification does not claim every sampled message has a supported body. Private receipts retain only anonymous counts, status codes and executable identity. No production message/contact/invitation mutation, new consent, keyring/config change or actual installed-cache write occurred during these checks; temporary copies and owned processes were removed.

## Native ARM Debug performance gate

The initial native ARM CI job for publication revision `95b733e7ff3ed3e814fbfa345f3ccf3893837033` failed the existing 30-second refresh deadline in the maximum-cache Debug workload. Earlier ARM unit, bar, held-cache and UI checks passed; x86_64 completed all gates. [The failed run](https://github.com/technologylab-ai/omagma/actions/runs/37308738326) and receipts remain preserved; publication was skipped.

Source `c5d1473b996fcbec43e7405b103fb76fe104253b` avoids copies of unescaped strings from an owned immutable index buffer, checks whether rows are already sorted before sorting, and inserts/repositions one row rather than sorting the complete index for each update. Regression tests cover caller lifetime, escaped strings, timestamp/ID ties, legacy unsorted indexes, immutable-body hashes and tail eviction. Locking, generation checks, atomic commits, workload, byte/count budgets and deadlines are unchanged.

The unchanged local maximum-cache run completed in 10.14 seconds in Debug and 1.47 seconds in Safe after the change. These process lifetimes are not a controlled architecture benchmark; the subsequent native ARM gate must establish its own result.

## Published artifacts and deployment

[Native release run 37313908584](https://github.com/technologylab-ai/omagma/actions/runs/37313908584) passed all gates on Linux x86_64 and arm64 at publication/tag revision `e91e1e86f759e18c931f2172b66ddb206ed8ff32`. Runtime source is `c5d1473b996fcbec43e7405b103fb76fe104253b`. ARM's unchanged maximum-cache workload completed in **22.73 seconds in Debug** and **3.40 seconds in Safe**, inside the existing 30-second deadline. Hosted x86_64 measured 17.07 / 3.09 seconds; these separate hosts/lifetimes do not establish an architecture cost. The earlier failed run remains preserved.

| Published static-musl artifact | Safe SHA-256 |
| --- | --- |
| Linux x86_64 | `597009ad9dc3616c8f5473cc70f411ce280b7e640c86c50def0f6caaf02b712d` |
| Linux arm64 | `d103b312cdc44e529ae59d7a684834dda5fb0737d90211cfc27d1d2441f5ebd9` |

Both architectures passed 209 unit executions in each mode, 48 CLI / 12 held-cache / five UI / maximum-cache / six background / 19 PTY / seven wire cases in Debug and Safe, plus separate Safe CLI/TUI 1,000-cycle memory gates. All four terminal memory runs had zero warm growth, zero quiet CPU and no allocation refusals; neither TUI emitted quiet-window bytes. Native ARM backend evidence does not establish ARM desktop integration.

The actual downloaded bundles passed all checksums, static ELF checks without PT_INTERP or DT_NEEDED, version/reservation agreement, normalized archive metadata and the exact 230-file public tree. The downloaded x86_64 executable is byte-identical to the locally qualified Safe artifact. It independently passed 48 CLI / 12 cache / five UI / six background / 19 PTY / seven wire cases, 13 bar integration / 13 HTTP/HTTPS cases and its typed callback probe. Identical bytes did not require another 1,000-cycle soak.

The final x86_64 binary also passed fresh local bar memory and closed-background gates: peak RSS **12,992 / 12,996 KiB**, zero warm growth and quiet CPU, at most one worker/two pending flags and 90 rows. The unchanged Qt component's earlier offscreen receipt retains its own executable identity above.

The downloaded x86_64 backend was installed atomically with a private backup, then a supported plugin rescan preserved the shell instance, closed popup, private account/profile settings and command/plugin links. Running executable identity and old-backend reaping were verified. The requested user timer is enabled at five minutes; its first read-only run finished successfully, all three account caches held recent history checkpoints within count/byte limits, and no cache process remained between runs. Cache updates preserve local drafts and recovery records. No production mail/contact/invitation mutation or additional consent occurred during this deployment.
