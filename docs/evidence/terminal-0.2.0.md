# Terminal mail qualification, 0.2.0

Dated 2026-10-05. This expansion builds on the immutable v0.1.1 bar release; its historical artifacts and [compiler migration evidence](zig-0.17.0.md) are preserved. Terminal write acceptance uses fictional accounts. No production message, contact or invitation was changed.

## Exact source and scope

- Runtime source: `7568a2467b5a93142259bc50057a177c3acf7150`.
- Application/package/manifest version: **0.2.0**.
- Exact compiler: **Zig 0.17.0**, source `7647adab80dd088f4de3610fd245915a912eb6ad`.
- libvaxis: `6fd944a27fb3d6f596e981076381a3131f2448b4`; zigimg: `c701c9f99779d7ddf594dcc6da8f858fd277d61f`; uucode: `ea62149739404a73c202b48a33bf6dd2af4bd9b0`.
- Local qualification: native Linux x86_64, static musl, baseline CPU, Debug and assertion-enabled Safe. LLVM builds include the terminal client. The system compiler was left unchanged.

The bar keeps separate read-only accounts, 30-row snapshots and configured Chrome-profile routing. Terminal modes add complete messages/threads, explicit pagination, bounded private caching, a Vim-oriented libvaxis TUI, split composition, `$EDITOR` takeover, contacts, reversible mail changes, attachments and iTIP invitation replies. Calendar views and permanent deletion are unsupported. No tmux or second terminal engine is required.

## Local terminal correctness

Both modes passed 120 unit executions across the main, codec and provider suites (52 + 21 + 47), and all active standalone probes compiled. Final artifact identities:

| Mode | SHA-256 |
| --- | --- |
| Debug | `79d85ca3a22ccd4d80f2ffbcdf57e688876c6d32c279a831b98767ab22100e65` |
| Safe, stripped | `046b6bd5ee929c6a47b576c091b6266316bce591e978fd09719cc3540b341279` |

Each final binary passed **42 CLI cases, 19 isolated PTY workflows and seven independent terminal HTTP tests**. Fixture and terminal-cell-model helpers passed 12 and six checks; the existing UI model passed its 1,000 replacement cycles. The test corpus contains three fictional accounts with 96 messages each and deliberately overlapping opaque IDs.

Checks cover account/cache/cursor isolation, MIME and charset decoding, reply/reply-all identity, binary attachments, draft restart and uncertain-send deduplication, private/special-file refusal, atomic disk-quota overlap, contact concurrency, invitation identities, bounded framing/backpressure, editor failure/interruption and terminal restoration. The HTTP peer verified literal headers and the complete 128 KiB request, rejected redirects without forwarding, enforced internal ten-second stalled/trickled deadlines and rejected requests/responses over the 3 MiB transport bound.

## Terminal memory and quiet CPU

Both Safe workloads completed 100 warm-up cycles, 1,000 measured cycles and a 60-second quiet interval. Acceptance thresholds remained 4 MiB maximum warm RSS/PSS growth and less than 0.5% of one CPU core. Neither process grew after warm-up or used a CPU tick during its quiet minute; the TUI emitted no unsolicited render output.

| Whole process | Settled RSS / PSS | OS peak RSS | Terminal heap peak | Rejected allocations |
| --- | ---: | ---: | ---: | ---: |
| Agent CLI | 7,000 / 7,000 KiB | 10,768 KiB | 7,235,433 bytes | 0 |
| TUI | 8,536 / 8,528 KiB | 12,400 KiB | 7,617,129 bytes | 0 |

The terminal allocator's 64 MiB ceiling and fixed backend/HTTP 16 MiB reservation are separate accounting bounds. Linux RSS/PSS measure the complete process including their touched pages, runtime and stacks. An external editor and terminal emulator have their own processes. These workload measurements are not absolute RSS guarantees. [Memory accounting](../MEMORY.md) and [reproduction contracts](../TERMINAL-VERIFICATION.md) provide details.

## Preserved failures and findings

Failed development receipts remain private and unchanged. Fixes addressed incorrect directory descriptor permissions, external-editor foreground restoration/readback ownership, rewriting an unchanged body during metadata-only mutation, and an input queue copied by value onto a bounded runtime stack. These are application defects, not established compiler regressions.

Independent PTY tests also exposed incomplete UTF-8 input loss at the pinned libvaxis 1,024-byte read boundary. A project-owned bounded adapter now preserves trailing partial codepoints and owns queued text. The exact 2,349-byte body and eight forced fragmentation cases pass in both modes. Source inspection separately established the pre-existing linked-libc foreground-wrapper gap and the exact 0.17 removal of deprecated `Allocator.dupeZ`. [Durable wiki findings](../ZIG017-WIKI-FOLLOWUP.md) distinguish dependency findings, source/API changes and application bugs.

## Remaining release and live boundaries

Local bar regression passed 13 integration and 13 transport cases in each mode, launch/callback/FD probes and an isolated synthetic Secret Service lifecycle. Safe backend memory passed 1,000 cycles with a 6,516 KiB peak RSS, zero warm growth and zero quiet CPU. The closed-background workload passed 1,001 refresh jobs with one active worker, bounded pending jobs and a 6,512 KiB peak RSS.

The unchanged offscreen Quickshell UI passed 1,000 open/close cycles after 200 warm-ups. Omagma's closed UI share was 16,004 KiB PSS over baseline, warm growth 296 KiB, with zero GUI/backend quiet CPU. All 1,204 views were destroyed. Its existing 20 MiB attributed-PSS and 2 MiB warm-growth gates were preserved; this is Qt lifecycle qualification, not a new compositor input claim.

Native hosted ARM qualification, actual downloaded release verification and deployment are still pending at this checkpoint. Final results will be added after those gates, without replacing historical release assets.

Separate terminal Desktop OAuth credentials/capabilities preserve the bar's strict read-only grant. Live read paging, write permissions, Gmail/People behavior and recipient delivery need dedicated live acceptance. A user-provided test mailbox is required for initial sends, contact changes and invitation replies; synthetic success does not establish remote deduplication or delivery.
