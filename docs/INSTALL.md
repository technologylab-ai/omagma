# Install the bar widget

omagma needs an Omarchy shell with user-plugin support. Build in the checkout, then link that checkout into the user plugin directory:

```sh
zig build -Doptimize=ReleaseSafe
mkdir -p "$HOME/.config/omarchy/plugins"
ln -s "$(pwd)" "$HOME/.config/omarchy/plugins/io.github.technologylab_ai.omagma"
```

Run this from the omagma checkout. If that plugin path already exists, inspect it before changing it. Keep the checkout and built binary available while the plugin is enabled.

Add one object to the desired existing bar section in `~/.config/omarchy/shell.json`, preserving the other entries and settings. For example, append this to `bar.layout.center`:

```json
{
  "id": "io.github.technologylab_ai.omagma",
  "daemonPath": "",
  "configPath": "",
  "fixtures": true
}
```

The fields belong directly on the bar entry. An empty `daemonPath` uses `zig-out/bin/omagma` in the plugin checkout. An empty `configPath` uses the backend’s standard configuration location. Set an explicit absolute path if your configuration lives elsewhere.

With `fixtures: true`, the dropdown displays synthetic mail without contacting Gmail or the keyring. Complete [account setup](SETUP.md), then change this setting to `false` for live mail. Click the magma icon to open the dropdown; no keybinding is needed.

User plugin/configuration changes normally hot reload. If discovery needs refreshing, run `omarchy-shell shell rescanPlugins`. If imported QML remains cached, `omarchy restart shell` reloads the shell. A restart affects the whole bar, so do it at a convenient time. Do not edit package-owned files under `/usr/share/omarchy/`.

To remove the widget, remove its bar entry and user plugin symlink. This leaves your configuration and keyring credentials intact. See [privacy](PRIVACY.md) for local disconnection and Google-side revocation.
