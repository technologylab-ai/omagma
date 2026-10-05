# Build and publish releases

End users should [install a verified release bundle](INSTALL.md). This page is for maintainers building the Linux backend and publishing matching plugin assets.

## Version and compiler

`build.zig.zon` is the source of the package version and minimum Zig version. The required compiler is **0.17.0 exactly**. Release tooling reads both fields; a compiler upgrade needs corresponding source changes and verification. If the system compiler is older, download and verify the matching OS/CPU archive from [Zig 0.17.0](https://ziglang.org/download/0.17.0/), select its extracted directory in the task's `PATH`, and check `zig version`. Nested packaging commands must inherit the same selection.

Bump `.version` in `build.zig.zon`, commit the change and push `main` to request a new version. The release workflow checks for an existing `vVERSION` GitHub release. It publishes only a new version and does not replace existing release assets. `workflow_dispatch` on a development branch verifies that branch without publishing; publication is restricted to `main`. A prerelease version remains a prerelease rather than becoming latest.

## Local packaging

From a source checkout with the declared Zig compiler and Python 3, stage or commit the intended public changes first. The packager uses audited tracked files and rejects unstaged tracked changes; ignored or untracked files are not bundled. On shared hosts, reserve the complete build/check workload using the [cooperative lock](VERIFICATION.md#cooperative-host-measurement-lock) before starting.

```sh
python3 scripts/release.py --arch x86_64
python3 scripts/release.py --arch arm64
```

The packager builds stripped `safe` backends (`-Doptimize=safe`) targeting baseline Linux musl and verifies static ELF output. Output goes to `dist/` by default; `--output-dir` chooses another directory. Each local run writes `SHA256SUMS-x86_64` or `SHA256SUMS-arm64`; publication combines them into `SHA256SUMS`. `--print-version` and `--print-zig-version` report the values read from `build.zig.zon`. These are build-time tools, not installed runtime helpers. Packaging does not edit an installed desktop configuration or private credentials.

Each architecture produces a raw binary and a complete plugin bundle:

| Asset | Contents |
| --- | --- |
| `omagma-linux-x86_64` / `omagma-linux-arm64` | Static backend executable |
| `omagma-VERSION-linux-x86_64.tar.gz` / `omagma-VERSION-linux-arm64.tar.gz` | Complete plugin under one top-level `omagma/` directory |
| `SHA256SUMS` | Checksums for the published binary and bundle assets, using basenames |
| `LICENSES.txt` | Project, Zig, musl, libvaxis, zigimg and uucode notices, also included in the bundles |

The bundle includes tracked public project contents: the runtime QML/JavaScript, manifest, assets, examples, docs and setup skill. Its added backend is `omagma/zig-out/bin/omagma`, preserving the plugin's default binary lookup. Packaging stamps the bundle manifest with the version from `build.zig.zon`. Private config, OAuth downloads, local notes and raw live-test output must remain excluded. `--version` reports `omagma VERSION`.

## Continuous release checks

The workflow uses native Ubuntu 24.04 x86_64 and ARM runners for backend tests and architecture-specific packaging. Both `debug` and `safe` run unit tests, standalone probes, full integration and transport checks, terminal CLI workflows and isolated PTY editor/lifecycle tests. `safe` additionally validates the release artifacts, 1,000-job backend/background workloads and separate 1,000-cycle CLI/TUI memory gates. Receipts identify the compiler version and optimization mode reported by the binary. A separate session bus and temporary keyring hold synthetic secrets for the Secret Service check. After both architectures succeed, the `main` publication step collects the bundles, raw binaries and combined `SHA256SUMS` for the package version.

The GitHub CLI uploads all six assets through an internal draft before publishing; it cleans up that draft on ordinary upload failures. If a terminated job leaves an unpublished draft, inspect its version, commit and assets before removing it and retrying. The workflow refuses to replace an existing release, draft or tag. It does not expose an incomplete release as latest.

Before publishing, verify executable versions and checksums, static linkage, archive paths and the included public setup instructions. The included backend still relies on system CA certificates and external Chrome/keyring programs. The QML UI still requires a compatible Omarchy/Quickshell host.

Native ARM backend tests and cross-compilation do not prove ARM desktop integration. Browser consent and live account routing remain explicit local checks; release CI uses synthetic fixtures and does not access Gmail credentials. Existing [memory gates](VERIFICATION.md) continue to apply to their measured workloads.
