# Omagma features

Choose the interface that fits your work: a compact read-only bar, an
experimental terminal client, or an experimental agent CLI. All three keep
configured accounts separate and open Gmail in each account's Chrome profile.

The bar runs on Linux Omarchy. The TUI and CLI run natively on Linux and macOS;
[Homebrew is preferred on Mac](MACOS.md).

This catalogue describes Omagma’s current features. Detailed controls and
examples live in the linked guides.

## At a glance

| Interface | Main purpose | Access |
| --- | --- | --- |
| [Omarchy bar](UI.md) | Glance at recent Inbox mail and unread counts, then open Gmail | One `gmail.readonly` permission |
| [TUI](TERMINAL.md) | Read full mail, work with drafts, reply/send and manage mailbox/contact data | Read-only to browse; a separate terminal grant for writes/contacts |
| [Agent CLI](AGENT-CLI.md) | The shared mail operations as structured commands and responses | The same account-specific terminal permissions as the TUI |

If the bar is all you need, install it and authorize only the read-only scope.
It needs neither People API nor the second terminal Google OAuth registration. The dated
three-account v0.2.2 measurement was approximately **31 MB** for the backend and attributed
bar UI together; Chrome and unrelated widgets are excluded. See
[memory accounting](MEMORY.md) for the exact version/date and assumptions.

## Main capabilities

### Read-only Omarchy bar

- Up to three accounts, each with its own recent Inbox list and unread count.
- Up to 30 recent messages per account, with sender, subject, time and snippet.
- Inbox/message links routed to the account's configured Chrome profile.
- Manual refresh and optional five-minute background refresh while closed.
- A compact keyboard-friendly dropdown with clear current, cached,
  disconnected, empty and partial-result states.
- Memory-only mail snapshots. The bar never sends, changes labels or read
  status, or saves mail to disk.

