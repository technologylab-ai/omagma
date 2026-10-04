# Install the bar widget

omagma needs an Omarchy shell with user-plugin support, Chrome, an unlocked Secret Service keyring with `secret-tool`, and system CA certificates. The release backend is statically linked with musl; the desktop UI and these services remain external dependencies. You do not need Zig to install a release.

## Download and verify

Open [the latest release](https://github.com/technologylab-ai/omagma/releases/latest) and download `SHA256SUMS` plus the complete bundle for your Linux machine:

| `uname -m` | Bundle |
| --- | --- |
| `x86_64` | `omagma-VERSION-linux-x86_64.tar.gz` |
| `aarch64` or `arm64` | `omagma-VERSION-linux-arm64.tar.gz` |

`VERSION` is the release’s version number without the leading `v`. The raw `omagma-linux-x86_64` and `omagma-linux-arm64` binaries are also available with their accompanying `LICENSES.txt`, but the complete bundle is preferred for bar installation because it includes the UI, assets, examples, docs, setup skill and license notices.

In the download directory, verify the available assets:

```sh
sha256sum --check --ignore-missing SHA256SUMS
```

Confirm that your selected bundle reports `OK`. Continue only after its checksum passes. Download the checksum and bundle from the same release. Checksums detect corrupt or mismatched files; they are not a separate signature.

## Extract and link

Set `omagma_bundle` to the actual downloaded filename. This example uses x86_64; choose the arm64 filename on ARM. Extract into a new, persistent versioned directory:

```sh
omagma_bundle=omagma-VERSION-linux-x86_64.tar.gz
omagma_release_dir="$HOME/.local/share/omagma/releases/${omagma_bundle%.tar.gz}"
mkdir -p "$omagma_release_dir"
tar -xzf "$omagma_bundle" -C "$omagma_release_dir"
"$omagma_release_dir/omagma/zig-out/bin/omagma" --version
```

The archive has one top-level `omagma/` directory. Check that `--version` runs successfully and matches the release before Google consent or desktop activation. The arm64 backend has architecture-specific build/test checks; an ARM Omarchy desktop is not claimed as tested.

For a first installation, link that extracted folder into the user plugin directory:

```sh
mkdir -p "$HOME/.config/omarchy/plugins"
ln -s "$omagma_release_dir/omagma" "$HOME/.config/omarchy/plugins/io.github.technologylab_ai.omagma"
```

If that plugin path already exists, inspect it before changing it. For an upgrade, prepare and verify a new versioned directory first, then point the existing plugin symlink at it. Preserve private account configuration and keyring credentials. Keep the linked folder available while the plugin is enabled.

Add one object to the desired existing bar section in `~/.config/omarchy/shell.json`, preserving the other entries and settings. For example, append this to `bar.layout.center`:

```json
{
  "id": "io.github.technologylab_ai.omagma",
  "daemonPath": "",
  "configPath": "",
  "fixtures": true
}
```

The fields belong directly on the bar entry. An empty `daemonPath` uses the included `zig-out/bin/omagma` inside the plugin folder. An empty `configPath` uses the backend’s standard configuration location. Set an explicit absolute path if your configuration lives elsewhere.

With `fixtures: true`, the dropdown displays synthetic mail without contacting Gmail or the keyring. Complete [account setup](SETUP.md), then change this setting to `false` for live mail. Click the magma icon to open the dropdown; no keybinding is needed.

User plugin/configuration changes normally hot reload. If discovery needs refreshing, run `omarchy-shell shell rescanPlugins`. If imported QML remains cached, `omarchy restart shell` reloads the shell. A restart affects the whole bar, so do it at a convenient time. Do not edit package-owned files under `/usr/share/omarchy/`.

To remove the widget, remove its bar entry and user plugin symlink. This leaves your configuration and keyring credentials intact. See [privacy](PRIVACY.md) for local disconnection and Google-side revocation.

## Source fallback

If there is no compatible release asset, build a source checkout with **Zig 0.17.0 exactly**. Omarchy may still provide 0.16.x. Download and verify the [0.17.0 archive](https://ziglang.org/download/0.17.0/) matching your OS/CPU, extract it into a task-owned directory, and select it only for this shell. Before a shared-host build or runtime check, acquire the [verification reservation](VERIFICATION.md#cooperative-host-measurement-lock).

```sh
omagma_zig_dir=/absolute/path/to/extracted-zig-0.17.0
export PATH="$omagma_zig_dir:$PATH"
zig version
zig build -Doptimize=safe
zig-out/bin/omagma --version
```

Confirm the compiler reports exactly `0.17.0` before building. The task's `PATH` also selects the compiler for nested Python/release tools; do not replace the system compiler.

Link the absolute checkout directory as the user plugin folder, then use the same bar entry and account setup. Development checks are described in [verification](VERIFICATION.md).
