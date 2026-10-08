# Terminal mail

**Experimental:** Omagma's TUI and agent CLI are under active development. This guide describes the current application. See the tiered [feature catalogue](FEATURES.md) and [installation](INSTALL.md).

The TUI and CLI run natively on Linux and macOS; only the Linux Omarchy bar needs Quickshell. The terminal needs a UTF-8 terminal, Chrome and your private account configuration. Linux uses unlocked Secret Service with `secret-tool`; Mac uses the unlocked default user Keychain. A release binary needs no Zig compiler. [Mac installation](MACOS.md) covers Homebrew and native bundles.

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

Cached mail appears immediately while Omagma checks for changes. The colored sync line shows fetching, refreshing, completion or offline cached mail. When a bounded fetch has a known batch, `metadata 1/32` or `bodies 1/32` reports that work; it is not your Inbox total. `NO_COLOR` keeps the same information as text.

Mail dates and the fixed **Synced** time use the
computer's timezone, including the DST offset for each date. An explicit `TZ`
environment setting overrides the system timezone. Restart the TUI after
changing it; if local rules cannot be loaded, the display labels its UTC
fallback. Cache and CLI epoch timestamps stay unchanged.

An open TUI picks up updates written by the [background cache timer](TERMINAL-BACKGROUND.md) or another Omagma client. New cached rows appear without Ctrl+R, preserving the selected mail and reader position where possible. At the newest head, new rows appear above your selection; when you are farther down, the selected mail stays at its screen row. It remains visible even if insertions would push it beyond the viewport. Compose, contacts, searches and review overlays keep their working context.

A compact **New mail** card appears at the top right of the main mailbox screen. It accumulates newly received Inbox messages separately for each account while you leave the TUI unattended. A key, click, wheel gesture or paste clears the card and continues the normal action. The card stays hidden in compose, contacts, search, review and expanded reading. Existing unread mail, initial cache filling, label changes and older-page downloads do not create arrival alerts.

`gg` jumps to the first mail in the entire cached mailbox or cached result set, including from a later window; on the main screen it works from either the list or reader. In expanded reading, `gg` scrolls the current body to its start. Home scrolls a focused reader to the top; in the mail list it selects the first row of the current window, keeping that window.

The list holds at most 32 messages at a time. Move past its last row with `j`, Down, the wheel or PageDown to load the next window and select the adjacent older message. Move above its first row with `k`, Up, the wheel or PageUp to return to adjacent newer cached mail. Existing mail remains readable while another window loads. Repeated boundary input requests one window.

After the cached tail, ordinary forward movement can fetch one older Gmail page. Backward movement uses cached metadata; a selected body that is missing can still be fetched read-only. `/` cache searches never fetch missing bodies or older provider results. `[` and `]` remain explicit page controls; `[` selects the previous window's first row.

Enter opens the full thread. `h`/`l` or Tab changes pane, `v` moves the reader beside or below the list, and `z` expands it. With the reader focused, `J`/`K` moves to adjacent mail across windows while lowercase `j`/`k` scrolls the body. `{`/`}` chooses a thread message, `t` or a click folds its body, and `Q`/`S` folds quoted history/a standard signature. The header stays compact in short panes and shows reading position. These controls do not change stored mail.

Mouse support is enabled by default. Click accounts, mailboxes, messages and contacts; the wheel scrolls the pane under the pointer. Loading placeholders and gaps cannot select unfinished mail. Use your terminal's selection modifier for text selection, or `--no-mouse` to retain ordinary terminal mouse behavior.

Unread subjects are bold and marked `●`; read subjects use normal weight.
Stars appear as `⭐` on the sender row, independently of unread or bulk
selection marks. A highlighted row identifies your selection without changing
its read status. The reader header shows read/starred state and readable label
names for that account, including custom labels.

In dialogs, Tab/Shift+Tab moves through fields, lists and action buttons;
Enter activates the focused button. Lists retain their selected row when you
move focus to an action. Send, Trash and invitation review start on Back or
Cancel, so an unprompted Enter does not submit a change. Keyboard focus has a
visible highlight, including the compose Alias, Add, attachment removal,
format and preview controls.

