# Dropdown behavior

The sidebar shows the configured account addresses in order, each with its own unread count. There is no combined inbox or combined unread total. The first enabled required account is selected initially; subsequent openings preserve the selected account while it remains configured.

Each account shows up to 30 recent Inbox messages, including read and unread messages. Rows show sender, subject and time; selecting a row reveals its plain-text snippet. **Refresh** requests that account’s mail. **Open inbox** and message activation launch Gmail in its configured Chrome profile. The UI does not download full bodies or attachments or change read status.

Loading, current, cached, disconnected, unavailable and never-checked states have distinct labels. A successful, current result with zero rows can say **Inbox is empty**. Missing access or a failed fetch never masquerades as an empty Inbox. Older successful data says **Cached**, keeps its last-checked time and remains neutral unless an actual account error is present.

Keyboard controls are Escape to close, Ctrl+R to refresh, Alt+1/2/3 for configured accounts, arrows to select a message and Enter to open it. Slots beyond the configured account count have no action.

All mail and account strings use Qt plain text. The model validates bounded snapshots and opaque identifiers, strips controls and directional overrides from display text, and rejects unknown account identities or older generations. Each successful snapshot replaces that account’s rows.

Closing destroys the popup content Loader. The service retains one bounded snapshot per account and a bounded ledger of request metadata, with no retained view callbacks. No UI timer fetches mail. Optional closed-popup polling belongs to the Zig backend; [background refresh](BACKGROUND-REFRESH.md) explains its cancellation and scheduling behavior.

The standalone lifecycle harness uses the offscreen Qt platform and synthetic mail. It exercises content creation/destruction without interacting with the desktop. Its memory baseline and platform limitations are described in [verification](VERIFICATION.md).
