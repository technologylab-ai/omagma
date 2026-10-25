# Terminal mail

**Experimental:** Omagma's TUI and agent CLI are under active development. This guide describes the current application. See the tiered [feature catalogue](FEATURES.md) and [installation](INSTALL.md).

The TUI and CLI run natively on Linux and macOS; only the Linux Omarchy bar needs Quickshell. The terminal needs a UTF-8 terminal, Chrome and your private account configuration. System credentials use unlocked Secret Service with `secret-tool` on Linux or the default user Keychain on Mac. Mac setup offers Interactive (Keychain) and Agent-enabled (private credential files), with the same TUI and CLI in both modes. A release binary needs no Zig compiler. [Mac installation](MACOS.md) covers the choice, Homebrew and native bundles.

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

Enter opens the conversation. Long conversations use 20-message windows with selected bodies loaded on demand. With the reader focused, `[`/`]` (or `:thread-older` / `:thread-newer`) loads an older/newer window; counts distinguish bodies still to load from messages outside the window. `{`/`}` selects and opens a message, and keeps reply and file actions attached to its message ID. Cached windows are explicitly incomplete.

`h`/`l` or Tab changes pane, `v` moves the reader beside or below the list, and `z` expands it. With the reader focused, `J`/`K` moves to adjacent mail across windows while lowercase `j`/`k` scrolls the body. `{`/`}` chooses a thread message, `t` or a click folds its body, and `Q`/`S` folds quoted history/a standard signature. The header stays compact in short panes and shows reading position. These controls do not change stored mail.

Mouse support is enabled by default. Click accounts, mailboxes, messages and contacts; the wheel scrolls the pane under the pointer. Loading placeholders and gaps cannot select unfinished mail. Drag across the received message body to select text, then press `y` or choose **Copy**. Your terminal's selection modifier, or `--no-mouse`, also retains ordinary terminal text selection.

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
format, inline preview, **Preview in browser** and **Continue in Gmail** controls.

Ctrl+P on the mailbox screen, or `:actions`, opens a searchable action palette
for this account and view. Type an action name, use Ctrl+N/P or the result list
to choose it, and deliberately activate Run/Enter. Tab/Shift+Tab also reaches
the controls. Opening, filtering and Back do not perform an action.

## Copying received mail

Focus the reader with `l` or Tab, then press `V` to enter **MOVE** with a text
cursor. Use `h`/`j`/`k`/`l`, arrows, `w`/`b`/`e`, `0`/`$` and `gg`/`G` to
reach your starting point. Press `V` or Space to mark it and enter **CHAR**;
move to the end and press `y` to copy. The earlier text stays out of the selection.

While selecting, `V` switches **CHAR** / **LINE**, with the current mode and
the next action shown in the hints. Space unmarks and returns to **MOVE** at
the same caret, so you can choose another starting point. Escape exits text mode.
For example, after reaching a paragraph's first character, `Space`, `$`, `y`
copies that paragraph without the preceding mail. **Select**, **Copy** and
**Cancel** also support Tab and Enter.
`o` swaps the two selection ends; Ctrl+D/U moves the caret half a page.
The selected text is highlighted. Mouse dragging uses the same explicit
`y`/Copy action; Tab and Enter can also reach the Copy and Cancel controls.
Highlighting follows the active theme's selection and text colors, with its
accent marking the caret. Monochrome mode uses reverse video.

Selection copies the displayed message body, with wrapped lines rejoined,
without pane borders, padding or action hints. Folded text stays excluded;
unfold quotes or signatures first if you want to select them. To copy the
whole focused message with its envelope, use `:copy-message` or the
**Copy message** action in Ctrl+P. This includes the decoded body and complete URLs.

`e` or `:view-editor` opens the focused received message in `$EDITOR`, then
`$VISUAL`, then an available nvim/vi/nano. The editor receives a private
temporary `message.txt` with its envelope and decoded body. You can select,
copy or save a separate file there. Closing the editor returns to the TUI
and removes the temporary snapshot; changes never update the received mail
or create a draft. In the composer, `e` continues to edit the draft body.

Copying uses the terminal clipboard protocol (OSC 52), including over SSH.
The terminal must allow clipboard writes; Omagma does not read the clipboard.
Received-message editor viewing works independently of clipboard support.

## Software updates

