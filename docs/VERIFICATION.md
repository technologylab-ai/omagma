# Developer verification

Maintainer/test-harness reference. Normal installation uses a verified release
bundle and [account setup](SETUP.md); end users do not need Zig, fixtures, Python,
Node, PTYs or offscreen GUI checks. [Development](DEVELOPMENT.md) describes the
short local iteration loop. Select checks appropriate to the change; full
qualification and memory soaks belong to release/resource work.

Use Zig **0.17.0 exactly**. `safe` checks correctness and establishes release allocator/runtime evidence. CI builds and tests Safe only; Debug is optional for local development or investigations. Omarchy may still ship a 0.16.x compiler. Download and verify the [exact 0.17.0 archive](https://ziglang.org/download/0.17.0/) for the execution host's OS/CPU, extract it into a task-owned directory, and select it for this shell:

```sh
omagma_zig_dir=/absolute/path/to/extracted-zig-0.17.0
export PATH="$omagma_zig_dir:$PATH"
zig version
```

Require exactly `0.17.0` before building. Keep the global compiler unchanged and ensure nested Python/build tools inherit this `PATH`. The `build-info` command reports the executable's compiler and optimization mode without credentials; receipts use those values rather than a caller's asserted build label. Historical evidence stays attached to its actual compiler and source revision.

## Cooperative host measurement lock

Before a heavy build, benchmark or runtime suite on a shared host, reserve the host-local directory `/tmp/zig-http-measurement.lock`. Complete this protocol before the commands below:

1. Inspect existing measurement/build processes, including work that may not follow the protocol. Coordinate with other owners; never stop their workload to make a test run.
2. Acquire the directory with one atomic `mkdir`. If the path exists, treat it as busy and inspect `owner.json`. Missing or incomplete metadata is also busy. Checking for absence without acquiring does not reserve the host.
3. Write `owner.json` with owner identity, purpose, hostname, UTC start, owner PID, unique ownership token and working directory. On Linux, also record `/proc/PID/stat` start ticks to distinguish PID reuse.
4. Hold the reservation through the entire workload: build, baseline, warmup, measurements, quiet interval and cleanup of owned children. A reservation on one host does not reserve another. Lightweight editing can continue while a different owner holds the lock.
5. After all owned build/server/client processes have stopped, the owner verifies its exact path and token, unlinks only `owner.json`, then releases the directory with `rmdir`. Never recursively delete the lock or remove it because it is old. For an interrupted owner, inspect process identity and children and coordinate recovery; leave the lock in place while ownership is uncertain.

This is cooperative exclusion, not CPU isolation or proof of a quiet host. Recheck the host and acquire a fresh reservation for later work. If a coordinator owns the reservation, run only work it delegates and leave release to that owner. Keep local ownership metadata private.

## Release correctness inventory

The following commands use synthetic accounts and never authorize Gmail or edit installed desktop configuration:

```sh
zig build test probes -Doptimize=safe -j2
zig build -Doptimize=safe -j2
zig-out/bin/omagma build-info
zig-out/bin/auth_probe launch
zig-out/bin/auth_probe callback
zig-out/bin/callback_budget
zig-out/bin/transport_probe
python3 tests/integration.py --binary zig-out/bin/omagma --build-mode safe
python3 tests/probes/transport_check.py --binary zig-out/bin/omagma --build-mode safe --https
node tests/ui_model.mjs
```

Python 3 and Node.js are needed for the harnesses; UI checks also need Quickshell. The UI harness forces `QT_QPA_PLATFORM=offscreen`, removes graphical-session routing variables and uses `--fixtures --dry-run-open`. It starts an isolated shell, never installs the plugin and cleans up its owned processes.

`zig build probes` installs the standalone launch/FD, callback, callback-budget and transport executables. The HTTPS checks make an unauthenticated Google request expecting an unauthorized response; they do not read a mailbox or use OAuth credentials. Run keyring probes only with a separate session bus and temporary synthetic keyring, as in the [release workflow](../.github/workflows/release.yml), rather than against the desktop's account credentials.

Release CI first builds each native Safe bundle and runs the complete applicable
short CLI/TUI, fixture, integration and first-use suites. Only after all four
preflights pass does each platform prime its shared history executable, followed
by independent correctness, growing-mail, retained-history and resource jobs.
Unique test executables compile in parallel in their owning jobs. An offline policy test enforces that dependency order.
The default `zig build test` includes all three correctness groups; CI runs them
as `test-main`, `test-extra` and `test-native-memory` on separate runners.
Shared dependencies compile together rather than in 31 separate extra roots.
History shards select their case at runtime and share a single executable.
Every test executes even when restored compilation caches are warm.

Native preflights have a 90-minute outer allowance; individual heavy gates have
60 minutes. These are failure bounds, not target durations. Individual test
watchdogs remain 120 seconds for ordinary tests, 300 seconds for growing-mail
stress and 1,200 seconds for each retained-history case. Each resource job runs
its checks serially without another gate competing on the runner. The existing
thresholds, 1,000-cycle workloads, 60-second quiet windows and child cleanup
remain required. These budgets are separate from application request deadlines.
Preserve failed receipts; retry the failed job in the same source run, retaining
successful gates. See [release provenance and retries](RELEASING.md#continuous-release-checks).
Terminal workflows have separate [correctness and memory checks](TERMINAL-VERIFICATION.md);
their allocation ceiling and measurements do not replace the bar gates below.

Backend integration covers bounded configuration, account isolation, empty and failed fetches, cancellation, background scheduling, owner exit and stdout backpressure. Model checks cover arbitrary configured domains, one-account handshakes, unknown identities, duplicate accounts, invalid frames, plain-text bounds, stale generations and 1,000 replacements. The UI harness exercises service restart, state changes, selection persistence, 1,000 Loader lifetimes and a quiet interval.

Fixture UI workflows do not establish compatibility with live provider responses.
Changes to Gmail or People decoding and mutations must also exercise the
production dispatcher with independent synthetic response data and assert the
exact requests, target identities and write counts. Cover omitted/null optional
fields, malformed cosmetic metadata and empty repeated fields; keep outbound
write validation and uncertain-result protections strict. The live label
metadata regressions run with the ordinary unit suite, or separately with
`zig build test -Doptimize=safe -Dtest-filter="live label metadata:"`.
Real-account read-only checks can supplement these tests when authorized;
production mailbox/contact writes require their own explicit authorization.

## Provider responses and ordinary mailbox workflows

Generated MIME fixtures have exact body sizes and regular optional metadata.
They are useful for UI behavior, but cannot establish compatibility with Gmail
responses that contain legacy label colors or retain a stripped UTF-8 byte order
mark in their declared body size. These failures need independent literal
provider responses, rather than fixtures produced by the application's encoder
or a generator that computes every declared size from the delivered data.

`src/terminal_mail_acceptance_tests.zig` runs with the ordinary Safe
unit gates on every native release platform. Its production-dispatcher checks
assert requests, identities, full body and attachment bytes, cache persistence
and later cached reads. A bounded set of 64 deterministic structure mutations
varies MIME nesting, part order, header case and optional fields while retaining
an independent content oracle. Malformed binary attachments remain explicit
failures. This is targeted compatibility coverage; it is not evidence that every
possible email is supported.

The attachment stream probe separately receives 30 MiB with a content length
and the exact 50 MiB incoming boundary with chunked framing, through the actual
HTTP client, base64 JSON decoder and independent digest sink. It checks constant
workspace use, over-limit refusal and unchanged upload limits. These tests do
not create a large attachment by sending synthetic mail, which would conflate
the smaller outgoing limit with receiving.

`python3 tests/terminal_mail_acceptance.py --binary /path/to/omagma --receipt /tmp/mail-acceptance.json`
uses an owned PTY and fictional provider-shaped mail. It starts with an older
cache containing a body refusal, refreshes through the provider decoder, opens
the recovered message and its attachments, saves a file, and creates formatted
replies and forwards without sending. Restart checks distinguish successful
recovery from a refusal that remains final under the current decoder. A large
unloaded inline-photo case keeps the body and file controls accessible, then
checks Reply, Reply all and Forward: unsupported formatting choices explain
their limits and remain disabled through keyboard and mouse input. Native
acceptance also saves and forwards verified photo bytes, and rejects an
oversized combined resource plan before downloading its images. The Darwin
variant uses the existing PTY guardian. No desktop window or real mailbox is
needed.

For an authorized live read-only check, sample several messages in each enabled
account, including attachment-bearing mail, rather than reading only the first
listed message. Record categorical refusal counts and artifact identities
without mail content or identifiers. Inspect every failure: a passing head
message does not make other recorded body refusals a passing compatibility
check. Test live mutations only with explicitly authorized disposable accounts.
When diagnosing a user report, distinguish cached reads from the fresh source
read used to preserve formatting, and verify the executable actually running;
repairing a cache with a candidate CLI does not replace a running older TUI.

The native PTY gate includes `growing-composer`: a refused ordinary reader
opens its full formatted reply source, preserves 146 inline images, edits a
note over 2 MiB through an external editor, opens its HTML preview, saves,
reopens, reviews and sends exactly once to the synthetic provider. The separate
`unknown-send-reopen` case opens the protected recovery preview while proving
that the original draft and receipt stay unchanged and Gmail upload stays
blocked. These paths run on the application's real worker stacks. Encrypted
private-socket tests also render the large draft through the daemon and verify
the private export, unchanged source and cleanup.

`native send memory HTTP:` tests exercise the production source/attachment
transport and MIME uploader with 21 growing reply stages near Gmail's wire
limit. They verify every image independently, reject oversized MIME before
submission, and check uncertain receipts and scoped-memory cleanup. These
correctness checks supplement the fixed browsing workloads; they do not impose
the browsing heap ceiling on an explicitly expanded native compose operation.
The complete 21-stage growing-store chain runs separately with
`zig build test-native-send-stress -Doptimize=safe --test-timeout 300s -Dtest-watchdog=true`,
in Safe on all four release platforms. Its dedicated deadline
keeps the full chain intact on slower native runners; ordinary correctness
tests retain their existing 120-second timeout.

## Received-message copy acceptance

Received-message copy/editor acceptance uses `tests/terminal_reader_copy.py`
and `tests/terminal_reader_editor.py` with an
owned PTY and fictional mail. Capture OSC 52 on its private master, rather than
writing to a real desktop clipboard. Check exact excerpts, Unicode and wrapped
lines, theme/monochrome styles, source changes, resize and editor return. The
received editor's temporary files must disappear while cached mail and drafts
remain unchanged; existing compose editor readback still needs its own check.

## Release resource qualification

Run these Safe workloads when qualifying a release or investigating a resource
regression, under the same reservation through child cleanup:

```sh
python3 tests/measure.py --binary zig-out/bin/omagma
python3 tests/ui_gui.py --binary zig-out/bin/omagma
python3 tests/background_measure.py --fixtures --binary zig-out/bin/omagma --config tests/fixtures/all-accounts.json --jobs 1000 --output /tmp/omagma-background.json
```

| Acceptance gate | Threshold |
| --- | --- |
| Whole backend RSS | At most 64 MiB |
| Closed Quickshell PSS added over baseline | At most 20 MiB |
| Warm median memory growth | At most 2 MiB |
| Quiet CPU | At most 0.5% of one core |
| Retained rows / active workers / pending jobs | At most 90 / 1 / 3 |

The default backend and UI soaks run 1,000 cycles and a 60-second quiet interval. A separate closed-background fixture test accelerates the timer for 1,000 jobs and measures bounds and memory growth. The default configuration has background polling disabled; quiet checks with polling enabled must fit between refresh deadlines.

UI memory uses a separate baseline with the same shell/runtime and reads Linux `smaps_rollup`. PSS accounts for shared mappings proportionally; private memory and warm trends reveal retained memory. RSS, PSS and the backend’s application-owned allocation budget are different quantities. A passing offscreen test cannot establish compositor placement, desktop dismissal or browser routing on every installation.

Real developer authorization/fetch/timer tests need explicit direction and private configuration. Live-write qualification uses a separately authorized disposable mailbox; this is not an installation requirement for ordinary users. Verify returned identity, account separation and profile routing without publishing mail, identifiers, token material or personal paths. Preserve failed receipts privately. Published summaries retain their named compiler/source/artifact identities in [Zig 0.17 migration evidence](evidence/zig-0.17.0.md), [memory accounting](MEMORY.md), [current terminal/native release evidence](evidence/terminal-0.2.4.md), [historical terminal/mouse evidence](evidence/terminal-0.2.3-mouse.md) and [historical Zig 0.16 evidence](../EVIDENCE.md). Later local source changes do not inherit those measurements.

## Static release checks

The [release workflow](../.github/workflows/release.yml) tests both backends on native Linux x86_64 and ARM runners. To package locally, stage or commit tracked changes first so the bundle matches the privacy-audited index:

```sh
python3 scripts/release.py --arch x86_64
python3 tests/release_check.py --arch x86_64
dist/omagma-linux-x86_64 build-info
python3 tests/integration.py --binary dist/omagma-linux-x86_64 --build-mode safe
python3 tests/probes/transport_check.py --binary dist/omagma-linux-x86_64 --build-mode safe --https
python3 tests/measure.py --binary dist/omagma-linux-x86_64
```

Use `--arch arm64` to cross-build and inspect the ARM bundle. Native executable checks need an ARM machine. Packaging rejects a dynamic loader, shared-library dependencies, debug symbols and private build paths. Archive checks verify checksums, exact tracked contents, normalized metadata, executable permissions and the version from `build.zig.zon`. See [release maintenance](RELEASING.md) for publication and draft recovery.
