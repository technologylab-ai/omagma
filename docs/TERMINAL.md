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
selection marks. Messages with known attachments show `📎` beside the subject.
A highlighted row identifies your selection without changing
its read status. The reader header shows read/starred state and readable label
names for that account, including custom labels.

In dialogs, Tab/Shift+Tab moves through fields, lists and action buttons;
Enter activates the focused button. Lists retain their selected row when you
move focus to an action. Send, Trash and invitation review start on Back or
Cancel, so an unprompted Enter does not submit a change. Keyboard focus has a
visible highlight, including the compose Alias, Add, attachment removal,
format and preview controls.

Ctrl+P on the mailbox screen, or `:actions`, opens a searchable action palette
for this account and view. Type an action name, use Ctrl+N/P or the result list
to choose it, and deliberately activate Run/Enter. Tab/Shift+Tab also reaches
the controls. Opening, filtering and Back do not perform an action.

## Software updates

The TUI checks for newer stable releases every 24 hours after mail work,
remembering the interval across restarts. **Upgrade available** appears on the
main mailbox screen with **Dismiss** and **How to update**; it stays hidden
while composing or using other views/dialogs. Dismiss remembers that release.
Use Ctrl+P **Updates** or `:updates` to reopen the guide, check again, or switch
automatic checking off. All controls support Tab/Shift+Tab, Enter and mouse.
The guide follows your actual Omarchy, Homebrew, source or manual installation.
See [updating Omagma](UPDATES.md) for the procedures and shared CLI commands.

## Reading HTML-only mail

The reader prefers a nonempty plain-text MIME alternative. For HTML-only mail, a native text view keeps headings, bold/italic emphasis, lists, quotes, preformatted blocks and simple tables. Colors use your chosen TUI palette. Narrow tables stack their cells; complex presentation tables flatten into reading order.

Scripts, remote images and other resources never run or load. Images show `[Image: caption]` using alt text or a title, or `[Image]` when neither is available; explicitly empty alt text hides decorative images. Links use the theme's cyan and underline, including HTTP(S) URLs in plain-text mail. Human-written link labels stay intact. Long visible URLs are shortened to their host/path and an ellipsis; `L` retains the complete destinations, including query parameters. These display changes leave stored mail and CLI bodies intact.

Paragraphs wrap at word boundaries. Hard newlines and indented/preformatted lines remain intact; overwide words split within the pane. The composer uses the same layout for its caret and text, keeping its editable content complete.

## Search

`/` searches this account's retained metadata and downloaded plaintext without fetching missing bodies. It supports quoted phrases, AND terms, negative terms, and `from:`, `to:`, `cc:`, `subject:`, `body:`, `label:`, `in:`, `filename:`, `is:unread|read|starred|important` and `has:attachment` predicates. `after:` (inclusive), `before:` (exclusive) and `on:` compare local calendar dates written as `YYYY-MM-DD` or `YYYY/MM/DD`; `newer:`/`older:` are absolute-date aliases. Unsupported named operators and invalid values produce a diagnostic. Use Gmail search for its full query language.

