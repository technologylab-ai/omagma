# Reproduce the checks

Use Zig **0.16.0 exactly**. Debug and ReleaseSafe serve different purposes: Debug checks correctness, while ReleaseSafe measures the release allocator/runtime behavior. The commands below use synthetic accounts and never authorize Gmail or edit installed desktop configuration.

```sh
zig build test -Doptimize=Debug
zig build -Doptimize=Debug -p .verification-debug
python3 tests/integration.py --binary .verification-debug/bin/omagma --build-mode Debug
zig build -Doptimize=ReleaseSafe
node tests/ui_model.mjs
python3 tests/measure.py --binary zig-out/bin/omagma
python3 tests/ui_gui.py --binary zig-out/bin/omagma
python3 tests/background_measure.py --fixtures --binary zig-out/bin/omagma --config tests/fixtures/all-accounts.json --jobs 1000 --output /tmp/omagma-background.json
```

Python 3 and Node.js are needed for the harnesses; UI checks also need Quickshell. The UI harness forces `QT_QPA_PLATFORM=offscreen`, removes graphical-session routing variables and uses `--fixtures --dry-run-open`. It starts an isolated shell, never installs the plugin and cleans up its owned processes.

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

Real authorization/fetch/timer tests are explicit opt-in checks with private configuration. Verify the returned identity, per-account isolation and browser profile routing without publishing mail, identifiers, token material or personal paths. Preserve failed local receipts, but keep raw test output out of public releases. Published summaries are in [evidence](../EVIDENCE.md).

## Static release checks

The [release workflow](../.github/workflows/release.yml) tests both backends on native Linux x86_64 and ARM runners. To package locally, stage or commit tracked changes first so the bundle matches the privacy-audited index:

```sh
python3 scripts/release.py --arch x86_64
python3 tests/release_check.py --arch x86_64
python3 tests/integration.py --binary dist/omagma-linux-x86_64 --build-mode ReleaseSafe
python3 tests/probes/transport_check.py --binary dist/omagma-linux-x86_64 --build-mode ReleaseSafe --https
python3 tests/measure.py --binary dist/omagma-linux-x86_64
```

Use `--arch arm64` to cross-build and inspect the ARM bundle. Native executable checks need an ARM machine. Packaging rejects a dynamic loader, shared-library dependencies, debug symbols and private build paths. Archive checks verify checksums, exact tracked contents, normalized metadata, executable permissions and the version from `build.zig.zon`. See [release maintenance](RELEASING.md) for publication and draft recovery.
