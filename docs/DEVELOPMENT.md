# Developing Omagma

This guide is for source builds, code changes and maintainer checks. Normal
installation uses a [release bundle](INSTALL.md) and [account setup](SETUP.md).
Developer fixtures, automated UI tests and resource qualification are not
onboarding requirements.

Read [AGENTS.md](../AGENTS.md#developing-omagma) before changing the code. Keep
private account/client files, tokens, real mail and local receipts outside the
tracked tree. Public examples and captures use fictional accounts.

## Build from source

Use **Zig 0.17.0 exactly**, matching `build.zig.zon`. Omarchy may still ship
0.16.x. Download and verify the official archive matching the host OS and CPU
from [the 0.17.0 release directory](https://ziglang.org/download/0.17.0/), then
select the extracted compiler for this task:

```sh
omagma_zig_dir=/absolute/path/to/extracted-zig-0.17.0
export PATH="$omagma_zig_dir:$PATH"
zig version
zig build -Doptimize=safe
zig-out/bin/omagma --version
zig-out/bin/omagma build-info
```

Confirm `zig version` prints exactly `0.17.0`. Keep the system compiler
unchanged; nested build/test tools inherit the task's PATH. The application
version is declared in `build.zig.zon`. Release bundles need no compiler.

The default includes the libvaxis TUI. The full dependency graph is pinned in
the package declaration. Linux release backends target static musl; for an
x86_64 development build matching that linkage:

```sh
zig build -Doptimize=safe -Dtarget=x86_64-linux-musl --prefix .verification-local
```

Use `aarch64-linux-musl` for an ARM64 target. Cross-compilation alone does not
establish native runtime or desktop behavior.

### Native Mac builds

Mac source builds need Xcode Command Line Tools (`xcode-select -p`) and the
same exact Zig 0.17.0 selection above. Download the matching official Mac archive;
do not substitute Omarchy's Linux compiler. Explicit baseline release targets
use the native SDK found by `xcrun`:

```sh
zig build -Doptimize=safe -Dtarget=aarch64-macos.13.0 -Dcpu=baseline
zig-out/bin/omagma --version
```

Use `x86_64-macos.13.0` on an Intel Mac. If automatic SDK discovery is unavailable,
pass `-Dmacos-sdk=/absolute/path/to/MacOSX.sdk`; this is a build option, not an
installed user's configuration setting. Mac executables use system libraries
and frameworks rather than static musl. Cross builds and deployment metadata do
not establish runtime behavior on a different architecture or oldest OS.

## Local changes

Use a separate development prefix and focused checks for the changed
behavior. `debug` verifies correctness; `safe` retains assertions with
optimization and is used for installed binaries and release checks.

```sh
zig build test -Doptimize=debug
zig build -Doptimize=safe --prefix .verification-local
```

For a small interface change, select the relevant test filter and owned-PTY
scenario instead of automatically running release or memory soaks. Follow the
[local iteration rules](../AGENTS.md#developing-omagma). An authorized local
installation replaces the executable atomically, preserving private config,
profiles, grants and cache. Keep the version unchanged until preparing a new
release.

## Fixtures and automated UI checks

Fixtures let developers exercise sends, contacts, mailbox changes and RSVP
without Google credentials. They are a separate provider/cache namespace and
must not be described as live delivery.

```sh
zig-out/bin/omagma tui --fixtures
node tests/ui_model.mjs
python3 tests/ui_gui.py --binary zig-out/bin/omagma
```

The Qt harness runs offscreen; terminal interaction harnesses own isolated
PTYs. Automated checks must not map desktop windows, capture the user's typing,
or change installed desktop configuration. See [bar verification](VERIFICATION.md)
and [terminal verification](TERMINAL-VERIFICATION.md) for meaningful scenarios.

Developer authorization is not permission to send production mail or mutate
production contacts. Live write qualification uses an explicitly provided
dedicated test mailbox. User installation and consent are different tasks:
after granting permissions, the user can explicitly send or edit through their
own TUI, and an agent acts only on a separately requested operation.

## Qualification and publication

Before heavy builds or runtime suites on a shared host, use the
[cooperative reservation protocol](VERIFICATION.md#cooperative-host-measurement-lock).
Hold the reservation through cleanup, respect another owner, and release only
your own token. This protocol belongs to shared-host development work.

Release qualification includes correctness, transport/authentication,
cancellation, account isolation, bounded storage, native platform checks and
the existing memory/quiet-CPU gates. [Verification](VERIFICATION.md) and
[terminal verification](TERMINAL-VERIFICATION.md) define those checks.
Actual RSS/PSS and application-owned limits are separate quantities.

[Release maintenance](RELEASING.md) describes version bumps, compiler archive
checksums, Linux static-musl and native macOS x86_64/arm64 bundles, privacy checks, CI and downloaded
artifact validation. Published assets and dated failed/passed evidence are
immutable. A local interface update is not a new release or fresh resource
qualification.

Architecture and evidence references are listed in the
[documentation index](README.md#development-and-reference). Current compiler
findings belong in [the wiki follow-up](ZIG017-WIKI-FOLLOWUP.md), distinguishing
confirmed compiler behavior from application and harness defects.

## Native macOS checks

Native Mac checks use owned PTYs, fictional mail and a temporary synthetic
keychain; they are maintainer tasks rather than installation steps. Reserve the
host and preserve source/binary/SDK identity as for the other native platforms.

```sh
zig build test probes -Doptimize=debug -j2
zig build -Doptimize=debug -j2
zig-out/bin/omagma probe-keyring
python3 tests/terminal_macos.py --binary zig-out/bin/omagma
python3 tests/launch_macos.py --binary zig-out/bin/omagma
python3 tests/terminal_integration.py --binary zig-out/bin/omagma --build-mode debug
```

Run the corresponding Safe checks and packaging gates for release qualification.
The macOS 13.0 binary deployment target is distinct from actual native test
hosts: CI uses newer macOS hosts and local Apple Silicon qualification uses
macOS 26.6.2/SDK 27.0. Keep each architecture/OS result separate, and require
native Intel evidence rather than calling an ARM cross-build an Intel test.
Mac memory/CPU gates have platform-specific evidence; do not copy the dated
Linux bar estimate onto Mac or TUI workloads. Synthetic checks are not live
Google delivery/consent or Omarchy bar qualification.

## Documentation website

The static website renders the canonical public Markdown and explicitly chosen
fictional assets. It needs Node.js 24 or newer and npm, with the single Markdown
dependency pinned in `website/package-lock.json`; no Zig/compiler, live account
or desktop configuration is involved. CI selects exact Node 24.21.0 LTS.

```sh
npm ci --prefix website --ignore-scripts --no-audit --no-fund
OMAGMA_SITE_BASE=/omagma/ npm run build --prefix website
npm run check --prefix website
```

Output is `website/dist/`, with dependencies/output ignored by Git. Use
`OMAGMA_SITE_BASE=/` for a root/custom-domain preview. The check validates
internal links/anchors, artifact boundaries and public-data patterns. Review
every screenshot/animation frame for fictional content before publication;
binary metadata checks alone cannot establish visual privacy.

[The Pages workflow](../.github/workflows/pages.yml) builds/checks pull requests,
then deploys only `main` using the `github-pages` environment. Enable **GitHub
Actions** in the repository's Pages settings before the first deployment.
Only the generated site is uploaded; Node dependencies, app binaries, caches,
local notes and private receipts stay outside that artifact. Build jobs have
read permissions; only deployment has Pages/OIDC write permissions. The
workflow uses official commit-pinned Actions and no long-lived deployment
secret. [GitHub's Pages workflow requirements](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).

Website publication is separate from application releases. An unchanged
already-published package version makes the existing release workflow skip
qualifying new app assets; a documentation push never retargets that version's
release. New candidates can qualify while the user tests locally; publication
requires an explicit go-ahead and [manual promotion](RELEASING.md) of the exact
successful run's artifacts. Keep dated evidence and published downloads immutable.