`\` explicitly searches Gmail using Google's query syntax. That can reach mail outside the cache and may take network time. `q` leaves search results and restores the original mailbox, selected message and reader position where still cached.

`:search-history` lists recent queries for this account, keeping Cache/Gmail
scope visible. `:save-search NAME` saves the current query and its scope;
`:saved-searches` reopens a named query. Deliberately choosing Open/Enter on an
entry runs that query with its retained scope; merely opening or filtering the
list does not search. History and named searches each keep at most eight
entries per account in private UI preferences. Saving an existing name replaces
that account's named entry with the current query and scope.

`:find TEXT` searches literal text in the focused message's displayed
subject/body and visible link labels, including the native HTML view. It
matches ASCII case-insensitively and other Unicode literally, including soft
wraps; folded quotes/signatures, other headers/messages and hidden URLs are
excluded. It highlights matches and keeps a
**Find 1/3** style counter visible. `n`/`N` visits the next/previous match;
Escape ends finding. This is separate from mailbox search and makes no server
request. The message needs a loaded body.

`:next-unread` and `:previous-unread` select adjacent unread cached mail in the
current mailbox, label or cache search, crossing cached windows as needed.
They keep mail unread, stay in this account and do not fetch older pages.
They are unavailable in explicit Gmail-search results; return to a cached view
first.

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

`a` opens the contact picker. A contact with several addresses offers an
explicit address choice. Ctrl+N/P and Enter choose account-local recipient
suggestions; insertion keeps the display name as `Name <address>` and quotes
commas or quotation marks correctly. Suggestions match retained From/To/Cc
metadata, including Sent mail, as well as saved contacts, so regular
correspondents need not be saved contacts. Matching stays local while one
bounded Sent-head metadata refresh runs in the background. Primary self and
duplicates are excluded.

Normal compose `f`, `:sender` or the From control opens a chooser of verified
identities rather than cycling blindly. Choose a row and Use, or Back to keep
the current sender. Account `senderName` and plaintext `signature` settings
remain in effect; changing From does not change the account's grant.

Ctrl+Z/Ctrl+Y undo/redo native text edits with their caret positions. Undo in
compose does not undo mailbox changes. Each paste and `$EDITOR` return is grouped
into one Undo step within the bounded history. The text history stays in memory
and is not recovered after restart; it does not rewrite the protected
original or provide an attachment/sender undo stack.

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

`:preview-browser` saves the current draft and explicitly opens its outgoing
HTML in the account's Chrome profile. The private preview keeps tables, styles
and verified inline raster images inside an isolated sandbox. Scripts, forms,
remote fetches and source navigation are blocked; remote pictures remain
absent. This does not send or upload a Gmail draft. One private preview file per
account is replaced on reuse and removed by local draft discard.

`e` edits the body with `$EDITOR`, then `$VISUAL`, then available nvim/vi/nano. In a Keep formatting draft, the editor receives only your note; the retained original and embedded images remain read-only. Fixed quoted arguments are passed directly without a shell. It temporarily takes over the terminal and restores the TUI afterward. `--editor-mode auto|takeover` uses this behavior; `embedded` is unsupported. No tmux is required. Saving the editor, pasting or autosaving never sends mail.

Escape/`q` saves and leaves normal compose. Ctrl+S or `:send` opens review;
explicit `y` or Enter on the deliberately focused **Send** button starts the
local send countdown.
Review starts with **Back** focused. It shows the account, selected From alias,
recipients, subject, format, rendered outgoing body, threading and attachments.
Review the outgoing preview and plain alternative before confirming. Saving,
switching format or preview, and pressing Enter on composer controls never submit mail.
Review warns when your newly authored note promises an attachment but no files
are attached. Back returns to add files; the warning does not submit mail or
invent missing files. Quoted history, fenced code and standard signatures do
not trigger this advisory.

The default cancellation period is ten seconds. `:send-grace 0..30` changes it;
zero deliberately selects immediate submission after review. While **Sending
in … · nothing sent yet** is visible, Ctrl+Z, Enter, Escape/`q` or clicking the
Undo control cancels and returns to the editable draft. Normal close cancels
an unsent countdown. Once submission starts there is no send recall or Undo.

After an interrupted process, a pending send remains paused. Reopen its local
draft and use `:resume-send` to start a fresh countdown or `:cancel-send` to
keep it unsent. Queue status is checked before allowing changes. Submitting
or unknown outcomes stay protected; restarting never automatically sends or
retries them. Use `:receipt` and inspect Sent mail when the outcome is uncertain.

## Attachments and links

`A` or **Add A** opens the outgoing file browser. In the Listing, Space or a
checkbox click marks files; marks remain when you visit another folder. Attach
imports the complete selected set, or the focused file if none is marked.
Space in Path remains filename text. Tab/Shift+Tab reaches the controls and
Enter activates them; Ctrl+O goes to the parent folder, Ctrl+G to Home and
Ctrl+T toggles hidden files. Oversized sets are refused before partially
attaching them so you can correct the choice.

`:detach NUMBER` or its **[x]** removes a file. The list shows selected count,
individual sizes and the combined 25 MiB budget. Up to 16 ordinary files remain
attached through saving, restart and editor return. Selected content is copied
to private account storage; later changes to the original path do not silently
change the saved attachment. The outgoing MIME must also fit 35 MiB. Oversized
content gets an explicit error; no file is silently truncated.

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

Received saves stream supported attachment content to a new private file,
including files too large for a JSON/base64 response. Direct saves refuse an
existing destination. `:save-all DIRECTORY` saves all files of the focused
message into an existing absolute directory. `:save-all` without a directory
opens the folder/file chooser, where Space selects which files to save. Batch
collisions get fresh names. A batch stops at the first failure and reports the
saved count and failed file; successful saves remain in place. Fix the cause
and explicitly choose the remaining files to retry. Failed saves are never
retried automatically. Saving files never sends mail.

`L` opens the link chooser; Enter opens the selected literal HTTP(S) destination in this account's Chrome profile. `o` opens the selected mail in Gmail; with a thread message focused, it opens that exact message. In normal reply/forward mode it opens the original context. Each action uses the current account's configured Chrome profile. Rendering mail never launches anything automatically.

## Labels, bulk actions and contacts

The sidebar includes Inbox, Sent, local Drafts, Archive, Trash, Spam, All Mail,
Unread and cached custom labels. Clicking a **label name** shows mail carrying
that label. To leave the label view, click **Inbox** or another mailbox; this
changes your view without removing labels from any messages. The sidebar shows
the portion of the custom-label collection that fits its height.

`m` opens the staged label checklist for the focused message or selected group.
`[x]` means present on all targets, `[-]` mixed membership and `[ ]` absent.
Space or Enter on a row toggles a planned change; `+`/`-` stages Add/Remove.
A `*` marks a change, and filtering keeps hidden staged choices. Apply or
Ctrl+S commits the changes; Cancel writes nothing. Tab/Shift+Tab reaches Filter,
List, Add, Remove, counted Apply and Cancel, including compact screens.
The account and target count stay visible, and editing is disabled while the
initial membership snapshot loads. System labels stay with mailbox/read/star
controls rather than this custom-label checklist.

Click the **LABELS heading**, or use `:labels`, to open **Manage labels**, for the
account's label collection. Use `n` New, `r` Rename, `c` Color, `d` Delete or `o` Open;
Tab/Shift+Tab and Enter reach the same buttons, and `/` filters the collection.
Create a label, rename one or review its deletion; these operations
are separate from assigning labels to mail. Deleting a label removes that label
from messages while keeping the emails themselves. System labels cannot be
created, renamed or deleted through this manager. Label collection changes use
the terminal account's existing `mail-modify` capability. Delete review starts
on Cancel and names the account and label. `y` or Enter on the deliberately
focused Delete button confirms; `d` does not confirm. Ctrl+R refreshes definitions
or checks the recorded receipt when an operation's outcome is uncertain.

Color opens a Back-first list of named Gmail-compatible colors with their
exact hex values and current marker. Save color deliberately updates that
definition; ordinary membership stays unchanged. Color choices require the
same `mail-modify` capability and remain separate from assigning labels.

Space selects mail, Ctrl+A selects the window, and actions apply to that set or
the focused message. Escape/`q` clears a selection first; Ctrl+Z or `:undo`
reverses the last completed account action. Changing mailbox/search context
clears its previous selection.
Bulk actions can have partial outcomes; uncertain items are not replayed.
`:scope message` selects the normal single-message scope. `:scope thread`
deliberately resolves the complete conversation before its review; targets
are pinned to this account and capped at 100, with incomplete or oversized
resolution refused. The review states the actual count, and later arrivals or
selection changes do not retarget it. An explicit Space selection takes
precedence and applies only to those selected messages.
`D` opens Trash review, initially focused on Cancel; `y` or Enter on the
deliberately focused Confirm button submits the change.

`:spam` and `:unspam` expose the same mailbox actions in the TUI; `unspam`
removes Spam and restores Inbox membership. They honor the current explicit
scope and return per-message outcomes with mailbox undo. The CLI/API batch
interface shares these actions. See
[batch commands](AGENT-CLI.md#commands).

`a` opens this account's address book. Search with `/`, create with `n`, edit
with `e`, and save with Ctrl+S. The editor keeps all supported addresses rather
than replacing a contact with its first one; name-only edits preserve the
address array and provider metadata. `:add-contact` opens editable name/address
fields prefilled from the focused sender; only Save writes a contact. Contacts
require the existing People API permission and retain etag conflict checks.
Contact deletion is not implemented.

`:discard-draft` deliberately reviews removal of the current local draft and
its recovery/preview copies. Cancel is the safe default. It does not delete a
Gmail draft or message, and pending/unknown submissions remain protected.

`I` inspects the focused calendar invitation and offers `a` Accept, `t` Tentative or `d` Decline. The reply is a standard scheduling email to the organizer, retaining the meeting's UID, sequence and recurrence instance. This works with Gmail, Outlook/Teams and other providers that include a valid iCalendar request; named `invite.ics` attachments and common calendar MIME types are supported. Older cached calendar attachments are refreshed only when you explicitly inspect them.

Invitations show a distinct callout below the message's labels, with
a calendar icon and **I · Respond** cue. A blank line separates it from the
labels when the reader has room; very short panes omit that spacing. Once
that header scrolls away, the callout pins to the reader's top, so a long
message cannot hide the response
action. Click the callout or press `I`
to review a response; neither action sends a reply by itself.

The card shows the meeting title and friendly start/duration where available.
Invitation review keeps account, attendee and organizer identities visible,
with local start/end, duration, location and stated response. UTC and supported
TZID times use local zoneinfo; embedded, custom or unavailable timezone data
keeps its stated wall time and label. All-day end dates are explicitly
exclusive, and ambiguous/nonexistent local times stay labeled.

Tab/Shift+Tab reaches Cancel, Accept, Tentative, Decline, Details and Join;
Cancel starts focused. `v`/Details toggles UID, sequence and recurrence details.
`o`/Join explicitly opens a safe HTTP(S) meeting URL in the inspected account's
Chrome profile. Enter submits only a deliberately focused reply action.

A copied Teams/Zoom join link alone has no organizer/attendee scheduling identity. Such mail can be read and opened with `o`, but Omagma cannot invent a valid RSVP. This needs no Calendar API permission, calendar view or calendar editing; sending a response requires the account's existing terminal RSVP/send grant.

File popups keep the current draft or reader underneath. Printable `q`, `j`,
`k` and Space remain filename text while Path has focus; the Listing has its
own selection controls. In the composer, Tab continues from Body to Add and
each file's `[x]`; Enter activates Add/removal, `x` removes the focused file,
and Esc returns to Body. Sizes use decimal kB/MB in the display; the byte limits
below use MiB. [Attachment controls](#attachments-and-links).

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
| Ctrl+P in mailbox / :actions | Discover account/view actions |
| :updates / Ctrl+P Updates | Release status, upgrade guide and daily/manual checks |
| :find TEXT, n/N, Escape | Current-message find, next/previous match, done |
| :next-unread / :previous-unread | Adjacent unread cached mail in the current view |
| :search-history / :saved-searches / :save-search NAME | Reuse or save account-specific queries |
| v / z | Reader layout / expand |
| J/K | Reader: adjacent mail |
| {/}, t, Q/S | Reader: thread card, fold body, quotes/signature |
| c / r / R | Compose / reply / reply-all |
| f / F in mailbox | Forward |
| k / t / e in reply/forward chooser | Keep formatting / Text quote / Attach original (.eml; `e` is forward-only) |
| Ctrl+T in compose | Toggle note Markdown/Plain; retained original stays unchanged |
| Ctrl+Z / Ctrl+Y in compose | Native text undo / redo |
| f / :sender in compose | Verified From chooser |
| p in normal compose | Outgoing preview / original context / plain alternative |
| :preview-browser in compose | Save and explicitly open the sandboxed outgoing browser preview |
| Tab/Shift+Tab, Enter in normal compose | Focus fields/controls; edit a field or activate a control |
| Ctrl+S / :send in compose | Open outgoing send review |
| y in send review | Confirm the reviewed draft and start the local send countdown |
| :send-grace 0..30 | Cancellation period in seconds; default 10, explicit 0 means immediate |
| Ctrl+Z / Enter / Undo during countdown | Cancel before submission and return to editing |
| :resume-send / :cancel-send | Explicitly handle a recovered paused send |
| A in normal compose | Add outgoing attachment |
| L / B | Links / received-file picker |
| o | Open selected mail in Gmail |
| Space / Ctrl+A / Ctrl+Z | Select / select window / undo |
| x / D / U / s / u / m | Archive / Trash review / restore / star / unread / labels |
| Space / +/- / Ctrl+S in labels | Toggle/stage membership / Apply; Cancel writes nothing |
| c in Manage labels | Choose a custom label color |
| :scope message\|thread | Choose single-message or reviewed conversation targets |
| :spam / :unspam | Shared Spam / Not spam actions |
| :add-contact / :discard-draft | Prefill sender contact / review local draft removal |
| :save-all DIRECTORY | Save focused-message files to a new private destination set |
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

Reader layout, split proportions, theme, key remaps, search history/named
searches, send grace and per-account mailbox/selected-mail/reader position live
in private `omagma/ui.json`; `--ui-file FILE` chooses another file.
`:split right 60` or `:split below 40` chooses a 25–75% split;
`:bind w down`, `:bind p up` and `:unbind w` remap mailbox keys without
intercepting text entry or confirmation. Ctrl+B is reserved for terminal/tmux
prefixes and cannot be rebound by Omagma.

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
| Ordinary outgoing attachments | 16 files, 25 MiB combined decoded bytes |
| Retained original inline resources | 32 resources, 2 MiB combined decoded bytes, separate from ordinary files |
| Original email (.eml) source | 2 MiB; encoded draft must also fit the request limit |
| Parsed incoming file/resource descriptors | 49 per message, within 128 MIME parts; streamed file content up to 50 MiB each; cached blobs also obey the account disk quota |
| Outgoing recipients | 32 across To/Cc/Bcc |
| Local drafts / undo receipts | 128 / 16 per account |
| Cached contacts / operation journal | 1,024 / 1,000 per account |
| Addresses per contact | 32; preserved through supported edits |
| Serialized JSON request | 3 MiB; larger ordinary file bytes use account handles |
| Complete outgoing MIME | 35 MiB, including body, resources and encoded ordinary files |
| Find query / matches / scanned display text | 256 bytes / 256 / 2 MiB; a + marks a capped count |
| Search history / named searches | 8 each per account; 4,096-byte queries and 96-byte names |
| Browser preview / UI preferences | One preview per account, at most 16 MiB / at most 256 KiB private preferences |
| Queued send intents | 32 active, 128 retained records per account; delay 0–30 seconds |

Large inline photos remain unloaded while reading: the reader shows image
placeholders, and received-file controls can save their content within the
50 MiB incoming limit. Keeping original formatting still has a separate
2 MiB combined embedded-resource limit. The reply/forward chooser checks that
before downloading images, disables unavailable choices and explains when to
use Text quote. A known oversized original email also disables its `.eml`
choice; the backend rechecks the fresh source when creating the draft.

Inline JSON body/resource data must fit the request limit. Ordinary file
handles avoid embedding large file bytes in that frame; the final encoded MIME
still has its separate cap. Oversized or unavailable content fails before saving a
partial draft or sending mail. Old mail is evicted under cache pressure;
local drafts, their retained originals and operation receipts are preserved.
`cache.clear` removes cached mail without removing drafts, contacts or receipts.

Every send or RSVP has an operation identity and a recorded outcome: applied, rejected or unknown. Applied means provider acceptance, not delivery. An unknown receipt protects its recovery draft; inspect the provider before deciding what to do next. Local duplicate guards do not guarantee server-side idempotency.

Cache files and drafts contain plaintext protected by owner-only filesystem permissions, not encryption at rest. Keep private configuration, credentials, cache files and real-mail captures outside Git. See [cache behavior](TUI-CACHE.md), [agent CLI](AGENT-CLI.md) and [developer references](DEVELOPMENT.md) for the deeper contracts.

Omagma uses Ctrl for modified app commands and reserves Ctrl+B. Letter
alternatives, Tab/Shift+Tab and Enter keep flows usable without Home, End,
Insert or Alt. `i` enters editing, `gg`/`G` navigate mail, and Ctrl+A/E move to
line start/end. Arrow and Home/End keys remain optional aliases; Ctrl+1/2/3
switches accounts from the mailbox, matching the bar popup.
