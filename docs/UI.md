# Dropdown behavior

Click the magma icon to open the compact bar dropdown. The sidebar lists your configured accounts in order, with a separate unread count for each. Choose an account to see up to 30 recent Inbox messages, including read and unread mail. The initial selection is the first enabled account marked `required`; later openings keep the selected account while it remains configured.

Rows show sender, subject and time. Select a row to see its plain-text snippet. **Refresh** updates the selected account. **Open inbox** and message activation open Gmail in that account’s configured Chrome profile. The bar fetches snippets and metadata; reading full messages and attachments happens in Gmail or the [terminal client](TERMINAL.md). The bar does not change read status or send mail.

**Open TUI** opens the selected account in Omarchy's default terminal, in a
centered floating window. The popup closes while the read-only bar backend
keeps running. The plugin installation also adds an **Omagma** application
launcher entry, which can take over Omarchy's **Super+Shift+E** email shortcut;
see [installation](INSTALL.md#application-launcher).

## Status labels

| Label | Meaning |
| --- | --- |
| Never checked | This account has no completed check yet. Select Refresh. |
| Loading… | A mail check is running. |
| Current | The last successful check is recent. |
| Cached | Showing an older successful result, with its last-checked time. |
| Disconnected | Connect or reconnect this account using [account setup](SETUP.md). |
| Unavailable | This account is disabled or mail access is unavailable. Its Inbox can still be opened in Chrome. |

**Cached** is a neutral age label, not a failed-fetch warning. An actual error appears separately, and the previous successful mail remains available. **Inbox is empty** appears only after a successful current check returns no messages; failed access is never presented as an empty Inbox. **Partial page** identifies a result that could not include all requested rows.

## Keyboard controls

| Key | Action |
| --- | --- |
| Escape | Close the dropdown |
| Ctrl+R | Refresh the selected account |
| Ctrl+1 / Ctrl+2 / Ctrl+3 | Choose a configured account |
| Up / Down | Select a message |
| Enter | Open the selected message in Gmail |

Shortcuts for account slots you have not configured do nothing.

## When closed

Closing releases the popup view while keeping one bounded memory snapshot per account. With scheduled refresh disabled, closing cancels an unfinished check without showing a cancellation error. Optional [background refresh](BACKGROUND-REFRESH.md) keeps checking connected accounts while the dropdown is closed. Reopening shows the available snapshot and its last-checked time. Mail disappears from the bar cache when its backend exits; the [terminal disk cache](TUI-CACHE.md) is separate.

The bar uses plain text for mail and account names. HTML, terminal controls and directional overrides are not rendered as active content. See [privacy](PRIVACY.md) for data and credential handling; [development](DEVELOPMENT.md) covers implementation and verification.
