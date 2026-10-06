# Omagma 0.2.4 release qualification

Dated 2026-10-06. Local correctness/resource qualification, all four native CI jobs, publication, downloaded-artifact checks, Homebrew installation/testing and Linux deployment are complete. Earlier releases and dated evidence remain unchanged. The TUI and agent CLI remain experimental.

## Source and executable identity

Runtime source: `80332934766f9f45af2ba4c92d466d53b27c8bf4`. Package and manifest version: **0.2.4**. Exact compiler: **Zig 0.17.0**. Local execution: native Linux x86_64, baseline CPU, static musl.

- Debug SHA-256: `fadbdca173973e4de3e91e087f330088f3218608b2d814c9da4e7b85061fd263`.
- Safe SHA-256: `8d251c195271bd703ccf3ce57cad12aec344db0f88e6a19eb48880af21b9a6cc`.

The subsequent Darwin-only deletion-output fix is source `a82e3a0f4d88b0db1ee4d0093dba5a0dbab0eaa0`. Repackaging that source produces **identical Linux release bytes**, SHA-256 `5483e981701fb06b34f6a69d6f47b6c4fd236862ba87df4c031129553578dc03`. The stripped packaged executable is distinct from the source-build Safe executable above; the resource results below identify the packaged bytes directly.

The builds passed the 340-test graph: 214 main, 41 codec and 85 provider tests. Unchanged codec/provider targets may be Zig-cache hits; active executable/probe entry points compiled in both modes.

The final sequential qualification passed **50 Debug jobs** and **37 Safe jobs**. Both modes include their own four compiled probes. Debug additionally includes 12 static fixture/parser/packaging checks and the 1,000-replacement JavaScript model check. Every accepted job records its executable/compiler/mode identity and no surviving observed owned children.

Test-only follow-ups replace transient attachment-success notice expectations with durable attachment rows, sizes and independently decoded persisted bytes/digests. Failed original receipts remain preserved. Same-artifact resumptions reuse only independently verified successful jobs with the identical binary SHA; no different runtime artifact's results are reused.

## Completed local correctness

All account, mail, draft and contact fixtures are fictional and caches/PTYs are isolated. Explicit synthetic send cases exercise review and operation receipts; they do not authorize or perform production Gmail writes. Tests neither map desktop windows nor change installed configuration, account grants or user Keychain state.

| Suite | Debug | Safe |
| --- | ---: | ---: |
| Bar integration | 13/13 | 13/13 |
| Bounded HTTP/HTTPS transport | 13/13 | 13/13 |
| Agent/one-shot CLI | 48/48 | 48/48 |
| Held-provider cache/navigation | 12/12 | 12/12 |
| Layout, theme, Contacts and Back/search | 5/5 | 5/5 |
| Maximum-cache workload | 1/1 | 1/1 |
| Background refresh/lease/cancellation | 6/6 | 6/6 |
| Editor/lifecycle PTY workflows | 19/19 | 19/19 |
| Independent loopback wire cases | 7/7 | 7/7 |
| Physical repaint | 3/3 | 3/3 |
| SGR mouse workflows | 5/5 | 5/5 |
| Non-resource HTML/provenance/security cases | 6/6 | 6/6 |
| New-feature focused suites | 16/16 | 16/16 |
| Standalone compiled probes | 4/4 | 4/4 |

The seven loopback cases establish wire/redirect/cancellation behavior; they are separate from HTTPS verification. The exact-2-MiB HTML 1,000-cycle/60-second resource case is also separate and is not included in the six ordinary HTML cases above.

The 16 focused suites cover backend batch/undo/identities and recovery, account-scoped cache windows, compose/reply/reply-all attachments, bulk triage, reader context, bidirectional cached scrolling, real fetch fractions, incremental loading, wheel pagination, local account/help controls, responsive reader/composer/status drawing, historical local timezone/DST, cached recipient completion and editor-result notice lifetime. Cached mail and Contacts remain usable while provider work is held. Fresh compose has its own draft preview; reply retains the intended original context. Unsafe paths, FIFO reads, overwrite attempts and implicit sends remain rejected.

