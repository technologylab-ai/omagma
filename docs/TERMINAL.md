# Terminal mail

**Experimental:** Omagma's TUI and agent CLI are under active development. This guide describes the current development checkout, including additions made after the public **v0.2.3** release. The released binaries remain unchanged; use a current source build when you need these newer features. See the tiered [feature catalogue](FEATURES.md) and [installation](INSTALL.md).

The same Linux binary runs the bar backend, TUI and CLI. The terminal needs a UTF-8 terminal, an unlocked Secret Service keyring, `secret-tool`, CA certificates and your private account configuration. Chrome is used for Google consent and explicitly opening Gmail links. A release binary needs no Zig compiler.

| Feature set | Availability |
| --- | --- |
| Read/cache mail and threads, metadata-only cache search, styled HTML, mouse navigation, reply/reply-all, local drafts, literal outgoing attachments, `$EDITOR`, contacts, single-message actions and RSVP | Public v0.2.3 |
| Automatic bidirectional windows, reader cross-window navigation, body-cache search, saved working context, remaps and compact reader polish | **Source only** |
| Forwarding, explicit sending identities/signatures, autocomplete and incomplete-draft autosave recovery | **Source only** |
| Bulk actions/undo, custom-label/Spam/All Mail/Unread views and the interactive label chooser | **Source only** |
| Link/received-file pickers, thread/quote/signature folding, preview keyboard controls, native path completion and Downloads defaults | **Source only** |

## Start

Connect accounts through [account setup](SETUP.md), then run:

```sh
omagma tui
omagma tui --account personal@example.com
```

Use `--config /absolute/private/config.json` when your configuration is elsewhere. `--grant-file FILE` selects a custom terminal grant registry; use the same path during authorization and later sessions.

For a preview without connecting Google, `omagma tui --fixtures` uses fictional mail and contacts. Fixtures are optional. You can use your own configured accounts directly after granting the permissions needed for your work.

Accounts remain separate. Select one with `1`, `2`, `3` or a click. Reading does not mark messages read. The bar stays read-only and keeps its own memory-only recent-mail snapshot.

## Read and navigate

Cached mail appears immediately while Omagma checks for changes. The colored sync line shows fetching, refreshing, completion or offline cached mail. **Source-only progress:** when a bounded fetch has a known batch, `metadata 1/32` or `bodies 1/32` reports that work; it is not your Inbox total. `NO_COLOR` keeps the same information as text.

**Source-only local time:** mail dates and the fixed **Synced** time use the
computer's timezone, including the DST offset for each date. An explicit `TZ`
environment setting overrides the system timezone. Restart the TUI after
changing it; if local rules cannot be loaded, the display labels its UTC
fallback. Cache and CLI epoch timestamps stay unchanged.

**Source-only window navigation:** the list holds at most 32 messages at a time. Move past its last row with `j`, Down, the wheel or PageDown to load the next window and select the adjacent older message. Move above its first row with `k`, Up, the wheel or PageUp to return to adjacent newer cached mail. Existing mail remains readable while another window loads. Repeated boundary input requests one window. In v0.2.3, use explicit `[`/`]` pages instead.

After the cached tail, ordinary forward movement can fetch one older Gmail page. Backward movement uses cached metadata; a selected body that is missing can still be fetched read-only. `/` cache searches never fetch missing bodies or older provider results. `[` and `]` remain explicit page controls; `[` selects the previous window's first row.

Enter opens the full thread. `h`/`l` or Tab changes pane, `v` moves the reader beside or below the list, and `z` expands it. With the reader focused, `J`/`K` moves to adjacent mail while lowercase `j`/`k` scrolls the body. **Source only:** reader movement crosses windows; `{`/`}` chooses a thread message, `t` or a click folds its body, and `Q`/`S` folds quoted history/a standard signature. Short-pane header and position polish also requires current source. These controls do not change stored mail.

Mouse support is enabled by default. Click accounts, mailboxes, messages and contacts; the wheel scrolls the pane under the pointer. Loading placeholders and gaps cannot select unfinished mail. Use your terminal's selection modifier for text selection, or `--no-mouse` to retain ordinary terminal mouse behavior.

## Reading HTML-only mail

The reader prefers a nonempty plain-text MIME alternative. For HTML-only mail, a native text view keeps headings, bold/italic emphasis, lists, quotes, preformatted blocks and simple tables. Colors follow the Omarchy palette. Narrow tables stack their cells; complex presentation tables flatten into reading order.

Scripts, remote images and other resources never run or load. Image alt text may appear. Links have styled labels and open only when explicitly chosen. The CLI receives decoded plaintext and optional HTML data rather than this styled screen.

**Source-only plaintext polish:** paragraphs wrap at word boundaries. Hard newlines and indented/preformatted lines remain intact; long URLs or words split within the pane. The composer uses the same layout for its caret and text.

## Search

`/` searches this account's retained mail without downloading missing bodies. **Source only:** matching downloaded plaintext, quoted phrases, AND terms, negative terms, and the extended `from:`, `to:`, `cc:`, `subject:`, `body:`, `label:`, `in:`, `is:unread|read|starred` and `has:attachment` predicates.

