# Incoming-mail compatibility qualification, 0.2.1

Dated 2026-10-05. This patch follows the immutable [v0.2.0 terminal release](https://github.com/technologylab-ai/omagma/releases/tag/v0.2.0). Its [original qualification](terminal-0.2.0.md), assets and failed private live receipts remain unchanged. No production message, contact or invitation was changed.

## Observed problem

Initial read-only acceptance of the downloaded 0.2.0 executable exposed two incoming-header failures. An ASCII Reply-To local part longer than 64 bytes rejected a message page with `InvalidAddress`; a To header with more than 32 recipients rejected another page with `TooManyRecipients`. The composer’s sending restrictions were shared with incoming message parsing.

Independent fictional regressions reproduced both errors on the old executable before the fix. No private addresses, message headers or identifiers are included here. These are application compatibility defects, not Zig 0.17 regressions. Header address syntax and SMTP transport limits are separate concerns. [RFC 5322, section 3.4.1](https://www.rfc-editor.org/rfc/rfc5322#section-3.4.1), [RFC 5321, section 4.5.3.1.1](https://www.rfc-editor.org/rfc/rfc5321#section-4.5.3.1.1).

## Change and exact source

Incoming address lists now own heap storage with at most 1,024 participants per address header. Address headers remain bounded to 16 KiB, aggregate headers to 32 KiB, whole addresses to 254 bytes and decoded display names to 256 bytes. RFC 2047 display names are decoded before applying the display-name limit. Existing supported ASCII grammar and injection checks are preserved.

Outgoing envelopes remain limited to 32 recipients and 64-byte local parts. Ordinary replies avoid copying unrelated To/Cc participants. Reply-all removes self and duplicates before enforcing the final sending limit, and returns an error without creating a draft if that envelope is too large. No recipients are silently dropped.

- Runtime source: `858ce32d21625a136fbed102d265e97bb95b0a48`.
- Publication/tag revision: `b8d25227681090a9be0d8364330e8115bb672ffb`; subsequent publication changes preserve that runtime source.
- Package/manifest version: **0.2.1**.
- Exact compiler: **Zig 0.17.0**, source `7647adab80dd088f4de3610fd245915a912eb6ad`.
- Local platform: native Linux x86_64, baseline CPU, static musl.
- Debug SHA-256: `f6c6106fef5b1817ac8b572f981f7fe0f5d7a5062407f7f60a3970998be35723`.
- Safe, stripped SHA-256: `4e936b367cdd6dd9ed5eac71ead732cb3b5f301cc047753ad8d5144b58b6e511`.

Both modes passed 141 unit executions (59 main, 28 codec, 54 provider). All active standalone probes and full executables compiled. Added unit checks independently cover 1,024/1,025 incoming participants, 32/33 outgoing participants, 64/65 local-part bytes, 256/257 decoded-name bytes, allocation-failure cleanup and reply identity.

## Terminal correctness

Debug and Safe each passed **45 CLI cases, 19 isolated PTY workflows and seven independent wire checks**. The fixture checker passed 13 independent checks and the terminal cell helper six. The original three-account, 96-message workload is unchanged; the new incoming-header cases apply a separate fictional fixture to temporary copies.

The three added CLI cases verify 34 delivered recipients and a 65-byte Reply-To local part through listing, full reading and complete threads in all three accounts. Ordinary reply preserves its intended recipient. Reply-all overflow and invalid outgoing Reply-To both fail without an orphan draft. Separate sending checks accept the literal 32-recipient/64-byte boundaries and reject 33/65 before journal or provider side effects.

## Terminal memory and quiet CPU

Safe CLI and TUI each passed 100 warm-up cycles, 1,000 measured cycles and a 60-second quiet interval. The unchanged workloads exercise all three fictional accounts. Both had zero warm RSS/PSS/private growth and zero measured quiet CPU; the TUI emitted no unsolicited output. The original 4 MiB growth and 0.5% quiet-CPU thresholds were preserved.

| Whole process | Settled RSS / PSS | OS peak RSS | Terminal heap peak | Rejected allocations |
| --- | ---: | ---: | ---: | ---: |
| Agent CLI | 6,932 / 6,932 KiB | 10,644 KiB | 6,692,585 bytes | 0 |
| TUI | 8,180 / 8,172 KiB | 12,032 KiB | 7,619,937 bytes | 0 |

The heap ceiling is 64 MiB; fixed backend/HTTP storage is a separate 16 MiB reservation. Whole-process RSS/PSS include their touched pages, runtime and stacks. These results establish the unchanged workloads, not absolute resident-memory guarantees. [Memory accounting](../MEMORY.md) preserves previous versions separately.

## Bar regression and live reads

Debug and Safe each passed the existing 13 integration and 13 HTTPS transport cases, launch/callback/FD probes and isolated synthetic Secret Service lifecycle. The model passed its 1,000 snapshot replacements. Safe backend memory passed 1,000 cycles with a 6,504 KiB peak RSS, zero warm growth and zero quiet CPU. The closed-background workload passed 1,001 jobs including its initial fetch, with one worker, bounded pending flags and a 6,508 KiB peak RSS.

The unchanged offscreen Qt UI passed 1,000 open/close cycles after 200 warm-ups. Attributed closed UI PSS was 12,476 KiB over a 42,918 KiB baseline, with declining warm PSS (-515 KiB), zero GUI/backend quiet CPU and all 1,204 views destroyed. The existing 20 MiB attributed-PSS and 2 MiB growth thresholds were unchanged. This verifies lifecycle behavior without mapping desktop windows or sending compositor input.

A separate private read-only test passed all three configured accounts using existing bar grants: each returned two 20-message pages, a full message and its thread. Cross-account/query cursors were rejected and unread state remained consistent. Receipts contain anonymous slots and counts; temporary caches and child processes were removed. No browser opening, contact access, explicit attachment request or mutation occurred.

## Release boundaries

[Native release CI run 37258436358](https://github.com/technologylab-ai/omagma/actions/runs/37258436358) passed on Linux x86_64 and arm64 with exact Zig 0.17.0. Each architecture passed 45 CLI cases, 19 isolated PTY workflows and seven wire checks in both Debug and Safe. Each also passed separate Safe CLI and TUI measurements with 100 warm-ups, 1,000 measured cycles and 60 quiet seconds. All four measurements had zero warm RSS/PSS/private growth, zero quiet CPU and no rejected allocations; neither TUI emitted quiet-window output. [Memory accounting](../MEMORY.md#terminal-modes-021) preserves these native CI measurements separately from the local table above.

| Native release artifact | Safe SHA-256 | Debug and Safe, each |
| --- | --- | --- |
| Linux x86_64 | `4e936b367cdd6dd9ed5eac71ead732cb3b5f301cc047753ad8d5144b58b6e511` | 45/45 CLI, 19/19 PTY, 7/7 wire |
| Linux arm64 | `6922dd901dda3b3d11becce72e8105ce12f7429b1739ea57fc569c07a76cf582` | 45/45 CLI, 19/19 PTY, 7/7 wire |

The published [v0.2.1 assets](https://github.com/technologylab-ai/omagma/releases/tag/v0.2.1) were downloaded and all five checksum entries verified. Both architectures passed static-executable, 207-member bundle, version/mode and bundled PATH checks. The actual downloaded x86_64 executable then passed **45/45 CLI, 19/19 PTY and 7/7 wire checks** in Safe mode. Its SHA-256 is identical to the local and native CI Safe executable above; the existing 1,000-cycle and private read-only qualifications therefore apply to those exact bytes without another soak or live terminal read. Downloaded receipts are retained as `terminal-v021-downloaded-{cli,pty,wire}.json`; earlier receipts remain unchanged. All owned test processes and peer threads were joined/reaped.

The initial raw download lacked execute permission and was refused before backend startup. Adding owner execute permission changed no executable bytes; its preflight receipt is preserved separately. Native arm64 terminal coverage does not establish arm64 desktop integration. Live sends, People changes and invitation delivery still need separate terminal permissions and an explicitly provided dedicated test mailbox; fictional write success does not establish remote delivery.

## Downloaded-release desktop deployment

The actual downloaded x86_64 executable additionally passed all 13 bar integration cases, all 13 HTTPS transport checks and the callback probe. A private read-only bar check fetched 30 messages for each of three accounts, retained 90 rows, checked account-specific Chrome launch arguments without opening a browser, and passed a 60-second quiet interval with zero CPU ticks, added jobs or events. It preserved the private configuration. The earlier full terminal live check of identical bytes fetched 40 messages per account and verified full messages and threads; neither check performed production writes or new consent.

The verified release executable was then installed atomically, with a private backup of the previous backend. The supported `shell rescanPlugins` call reloaded ordinary plugins while preserving keepLoaded authentication services. The Omarchy shell PID stayed unchanged, the old backend was reaped, and the running replacement's executable hash and reported version matched the release. Account/client/profile settings and the existing CLI/plugin links remained unchanged; the popup stayed closed. A fresh closed UI has no delivered snapshots until opened, so its row count was not used as proof of the backend's mail cache. No desktop window was mapped or keyboard input sent.

Five installed-backend samples were stable at 15,480 KiB RSS and 15,472 KiB PSS. Combined with the separately qualified 12,476 KiB UI attribution, the approximate three-account bar footprint is 27,948 KiB (28.6 MB), rounded to 29 MB in the README. [Memory accounting](../MEMORY.md) retains the distinction between live samples, synthetic UI attribution and historical versions. The published 0.1.0, 0.1.1 and 0.2.0 assets were not replaced.