## Reading HTML-only mail

The reader prefers a nonempty plain-text MIME alternative. For HTML-only mail, a native text view keeps headings, bold/italic emphasis, lists, quotes, preformatted blocks and simple tables. Colors use your chosen TUI palette. Narrow tables stack their cells; complex presentation tables flatten into reading order.

Scripts, remote images and other resources never run or load. Images show `[Image: caption]` using alt text or a title, or `[Image]` when neither is available; explicitly empty alt text hides decorative images. Links use the theme's cyan and underline, including HTTP(S) URLs in plain-text mail. Human-written link labels stay intact. Long visible URLs are shortened to their host/path and an ellipsis; `L` retains the complete destinations, including query parameters. These display changes leave stored mail and CLI bodies intact.

Paragraphs wrap at word boundaries. Hard newlines and indented/preformatted lines remain intact; overwide words split within the pane. The composer uses the same layout for its caret and text, keeping its editable content complete.

## Search

`/` searches this account's retained metadata and downloaded plaintext without fetching missing bodies. It supports quoted phrases, AND terms, negative terms, and the `from:`, `to:`, `cc:`, `subject:`, `body:`, `label:`, `in:`, `is:unread|read|starred` and `has:attachment` predicates.

`\` explicitly searches Gmail using Google's query syntax. That can reach mail outside the cache and may take network time. `q` leaves search results and restores the original mailbox, selected message and reader position where still cached.

The CLI exposes both modes through `omagma mail search --cached` / `--server`, or JSONL `cacheOnly:true` / `false`. See [the CLI guide](AGENT-CLI.md) and [cache behavior](TUI-CACHE.md).

Error status lines include a short diagnostic code. `?` opens Help with that
code and its explanation at the top; Escape/`q` returns to the current view.

Within Help, `/` searches shortcut names, descriptions and section names,
ignoring case. Matches highlight immediately. Enter keeps the query and
`n`/`N` moves through matches. Esc clears the search before leaving Help;
letters such as `q` remain text while entering a query.

## Compose, reply and forward

Use `c` for a new message, `r` for reply and `R` for reply-all. `f`/`F` forwards, and a reply from the reader targets its focused thread card. All forwarding modes create an unaddressed draft; choose recipients before sending.

When the original contains HTML, reply, reply-all and forward open a mode
chooser. **Keep formatting** (`k`) is selected initially: write your own note
above the original HTML, retaining its tables, styling and embedded images.
**Text quote** (`t`) puts a plain-text quotation in the editable body.
Forward also offers **Attach original (.eml)** (`e`), which attaches the
complete original message and leaves the body ready for your note.
Tab/Shift+Tab selects a choice, Enter or a click activates it, and Escape/`q`
returns to reading. Mail without HTML keeps the direct text-quote workflow.

In **Keep formatting**, only your note is editable. Its usual Markdown
rendering and Omagma footer appear above a read-only original. Switching your
note to Plain leaves the original HTML intact. The draft owns that original
and its embedded image data, so they survive saving, restarting and eviction
of the source mail from the cache. Outgoing preview and send review include
the retained original, with the same content used for sending. Received
regular attachments accompany Keep formatting and Text quote forwards.

**Attach original (.eml)** includes the original headers and contained
attachments; those contained files are not duplicated as separate outgoing
attachments. The recipient opens the attached message to see the original.
Your note uses the usual Markdown/Plain controls. In either mode, remote images
still depend on the recipient's settings and the image server, and final
styling follows the receiving email client.

New replies and forwards place the caret at the top of your note or above
the editable text quote. Ctrl+G focuses the body and jumps to its start
without changing the text. Reopening an existing draft keeps its usual editing
behavior; Ctrl+G is available there too.

New messages, replies, reply-all and forwards start
in **Markdown**. Existing drafts keep their saved format; older drafts remain
**Plain**. Ctrl+T toggles Markdown/Plain without rewriting the editable source
or changing a retained formatted original.
The Body label shows the current format (MD or Plain); the Ctrl+T button
names the format that pressing it switches to.

Compose starts in normal mode. Tab/Shift+Tab moves through fields and controls;
`j`/`k` also selects To, Cc, Bcc, Subject or Body. `i` or Enter begins insertion
in a field, and Enter activates a focused control. Escape returns to normal
mode. Letters such as `q`, `p`, `L` and `B` remain text while inserting. The
selected field has a row highlight, and the body follows its caret.

Body receives a full selection row, From has a separate explicit alias action, and one footer keeps the relevant shortcuts visible.

`a` opens the contact picker. Recipient insertion offers Ctrl+N/P and Enter for account-local cached suggestions; normal compose `f` or the alias action selects a verified identity; account `senderName` and plaintext `signature` settings override primary defaults. Alias selection does not change the sending account's grant. Recipient suggestions match names and addresses from retained From/To/Cc metadata, including Sent mail, so regular correspondents need not be saved contacts. Matching stays local while one bounded Sent-head metadata refresh runs in the background; it uses the existing mail permission. Primary self and duplicates are excluded.

Changes save locally after a pause, including unfinished addresses. An unfinished recovery draft must be corrected before review and sending. Drafts appear under **Drafts** and survive restart; they are local Omagma drafts, not Gmail's web draft folder.

At 90 columns or more, the composer shows the outgoing rendered preview beside
the editable source. In normal mode, `p` switches between that preview, the
original message for replies/forwards, and the plain-text alternative. Original
thread context stays available while composing. Below 90 columns, `p` opens
the preview full-screen; Escape/`q` returns to source. Ctrl+D/U or PageDown/PageUp
scrolls the selected preview, and `L`/`B` opens links or received files from the
original context. These actions preserve the outgoing draft, account, recipients
and attachments.

Markdown supports headings, emphasis, strikethrough, lists, quotes, tables,
links and fenced code. Supported fence languages receive syntax highlighting;
unknown languages remain literal code. The outgoing email includes rendered
HTML and a readable plain-text alternative. Raw HTML is escaped and remote
Markdown images stay inert as alt text or safe links. A small footer reads **[logo] Sent with omagma 🌋**: the approved tiny logo
comes first, “Sent with” stays grey, and only “omagma” is an orange, underlined
link to the project website. The volcano finishes the line. Rendering fetches no resources.
Plain mode sends the editable source literally; a Keep formatting draft still
includes its retained original HTML below that note. The native preview shows
the outgoing content; final styling follows the receiving email client.

`e` edits the body with `$EDITOR`, then `$VISUAL`, then available nvim/vi/nano. In a Keep formatting draft, the editor receives only your note; the retained original and embedded images remain read-only. Fixed quoted arguments are passed directly without a shell. It temporarily takes over the terminal and restores the TUI afterward. `--editor-mode auto|takeover` uses this behavior; `embedded` is unsupported. No tmux is required. Saving the editor, pasting or autosaving never sends mail.

Escape/`q` saves and leaves normal compose. Ctrl+S or `:send` opens review;
explicit `y` or Enter on the deliberately focused **Send** button sends.
Review starts with **Back** focused. It shows the account, selected From alias,
recipients, subject, format, rendered outgoing body, threading and attachments.
Review the outgoing preview and plain alternative before confirming. Saving,
switching format or preview, and pressing Enter on composer controls never submit mail.
If the provider result is uncertain, keep the draft, use `:receipt` to inspect
its journal and check Sent mail before attempting another send.

## Attachments and links

`A` or **Add A** attaches another outgoing file. `:detach NUMBER` or its **[x]** removes one. Filenames and sizes stay visible, and the wheel scrolls the attachment list. You can attach up to 16 regular files, within the limits below; files remain attached through saving and editor return.

Attachment paths are literal and direct paths with spaces need no quoting.
Ctrl+F completes files/directories; Ctrl+Shift+F cycles matches backward.
Filename prefix matching ignores ASCII case and returns the actual spelling.
Tab/Shift+Tab moves among popup controls and Ctrl+U clears the path. Completion
excludes symlinks and special files. Shell expressions or variables are not
expanded.

Ctrl+S confirms the current file choice, whether attaching, saving or saving
and opening. Ctrl+N/P browses file rows. In a narrow popup, the hint follows the
focused path, folder control or action button; searchable Help contains the
complete file-browser shortcuts, including reverse completion.

`B`, `:attachments` or a file click opens the thread's attachment list.
Tab/Shift+Tab chooses the list, Save, Save & open or Back; Enter activates the
focused action. From the list, `s` or Enter chooses Save and `o` chooses
Save & open. The popup suggests a sanitized, fresh name in XDG Downloads or
`HOME/Downloads`; Ctrl+U replaces it and Ctrl+F completes paths. Saving creates
a new private file and refuses overwrite or symlink traversal.

Numeric `:save-attachment NUMBER /absolute/path` also saves a file directly. Paths with spaces are literal. If a completion list is visible, Escape hides it first; Escape again leaves the path prompt. Saving/opening a received file reports the explicit result while retaining its originating reader or draft.

`L` opens the link chooser; Enter opens the selected literal HTTP(S) destination in this account's Chrome profile. `o` opens the selected mail in Gmail; with a thread message focused, it opens that exact message. In normal reply/forward mode it opens the original context. Each action uses the current account's configured Chrome profile. Rendering mail never launches anything automatically.

## Labels, bulk actions and contacts

The sidebar includes Inbox, Sent, local Drafts, Archive, Trash, Spam, All Mail,
Unread and cached custom labels. Clicking a **label name** shows mail carrying
that label. To leave the label view, click **Inbox** or another mailbox; this
changes your view without removing labels from any messages. The sidebar shows
the portion of the custom-label collection that fits its height.

`m` opens **Choose label**, which assigns or removes an existing custom label
on the current mail or selected group. `/` filters the list and `+`/`-` applies
Add/Remove. Tab/Shift+Tab chooses Filter, List, Add, Remove or Back; Enter
activates the focused action. Gmail's system labels are hidden here: mailbox
and read/star actions have their own controls.

Click the **LABELS heading**, or use `:labels`, to open **Manage labels**, for the
account's label collection. Use `n` New, `r` Rename, `d` Delete or `o` Open;
Tab/Shift+Tab and Enter reach the same buttons, and `/` filters the collection.
Create a label, rename one or review its deletion; these operations
are separate from assigning labels to mail. Deleting a label removes that label
from messages while keeping the emails themselves. System labels cannot be
created, renamed or deleted through this manager. Label collection changes use
the terminal account's existing `mail-modify` capability. Delete review starts
on Cancel and names the account and label. `y` or Enter on the deliberately
focused Delete button confirms; `d` does not confirm. Ctrl+R refreshes definitions
or checks the recorded receipt when an operation's outcome is uncertain.

Space selects mail, Ctrl+A selects the window, and actions apply to that set or
the focused message. Escape/`q` clears a selection first; Ctrl+Z or `:undo`
reverses the last completed account action. Scope changes clear selection.
Bulk actions can have partial outcomes; uncertain items are not replayed.
`D` opens Trash review, initially focused on Cancel; `y` or Enter on the
deliberately focused Confirm button submits the change.

The CLI/API batch interface also supports `spam` and `unspam`
actions; `unspam` removes Spam and restores Inbox membership. See
[batch commands](AGENT-CLI.md#commands).

`a` opens this account's address book. Search with `/`, create with `n`, edit with `e`, and save a contact with Ctrl+S. Contacts require People API permissions. Version conflicts are reported so you can refresh before editing again. Contact deletion is not implemented.

`I` inspects the focused calendar invitation and offers `a` Accept, `t` Tentative or `d` Decline. The reply is a standard scheduling email to the organizer, retaining the meeting's UID, sequence and recurrence instance. This works with Gmail, Outlook/Teams and other providers that include a valid iCalendar request; named `invite.ics` attachments and common calendar MIME types are supported. Older cached calendar attachments are refreshed only when you explicitly inspect them.

Invitations show a distinct callout below the message's labels, with
a calendar icon and **I · Respond** cue. A blank line separates it from the
labels when the reader has room; very short panes omit that spacing. Once
that header scrolls away, the callout pins to the reader's top, so a long
message cannot hide the response
action. Click the callout or press `I`
to review a response; neither action sends a reply by itself.

Invitation review also supports Tab/Shift+Tab across Accept, Tentative, Decline
and Cancel, with Cancel focused initially. Enter submits only the deliberately
focused reply action. The account and organizer identities remain visible
before submission.

A copied Teams/Zoom join link alone has no organizer/attendee scheduling identity. Such mail can be read and opened with `o`, but Omagma cannot invent a valid RSVP. This needs no Calendar API permission, calendar view or calendar editing; sending a response requires the account's existing terminal RSVP/send grant.

File operations use a compact popup over the current draft or reader. `A` opens the attachment browser; `B` in the reader chooses received files and offers Save or Save & open. Arrows and the mouse wheel browse, clicking a row selects it, and the explicit Attach/Save button or Enter performs the action. Enter on a directory navigates into it. Tab/Shift+Tab move through the path, folder controls, file list and action buttons; Enter activates the focused control. Ctrl+F completes a literal path, Ctrl+U clears it, and Esc returns to the same draft or attachment picker. Printable `q`, `j` and `k` remain filename text. Ctrl+O goes to the parent folder, Ctrl+G goes Home, Ctrl+T toggles hidden files, and Ctrl+N/P browse entries; the buttons show these shortcuts. In the composer, Tab continues from Body to Add and then each attachment’s `[x]`; Shift+Tab goes backwards, and Enter activates Add or removes the focused file. `x` also removes the focused file, while Esc returns to Body. Multiple outgoing files are added with repeated `A`; the composer shows their combined size against its 2 MiB limit. Attachment sizes use rounded decimal kB/MB consistently, with bytes for very small files; the underlying byte limits are unchanged.

Save creates a new file. An existing filename produces an inline error and retains the entered path, so you can choose another name; no overwrite is implicit. Popup clicks stay inside the popup. Saving or attaching does not send mail.

List previews decode escaped punctuation such as `&#39;`. The reader can repair strong repeated patterns caused by UTF-8 text decoded as Windows-1252 in prose, while preserving literal URLs and technical/code examples. Stored mail and CLI body text retain their original normalized bytes; ambiguous text keeps its original display.