**Source only:** downloaded-body search, compound predicates and restoring the pre-search working position. The public v0.2.3 cache search covers metadata with simpler predicates; `\` already supports explicit Gmail search there.

`\` explicitly searches Gmail using Google's query syntax. That can reach mail outside the cache and may take network time. `q` leaves search results. **Source only:** returning restores the original mailbox, selected message and reader position where still cached.

The CLI exposes both modes through `omagma mail search --cached` / `--server`, or JSONL `cacheOnly:true` / `false`. See [the CLI guide](AGENT-CLI.md) and [cache behavior](TUI-CACHE.md).

## Compose, reply and forward

Use `c` for a new message, `r` for reply and `R` for reply-all. **Source only:** `f`/`F` forwards, and a reply from the reader targets its focused thread card. Forwarding creates an unaddressed draft with the original attachments; choose recipients before sending.

Compose starts in normal mode. Tab or `j`/`k` selects To, Cc, Bcc, Subject or Body. `i` or Enter begins insertion; Escape returns to normal mode. Letters such as `q`, `L` and `B` remain text while inserting. The selected field has a row highlight, and the body follows its caret.

**Source-only composer polish:** Body receives a full selection row, From has a separate explicit alias action, and one footer replaces repeated in-pane hints.

`a` opens the contact picker. **Source only:** recipient insertion offers Ctrl+N/P and Enter for account-local cached suggestions; normal compose `f` or the alias action selects a verified identity; account `senderName` and plaintext `signature` settings override primary defaults. Alias selection does not change the sending account's grant.

**Source-only autosave:** changes save locally after a pause, including unfinished addresses. An unfinished recovery draft must be corrected before review and sending. Drafts appear under **Drafts** and survive restart; they are local Omagma drafts, not Gmail's web draft folder. In v0.2.3, explicitly save/review or leave compose to retain edits.

At 90 columns or more, the composer shows its original thread or a draft preview. **Source-only preview controls:** normal Ctrl+D/U or PageDown/PageUp scrolls it, and `L`/`B` opens its links or received files. These actions preserve the outgoing draft, account, recipients and attachments.

`e` edits the body with `$EDITOR`, then `$VISUAL`, then available nvim/vi/nano. Fixed quoted arguments are passed directly without a shell. It temporarily takes over the terminal and restores the TUI afterward. `--editor-mode auto|takeover` uses this behavior; `embedded` is unsupported. No tmux is required. Saving the editor, pasting or autosaving never sends mail.

Escape/`q` saves and leaves normal compose. Ctrl+S or `:send` opens review; only explicit `y` sends. Review shows the account, recipients, subject, body, threading and attachments (plus the selected From alias in current source). If the provider result is uncertain, keep the draft, use `:receipt` to inspect its journal and check Sent mail before attempting another send.

## Attachments and links

`A` attaches another outgoing file and `:detach NUMBER` removes one. **Source-only controls:** **Add A**, always-visible filenames/sizes, individual **[x]** and attachment-list wheel scrolling. You can attach up to 16 regular files, within the limits below; files remain attached through saving and editor return.

Attachment paths are literal and direct paths with spaces need no quoting. **Source-only completion:** Tab completes files/directories, Tab/Shift+Tab cycles bounded matches and Ctrl+U clears the prompt. Completion excludes symlinks and special files. Shell expressions or variables are not expanded.

**Source-only received-file picker:** `B`, `:attachments` or a file click opens the thread's attachment list. `s` or Enter chooses Save; `o` chooses Save & open. The prompt suggests a sanitized, fresh name in XDG Downloads or `HOME/Downloads`; Ctrl+U replaces it and Tab completes paths. Saving creates a new private file and refuses overwrite or symlink traversal. In v0.2.3, use `:save-attachment NUMBER /absolute/path` instead.

Numeric `:save-attachment NUMBER /absolute/path` also remains available in current source. Paths with spaces are literal. If a completion list is visible, Escape hides it first; Escape again leaves the path prompt. Saving/opening a received file reports the explicit result while retaining its originating reader or draft.

**Source-only link chooser:** `L` opens literal HTTP(S) destinations; Enter opens the selection in this account's Chrome profile. `o` in the mailbox opens selected mail in Gmail and is already available in v0.2.3. Rendering mail never launches anything automatically.

## Labels, bulk actions and contacts

The released sidebar includes Inbox, Sent, local Drafts, Archive and Trash. **Source only:** Spam, All Mail, Unread and cached custom labels, plus the `m` chooser with `/` filtering, Enter/**Add** and `-`/**Remove**. In v0.2.3, `m` accepts a literal existing label. Omagma does not create, rename or delete definitions.

**Source-only bulk/undo:** Space selects mail, Ctrl+A selects the window, and actions apply to that set or the focused message. Escape/`q` clears a selection first; Ctrl+Z or `:undo` reverses the last completed account action. Scope changes clear selection. Bulk actions can have partial outcomes; uncertain items are not replayed. Single-message archive/star/unread/labels and `D` Trash review with explicit `y` already exist in v0.2.3.

The source-only CLI/API batch interface also supports `spam` and `unspam`
actions; `unspam` removes Spam and restores Inbox membership. See
[batch commands](AGENT-CLI.md#commands).

`a` opens this account's address book. Search with `/`, create with `n`, edit with `e`, and save a contact with Ctrl+S. Contacts require People API permissions. Version conflicts are reported so you can refresh before editing again. Contact deletion is not implemented.

`I` inspects a calendar invitation and offers accepted, tentative or declined replies. This sends an RSVP email; there is no Calendar API permission, calendar view or calendar editing.

## Keys

| Key | Action | Availability |
| --- | --- | --- |
| j/k, arrows, gg/G, Ctrl+D/U | Move or scroll focused pane | v0.2.3; automatic boundary windows source only |
| h/l, Tab/Shift+Tab, Enter | Change pane or open selected item | v0.2.3 |
| 1/2/3 | Switch account | v0.2.3 |
| / / \ | Search cache / Gmail | v0.2.3; body search source only |
| v / z | Reader layout / expand | v0.2.3 |
| J/K | Reader: adjacent mail | v0.2.3; crossing windows source only |
| {/}, t, Q/S | Reader: thread card, fold body, quotes/signature | **Source only** |
| c / r / R | Compose / reply / reply-all | v0.2.3 |
| f / F in mailbox | Forward | **Source only** |
| A in normal compose | Add outgoing attachment | v0.2.3; visible Add/[x]/completion source only |
| L / B | Links / received-file picker | **Source only** |
| o | Open selected mail in Gmail | v0.2.3 |
| Space / Ctrl+A / Ctrl+Z | Select / select window / undo | **Source only** |
| x / D / U / s / u / m | Archive / Trash review / restore / star / unread / labels | v0.2.3; interactive label chooser source only |
| a / I | Contacts / invitation reply | v0.2.3 |
| Ctrl+R / Ctrl+L / ? / q | Refresh / colors / help / back or quit | v0.2.3; original search-position restoration source only |

`q` backs out of readers, search, contacts, help and draft review before quitting the mailbox. It remains text in insertion and path fields. `?` shows the full, scrollable help for the current interface.

Basic reader layout and `--ui-file FILE` are in v0.2.3. **Source-only preferences:** split proportions, key remaps and per-account mailbox/selected-mail/reader position live in private `omagma/ui.json`. `:split right 60` or `:split below 40` chooses a 25–75% split; `:bind n down`, `:bind p up` and `:unbind n` remap mailbox keys without intercepting text entry or confirmation. Ctrl+L reloads the Omarchy palette; desktop fonts/theme configuration stay with the terminal.

## Live permissions

Follow [full TUI/CLI permissions](SETUP.md#full-tuicli-permissions) for the Google project, People API, separate terminal Desktop client and per-account consent. The TUI and CLI share that terminal grant; the bar retains its original read-only client and credentials.

For all implemented live features, authorize the complete local capability set:
`mail-read,mail-send,mail-modify,contacts-read,contacts-write,calendar-rsvp`.
The setup guide explains the corresponding two Google scopes and the browser steps. A Console scope change alone does not replace an account's existing token. Restart an open TUI after authorizing its updated grant.

You can use your own accounts after consent, including sending a first message to yourself. Agent actions still need your task authorization. A dedicated test mailbox is a development qualification tool, not an installation requirement.

## Bounds and recovery

| Limit | Default or supported maximum |
| --- | --- |
| Retained mail per account | Default 2,000 entries / 256 MiB; configurable up to 10,000 / 1 GiB |
| Display/result window | 32 in the TUI; up to 100 per CLI page |
| Loaded thread | 100 messages |
| Message body | 2 MiB |
| Outgoing attachments | 16 files, 2 MiB combined decoded bytes |
| Incoming attachments | 32 per message |
| Outgoing recipients | 32 across To/Cc/Bcc |
| Local drafts / undo receipts | 128 / 16 per account |
| Cached contacts / operation journal | 1,024 / 1,000 per account |
| Serialized request | 3 MiB, including encoded attachment data |

Encoded bodies and attachments must also fit the request limit; an oversized or unavailable file fails explicitly instead of being silently omitted. Old mail is evicted under cache pressure; local drafts and operation receipts are preserved. `cache.clear` removes cached mail without removing drafts, contacts or receipts.

Every send or RSVP has an operation identity and a recorded outcome: applied, rejected or unknown. Applied means provider acceptance, not delivery. An unknown receipt protects its recovery draft; inspect the provider before deciding what to do next. Local duplicate guards do not guarantee server-side idempotency.

Cache files and drafts contain plaintext protected by owner-only filesystem permissions, not encryption at rest. Keep private configuration, credentials, cache files and real-mail captures outside Git. See [cache behavior](TUI-CACHE.md), [agent CLI](AGENT-CLI.md) and [developer references](DEVELOPMENT.md) for the deeper contracts.
