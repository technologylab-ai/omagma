# Native HTML reader qualification, 0.2.3 pre-mouse checkpoint

Dated 2026-10-05. This records the qualified **pre-mouse** runtime checkpoint. The TUI and agent CLI remain experimental. The subsequent mouse implementation is outside these receipts; native ARM CI, publication and deployment of 0.2.3 are pending. Earlier releases, evidence and failed receipts remain unchanged.

## Source and executable identity

Runtime source: `e4f852512646ce7cb4931677d391d3a49b82faeb`. Package and manifest version: **0.2.3**. Exact compiler: **Zig 0.17.0**. Local execution: native Linux x86_64, baseline CPU, static musl.

- Debug SHA-256: `47aa75a3d98d020452146f38e556f37dffa006baa390224459d3d5465aa966f9`.
- Safe SHA-256: `9773090d7bda7c19ef4e3d36cfed338cf496bd3c7c959e35c8ece301fa5d414e`.

The sequential driver (`html-final-v023-1-driver.json`) passed all 18 jobs and recorded all owned children reaped. These checks used fictional accounts and isolated caches: no live helper, production writes, desktop interaction or new consent was involved. The additional repaint receipts identify the same two executables.

## Reader behavior and limits

The native semantic HTML reader preserves headings, emphasis, underline, code, strike, preformatted spacing, lists, quotes and bounded data tables. Presentation and nested layout tables flatten into readable content; narrow tables use a stacked representation. The filter suppresses hidden content, scripts, styles and unsafe terminal controls. It loads no resources or remote images, runs no JavaScript and has no CSS engine. Styled links do not create OSC8 actions or open a browser. This is a bounded mail filter, not a complete browser or HTML-standard implementation.

Nonempty plain MIME content remains preferred. Full messages carry `bodySource` as `plain`, `html` or `unknown`; metadata rows have unknown provenance. CLI and reply `bodyText` retain the existing conversion behavior. An old cached record with unknown provenance is eligible for rich display only when `sanitizeText(htmlToText(bodyHtml))` exactly equals its stored plain fallback. That compatibility inference performs no provider request and rewrites no body file or hash; it cannot establish the original preference when an old plain part happens to be identical.

Input and semantic text remain bounded at **2 MiB**. Document limits include 1,024 blocks, 8,192 spans, 4,096 table cells, 32 columns and 256 rows. Layout remains bounded at 16,384 lines and 65,536 runs. Complexity refusal displays the complete stored plain fallback rather than refusing the body. The exact-2-MiB fixture exceeds the layout line cap, so its qualification establishes **complete plain fallback and reachable tail**, not formatted rendering of that entire boundary body.

Existing transport, MIME and cache limits are unchanged: 3 MiB Google wire responses, 2 MiB decoded plain/HTML leaves, 3 MiB aggregate decoded MIME bytes, and 32 KiB header bytes per entity/part. A normalized message containing both HTML and its plain fallback can exceed the wire size; the boundary DTO is about 4.3 MiB. The TUI response bound is 32 MiB within the 64 MiB terminal heap cap. The default disk policy remains the newest 2,000 messages and a 256 MiB byte guard per account.

## Synthetic correctness

Debug and Safe each passed **235 unit executions**: 124 main, 41 codec and 70 provider. All active executables and probes compiled.

| Suite | Debug | Safe |
| --- | ---: | ---: |
| Agent/one-shot CLI | 48/48 | 48/48 |
| Held-provider cache/navigation | 12/12 | 12/12 |
| Layout, theme, Contacts and Back/search | 5/5 | 5/5 |
| Maximum-cache workload | 1/1 | 1/1 |
| Background refresh/lease/cancellation | 6/6 | 6/6 |
| Editor/lifecycle PTY workflows | 19/19 | 19/19 |
| Independent loopback transport | 7/7 | 7/7 |
| HTML/provenance/security/resource cases | 7/7 | 7/7 |
| Follow-up physical repaint cases | 3/3 | 3/3 |

The Debug (`html-final-v023-1-html-debug.json`) and Safe HTML receipts (`html-final-v023-1-html-safe.json`) establish plain preference, unchanged legacy conversion and cached body digests across three fictional accounts. Cached reads work before a held remote refresh completes. Normal documents retain styles and table alignment; repeated navigation reuses the parsed document and layout. Safety fixtures make zero resource requests.

