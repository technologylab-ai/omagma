# Background terminal cache

A user systemd timer can refresh the terminal cache every five minutes, even while the TUI is closed. It runs the native `omagma cache-refresh` command, processes enabled accounts sequentially and exits afterward. It reuses each account's existing **read-only bar grant**; sending, mailbox changes and contacts are not part of this job.

The timer and TUI share the same disk cache and account refresh coordination. A simultaneous refresh is coalesced while cached reading remains available. The popup retains its independent 30-message memory snapshot and refresh setting. Enabling this timer does not reload the desktop or change terminal write permissions.

A terminal-only installation still needs the read-only bar Google OAuth registration and `omagma auth` for each account when using this timer. The full terminal grant is not used for automatic fetching. You do not need to install the bar widget; follow [read-only account setup](SETUP.md#read-only-google-oauth-registration).

## Enable the timer

Use the service/timer files in `systemd/` that match your installed binary. Installing a release binary needs no Zig compiler. [Installation](INSTALL.md).

Put the intended binary at `~/.local/bin/omagma`. Check the sample service's `--config` and `--cache-dir` arguments: they name the default private paths under your home directory. If you use custom XDG locations or another configuration/cache, change those arguments to the actual absolute paths. Preserve an existing service/timer before replacing it. No account addresses or credentials belong in the unit.

From the matching release bundle or checkout:

```sh
omagma_unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$omagma_unit_dir"
cp systemd/omagma-cache-refresh.service systemd/omagma-cache-refresh.timer "$omagma_unit_dir/"
systemctl --user daemon-reload
systemctl --user enable --now omagma-cache-refresh.timer
systemctl --user list-timers omagma-cache-refresh.timer
```

Only the explicit `enable --now` step starts scheduled work. These instructions do not require a shell/plugin reload.

## Check or change it

Run a read-only check once:

```sh
omagma cache-refresh
```

Normal output reports anonymous account-slot outcomes, not addresses, message contents or tokens. `--quiet` suppresses that output. `--force` bypasses the freshness age check while still respecting an active refresh. A locked/unavailable keyring keeps cached mail intact rather than displaying a surprise unlock prompt.

`--prefetch-bodies N` chooses 0–64 recent bodies; the default head is 32 and zero disables automatic body filling. Add the option to the service's command if changing that policy, and use the same value in your TUI/CLI sessions. `--metadata-limit` and `--disk-limit-bytes` also apply. All retention limits and oldest-tail eviction remain in effect. See [cache behavior](TUI-CACHE.md).

Inspect the last run with `systemctl --user status omagma-cache-refresh.service`. To stop scheduled fetching:

```sh
systemctl --user disable --now omagma-cache-refresh.timer
```

Stopping the timer preserves the cache, local drafts, credentials and the popup's separate refresh setting. [Account setup](SETUP.md) covers the read-only connection; [full TUI/CLI permissions](SETUP.md#full-tuicli-permissions) is optional when you also want interactive write/contact features.