[Install the bar](INSTALL.md) · [Read-only account setup](SETUP.md#read-only-google-oauth-registration)
· [Bar controls](UI.md)

### Experimental terminal mail client

- Full messages and chronological threads, with plaintext-first rendering and
  a native formatted view for HTML-only mail.
- Reader beside or below the list, expanded reading, Vim-oriented keys and
  mouse navigation, with a choice of Omagma volcano-orange colors or the
  current Omarchy palette.
- Cache-first startup and usable cached mail during refresh; bounded message
  count/byte retention evicts the oldest mail tail.
- An optional Linux read-only five-minute cache timer keeps mail ready while the
  TUI is closed.
- An open TUI adopts background cache updates and shows a main-screen-only
  arrival card with separate account counts; interaction clears it automatically.
- `gg` reaches the first mail across cached windows without scrolling back manually.
- Separate cache search and explicit Gmail search; explicit page navigation
  fetches beyond the bar's recent-mail limit.
- Local drafts, compose/reply/reply-all, outgoing attachments and explicit
  sending review. `$EDITOR` can take over the terminal and return afterward;
  no tmux dependency.
- Markdown source with an outgoing rendered
  preview, plain alternative and retained reply/forward context. New TUI
  compositions default to Markdown; existing drafts retain their format.
- Contact list/search, create/edit, and account-scoped archive, Trash/restore,
  star/unread and existing-label assignment.
- Inspect calendar invitations and send accept/tentative/decline RSVP emails.
  There are no calendar views.

- Forward with original files, choose sender identities/signatures, use
  autocomplete and recover drafts automatically. Bulk selection/undo,
  custom-label views, folded conversations, link/received-file pickers,
  cached-body search, continuous cache-window navigation and personalized
  working context are included.

[Terminal workflows and keys](TERMINAL.md) · [Full terminal permissions](SETUP.md#full-tuicli-permissions)

### Experimental agent CLI

- One-shot commands and a JSONL client (`omagma cli` / `omagma agent`) use the
  same account-scoped executor as the TUI.
- Up to 100 messages per requested page, explicit continuation cursors and
  cache-only versus server search.
- Decoded body/envelope/thread/attachment data, drafts, replies, sending,
  mailbox changes, contacts and invitation replies.
- Explicit Markdown/Plain draft formats and local rendered `draft.preview`;
  CLI source defaults to Plain.
- Explicit account identity, locally checked capabilities and durable
  operation receipts. Unknown send outcomes are not automatically retried.
- Forward planning, verified sender discovery, bulk per-item
  outcomes/undo, richer cached-body search, relative cache-window anchors and
  incomplete-draft recovery commands.

[CLI contract and examples](AGENT-CLI.md) · [CLI/TUI coverage differences](AGENT-CLI.md#cli-and-tui-coverage)

## Smaller features that improve daily use

### Reading and navigation

- `h`/`l` or Tab changes pane; `v` switches right/below; `z` expands the reader.
  With the reader focused, `J`/`K` changes mail and `j`/`k` scrolls its body.
- Unread subjects are bold and marked `●`; read subjects use normal weight.
  `⭐` stars stay visible independently of bulk selection. Reader headers show
  the account's readable label names.
- Search Help with `/` by shortcut, description or section; `n`/`N` visits
  highlighted matches. Esc clears a query before leaving Help.
- The bar's **Open TUI** button opens the selected account in a floating
  terminal. An optional Omagma application launcher entry opens the TUI
  directly; see [installation](INSTALL.md#application-launcher).
- Mouse clicks choose accounts, mailboxes, messages and contacts. `--no-mouse`
  keeps mouse handling in the terminal, and the terminal's selection modifier
  remains available for selecting text.
- HTML-only text keeps headings, emphasis, lists, quotes, code/preformatted
  blocks and simple tables. Remote resources never load.
- Links are colored and underlined in HTML and plain-text mail. Long visible
  URLs use compact labels while `L` keeps their full destinations. HTML images
  show caption placeholders; decorative empty-alt images stay hidden.
- Missing bodies and partial cached threads are identified explicitly; a
  snippet is not passed off as a complete body.
- Both-direction scrolling moves through adjacent cached
  windows, including after restarting in a middle position. Cached searches
  never fetch missing bodies or older Gmail pages.
- Loading placeholders animate during unavailable-mail fetches
  and become real rows as metadata/body previews arrive. Batch `n/m` counters
  describe actual work, not Inbox totals; cached mail stays usable.
- Wheel/touchpad scrolling works over row gaps and loading
  placeholders, while unfinished rows remain unclickable.
- Compact word-wrapped reader headers, current-window counts,
  reader progress and fixed last-synced timestamps keep short panes useful.
- Mail dates and sync times follow the computer's local
  timezone, including historical DST and fractional offsets. An unavailable
  timezone is explicitly identified when UTC is used as a fallback.
- `{`/`}` chooses a thread message, `t` folds its body, and
  `Q`/`S` folds quoted history or a signature while keeping the focused card.
  An earlier-message cue identifies collapsed cards above the viewport.
- `/` searches cached metadata and downloaded bodies with
  match excerpts/highlights. Returning from
  search restores the prior selected mail, focus and scroll.
- `\` explicitly searches Gmail; `/` searches cached metadata and downloaded
  bodies without a network request.

[Reading](TERMINAL.md#read-and-navigate) · [Search](TERMINAL.md#search) · [Cache behavior](TUI-CACHE.md)

### Composition, files and contacts

- Normal/insert modes keep editing separate from commands. To/Cc/Bcc/subject
  and body remain visible; sending requires a review and explicit confirmation.
- Ctrl+T switches Markdown/Plain without rewriting source; normal compose `p`
  selects outgoing preview, original reply/forward context or plain alternative.
  Tab/Shift+Tab focuses controls and Enter activates the selected control.
- Markdown mail includes headings, lists, quotes, tables and highlighted fenced
  code, rendered HTML and meaningful plain text. Raw HTML and remote images
  stay inert. The tiny approved footer logo is embedded, with no remote fetch.
- Multiple outgoing attachments survive local saves and `$EDITOR` return.
  Limits are explicit: up to 16 files and 2 MiB of aggregate decoded outgoing
  attachments, with a separate 2 MiB body limit and 3 MiB request limit.
- `A` adds files repeatedly and `:detach NUMBER` removes one. The direct
  `:save-attachment NUMBER /absolute/path` command saves a received file.
- `$EDITOR`, then `$VISUAL`, then an available nvim/vi/nano supplies external
  editing; fixed quoted arguments are supported without invoking a shell.
- Debounced local recovery preserves unfinished addresses,
  body and files. Autosave, paste, editor save and leaving compose never send.
- Ctrl+N/P and Enter choose account-local cached correspondents and saved
  contacts in the selected address field. Regular correspondents need not be
  saved contacts; name/address matching remains local during background refresh.
- `f` or the alias action cycles verified sender identities;
  configured sender names and plaintext signatures are retained.
- Sizes and individual `[x]` controls stay visible, and the
  wheel reaches longer outgoing file lists.
- In file popups, Tab/Shift+Tab focuses the path, folder controls, rows and
  action buttons; Enter activates the selected control. Ctrl+F completes
  literal paths with spaces, matching filename prefixes without regard to ASCII
  case and retaining their actual spelling. Ctrl+U clears the path. No shell
  expansion occurs.
- Received files have a picker across the loaded thread and a
  suggested XDG Downloads filename. Collisions get a fresh name; saves refuse
  overwrite and create private files. Save & open explicitly invokes a viewer.
- `L` opens an account-profile URL chooser.
- Ctrl+D/U or PageUp/PageDown scrolls the selected preview in
  normal compose mode; preview link/file actions retain the outgoing draft.
- The contact's name and address share selection highlighting.
  Local autocomplete and contact pickers remain account-specific.

[Compose, replies and files](TERMINAL.md) · [Contact commands](AGENT-CLI.md#commands)

### Organizing mail and making the workspace yours

- Archive and Trash are reversible; reading does not automatically mark mail
  read. Star/unread changes are explicit.
- Space selects mail and Ctrl+A selects the current page.
  Bulk actions return per-message results; Ctrl+Z/`:undo` reverses confirmed
  successful touched-label changes, preserving unrelated changes.
- Custom-label, Spam, All Mail and Unread views complement
  Inbox/Sent/local Drafts/Archive/Trash. The label chooser filters by name and
  has explicit Add/Remove actions.
- Dialog controls support Tab/Shift+Tab and Enter, including label actions,
  received attachment saving, contact editing and compose aliases. Submission
  reviews begin on Back/Cancel; only a deliberately chosen action submits.
- `q` goes back through reader, search, help and compose
  contexts before quitting; in text-entry fields it remains a normal character.
- Account/mailbox/selected-message/reader-scroll context,
  split ratios and mailbox key remaps restore from private preferences.
  `:split`, `:bind` and `:unbind` provide lightweight personalization.
- `T`/`:theme` previews Omagma's volcano-orange palette or Follow Omarchy;
  Apply saves privately and Cancel restores the previous choice. Follow
  Omarchy updates with the desktop; missing themes use Omagma colors.
  Ctrl+L reloads the selected mode. `NO_COLOR` retains meaningful text states
  and selected-item highlighting.
- Configurable body prefetch accepts 0–64; zero disables it.

[Organization and keys](TERMINAL.md) · [Background cache](TERMINAL-BACKGROUND.md)

### Structured agent workflows

- Explicit accounts accompany every mail/contact/draft operation. Pagination
  cursors stay bound to the same account/query/view.
- Operation IDs and journal receipts make send outcomes inspectable. An
  uncertain submission retains its recovery draft; automatic resend is avoided.
- Contact updates use etag preconditions instead of silently overwriting a
  changed contact.
- JSONL `mail.attachment` and one-shot `omagma mail attachment` return
  attachment bytes as base64url; callers save them with their own file tools.
  There is no `--output-file` option. The interactive save/path picker is a
  TUI convenience.
- JSONL `draft.bodyFormat` and one-shot `--format markdown|plain` select the
  outgoing interpretation. `draft.preview` returns unchanged source, generated
  HTML and its plain alternative without sending or saving the supplied body.
- Per-item bulk outcomes and undo tokens, relative before/after
  cache anchors with retained-boundary fallback, and raw local recovery fields
  support agent-controlled workflows.
- CLI/API batches can mark selected mail as spam or restore it
  from Spam to Inbox, with the same per-item outcomes and undo rules.

[Commands, data and limits](AGENT-CLI.md) · [Receipts and recovery](TERMINAL.md)

## Permissions, storage and current limits

Full TUI/CLI use requests six local capabilities that map to two Google scopes:
`gmail.modify` and `contacts`. A terminal-only installation uses one terminal Google OAuth registration and grant.
Alongside the bar, use a different registration; the bar continues using its
single `gmail.readonly` permission.
[Account setup](SETUP.md) is the canonical permission guide.

Tokens stay in Secret Service on Linux or the default user Keychain on macOS; private terminal cache, drafts, contacts and
receipts are plaintext protected by filesystem permissions. The bar's mail
cache is memory-only. Accounts, credentials, message IDs and profile routing
remain separate. [Privacy details](PRIVACY.md).

Current limitations: no unified Inbox/unread total, calendar views, permanent
mail deletion or contact deletion. Drafts
are local rather than synchronized Gmail drafts. The external editor uses a
full-terminal takeover; there is no embedded editor pane. See
[CLI/TUI coverage](AGENT-CLI.md#cli-and-tui-coverage) and
[terminal bounds](TERMINAL.md#bounds-and-recovery).

## Label assignment and collection management

`m` assigns or removes an existing custom label on mail. The sidebar's **LABELS**
heading opens collection management: create, rename or delete a custom label.
The TUI and CLI share these operations, with system labels protected and
deletion explicitly reviewed. Deleting a definition keeps its emails. Clicking
a label name browses its mail; Inbox or another mailbox leaves that label view.
The existing `gmail.modify` permission covers the Gmail APIs.
