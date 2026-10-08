# Install Omagma

On **macOS**, use [Homebrew and native terminal installation](MACOS.md).
The TUI and CLI need no Omarchy or Quickshell on a Mac. The bar widget described
below is a Linux Omarchy integration.

## Install the bar widget

omagma needs an Omarchy shell with user-plugin support, Chrome, an unlocked Secret Service keyring with `secret-tool`, and system CA certificates. The release backend is statically linked with musl; the desktop UI and these services remain external dependencies. You do not need Zig to install a release.

## Download and verify

Open [the latest release](https://github.com/technologylab-ai/omagma/releases/latest) and download `SHA256SUMS` plus the complete bundle for your Linux machine:

| `uname -m` | Bundle |
| --- | --- |
| `x86_64` | `omagma-VERSION-linux-x86_64.tar.gz` |
| `aarch64` or `arm64` | `omagma-VERSION-linux-arm64.tar.gz` |

`VERSION` is the release’s version number without the leading `v`. The raw `omagma-linux-x86_64` and `omagma-linux-arm64` binaries are also available with their accompanying `LICENSES.txt`, but the complete bundle is preferred for bar installation because it includes the UI, assets, examples, docs, setup skill, optional `systemd/` cache-timer units and license notices.

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

Complete [account setup](SETUP.md) using the extracted executable, starting with one account. Keep its private configuration outside the release directory so upgrades preserve it. You can add the widget before authorizing an account; it will show **Disconnected** until access is approved.

Add one object to the desired existing bar section in `~/.config/omarchy/shell.json`, preserving the other entries and settings. For example, append this to `bar.layout.center`:

```json
{
  "id": "io.github.technologylab_ai.omagma",
  "daemonPath": "",
  "configPath": "",
  "fixtures": false
}
```

The fields belong directly on the bar entry. An empty `daemonPath` uses the included `zig-out/bin/omagma` inside the plugin folder. An empty `configPath` uses the backend’s standard configuration location. Set an explicit absolute path if your configuration lives elsewhere.

`fixtures: false` uses your configured Gmail accounts. Click the magma icon to open the dropdown; no keybinding is needed. Choose the connected account and open a message to check that Gmail uses its configured Chrome profile. The widget remains read-only.

User plugin/configuration changes normally hot reload. If discovery needs refreshing, run `omarchy-shell shell rescanPlugins`. If imported QML remains cached, `omarchy restart shell` reloads the shell. A restart affects the whole bar, so do it at a convenient time. Do not edit package-owned files under `/usr/share/omarchy/`.

To remove the widget, remove its bar entry and user plugin symlink. This leaves your configuration and keyring credentials intact. See [privacy](PRIVACY.md) for local disconnection and Google-side revocation.

## Optional terminal command

The verified backend also runs the [TUI and agent CLI](TERMINAL.md). To make
`omagma tui` available after bar installation, link the plugin's executable into
an existing user PATH directory. Inspect any existing `omagma` command first;
do not overwrite an unrelated executable. For a first link:

```sh
mkdir -p "$HOME/.local/bin"
ln -s "$HOME/.config/omarchy/plugins/io.github.technologylab_ai.omagma/zig-out/bin/omagma" "$HOME/.local/bin/omagma"
omagma --version
omagma tui
```

Confirm `$HOME/.local/bin` is already on PATH, or invoke the executable by its
absolute path. Linking through the plugin path follows future verified plugin
upgrades. Terminal-only installations can use the raw release binary and its
`LICENSES.txt` without installing the bar.

Read-only terminal mail can use your bar authorization. For replies, sending,
mailbox changes or contacts, follow [terminal permissions](SETUP.md#full-tuicli-permissions).
The TUI and CLI are experimental; [the terminal guide](TERMINAL.md) explains
their workflows and controls.

## Application launcher

The bar popup's **Open TUI** button opens the selected account in a floating
terminal. It uses Omarchy's default terminal and your existing terminal
configuration. Terminal permissions remain separate from the read-only bar.

After making `omagma` available on PATH, add it to Omarchy's application
launcher with the supplied desktop entry and icon:

```sh
mkdir -p "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/256x256/apps"
cp assets/omagma.desktop "$HOME/.local/share/applications/omagma.desktop"
cp assets/omagma-logo.png "$HOME/.local/share/icons/hicolor/256x256/apps/omagma.png"
update-desktop-database "$HOME/.local/share/applications"
```

Run these commands from the installed bundle folder. Search for **Omagma** in
the launcher. It runs `omagma tui` using the `TUI.float.omagma` application ID;
Omarchy's default TUI window rules provide a centered floating window. For a
larger starting size, copy the rules in
[examples/omagma-hyprland.lua](../examples/omagma-hyprland.lua) into your user
Hyprland Lua configuration, then run `hyprctl reload` and check
`hyprctl configerrors`.

## Optional demo

To look around before connecting Gmail, run `omagma tui --fixtures`, or set
`fixtures: true` on the bar entry. This displays fictional mail without using
Google credentials. Set it back to `false` when you want your configured Gmail
accounts. Demo mode is optional; it is not an installation check or prerequisite.

## Source fallback

To build Omagma from a checkout, follow
[source builds](DEVELOPMENT.md#build-from-source). They
require **Zig 0.17.0 exactly**; Omarchy may still provide 0.16.x. Select the
matching official compiler for that shell without replacing the system compiler.
Then link the absolute checkout directory as the user plugin folder and use the
same account setup and live bar entry above.