## Keys

| Key | Action |
| --- | --- |
| j/k, arrows, G | Move or scroll focused pane |
| Ctrl+D/U in the mail list | Scroll half a visible page of messages, using the current pane height |
| PageDown/PageUp in the mail list | Scroll a full visible page of messages |
| gg | First cached mail; expanded reader: start of body |
| h/l, Tab/Shift+Tab, Enter | Change pane or open selected item |
| 1/2/3 | Switch account |
| / / \ | Search cache / Gmail |
| v / z | Reader layout / expand |
| J/K | Reader: adjacent mail |
| {/}, t, Q/S | Reader: thread card, fold body, quotes/signature |
| c / r / R | Compose / reply / reply-all |
| f / F in mailbox | Forward |
| k / t / e in reply/forward chooser | Keep formatting / Text quote / Attach original (.eml; `e` is forward-only) |
| Ctrl+T in compose | Toggle note Markdown/Plain; retained original stays unchanged |
| p in normal compose | Outgoing preview / original context / plain alternative |
| Tab/Shift+Tab, Enter in normal compose | Focus fields/controls; edit a field or activate a control |
| Ctrl+S / :send in compose | Open outgoing send review |
| y in send review | Explicitly submit the reviewed draft |
| A in normal compose | Add outgoing attachment |
| L / B | Links / received-file picker |
| o | Open selected mail in Gmail |
| Space / Ctrl+A / Ctrl+Z | Select / select window / undo |
| x / D / U / s / u / m | Archive / Trash review / restore / star / unread / labels |
| a / I | Contacts / invitation reply |
| T / :theme | Preview and choose the TUI theme |
| Ctrl+R / Ctrl+L / ? / q | Refresh / colors / help / back or quit |