The TUI checks for newer stable releases every 24 hours after mail work,
remembering the interval across restarts. **Upgrade available** appears on the
main mailbox screen with **Dismiss** and **How to update**; it stays hidden
while composing or using other views/dialogs. Dismiss remembers that release.
Use Ctrl+P **Updates** or `:updates` to reopen the guide, check again, or switch
automatic checking off. All controls support Tab/Shift+Tab, Enter and mouse.
The guide follows your actual Omarchy, Homebrew, source or manual installation.
See [updating Omagma](UPDATES.md) for the procedures and shared CLI commands.

## Received message views

The reader initially prefers a nonempty plain-text MIME alternative. Press `p` in the reader to switch between **Plain** and **Formatted** for that message, including messages with a weak plain alternative. `:received plain`, `:received formatted` and `:received auto` select the mode explicitly. The choice follows that message through an in-session refresh or thread-window change; the last 32 explicit message choices are remembered in that session. For HTML-only mail, a native text view keeps headings, bold/italic emphasis, lists, quotes, preformatted blocks and simple tables. Colors use your chosen TUI palette. Narrow tables stack their cells; complex presentation tables flatten into reading order.

Scripts, remote images and other resources never run or load. Images show `[Image: caption]` using alt text or a title, or `[Image]` when neither is available; explicitly empty alt text hides decorative images. Links use the theme's cyan and underline, including HTTP(S) URLs in plain-text mail. Human-written link labels stay intact. Long visible URLs are shortened to their host/path and an ellipsis; `L` retains the complete destinations, including query parameters. These display changes leave stored mail and CLI bodies intact.

`:density compact` gives one-line mail rows and smaller reader headers; `:density comfortable` restores the spaced layout. The preference survives restart. `H` expands the current message’s sender, recipients, date, read state and labels.

Paragraphs wrap at word boundaries. Hard newlines and indented/preformatted lines remain intact; overwide words split within the pane. The composer uses the same layout for its caret and text, keeping its editable content complete.

## Search

`/` searches this account's retained metadata and downloaded plaintext without fetching missing bodies. It supports quoted phrases, AND terms, negative terms, and `from:`, `to:`, `cc:`, `subject:`, `body:`, `label:`, `in:`, `filename:`, `is:unread|read|starred|important`, `has:attachment` and `status:partial` predicates. `status:partial` finds decode warnings, unavailable bodies and incomplete metadata; use All Mail or the retained-cache view to include rows whose labels could not be verified. `after:` (inclusive), `before:` (exclusive) and `on:` compare local calendar dates written as `YYYY-MM-DD` or `YYYY/MM/DD`; `newer:`/`older:` are absolute-date aliases. Unsupported named operators and invalid values produce a diagnostic. Use Gmail search for its full query language.