## Maximum-cache workload

Both modes seed 2,000 metadata records, add 100 full messages and delete ten. The newest 2,000 records remain, with 102 independently validated body references and preserved existing body digests. Explicit prefetch is bounded at 64; 36 explicit literal-ID reads complete the original 100-new-body workload. The refresh deadline, disk quota and memory cap are unchanged; the receipt separates refresh from those explicit reads.

| Measure | Debug | Safe |
| --- | ---: | ---: |
| Refresh time, seconds | 5.6328 | 1.1381 |
| Additional 36 reads, seconds | 7.0008 | 1.3437 |
| Application-owned heap peak, bytes | 63,787,260 | 63,787,974 |
| Refused allocations | 0 | 0 |
| Cache bytes | 3,396,611 | 3,396,611 |

The limits remain 64 MiB terminal heap and 256 MiB cache bytes per account. This correctness stress is not a settled RSS/PSS or 1,000-cycle memory measurement. Runtime/libc storage, fixed reservations and whole-process resident memory remain distinct from allocator accounting.

## Preserved failures and application fixes

Earlier failed candidates remain recorded with their actual source and executable identities. The fixes address application behavior: preserving the current reader card across an asynchronous same-thread response; retaining editor action notices during background work; deciding exit-time draft persistence from the actual typed save acknowledgement rather than a global warning; and preventing background recipient hints from erasing a same-context attachment-refusal diagnostic.

An owned-PTY trace identified the last diagnostic race precisely: a queued cached-recipient job wrote a loading hint after the FIFO refusal, despite an unchanged compose status context. The fixed candidate passes the original two-second refusal, exact Help diagnostic, private persisted-draft, no-send and terminal-restoration oracles.

Large plaintext fallback drawing received allocation-free fast paths without changing the complete body, semantic layout limits, deadlines or resource thresholds. Short diagnostic runs retain their explicit non-acceptance classification; they cannot substitute for the full Safe resource gate.

The shared child-wait cancellation cleanup finding is recorded separately with the compiler-source comparison. These application ownership/status/rendering and test-oracle findings are not demonstrated Zig compiler regressions.

## Actual packaged Linux executable

The stripped Linux x86_64 executable passed normalized archive/privacy/checksum/version and static ELF qualification, followed by 13 bar integration, 13 bounded HTTP/HTTPS, 48 CLI and seven independent loopback wire cases. The corrected multiple-file composer fixture passed fresh compose, reply and reply-all, including exact persisted filename/size/decoded bytes/digests, mouse add/remove, review and no sends. All observed owned children were cleaned.

The fixture waits for the complete composer pane **and footer** within its original deadline. A CI failure had observed the first half of a valid terminal repaint before the footer bytes arrived; its failed log remains preserved. This test-only readiness correction changes no product behavior or timeout. Actual published-download verification is recorded separately below.

A later native ARM Debug mouse failure exposed another incomplete readiness predicate: restored editor protocol/body alone does not establish that the intentional foreground local-save fence has completed. The corrected test waits for the existing acknowledged-save sync row and saved title, positive editor-return notice, retained body and exact single tracking mode 1002 within the same deadline. It then proves the real Subject click/typed value, the same completed editor PID/action and no editor re-entry. The corrected case passed separately on the source-build Debug executable and actual packaged Safe executable, retaining zero provider mutations/sends, unchanged mail/contact/journal state and terminal/reporting restoration. The original failure and the distinction between observed cells and inferred event timing remain preserved; no runtime change, sleep, click retry or deadline extension was introduced.

## Packaged Safe memory and quiet acceptance

