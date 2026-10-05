# Reproduce the checks

Use Zig **0.17.0 exactly**. `debug` checks correctness; `safe` also establishes release allocator/runtime evidence. Omarchy may still ship a 0.16.x compiler. Download and verify the [exact 0.17.0 archive](https://ziglang.org/download/0.17.0/) for the execution host's OS/CPU, extract it into a task-owned directory, and select it for this shell:

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

## Correctness and memory checks

The following commands use synthetic accounts and never authorize Gmail or edit installed desktop configuration:

```sh
zig build test probes -Doptimize=debug -j2 --prefix .verification-zig017-debug
zig build -Doptimize=debug -j2 --prefix .verification-zig017-debug
.verification-zig017-debug/bin/omagma build-info
.verification-zig017-debug/bin/auth_probe launch
.verification-zig017-debug/bin/auth_probe callback
.verification-zig017-debug/bin/callback_budget
.verification-zig017-debug/bin/transport_probe
python3 tests/integration.py --binary .verification-zig017-debug/bin/omagma --build-mode debug
python3 tests/probes/transport_check.py --binary .verification-zig017-debug/bin/omagma --build-mode debug --https
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
python3 tests/measure.py --binary zig-out/bin/omagma
python3 tests/ui_gui.py --binary zig-out/bin/omagma
python3 tests/background_measure.py --fixtures --binary zig-out/bin/omagma --config tests/fixtures/all-accounts.json --jobs 1000 --output /tmp/omagma-background.json
```

Python 3 and Node.js are needed for the harnesses; UI checks also need Quickshell. The UI harness forces `QT_QPA_PLATFORM=offscreen`, removes graphical-session routing variables and uses `--fixtures --dry-run-open`. It starts an isolated shell, never installs the plugin and cleans up its owned processes.

`zig build probes` installs the standalone launch/FD, callback, callback-budget and transport executables. The HTTPS checks make an unauthenticated Google request expecting an unauthorized response; they do not read a mailbox or use OAuth credentials. Run keyring probes only with a separate session bus and temporary synthetic keyring, as in the [release workflow](../.github/workflows/release.yml), rather than against the desktop's account credentials.

Give cold compilation, each probe and the complete suite adequate outer watchdog budgets. Release CI allows 60 minutes for a build/test job. That outer limit is separate from the application's 10-second request deadline, 30-second refresh deadline and 180-second consent deadline. Leave time for expected timeout cases, 1,000-cycle workloads, the 60-second quiet interval and child cleanup; preserve receipts from an interrupted gate. Terminal workflows have separate [correctness and memory checks](TERMINAL-VERIFICATION.md); their allocation ceiling and measurements do not replace the bar gates below.

Backend integration covers bounded configuration, account isolation, empty and failed fetches, cancellation, background scheduling, owner exit and stdout backpressure. Model checks cover arbitrary configured domains, one-account handshakes, unknown identities, duplicate accounts, invalid frames, plain-text bounds, stale generations and 1,000 replacements. The UI harness exercises service restart, state changes, selection persistence, 1,000 Loader lifetimes and a quiet interval.

| Acceptance gate | Threshold |
| --- | --- |
| Whole backend RSS | At most 64 MiB |
| Closed Quickshell PSS added over baseline | At most 20 MiB |
| Warm median memory growth | At most 2 MiB |
| Quiet CPU | At most 0.5% of one core |
| Retained rows / active workers / pending jobs | At most 90 / 1 / 3 |

The default backend and UI soaks run 1,000 cycles and a 60-second quiet interval. A separate closed-background fixture test accelerates the timer for 1,000 jobs and measures bounds and memory growth. The default configuration has background polling disabled; quiet checks with polling enabled must fit between refresh deadlines.

UI memory uses a separate baseline with the same shell/runtime and reads Linux `smaps_rollup`. PSS accounts for shared mappings proportionally; private memory and warm trends reveal retained memory. RSS, PSS and the backend’s application-owned allocation budget are different quantities. A passing offscreen test cannot establish compositor placement, desktop dismissal or browser routing on every installation.

Real authorization/fetch/timer tests are explicit opt-in checks with private configuration. Verify the returned identity, per-account isolation and browser profile routing without publishing mail, identifiers, token material or personal paths. Preserve failed local receipts, but keep raw test output out of public releases. Published summaries are in [current Zig 0.17 evidence](evidence/zig-0.17.0.md), [memory accounting](MEMORY.md) and [historical Zig 0.16 evidence](../EVIDENCE.md).

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
