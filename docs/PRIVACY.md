# Privacy and credentials

Omagma connects directly to Google’s APIs. Every configured account authorizes separately, and mail, unread counts and browser profiles remain account-specific. Public examples and screenshots use fictional accounts.

## Bar access

The bar requests `gmail.readonly`. Google classifies this as a restricted scope that permits broader mailbox reading than the bar actually uses. [Google’s scope definitions](https://developers.google.com/workspace/gmail/api/auth/scopes).

The bar fetches an Inbox page of at most 30 messages per account, with selected metadata and snippets. It does not download full bodies or attachments, change labels or read status, or send mail. Its cache lives in bounded process memory and disappears when the backend exits. The bar does not save mail history or mail logs to disk.

Gmail links open in the account’s configured Chrome profile. Reading a message in Gmail is then handled by Gmail itself.

## Credentials and consent

Refresh tokens are stored in Secret Service on Linux or the current default user Keychain on macOS, using Omagma’s service namespace and verified account identity. Token contents never go in command-line arguments. Access tokens remain in backend memory. Neither token type is sent to the bar UI or terminal client’s response frames.

Mac entries trust Omagma and Apple’s signed `/usr/bin/security` helper, allowing reads after an unsigned binary upgrade. Native checks target the exact default keychain and account/grant, suppress their own UI, and refuse a known locked keychain before starting the read helper. If the lock state changes during handoff or an item’s ACL was edited, the operating system may still request permission. A blocked read is canceled at Omagma’s finite deadline. Unlock the keychain explicitly and retry if Omagma reports `KeyringUnavailable`. This is per-user credential storage, consistent with Linux Secret Service, rather than isolation from programs with equivalent user access.

Consent opens your configured Chrome profile and returns through a temporary local IPv4 callback listener. Omagma verifies the random state, PKCE exchange and returned Gmail identity before accepting the grant. The consent command has a 180-second deadline. Keep the downloaded Google OAuth registration JSON and account configuration private, outside Git. Google treats installed applications as unable to keep registration secrets confidential; refresh tokens still need protection. [Google’s installed-app model](https://developers.google.com/identity/protocols/oauth2/native-app).

## Terminal client

The experimental TUI and CLI can read complete messages, threads and attachments using an existing read-only grant. Sending, mailbox changes and contacts require [separate terminal authorization](SETUP.md#full-tuicli-permissions). Terminal refresh tokens use a separate namespace on either platform. If you use a bar/read-only registration, broader terminal access uses a different Google OAuth registration so the read-only authorization remains intact. Terminal-only setup needs just one registration. Installation or read access alone does not authorize an agent to send mail or change contacts.

Terminal modes save cached mail, local drafts, contacts and operation receipts in owner-only directories and files. The defaults are `$XDG_CACHE_HOME/omagma/terminal` or `$HOME/.cache/omagma/terminal`; directories use mode 0700 and files use 0600. Live and fixture data have separate namespaces, and account/message filename components are hashes. **Mail and drafts are plaintext on disk, not encrypted at rest.** Filesystem permissions restrict access; a backup or administrator with file access can still read them.

The cache keeps the newest mail within message-count and byte quotas. Old-tail eviction removes mail and its cached bodies while preserving drafts and uncertain-operation receipts. Clearing the mail cache also preserves drafts, contacts and receipts. See [cache behavior](TUI-CACHE.md). Omagma also saves account addresses, mailbox/selected-message context and key/layout preferences in the private `omagma/ui.json` configuration file.

The CLI returns requested mail and contacts to its caller. Treat its stdout, redirected files and agent logs as private. Local send and invitation receipts contain account/message identities and submission state; they are private too. An uncertain send is retained for review rather than automatically resubmitted.

## Message rendering and attachments

Display text is sanitized to remove terminal controls and directional formatting. A supplied plain-text body takes precedence. HTML-only mail becomes bounded formatted text; scripts, stylesheets, remote images and other remote resources never run or load.

The reader’s link chooser opens only an explicitly selected HTTP(S) URL in the account’s Chrome profile. Received attachments are saved only after you choose a destination; existing files are not overwritten. Its Open action delegates a saved, private file of a supported document/image type to the desktop viewer. Reading mail does not automatically launch a link or attachment.

Fixture providers make no Gmail API or keyring requests. You can try fictional mail with `omagma tui --fixtures`; this is optional and does not grant live permissions.

## Disconnect or remove

Removing the Linux widget, uninstalling Homebrew’s `omagma` formula, or removing a manually installed executable leaves your private configuration, cache and keyring credentials available for later use. The bar protocol’s `disconnect` command removes its local account token and clears its memory cache. `omagma terminal-auth revoke --account ACCOUNT` removes the terminal token and registry entry; use your usual `--config` and `--grant-file` options when you selected non-default paths.

These local removals do not revoke Google’s grant or erase terminal cache files. To invalidate Google-side access, revoke Omagma in your Google Account. To delete local mail, review the private cache directory and any files you explicitly saved. Keep real mail, addresses, message IDs, OAuth downloads and callback URLs out of public issues, screenshots and shared logs.
