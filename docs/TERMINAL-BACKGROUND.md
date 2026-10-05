# Background terminal cache

The experimental TUI cache can refresh every five minutes while the TUI is closed. A user systemd timer runs the native `omagma cache-refresh` one-shot. It processes configured enabled accounts sequentially, uses existing read-only bar credentials and returns afterward; no cache daemon stays resident between runs. It performs no send, contact or mailbox mutation.

The popup keeps its existing bounded 30-message memory cache and refresh worker. Terminal background work uses the disk cache's Gmail history path: unchanged messages need no repeated metadata or body download. The timer and TUI use account-specific refresh leases to coalesce duplicate cache work while leaving cached reads available. Manual refresh bypasses age checks, while respecting the lease. Cache count and byte policy are shared across callers.

Release bundles include the user service and timer in `systemd/`. Verify and install the same release binary used by the TUI into `~/.local/bin/omagma` before enabling them. The sample service names the standard private config and cache locations explicitly. If using `XDG_CONFIG_HOME`, `XDG_CACHE_HOME` or a custom path, adjust those two arguments to the actual absolute private paths; no addresses or credentials belong in the unit. Preserve any existing unit before replacing it.

```sh
omagma_unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$omagma_unit_dir"
cp systemd/omagma-cache-refresh.service systemd/omagma-cache-refresh.timer "$omagma_unit_dir/"
systemctl --user daemon-reload
systemctl --user enable --now omagma-cache-refresh.timer
systemctl --user list-timers omagma-cache-refresh.timer
```

To check once without changing Gmail:

```sh
omagma cache-refresh
```

The result contains anonymous account-slot outcomes, never mail, addresses, message IDs or tokens. `--quiet` suppresses that output. Automatic keyring access uses a non-unlocking Secret Service search; a locked or unavailable keyring leaves cached mail intact. Local configuration, cache identity and permissions errors remain explicit. Runs have finite per-account deadlines; service stop cancels owned work and systemd reaps its process group.

Disable scheduled fetching with `systemctl --user disable --now omagma-cache-refresh.timer`. This preserves mail cache files, drafts, credentials and the popup's independent refresh setting. The terminal cache remains plaintext under owner-only filesystem permissions. [Cache behavior](TUI-CACHE.md), [terminal setup](TERMINAL.md).
