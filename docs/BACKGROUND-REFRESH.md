# Background refresh

The bar can check mail every five minutes even while its dropdown is closed. In your existing private account configuration, set `refreshIntervalSeconds` to `300`, preserving the other configuration fields. The setting takes effect when the backend restarts; see [bar installation](INSTALL.md) for reload options.

The value must be a JSON integer: `0` disables scheduled refresh, and `60..86400` sets an interval in seconds. The default is `0`.

## What changes

| Setting | Behavior |
| --- | --- |
| `0` | Opening the dropdown or selecting an account checks never-checked or aged data. Refresh updates the selected account. Closing cancels an unfinished check and keeps its previous successful result. |
| `300` | Enabled, connected accounts are checked at startup and approximately every five minutes, including while the dropdown is closed. Closing lets an active check finish. Refresh still updates the selected account immediately when the dropdown is open. |

Disconnected and disabled accounts are skipped. An account waiting after a failed request follows its retry delay. Mail checks run one at a time; a delayed interval does not create a queue of catch-up checks. Each successful result replaces that account’s bounded memory snapshot.

If a refresh fails, cached mail and its last-checked time remain available. Background access uses the existing read-only grant and needs an unlocked keyring. Accounts can succeed or fail independently. Ending the backend stops its refresh schedule.

## Terminal mail cache

The bar setting updates the bar’s recent-mail snapshot. To keep full-message terminal cache data ready while the TUI is closed, enable the optional [terminal cache timer](TERMINAL-BACKGROUND.md). That timer runs a short cache-update command and exits between updates; it does not send mail or change contacts or mailbox state. Both options preserve separate accounts and use read-only access for fetching.

[Account configuration](SETUP.md) · [Dropdown states](UI.md) · [Developer scheduling checks](DEVELOPMENT.md)