The Debug (`html-repaint-final-debug.json`) and Safe repaint receipts (`html-repaint-final-safe.json`) separately cover a physical terminal resize from 225 to 251 columns, including cells beyond the 240-column logical layout limit. They verify removal of old borders/carets, immediate tail display after End and wider/taller reflow, and a 27-column navigation pane for a fictional 21-character account address.

The unchanged maximum-cache workload starts with 2,000 metadata records, adds 100 full messages and deletes ten. It retains the newest 2,000, validates 102 body references and hashes, and finds no orphan bodies. Debug/Safe refresh took **8.22 / 1.41 seconds**, with capped heap peaks **44,231,172 / 44,214,520 bytes**, zero allocation refusals and disk use **3,392,173 bytes**. The 30-second refresh deadline and workload were not increased.

## Preserved failures and application fixes

The initial valid exact-2-MiB HTML fixture failed with `OutOfMemory` during cache prefetch, before the reader opened. The failed HTML run (`html-third-debug.json`) remains preserved. Overlapping fixture, decoded HTML, plain fallback and internal JSON conversions consumed the bounded arena. Typed prefetch now avoids a message-to-JSON-to-message round trip while preserving the original account/capability checks, exact response identity, external-body checks and joined deadlines. Precise bounded reservations avoid repeated large output allocations.

Consumer fixes release response-validation scratch, defer rich preparation until response scratch is freed, and release completed worker storage before drawing. The layout checks an unavoidable hard-line lower bound before allocating vectors and frees failed layout scratch. The body and fallback stay complete; no fixture or memory ceiling was reduced or raised.

An earlier End-key diagnostic reached the tail only after another key because scrolling was clamped after painting. The reader now clamps to the actual viewport before painting and performs at most one cleared repaint when reflow changes the measured row count. A small one-cycle/one-second diagnostic was marked `acceptanceRun: false`; it is not a substitute for the final resource acceptance below. Initial test-oracle and allocation failures also remain preserved. These are application ownership, allocation and rendering fixes, not demonstrated Zig compiler regressions.

## Safe memory and quiet acceptance

Each Safe gate uses **100 warm-ups, 1,000 measured cycles and 60 quiet seconds**. The ordinary CLI (`html-final-v023-1-memory-cli-safe.json`) and TUI receipts (`html-final-v023-1-memory-tui-safe.json`) are separate from the exact-2-MiB HTML resource case.

| Safe workload | Settled RSS / PSS (KiB) | Warm growth (KiB) | OS peak RSS (KiB) | Capped heap peak (bytes) |
| --- | ---: | ---: | ---: | ---: |
| Ordinary CLI | 9,016 / 9,008 | 0 | 12,868 | 4,698,191 |
| Ordinary TUI | 11,628 / 11,620 | 40 | 14,500 | 5,273,534 |
| Exact-2-MiB HTML fallback | 27,896 / 27,888 | -4 | 38,540 | 56,049,942 |

All three had zero refused allocations and zero quiet CPU ticks. Both TUI workloads emitted no quiet-window bytes. The HTML case reached its complete tail and retained exactly one document parse, one layout attempt and one explicit fallback throughout navigation. Debug also passed 100 measured large-body cycles and a two-second quiet observation; that shorter run is explicitly not the 1,000-cycle acceptance gate.

The unchanged limits are 64 MiB capped terminal heap, at most 4 MiB warm median growth and less than 0.5% of one core while quiet. The separate fixed backend/HTTP reservation remains 16 MiB. RSS/PSS and OS high-water marks describe the whole process, including touched fixed storage, runtime and stacks; they are not interchangeable with allocator accounting. No absolute terminal RSS/PSS acceptance ceiling is inferred from these measurements.

## Pending qualification and publication

This evidence qualifies only the pre-mouse checkpoint above. Mouse behavior requires its own source identity, regression checks and final evidence. Native x86_64/ARM release CI, downloaded-asset verification, publication and deployment of 0.2.3 remain pending. The published 0.2.2 release and its historical evidence are unchanged.
