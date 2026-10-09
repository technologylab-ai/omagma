# Build and publish releases

End users should [install a verified release bundle](INSTALL.md). This page is for
maintainers building Linux/macOS backends and publishing their matching bundles.
[Development](DEVELOPMENT.md) covers faster local iteration: it keeps the package
version unchanged and does not publish a release or rerun resource qualification
for every interface edit. Existing release assets remain immutable; each new
version bundles its own qualified source tree.

## Version and compiler

`build.zig.zon` is the source of the package version and minimum Zig version. The required compiler is **0.17.0 exactly**. Release tooling reads both fields; a compiler upgrade needs corresponding source changes and verification. If the system compiler is older, download and verify the matching OS/CPU archive from [Zig 0.17.0](https://ziglang.org/download/0.17.0/), select its extracted directory in the task's `PATH`, and check `zig version`. Nested packaging commands must inherit the same selection.

Bump `.version` in `build.zig.zon`, commit the change and push `main` to qualify a new candidate. The **Release** workflow checks for an existing `vVERSION` GitHub release, builds all four native platforms and runs the complete gates. It saves the verified artifacts for 30 days and does not publish. `workflow_dispatch` can also start qualification; development branches are verified without becoming publishable candidates.

Let qualification run while the user tests locally. After the user explicitly approves publication, dispatch **Publish qualified release** on `main` with the successful qualification run ID. It verifies the source revision, platform results and artifact provenance, then publishes those exact artifacts without rebuilding or repeating the long suites. The dispatch revision must match the qualified commit. Changes after qualification require a new run; expired, failed, foreign or incomplete runs cannot be promoted.

Publication creates only a new version and never replaces a release, draft or tag. A prerelease version remains a prerelease rather than becoming latest. Homebrew and documentation deployment follow publication.

Review `docs/release-notes/VERSION.md` before requesting publication. The publisher uses that version's highlights and appends matching compiler, download and setup links; a generic description is available when no versioned notes exist. Release notes describe the complete current application, including its experimental terminal status.

## Local packaging

From a source checkout with the declared Zig compiler and Python 3, stage or commit the intended public changes first. The packager uses audited tracked files and rejects unstaged tracked changes; ignored or untracked files are not bundled. On shared hosts, reserve the complete build/check workload using the [cooperative lock](VERIFICATION.md#cooperative-host-measurement-lock) before starting.

```sh
python3 scripts/release.py --arch x86_64
python3 scripts/release.py --arch arm64
# On a matching native Mac, choose its architecture:
python3 scripts/release.py --os macos --arch arm64
python3 tests/release_check.py --os macos --arch arm64
```

The packager builds stripped `safe` backends (`-Doptimize=safe`) with baseline CPUs. Linux defaults remain static musl and require static ELF output. `--os macos` requires a matching native Mac, targets macOS 13.0 explicitly and validates thin Mach-O CPU subtype, minimum OS/platform, system-only dependencies, loader/search-path bounds and stripped/private-path constraints. The observed direct libraries are libSystem, libobjc, Security and CoreFoundation; no Homebrew dylibs are bundled. Output goes to `dist/` by default; `--output-dir` chooses another directory. Linux writes `SHA256SUMS-x86_64` or `SHA256SUMS-arm64`; Mac writes `SHA256SUMS-macos-x86_64` or `SHA256SUMS-macos-arm64`. Publication combines all platform fragments and the license notice into `SHA256SUMS`. `--print-version` and `--print-zig-version` report the values read from `build.zig.zon`. These are build-time tools, not installed runtime helpers. Packaging does not edit an installed desktop configuration or private credentials.

Each OS/architecture produces a raw binary and complete audited-source bundle:

| Asset | Contents |
| --- | --- |
| `omagma-linux-x86_64` / `omagma-linux-arm64` | Static backend executable |
| `omagma-VERSION-linux-x86_64.tar.gz` / `omagma-VERSION-linux-arm64.tar.gz` | Complete Linux plugin under one top-level `omagma/` directory |
| `omagma-macos-x86_64` / `omagma-macos-arm64` | Native Mac terminal executable using system libraries |
| `omagma-VERSION-macos-x86_64.tar.gz` / `omagma-VERSION-macos-arm64.tar.gz` | Complete audited source/docs and native executable under `omagma/` |
| `SHA256SUMS` | Checksums for the published binary and bundle assets, using basenames |
| `LICENSES.txt` | Project, Zig, musl, libvaxis, zigimg and uucode notices, also included in the bundles |

The bundle includes tracked public project contents: runtime QML/JavaScript,
manifest, assets, examples, docs, setup skill and optional user service/timer
files under `systemd/`, including `omagma-cache-refresh.service` and `.timer`;
packaging does not enable them. The included backend is
`omagma/zig-out/bin/omagma`, preserving the plugin's
default lookup. Packaging stamps the bundle manifest with the package version.
Private config, OAuth downloads, local notes and raw live-test output stay
excluded. `--version` reports `omagma VERSION`.

The compiler installer uses checked official per-platform archive metadata in
`.github/zig-release.json`, verifies the downloaded size/hash and exact version,
and exposes that compiler to subsequent job steps. Changing only a version
string or depending on `download/index.json` is insufficient for a compiler
port. Keep archive metadata, package pin, source guard, scripts and CI in sync.

## Continuous release checks

The workflow uses native Ubuntu 24.04 x86_64 and ARM runners for backend tests and architecture-specific packaging. Both `debug` and `safe` run unit tests, standalone probes, full integration and transport checks, terminal CLI workflows and isolated PTY editor/lifecycle tests. Current-feature acceptance also covers account-scoped bulk/undo, cached-window navigation/search, forwarding/files, composer recovery/completion, reader context, actual loading/progress, mouse/wheel routing, compact layouts and local timezone displays. The fixture timezone database is installed and checked before either native suite. `safe` additionally validates the release artifacts, 1,000-job backend/background workloads and separate 1,000-cycle CLI/TUI memory gates. Receipts identify the compiler version and optimization mode reported by the binary. A separate session bus and temporary keyring hold synthetic secrets for the Secret Service check. After all required native platform jobs succeed, the candidate is ready for approval. Manual promotion later collects those saved bundles, raw binaries and combined `SHA256SUMS` for the package version.

After explicit approval, the promotion workflow downloads the successful run's four release artifacts, verifies their checksums and uses the GitHub CLI to upload all ten assets through an internal draft before publishing. It cleans up that draft on ordinary upload failures. If a terminated job leaves an unpublished draft, inspect its version, commit and assets before removing it and retrying. The publisher refuses to replace an existing release, draft or tag and does not expose an incomplete release as latest.

Mac jobs run natively on Apple Silicon and Intel hosts and verify the actual
packaged executable, native Keychain/upgrade/lifecycle behavior and the
platform-specific terminal gates. Run `python3 tests/release_binary.py` for the
independent literal ELF/Mach-O format oracles; these lightweight tests do not
replace native qualification. All four platform jobs must succeed before
publishing. Homebrew installation is preferred on Mac; its formula must use the
selected immutable release archive and verified architecture-specific SHA256.

Before publishing, verify executable versions and checksums, platform linkage,
archive paths, license notices and public setup instructions. Check actual
downloaded native release bytes separately: checksum, `--version`/`build-info`,
no ELF interpreter or DT_NEEDED on Linux, validated Mach-O/system dependencies
on Mac, and the corresponding synthetic integration/transport checks. Source-built
checks alone do not establish the published artifact. The included backend still
relies on system CA certificates and external Chrome/keyring programs; the QML UI
requires a compatible Omarchy/Quickshell host. Fixture and release checks remain
developer responsibilities, not tasks required of an ordinary installer.

Native ARM backend tests and cross-compilation do not prove ARM desktop integration. Browser consent and live account routing remain explicit local checks; release CI uses synthetic fixtures and does not access Gmail credentials. Existing [memory gates](VERIFICATION.md) continue to apply to their measured workloads.