`\` explicitly searches Gmail using Google's query syntax. While entering a mail search, **Ctrl+G** switches between Cache and Gmail and keeps the query; **Enter** runs it in the selected scope. That can reach mail outside the cache and may take network time. `q` leaves search results and restores the original mailbox, selected message and reader position where still cached.

`:search-history` lists recent queries for this account, keeping Cache/Gmail
scope visible. `:save-search NAME` saves the current query and its scope;
`:saved-searches` reopens a named query. Deliberately choosing Open/Enter on an
entry runs that query with its retained scope; merely opening or filtering the
list does not search. History and named searches each keep at most eight
entries per account in private UI preferences. Saving an existing name replaces
that account's named entry with the current query and scope.

`:find TEXT` searches literal text in the focused message's displayed
subject/body and visible link labels, including the native HTML view. It
uses Unicode case folding (for example, `Straße` matches `STRASSE`), including
soft wraps; folded quotes/signatures, other headers/messages and hidden URLs are
excluded. It highlights matches and keeps a
**Find 1/3** style counter visible. `n`/`N` visits the next/previous match;
Escape ends finding. This is separate from mailbox search and makes no server
request. The message needs a loaded body. Case folding preserves the original
text and highlight boundaries; accents are not removed. Cached mailbox search
uses the same Unicode matching.

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
returns to reading. Replies and reply-all to mail without HTML open directly
with a text quote. Forwarding mail without HTML offers **Text quote** or
**Attach original (.eml)**, with Text quote selected initially.

In **Keep formatting**, only your note is editable. Its usual Markdown
rendering and Omagma footer appear above a read-only original. Switching your
note to Plain leaves the original HTML intact. The draft owns that original
and its embedded image data, so they survive saving, restarting and eviction
of the source mail from the cache. Received regular attachments accompany
Keep formatting and Text quote forwards.

A formatted reply has an **Original included / omitted** row. **Q Reply without
original** omits the retained original and its embedded resources from outgoing
HTML, plain text, browser preview and Gmail handoff. **Q Include original**
restores them exactly; the saved draft keeps the complete source and resources
through autosave and restart. Ctrl+Z immediately undoes that policy change and
Ctrl+Y reapplies it. The note and ordinary attachments are unchanged. This
choice applies to replies; forwards keep their original. Pending or uncertain
sends, queued drafts and drafts paused in Gmail cannot change this choice.

**z Fold / Expand** changes only the terminal preview. Long originals start
folded, with an excerpt and an explicit reminder that the full content is kept.
Long trailing `>` text quotations can also be folded in the preview; they remain
part of the editable body and outgoing message. Review supports the same view
control. On narrow screens, z opens the full preview so the change is visible.
Folding never changes sent bytes or hides content in the browser preview. Q and z remain literal text in INSERT mode; click or Tab/Enter
activates their visible controls.

The native composer shows the saved revision's MIME size. Review displays exact
bytes, the provider limit, and the size without the original when available.
Editing invalidates the count until autosave and measurement finish. The measured
content is checked again before sending; another process changing the saved
draft requires a new review. A cancelled or rejected send also requires a fresh
review and operation identity. Incomplete addresses can make exact size unavailable.
If a rendered alternative already exceeds the provider limit, review reports
that proven overflow without claiming an exact byte count; the complete source
stays saved. Near-limit and over-limit drafts
remain saved; Send is unavailable until the complete message fits. Use Back to
revise the note, remove ordinary files, or explicitly omit a reply's original.
Back returns to normal controls, so Q can select that explicit reduction.
No text or images are removed automatically.

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

Changes save locally after a pause, including unfinished addresses. An unfinished recovery draft must be corrected before review and sending. Drafts appear under **Drafts** and survive restart; they are local Omagma drafts, not Gmail's web draft folder. The list loads compact pages; j/k crosses page boundaries, Next/Previous moves between pages, and gg returns to the first page. Opening a draft loads its complete recipients, files and source.

If another Omagma process sends the saved draft while this composer has newer
edits, those edits are saved as a new local draft. The sent source stays intact,
and sending the recovered draft requires a fresh review. Uncertain submissions,
queued sends and drafts owned by Gmail remain protected.

When a size check or send review detects changes saved by another process,
autosave pauses for this view. `:resolve-draft` offers **Save local copy** and
**Reload saved draft**. Reload refuses unsaved local edits; saving a copy keeps
the complete local text, original and files under a new ID without changing the
other draft. Exiting with unresolved local edits preserves an independent copy.

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

The composer’s **Preview in browser** button (`P` in normal mode, or
`:preview-browser`) saves the current draft and explicitly opens its outgoing
HTML in the account's Chrome profile. The private preview keeps tables, styles
and verified inline raster images inside an isolated sandbox. Scripts, forms,
remote fetches and source navigation are blocked; remote pictures remain
absent. This does not send or upload a Gmail draft. One private preview file per
account is replaced on reuse and removed by local draft discard. Unfinished
recipient fields are saved for recovery and do not prevent previewing the body.
For a protected send or a draft paused in Gmail, preview opens the saved local
copy without changing it; Gmail may have newer edits.

The browser and Gmail buttons stay below the composer in both split and narrow
views, including the full inline preview. Tab/Shift+Tab reaches each available
button and Enter activates it. In INSERT, `P` and `g` remain literal text; the
buttons omit those shortcut letters until normal mode returns. Lowercase `p`
continues to switch the inline preview.

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
zero deliberately selects immediate submission after review. During the
countdown, **Undo** and **Send now** are visible together. Ctrl+Z or
Escape/`q` cancels and returns to the editable draft; Ctrl+S sends the reviewed
message immediately without changing the default delay for future messages.
Tab/Shift+Tab switches buttons and Enter activates the focused button; Undo is
focused initially. Both buttons are clickable and remain in place as the timer
ticks, including in narrow terminals. Pasted text cannot activate either action.
Normal close cancels an unsent countdown. Once submission starts there is no
send recall or Undo; the draft stays protected if its outcome is uncertain.

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
individual sizes and the 25 MiB decoded budget shared with included original
images. Native file sets use the shared 1,040-part budget (ordinary files plus
included original resources); the browser supports 16 ordinary files. Files
remain attached through saving, restart and editor return. Selected content is copied
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

## Invitation replies

`I` inspects the focused calendar invitation and offers `a` Accept, `t` Tentative or `d` Decline. The reply is a standard scheduling email to the organizer, retaining the meeting's UID, sequence and recurrence instance. This works with Gmail, Outlook/Teams and other providers that include a valid iCalendar request; named `invite.ics` attachments and common calendar MIME types are supported. Older cached calendar attachments are refreshed only when you explicitly inspect them.

**Accept** and **Tentative** also save supported
invitations and your response to the same account's primary calendar when
Calendar write access is enabled. The RSVP review shows this before confirmation.
An existing event is matched by its invitation identity to avoid duplicates.
Mail and Calendar outcomes are shown separately: a Calendar failure never
resends your RSVP. **C · Check status** checks an uncertain Calendar result or retries a temporary
Calendar failure without resending the RSVP.
Without Calendar access, RSVP email continues to work as before. Unsupported
recurring changes or ambiguous times remain explicit rather than guessed.

## Calendar

The native Calendar view requires optional per-account Calendar access.
Press `C`, choose Calendar in the sidebar, or use the
action palette. `1`/`2`/`3` switch Agenda/Day/Week; `g` chooses which calendars to
show, including read-only holiday calendars. Space toggles a source, `a` switches
between the current account and all configured accounts, and Enter applies the
selection. Esc cancels pending changes; `o` shows only the focused calendar and
`c` changes its theme color. Source letters and names remain visible without
color. The selection persists across restarts. `h`/`l` move the date range,
`Ctrl+G` jumps to a date, and `t` returns to today. `j`/`k`
select an event and Enter opens its details. `/` searches only the loaded date
range. Buttons also support Tab/Shift+Tab, Enter and mouse clicks. Narrow
terminals use a compact presentation, with all-day dates kept separate from
timed appointments. `?` opens the same searchable help presentation as Mail:
`/` finds keys, actions and sections; `n`/`N` visits matches. Esc clears a search
first, then returns to the Calendar page you opened it from. The Back control
also supports mouse, Tab and Enter.

In Week, extra height reveals up to four event titles per hour. `+N` lists the
other events in that exact hour; **Space · Show all** lists events sharing the
selected event's visible rows. The chooser shows exact dates, time zones,
calendar and account; Enter selects and reveals, then ordinary Enter opens the
chosen event. Esc returns to the same context. The optional `g`, then `p`
Priority calendar influences the display order after non-declined events and
starts in the current hour. Source letters and `*` remain readable without
colour. A deliberate reveal pins only its chosen hour or all-day date, so a long
routine cannot hide new starts in other hours.

### Create and edit meetings

Press `n` to create a timed or all-day event, or `e` to edit the selected event.
The editor names the destination account/calendar and time zone. Its all-day
last date is inclusive; the provider's exclusive end is handled automatically.
Choose Google Meet to generate a video link, or paste an HTTPS link from another
meeting service. Added guests receive invitations only after the explicit
review and confirmation; changes to existing guests require a notification
choice. `Ctrl+S` opens the review, and `y` confirms after its complete contents
have been read. Recurring edits affect the selected occurrence. Skipped DST
times are refused; repeated times offer an explicit first/second occurrence.
See [creating and editing events](CALENDAR-EVENTS.md) for permissions,
supported edits and recovery after an uncertain save.

`O` opens Google Calendar and `b` opens the selected event in its owning
account's configured Chrome profile. Opening an event uses Google's returned
event link and fixes the account selector; it does not guess an event ID from
an invitation.

### Join meetings in the right Chrome profile

Events with a usable meeting link have a camera marker. Press **o** on the
selected event, or use **Join** in its event card, to open the meeting in that
account's configured Chrome profile. The card keeps the event title, time and
actions visible while long descriptions scroll. Local times, date-only events
and any differing event timezone are labeled explicitly. An event opened here
already belongs to the displayed calendar; **A** is the invitation action in Mail.

## Meeting reminders

While the native TUI is open, meeting reminders appear ten minutes before a
timed event in a readable primary or selected calendar. You can stay in Mail;
opening Calendar first is not required. The card shows minutes until the start,
then minutes remaining during the event, and disappears when the event ends.
All-day, declined and cancelled events do not raise reminders.

The reminder leaves your typing focus alone. Click its controls, or press **M**
(**Shift+m**, Meeting actions) to focus the card: **Ctrl+D** dismisses it, **o** joins an online meeting in that event
account's configured Chrome profile, and **n** moves to another due reminder.
Tab/Shift+Tab and Enter also operate its controls; Esc or M returns to your work.
In compose, search and other text fields, `M` remains text. Plain `d` does not
dismiss the reminder. Without card focus, Ctrl+D keeps its
normal scrolling behavior. Cards appear on the main Mail and Calendar screens;
composing, external editors, event details and modal dialogs keep their own screen and input.
After returning to Mail or Calendar, a still-due reminder shows its current time.
Join appears only for a usable meeting link. Dismissal lasts for that occurrence
in the current TUI session, including subsequent calendar refreshes. Reminders
run only while the TUI is open and use the existing Calendar read permission.

## Invitations in Mail

From an invitation, `A` opens a review for adding the event to the selected
calendar, or applying a supported newer update/cancellation. Review the account,
calendar and times before confirming. The saved review fixes the exact action;
it never sends an RSVP email. If the connection fails after dispatch, the outcome
remains unknown. **r · Check Calendar** checks the recorded action without
applying it again, including after restart. Do not resubmit the event to resolve
an unknown result.

Calendar access requires optional Google permissions. The missing-permission
screen can copy an authorization command retaining existing capabilities; it
does not start consent automatically. See [Calendar permissions and account
setup](CALENDAR-PERMISSIONS.md) for scope choices and Google Console steps.
Retained offline views show their stale state and cannot establish availability
or authorize a calendar change. Event details show the display timezone and
original invitation timezone; ambiguous floating times require an explicit
decision.

Invitations show a themed event card below the message's labels, with a bold
title, accent-colored time and **I · Respond** cue. A roomy reader uses a quiet
border and three content rows; smaller panes retain a compact one-to-three-row
summary so the message body stays readable. Invitations with a detected, usable
meeting link show the ** video-call icon**, matching Calendar; cancelled meetings
do not. The same marker appears in invitation review, where `o` joins in the
invitation account's Chrome profile. A blank line separates the card from the
labels when the reader has room; very short panes omit that spacing. Once
that header scrolls away, the callout pins to the reader's top, so a long
message cannot hide the response
action. Click the callout or press `I`
to review a response; neither action sends a reply by itself.

The card shows the meeting title and friendly start/duration where available.
Invitation review uses the same card styling as Calendar, sizing itself to the
content. The title and time, account, attendee, organizer and separate RSVP and
Calendar outcomes stay visible while longer details scroll. Join is prominent
near the title; response controls remain at the bottom. Local start/end,
duration, location and stated response remain available. UTC and supported
TZID times use local zoneinfo. An embedded/custom timezone converts only when its rules agree with a known zone for the event; unresolved rules keep their stated wall time and label. All-day end dates are explicitly
exclusive, and ambiguous/nonexistent local times stay labeled.

Cancellation, publication and RSVP notices also open
in the invitation drawer, with response controls disabled. Cancelled events do
not offer Join. Inspection uses retained verified aliases and cached invitation
data without a provider call when available. A response confirmed by Omagma is
shown only for the exact invitation source it answered; an uncertain response
remains protected across restart. **C · Check Sent** looks for the exact recorded
RSVP in Sent without sending again. Only a matching sent response confirms it;
a missing result leaves the outcome unknown.

Tab/Shift+Tab reaches Cancel, Accept, Tentative, Decline, Details and Join;
Cancel starts focused. `v`/Details toggles UID, sequence and recurrence details.
`o`/Join explicitly opens a safe HTTP(S) meeting URL in the inspected account's
Chrome profile. Enter submits only a deliberately focused reply action.

A copied Teams/Zoom join link alone has no organizer/attendee scheduling identity. Such mail can be read and opened with `o`, but Omagma cannot invent a valid RSVP. This needs no Calendar API permission, calendar view or calendar editing; sending a response requires the account's existing terminal RSVP/send grant.

## File dialogs

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
| V in the reader | Move a text cursor to your chosen starting point |
| V / Space in MOVE | Start character selection at the caret |
| V / Space while selecting | Switch character/line mode / unmark and reposition |
| y / Escape in visual selection | Copy / clear selection |
| :copy-message / Ctrl+P Copy message | Copy focused received message with its envelope |
| e / :view-editor in the reader | Open a temporary received-message copy in the external editor |
| J/K | Reader: adjacent mail |
| {/}, t, Q/S | Reader: thread card, fold body, quotes/signature |
| c / r / R | Compose / reply / reply-all |
| f / F in mailbox | Forward |
| k / t / e in reply/forward chooser | Keep formatting / Text quote / Attach original (.eml; `e` is forward-only) |
| Ctrl+T in compose | Toggle note Markdown/Plain; retained original stays unchanged |
| Ctrl+Z / Ctrl+Y in compose | Native text undo / redo |
| f / :sender in compose | Verified From chooser |
| p in normal compose | Outgoing preview / original context / plain alternative |
| P / Preview in browser / :preview-browser in normal compose | Save and explicitly open the sandboxed outgoing browser preview |
| g / Continue in Gmail / :gmail-draft in normal compose | Open Gmail handoff review or status; upload requires a further explicit choice |
| Tab/Shift+Tab, Enter in normal compose | Focus fields/controls; edit a field or activate a control |
| Ctrl+S / :send in compose | Open outgoing send review |
| y in send review | Confirm the reviewed draft and start the local send countdown |
| :send-grace 0..30 | Cancellation period in seconds; default 10, explicit 0 means immediate |
| Ctrl+S during the countdown | Send now for this reviewed message; the default delay remains unchanged |
| Ctrl+Z / Undo during countdown | Cancel before submission and return to editing |
| Tab/Shift+Tab, then Enter during countdown | Choose Undo or Send now; Undo is focused initially |
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

For the published mail/contact features, authorize the complete local capability set:
`mail-read,mail-send,mail-modify,contacts-read,contacts-write,calendar-rsvp`.
The setup guide explains the corresponding Google scopes and browser steps.
The development Calendar features use the optional grants described in
[Calendar permissions](CALENDAR-PERMISSIONS.md). A Console scope change alone
does not replace an account's existing token. Restart an open TUI after
authorizing its updated grant.

You can use your own accounts after consent, including sending a first message to yourself. Agent actions still need your task authorization. A dedicated test mailbox is a development qualification tool, not an installation requirement.

## Bounds and recovery

| Limit | Default or supported maximum |
| --- | --- |
| Retained mail per account | Default 2,000 entries / 256 MiB; configurable up to 10,000 / 1 GiB |
| Display/result window | 32 in the TUI; up to 100 per CLI page |
| Native conversation window | 20 message cards at a time; up to 1,000 member IDs; 4 MiB of loaded body DTOs per window |
| Ordinary received body | 2 MiB; ordinary MIME decoding has a 3 MiB combined decoded budget |
| Compose source / each rendered alternative | Native Linux/macOS: 35 MiB, subject to the complete outgoing MIME limit; portable browser: 2 MiB |
| Ordinary outgoing attachments | Native: files plus included original resources share 1,040 parts and 25 MiB decoded; browser: 16 files |
| Retained original inline resources | Up to 1,024; included resources share the native outgoing part/byte budgets; browser resources retain a 2 MiB limit |
| Original email (.eml) source | Native: up to 25 MiB, with sources above 2 MiB stored as blobs; browser: 2 MiB |
| Parsed incoming file/resource descriptors | 1,041 per message, within 4,180 MIME parts; streamed file content up to 50 MiB each; cached blobs also obey the account disk quota |
| Outgoing recipients | Native: 500 across To/Cc/Bcc; browser: 32 |
| Active local drafts / undo receipts | 128 editable or protected drafts / 16 undo receipts per account; settled sent sources move to paged retained history |
| Cached contacts | 1,024 per account |
| Active operation work | 1,000 protected/pending entries per account; settled receipts move to paged history and retain replay protection |
| Calendar invitation work | 256 active reviews/identities; native settled identity/version and operation fences move to paged history, within the account disk quota |
| Addresses per contact | 32; preserved through supported edits |
| Serialized JSON | Ordinary requests: 3 MiB; selected native compose frames/records: 420 MiB serialization ceiling, allocated only for actual content |
| Complete outgoing MIME | 35 MiB (36,700,160 bytes), including body, resources, logo and encoded ordinary files |
| Find query / matches / scanned display text | 256 bytes / 256 / 2 MiB; a + marks a capped count |
| Search history / named searches | 8 each per account; 4,096-byte queries and 96-byte names |
| Native outgoing HTML preview / UI preferences | One streamed preview per account, at most 246 MiB within the account disk quota / at most 256 KiB private preferences |
| Queued send intents | 32 active; settled records move to paged history; delay 0–30 seconds |

Native compose, reply/forward, draft review and submission use dynamic storage
for the actual content, separate from the ordinary 64 MiB browsing heap.
The 420 MiB serialization ceiling covers JSON escaping and multiple text
alternatives; it is not a memory reservation or an outgoing-message allowance.
A selected compose source can exceed the ordinary reader's body limit without
expanding background reads. The portable browser keeps its 2 MiB text/resource
tier and 3 MiB request limit.

Large inline photos remain unloaded while reading: the reader shows image
placeholders, and received-file controls can save their content within the
50 MiB incoming limit. Native replies, reply-all and forwards retain larger
embedded images as immutable account attachment blobs from the first capture.
Those resources and ordinary outgoing files share the 25 MiB decoded limit.
The browser keeps its smaller
2 MiB resource limit. The mode chooser checks known sizes before downloading
content; the backend rechecks the fresh source before saving a draft.
The final 35 MiB encoded-MIME limit still applies. The newly generated Omagma
logo has a separate 16 KiB allowance and consumes no ordinary file or retained
resource slot, but counts toward encoded MIME. Logos already in the original
count as retained resources and share the 25 MiB decoded budget.

Inline JSON file/resource data remains limited to 2 MiB of decoded bytes in
total; account handles carry larger content. Body text must fit its compose
and request limits, and final encoded MIME has its separate cap. Oversized or
unavailable content fails before saving a partial draft or sending mail.
Old mail is evicted under cache pressure;
local drafts, their retained originals and operation receipts are preserved.
`cache.clear` removes cached mail without removing drafts, contacts or receipts.

Every send or RSVP has an operation identity and a recorded outcome: applied, rejected or unknown. Applied means provider acceptance, not delivery. An unknown receipt protects its recovery draft; inspect the provider before deciding what to do next. Local duplicate guards do not guarantee server-side idempotency.

The default file store protects cache files and drafts with owner-only
filesystem permissions; it does not encrypt them. An optional
[encrypted native vault](ENCRYPTION.md) with explicit migration and a
shared unlocked daemon for CLI/TUI sessions encrypts retained data at rest.
Migration preserves the original plaintext source files. Keep private configuration,
credentials, cache files and real-mail captures outside Git. See [cache behavior](TUI-CACHE.md), [agent CLI](AGENT-CLI.md) and [developer references](DEVELOPMENT.md) for the deeper contracts.

Omagma uses Ctrl for modified app commands and reserves Ctrl+B. Letter
alternatives, Tab/Shift+Tab and Enter keep flows usable without Home, End,
Insert or Alt. `i` enters editing, `gg`/`G` navigate mail, and Ctrl+A/E move to
line start/end. Arrow and Home/End keys remain optional aliases; Ctrl+1/2/3
switches accounts from the mailbox, matching the bar popup.

Local follow-ups are available in the native terminal. Press `b` on a received
message (or `:follow-up`) and choose Today, Tomorrow, or enter `YYYY-MM-DD`.
`Ctrl+S` saves the date; `Esc` cancels. Open **Follow-ups** in navigation or use
`:follow-ups` to see this account's overdue, due-today, and upcoming reminders.
Within the list, `b` edits the selected reminder and `d` marks it done. Done
removes the local reminder permanently; it does not archive, snooze, mark read,
or otherwise change Gmail. `Enter` opens the selected mail and may download it
if its body is unavailable offline.

Follow-ups stay on this computer, survive restarts and `cache.clear`, and use
the account's configured vault or private-file storage. There is one active
reminder per message and a maximum of 100 per account; the app refuses new
reminders at the limit until some are marked done. Missing or deleted mail does
not silently remove its reminder. When a new reminder's message metadata is no
longer cached, Omagma reads that exact message's metadata from its account in
Gmail without requiring cache retention. This needs a connection and read access;
existing dates can be edited offline even after cache cleanup.
Dates use the computer's local calendar day without a time-of-day alarm.
The JSONL commands are `reminder.list`, `reminder.set`, and `reminder.done`;
writes require `expectedVersion` (0 for creation, the current entry version for
editing or completion) so two clients cannot silently overwrite one another.

## Continue a draft in Gmail

In a saved native draft, choose the visible **Continue in Gmail** button, press
`g` in normal mode, open the command palette’s **Continue in Gmail**, or use
`:gmail-draft`. Opening this review does not upload or send anything. When local
editing is paused, the composer labels the button **Gmail status**. This account needs `mail-drafts` authorization
(`gmail.compose`), or its existing `mail-modify` grant. Adding permission is an
explicit authorization step; the old grant stays usable until consent succeeds.
The handoff uploads one MIME draft, including recipients, Bcc, sender and files,
and pauses local edits and sending. It retains the original local Markdown and
reply source. It does not send mail.

The handoff survives restart. **Check Gmail draft** reads the remote draft's
current version. **Take back** enables the original local copy and keeps the
Gmail copy. If Gmail has newer edits, choose explicitly between keeping the
original local source or importing Gmail's complete text into a **new** local
draft. Import preserves To/Cc/Bcc and supported files, uses Plain text, and does
not append another quote or footer. It rechecks the remote version after
fetching the content. The original local draft and Gmail draft both remain.
Unsupported, ambiguous, or oversized content stays in Gmail; Omagma refuses a
partial import. Normal outgoing part, recipient and byte limits apply, including the 25 MiB decoded file budget.

Before sending a reclaimed or imported copy, check Gmail and acknowledge the
copy warning in Review send. The acknowledgement belongs to the exact reviewed
content and is invalidated by edits. A missing Gmail draft may have been sent or
deleted; absence does not establish delivery. An uncertain upload remains
paused and is never retried automatically. A positive exact-message lookup can
recover its link; an empty search leaves the outcome unknown.

The JSONL interface provides `draft.gmail-info`, `draft.gmail-save`,
`draft.gmail-status`, `draft.gmail-take-back`, and `draft.gmail-import`.
Provider operations require the current `expectedVersion`; upload also requires
`expectedDigest`, and import requires `expectedRemoteMessageId`. Copy warnings
on `draft.send` / `draft.queue` require `acknowledgeGmailCopy: true` and the
current `gmailCopyDigest`. Omagma never updates or deletes the Gmail draft as
part of this workflow.


### Retained sent sources and operation history

Accepted sends move their immutable local source and settled receipt out of the
active draft index. Sending regularly does not consume all 128 active draft
slots or stop at 1,000 lifetime receipts. Pending, unknown, queued and unresolved
Gmail or Calendar work stays protected and is never discarded to make space.

The native CLI exposes bounded pages through `history.drafts`,
`history.operations` and `history.queues` (`limit` 1–100 and the returned
`nextCursor`). `operation.read` still resolves old identities after restart.
`draft.read` opens an exact retained source; `draft.clone` makes a new editable
copy without changing the archived source.

The active Drafts list also pages compact recipient/file counts, so browsing
many drafts does not reload their full recipient lists or attachment metadata.
If another client changes a saved draft while the composer contains local
edits, preserve those edits as a separate local recovery copy or reload the
saved source when the local view is clean. If another client already sent the
source, recovery uses a new local ID and leaves the sent version intact.

Retained content counts toward the account’s configured disk quota. An explicit
`history.delete-source` request with `confirm:true` removes settled source
content; `discardFiles:true` also removes files no longer referenced by any
active or retained source, cache body or outbox. Permanent receipt/content
fingerprints remain, so deleting source content cannot make an old operation
send again. Cache clear preserves these records. Corrupt or missing history
blocks the affected operation instead of permitting an unsafe retry.

Native storage reads existing account indexes and upgrades them to schema 2 on
subsequent writes. Calendar invitation state likewise upgrades on its next
write. Omagma 0.2.12 and older reject the newer state; replacing the executable
with an older version does not downgrade it. Close clients and stop the vault
daemon before upgrading, then use the same version for every client sharing
the store. Incompatible vault clients and daemons refuse data operations before
dispatch. Status, lock and stop remain usable; use the current executable for
`omagma vault stop`, `omagma vault start` and `omagma vault unlock` after an
upgrade. Do not clear local state to work around a version mismatch: it holds
drafts and submission history. The vault encryption format and application
password remain unchanged.

Browser Calendar remains a separate tech demo; these native storage and
composer improvements do not turn it into a supported everyday client.
