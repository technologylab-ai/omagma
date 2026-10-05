# Terminal mail

The same native binary runs the bar backend, TUI and agent CLI. A complete release is preferred; its `zig-out/bin/omagma` needs no compiler. For terminal-only use, the matching static `omagma-linux-ARCH` binary plus the release's `LICENSES.txt` is sufficient. Verify its entry in `SHA256SUMS`, make it executable, and put it in a user-controlled PATH directory. The terminal needs Linux and a UTF-8 terminal; live Gmail additionally needs an unlocked Secret Service keyring, `secret-tool`, CA certificates and private account configuration. Chrome is needed for consent and explicitly opening Gmail links.

## Start safely

```sh
omagma tui --fixtures
omagma tui --account personal@example.com --config /absolute/private/config.json
```

Fixtures use three fictional accounts and a separate mock provider with mail sends, mailbox changes, contacts and RSVP enabled. They require no OAuth grant and never contact Google. Defaults use the private terminal cache under `$XDG_CACHE_HOME/omagma/terminal` or `$HOME/.cache/omagma/terminal`; use a separate `--cache-dir` for experiments. Existing cache directories must be owner-only (0700). Files are created 0600. The cache base separates `fixtures/` and `live/` namespaces even for the same account. Account directories and message filenames are hashes, never addresses. The terminal cache contains plaintext mail and drafts protected by filesystem permissions; it is not encrypted at rest.

The bar stays read-only and does not persist mail. Terminal reads do not mark mail read. Each command and each TUI view names one configured account; there is no combined inbox.

## Keys

| Key | Action |
| --- | --- |
| j/k, gg/G, Ctrl+D/U | Move or scroll |
| h/l, Tab/Shift+Tab | Change pane |
| Enter | Open mailbox, full thread, draft or contact |
| [ / ] | Previous / next page |
| / | Search this account |
| 1/2/3 | Select a configured account |
| z | Expand reader |
| c / r / R | Compose / reply / reply-all |
| a | Contacts; n creates, e edits |
| s / u | Toggle star / unread |
| x / D / U | Archive / confirm Trash / restore |
| m | Add a label; prefix with - to remove |
| I | Inspect and review an invitation reply |
| o | Open Gmail in this account's configured Chrome profile |
| Ctrl+R / ? / q | Refresh / help / back or quit |

Compose uses normal and insert modes: select a field with Tab or j/k, enter text with i/Enter, then Escape returns to normal mode. The body wraps with a visible caret. The contact picker fills the selected recipient field. A in normal compose opens a literal attachment-path prompt; `:detach NUMBER` removes an attachment. Attachment contents survive draft save and editor return. The reader numbers attachments. `:save-attachment NUMBER /absolute/path` saves one to a literal, owner-only destination and refuses overwrite; the agent interface also provides `mail.attachment`.

Press e in normal compose to edit the body with `$EDITOR` (then `$VISUAL`, then nvim/vi/nano), using direct argv without a shell. Quoted fixed arguments are supported. It takes over the terminal, then restores the TUI, including after errors or termination. The built-in composer remains split; an arbitrary editor pane is deferred pending a bounded embedded VT implementation. `--editor-mode auto|takeover` uses takeover; `embedded` reports a visible unsupported-mode error. No tmux or Ghostty is needed.

Escape/q saves a draft before leaving compose. Ctrl+S or `:send` opens review, and only explicit y submits. Ordinary Enter, editor save and pasted text never send. Review includes the account, recipients, subject, threading, body and attachments. An unknown outcome preserves the draft and operation identity; inspect the receipt and provider before deciding whether any new send is appropriate. Applied means provider acceptance, not recipient delivery.

Invitation review shows the validated attendee, organizer, UID and event. Accepted/tentative/declined sends a standards-based iTIP REPLY email. It does not update or display Google Calendar. Contacts are read and written through People, with an etag precondition for edits. A successful live contact write returns the provider contact directly; its invalidated cache refreshes on the next contacts read.

## Live permissions

Existing bar configuration and credentials support terminal read-only mail. To enable writes, create a **second Desktop OAuth client in the same Google project**, download its private JSON, and authorize a separate terminal grant. This protects the bar's strict read-only token response checks and Secret Service namespace. Keep the client JSON and grant registry outside Git and owner-only. No new consent is initiated by opening the TUI.