All six resource gates passed sequentially on the actual packaged Linux executable identified above. The five quiet gates are **backend, offscreen UI, terminal CLI, terminal TUI and exact-2-MiB HTML fallback**. Each completes 1,000 measured cycles and its own 60-second idle interval. Backend/CLI/TUI/HTML use 100 warm-ups; offscreen UI uses 200. All five observed zero quiet CPU. The two terminal rendering workloads emitted zero quiet bytes.

| Packaged process workload | Late-quarter RSS / PSS (KiB) | Warm growth (KiB) | OS RSS high-water (KiB) | Application-owned heap peak (bytes) |
| --- | ---: | ---: | ---: | ---: |
| Bar backend | 7,240 / not sampled | 0 | 7,248 | Fixed reservation accounted separately |
| Terminal CLI | 7,648 / 7,640 | 0 | 11,532 | 4,855,461 |
| Terminal TUI | 10,328 / 10,320 | 36 | 13,884 | 5,833,335 |
| Exact-2-MiB HTML fallback | 23,748 / 23,740 | -48 | 34,652 | 56,758,610 |

The unchanged terminal thresholds are a 64 MiB application-owned heap ceiling, at most 4 MiB warm median RSS/PSS growth and less than 0.5% of one core while quiet. The backend retains its separate 16 MiB reservation, 64 MiB process-RSS ceiling and 2 MiB warm-growth ceiling. All relevant allocator checks report zero refused allocations. Whole-process RSS/PSS, fixed reservations and allocator peaks are different measurements; no absolute terminal RSS/PSS ceiling is inferred.

The HTML input is exactly 2 MiB. Semantic complexity refusal retains the **complete plaintext fallback**: the test reaches its tail and returns home, with one document parse, one layout attempt and one fallback throughout 1,000 navigation cycles. Measured navigation took 97.5145 seconds and the quiet interval 60.0017 seconds. A shorter diagnostic run retains its non-acceptance classification and is not used for these results.

The offscreen Qt/Quickshell lifecycle test exercises 1,000 popup open/close cycles after 200 warm-ups, retaining at most 90 rows across three fictional accounts. Its closed host ended at 101,752 KiB RSS / 78,152 KiB PSS; the independent host baseline was 64,140 KiB PSS, leaving 14,012 KiB incremental closed PSS in this process lifetime. Warm PSS/private growth was -404/-644 KiB. Both GUI and backend quiet CPU were zero, the generation remained unchanged, and all 1,204 popup creations matched destructions. This is offscreen lifecycle/resource evidence, not compositor input or a live desktop measurement.

The **background scheduling fixture gate is separate**: it accelerates an active scheduler past 1,000 completed jobs (1,001 observed), with one active and at most two pending jobs, 90 retained rows, 116 KiB warm RSS growth and 8,032 KiB OS RSS high-water. In fixture mode, its `--idle-seconds` argument does not create a quiet interval. It establishes bounded scheduling/growth, not a sixth 60-second quiet CPU/output observation.

## Native CI and publication

Both prior Mac CI architectures reached packaged CLI/transport/lifecycle, then failed the Keychain upgrade positive acknowledgement. The native owner traced this to the application's 256-byte capture of human-readable signed-deletion output. Source `a82e3a0` ignores that output while retaining the finite owned-child wait and an independent native-absence acknowledgement. This is application subprocess-output handling, not a demonstrated Zig 0.17.0 regression. Corrected native Keychain/upgrade/re-sign gates passed before publication; original failed receipts remain unchanged.

