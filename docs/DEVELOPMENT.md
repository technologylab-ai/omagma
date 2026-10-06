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
checksums, x86_64/arm64 static-musl bundles, privacy checks, CI and downloaded
artifact validation. Published assets and dated failed/passed evidence are
immutable. A local interface update is not a new release or fresh resource
qualification.

Architecture and evidence references are listed in the
[documentation index](README.md#development-and-reference). Current compiler
findings belong in [the wiki follow-up](ZIG017-WIKI-FOLLOWUP.md), distinguishing
confirmed compiler behavior from application and harness defects.

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
building/publishing new app assets; a documentation push never retargets that
version's release. Keep dated evidence and published downloads immutable.