`q` backs out of readers, search, contacts, help and draft review before quitting the mailbox. It remains text in insertion and path fields. `?` shows the full, scrollable help for the current interface.

The mailbox footer exposes labels and themes alongside the main mail actions.
Normal compose shows `e` for `$EDITOR`; the original-message preview shows its
`L`/`B` link and attachment actions when space permits. Help also covers text
editing (`Ctrl+A/E` for line start/end), list navigation and review controls.
Shortcuts are scoped to their view: printable letters remain data during text
entry, and preview scrolling uses normal compose mode.

Reader layout, split proportions, theme, key remaps and per-account mailbox/selected-mail/reader position live in private `omagma/ui.json`; `--ui-file FILE` selects another preferences file. `:split right 60` or `:split below 40` chooses a 25–75% split; `:bind n down`, `:bind p up` and `:unbind n` remap mailbox keys without intercepting text entry or confirmation.

Press `T` on the mailbox screen, or enter `:theme`, to preview **Omagma**,
the built-in volcano-orange palette used in project screenshots, or **Follow
Omarchy**, the default. `j`/`k` previews the whole interface; Tab/Shift+Tab
chooses the list, Apply or Cancel, and Enter activates the focused choice.
Only Apply saves the choice; Escape/Cancel restores the saved theme. Follow
Omarchy adopts local theme changes automatically. Ctrl+L redraws and reloads
the chosen theme. Without an available Omarchy palette, it uses Omagma colors
and says so in the picker. `NO_COLOR` retains text and focus indicators, and a
theme choice remains available for later color sessions. This changes Omagma's
appearance only; desktop themes and terminal fonts stay with your terminal.