[Main release CI 37511782893](https://github.com/technologylab-ai/omagma/actions/runs/37511782893) completed successfully on native Ubuntu 24.04 x86_64/arm64 and macOS 15 Intel/Apple Silicon. All four jobs passed their architecture-appropriate Debug/Safe correctness, active entry points, actual packaged-binary checks, credential-store/lifecycle and resource gates. Linux jobs cover static musl and the corrected mouse save-ACK predicate; Mac jobs cover system-framework linkage, native Keychain, guardian terminal/editor restoration, detached launch and separate RSS/physical-footprint measurements. Offscreen Qt lifecycle/resource evidence comes from the local x86_64 run above; GitHub CI does not run the Qt harness. Native backend/owned-PTY coverage is separate from live desktop integration. Linux background fixtures establish active scheduling/growth rather than a quiet interval.

The [v0.2.4 release](https://github.com/technologylab-ai/omagma/releases/tag/v0.2.4) was published at source/tag commit `33e24c689fc38de1b8cfa77c8a641ad40b80ea3c` on 2026-10-06. It contains ten assets: four OS/architecture bundles, four raw executables, `LICENSES.txt` and `SHA256SUMS`. Publication waited for all four native jobs. The automated Homebrew update job completed successfully. Earlier releases and their published assets were not replaced.

| Published executable | SHA-256 |
| --- | --- |
| Linux x86_64 | `5483e981701fb06b34f6a69d6f47b6c4fd236862ba87df4c031129553578dc03` |
| Linux arm64 | `7d573e612060515104a63e9212d9567445ca97f7050945ec9ca179f6b605bb27` |
| macOS x86_64 | `d0acaff697212cc6250dc9302a2021aa8f4e2ab162d112fc9764b27377f0b3d7` |
| macOS arm64 | `17ce5c04818b1acd2612ce4f576c061f2dd8afc3580148a429ce47b30bd15bd2` |

Linux executables have neither ELF PT_INTERP nor DT_NEEDED. Native macOS binaries target baseline CPUs and macOS **13.0 or newer**; their system dependencies are CoreFoundation, Security, libSystem and libobjc, with no RPATH, external application library, DWARF or private build-path dependency. Mach-O SDK metadata is 27.0, distinct from the 13.0 deployment floor. Normalized public bundles contain 313 entries with exact manifest/backend version agreement. Checksums identify the actual artifacts; native CI qualifies each architecture without implying ARM desktop installation.

## Native CI resource observations

These are separate process lifetimes from the local measurements above. All rows complete 100 warm-ups, 1,000 measured cycles and at least 60 quiet seconds. They match the published executable hashes above, retain unchanged terminal heap/growth/quiet thresholds and report zero refused allocations and quiet CPU. TUI quiet windows emit zero bytes.

| Native Linux CI process | Late RSS / PSS (KiB) | Warm growth (KiB) | OS RSS high-water (KiB) | Heap peak (bytes) |
| --- | ---: | ---: | ---: | ---: |
| x86_64 CLI | 8,276 / 8,268 | 0 | 12,368 | 4,855,461 |
| x86_64 TUI | 11,144 / 11,136 | 0 | 14,328 | 5,605,849 |
| arm64 CLI | 6,640 / 6,636 | 0 | 10,340 | 5,104,963 |
| arm64 TUI | 9,324 / 9,320 | 72 | 12,352 | 5,739,432 |

Exact-2-MiB HTML gates also pass 1,000/60 with complete fallback tails and single parse/layout/fallback reuse. x86_64 has 27,804/27,796 KiB late RSS/PSS, zero warm growth, 37,980 KiB OS high-water and 56,754,632-byte heap peak. ARM has 20,176/20,172 KiB, 24 KiB warm growth, 33,872 KiB high-water and 49,849,540-byte heap peak. Both have zero refusals, quiet CPU and quiet output. Native backend warm RSS growth is 0/52 KiB for x86_64/ARM, with zero quiet CPU. Separate active background fixtures complete 1,000 jobs with growth 0/70 KiB and bounded one-active/two-pending/90-retained state; they do not establish a quiet interval.

| Native macOS CI process | Late RSS / physical footprint (KiB) | RSS / footprint growth (KiB) | Sampled peak RSS (KiB) | Heap peak (bytes) |
| --- | ---: | ---: | ---: | ---: |
| Intel CLI | 7,892 / 5,916 | 0 / 0 | 10,864 | 4,855,498 |
| Intel TUI | 11,500 / 8,752 | 0 / 0 | 14,396 | 6,622,597 |
| Apple Silicon CLI | 8,480 / 6,416.94 | 0 / 0 | 11,728 | 5,451,414 |
| Apple Silicon TUI | 13,616 / 10,961.25 | 32 / 48.06 | 16,352 | 6,598,876 |

macOS physical footprint is not Linux PSS, and sampled peak RSS is not Linux VmHWM. Earlier local Mac measurements retain their own executable identity; they are not relabeled as results for the published `17ce5c…` bytes. These measurements do not isolate compiler, architecture, SDK or operating-system costs.

## Actual downloaded Linux executable

The downloaded Linux x86_64 raw executable has SHA-256 `5483e981701fb06b34f6a69d6f47b6c4fd236862ba87df4c031129553578dc03`, **identical to the packaged bytes measured above**. The downloaded release passes the nine-entry checksum inventory, normalized/privacy-audited 313-entry bundle, static ELF/no-PT_INTERP/no-DT_NEEDED, manifest/backend version and budget checks.

Fresh checks against that downloaded path passed 13 integration, 13 HTTP/HTTPS, 48 agent/one-shot CLI and seven independent loopback wire cases. Build-info independently reports application 0.2.4, exact Zig 0.17.0 and Safe. All observed owned children were cleaned. The identical full SHA allows existing accepted resource receipts to apply without repeating the 1,000-cycle soaks. Native ARM backend CI remains separate from ARM desktop deployment.

## Actual downloaded macOS and Homebrew installation

The downloaded ARM executable has the exact published `17ce5c…` hash above; its bundle hash is `43ec9419908556ba1a0b52889645705939eef5789a27753c255ebe3c10acfbef`. The nine-entry manifest, normalized 313-entry source bundle, exact manifest/backend version, baseline ARM Mach-O, 13.0 floor, system dependencies and private-path/RPATH/DWARF exclusions passed. The downloaded executable independently passed 48 CLI and seven wire cases, four native terminal/editor/termination cases, detached handshake/descriptor/signal-mask and failure cleanup, and private native Keychain normal, exact re-sign, raw-filename, account/scope isolation, size, lock and parent-directory oracles.

The preferred [Homebrew tap](https://github.com/renerocksai/homebrew-tap) advanced by fast-forward to `294dadfe0e77e34733cbc93c3400df26012603bc`. The existing Omajot formula remained byte-identical. Actual `brew install renerocksai/tap/omagma` and `brew test omagma` both succeeded on Apple Silicon. The installed 0.2.4 executable has the **same full published `17ce5c…` SHA**, and separately passed the 48 CLI, seven wire and native lifecycle/Keychain checks above. Documentation, setup skill, fictional examples and licenses are installed. No new resource measurement was needed for identical qualified bytes; the re-sign oracle independently checks the credential path if Homebrew changes the signature.

These checks use private synthetic namespaces and preserve existing user configuration, default Keychain, profiles, services and consent. They do not perform a production Gmail write. Actual Mac installation is Apple Silicon evidence; Intel installation is not inferred from native CI.

## Linux deployment and live documentation

The downloaded `5483e981…` executable was installed atomically with a private backup and the supported Omarchy plugin rescan. The running daemon's executable hash matches published bytes. Protected account/profile, client/grant and shell files retain hashes and permissions; the existing shell process survives the rescan. The five-minute cache-refresh timer remains enabled and active. No new consent or production mutation was issued, and owned test children were cleaned before deployment.

[Pages deployment 37516315960](https://github.com/technologylab-ai/omagma/actions/runs/37516315960) succeeded. Live HTML checks verify both URL-first agent copy prompts, preferred Homebrew instructions and public setup/skill routes with fictional examples. Earlier nine-route desktop/mobile/tablet headless QA remains synthetic website-layout evidence, separate from installed-app desktop testing. Post-release evidence/docs publication does not replace immutable v0.2.4 assets or older releases.