Enable People API in that project for contacts. Add only the needed Gmail/People scopes in Google Auth Platform, preserve the existing audience/test-user restrictions, then run:

```sh
omagma terminal-auth authorize --account personal@example.com \
  --config /absolute/private/config.json \
  --client-file /absolute/private/terminal-client.json \
  --capabilities mail-read,mail-send,mail-modify,contacts-read,contacts-write,calendar-rsvp
omagma terminal-auth status --account personal@example.com --config /absolute/private/config.json
```

The browser opens in the configured account's Chrome profile. Select that exact account and approve the displayed permissions. The command verifies Gmail identity and the actual granted scopes before storing a token. The browser callback alone does not prove success. If policy blocks a scope, report the error and keep working with fixtures. There is no shared hosted OAuth client, account scraping or reuse of another application's tokens.

Capabilities are local gates as well as OAuth scopes. `mail-read` is required; choose only what is needed. `calendar-rsvp` grants the ability to send the prepared reply; it does not grant ordinary send unless `mail-send` is also present. `mail-modify` uses Gmail modify scope, but local command capabilities remain separate. Desktop clients do not support incremental consent here: request the complete desired capability set when replacing a terminal grant. `terminal-auth revoke` removes the local terminal token/registry entry without altering the bar; it is not a remote Google revocation request. The default registry is `$XDG_CONFIG_HOME/omagma/terminal-grants.json` or `$HOME/.config/omagma/terminal-grants.json`; use the same `--grant-file FILE` for authorization and later terminal/agent sessions when selecting another registry.

Use a dedicated test Gmail account for first live writes. Development tests are synthetic and do not prove live delivery, Workspace policy approval or contact mutation. [Provider design](TERMINAL-PROVIDER-DESIGN.md) lists exact scopes and source references.

## Bounds and recovery

Pages contain at most 100 messages (TUI requests 32). Live thread reads reject more than 100 messages or an oversized response explicitly. Cache defaults are 2,000 metadata entries and 256 MiB per account, configurable with `--metadata-limit` / `--disk-limit-bytes`; hard ceilings are 10,000 and 1 GiB. Bodies and aggregate decoded outgoing attachments are 2 MiB, requests and live provider response storage 3 MiB, outgoing recipients 32, outgoing attachments 16, incoming attachments 32 per message, local drafts 128, cached contacts 1,024 and operation receipts 1,000. A full journal refuses new submissions instead of forgetting uncertain outcomes. Terminal heap allocations are capped at 64 MiB; the existing 16 MiB fixed backend/HTTP reservation is accounted separately. OS/std/editor memory is outside those application storage bounds.

Incoming envelopes allow up to 1,024 participants per address header, 16 KiB per address header and 32 KiB of aggregate headers. Addresses have a practical 254-byte cap; RFC 2047 decoded display names have a 256-byte cap. Incoming local parts may exceed 64 bytes; outgoing SMTP addresses retain the 64-byte local-part limit and outgoing recipients remain capped at 32. The ASCII address grammar is unchanged, without SMTPUTF8 or expanded obsolete forms. Reply-all removes self aliases and duplicates before enforcing the final 32-recipient cap; overflow returns an error rather than truncating recipients.

Disk quotas count logical file bytes, including the overlap during atomic replacement. Bodies are evictable. Direct sends also save recovery drafts before submission; unknown operations protect those drafts against changed-content edits or discard. Use `draft.discard` to explicitly remove completed local drafts. Drafts and operation receipts are retained; quota exhaustion is an explicit error. `cache.clear` removes cached mail while preserving drafts, contacts and receipts. Cache cursors are account/query/generation scoped; after mutations or clear, restart pagination instead of reusing a stale cursor. Per-account locks prevent simultaneous writers. Synthetic submitted mail has its own quota-counted outbox, capped at 128, so cache eviction/clear does not erase mock sends.

Mail is rendered as text: terminal controls and bidi formatting are filtered, graphemes bounded, and remote HTML content never loads. [Agent contract](AGENT-CLI.md), [UI implementation](TERMINAL-UI-DESIGN.md), [verification](TERMINAL-VERIFICATION.md).