## Live permissions

Follow [full TUI/CLI permissions](SETUP.md#full-tuicli-permissions) for the Google project, People API and per-account consent. Fresh terminal-only setup uses one registration; alongside an existing read-only registration, use a different one for broader terminal access. The TUI and CLI share the terminal grant; an existing bar retains its read-only registration and credentials.

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
| Message body / draft source / each rendered alternative | 2 MiB |
| Outgoing attachments | 16 files, 2 MiB combined decoded bytes |
| Original email (.eml) source | 2 MiB; encoded draft must also fit the request limit |
| Incoming attachments | 32 per message |
| Outgoing recipients | 32 across To/Cc/Bcc |
| Local drafts / undo receipts | 128 / 16 per account |
| Cached contacts / operation journal | 1,024 / 1,000 per account |
| Serialized request | 3 MiB, including encoded attachment data |

Encoded bodies, retained originals and attachments must also fit the request
limit. Oversized or unavailable content fails explicitly before saving a
partial draft or sending mail. Old mail is evicted under cache pressure;
local drafts, their retained originals and operation receipts are preserved.
`cache.clear` removes cached mail without removing drafts, contacts or receipts.

Every send or RSVP has an operation identity and a recorded outcome: applied, rejected or unknown. Applied means provider acceptance, not delivery. An unknown receipt protects its recovery draft; inspect the provider before deciding what to do next. Local duplicate guards do not guarantee server-side idempotency.

Cache files and drafts contain plaintext protected by owner-only filesystem permissions, not encryption at rest. Keep private configuration, credentials, cache files and real-mail captures outside Git. See [cache behavior](TUI-CACHE.md), [agent CLI](AGENT-CLI.md) and [developer references](DEVELOPMENT.md) for the deeper contracts.

Omagma uses Ctrl for modified app commands. Letter shortcuts cover file navigation; `i` enters compose editing, `gg`/`G` navigate mail, and Ctrl+A/E move to the start/end of a text line. Home/End and arrow keys remain optional aliases. Ctrl+1/2/3 also switches accounts from the mailbox, matching the bar popup.
