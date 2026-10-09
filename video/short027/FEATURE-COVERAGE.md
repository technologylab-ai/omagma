# v0.2.7 film feature coverage

The opening's **9 highlights** counts eight demonstrated workflows. It does
not count every feature in the release. The film gives each workflow
time to establish its context, show an action and hold the result. Smaller
changes appear in the closing recap or the description.

The [storyboard](STORYBOARD.md) controls the final shots and timing. This map
connects those eight chapters to the [complete release notes](../../docs/release-notes/0.2.7.md)
and [terminal guide](../../docs/TERMINAL.md).

## 01 — Start from your bar

The Omarchy popup's **Open TUI** opens the selected account in a centered
floating terminal. The orange Omagma theme establishes the film's visual style.
Any arrival card in this shot provides context: new-mail cards were already
available in v0.2.6, while this release adds the desktop launch workflow.

The bar remains read-only. Its Open TUI button launches the separately
authorized terminal client rather than giving the bar permission to send mail.

## 02 — Find a command

**Ctrl+P in the mailbox** opens a searchable action palette for the current
account and view. This chapter stays with that one palette, making its filter
and matching actions readable before moving on. Searchable Help appears in
the recap. Tab/Shift+Tab and Enter reach dialog actions, with visible focus and
safe Back/Cancel defaults in reviews.

Ctrl+P has a different role while editing a recipient: it moves through
completion suggestions. The film's keycaps must retain their captured context.

## 03 — Find inside the message

In-message find highlights displayed text, keeps its match counter visible,
and uses **n/N** for the next/previous match. The shot stays in the same reader
as the highlight moves, rather than switching into another search dialog.

Search history and named searches belong in the recap/description. They retain
the account and Cache/Gmail scope; choosing an entry explicitly runs it.

The broader release also adds cached unread navigation and filename, date and
important-state predicates. Message find is a local operation on the loaded
displayed message, separate from mailbox search or a Gmail server query.

## 04 — Choose labels. Apply once.

The **m** checklist shows checked, mixed and absent membership. The continuous
sequence establishes initial membership, stages two changes, deliberately
activates Apply and holds the resulting reader state. Multiple changes remain
staged until Apply; filtering retains those choices. The film keeps this one
membership workflow together instead of switching to the color dialog.

Custom-label colors and explicit message/conversation scope remain broader
release/recap features. Scope adds account, subject and count to reviewed
actions.

The separate **LABELS** manager creates, renames, colors, deletes and opens
custom-label definitions. Assigning a label to mail and editing the collection
remain different operations. Deleting a definition keeps the messages.

## 05 — Meetings, made readable

The styled invitation card sits below message labels and remains available
when its original header scrolls away. Review displays friendly local meeting
details. **o Join in invitation review** explicitly opens the meeting URL;
ordinary mailbox **o** opens the selected mail in Gmail.

**I** opens review rather than sending a reply. Accept/Tentative/Decline are
deliberately reviewed RSVP emails; the client does not claim to edit a calendar.

## 06 — Pick files together

The native file browser marks multiple files, including across folders, and
attaches the whole set. The chapter stays on the file selection and its
resulting attachment list, giving the checked rows and completed set time to
register. The release also adds received Save All/selected, paperclip indicators
and bounded streaming for larger ordinary attachments.

Named recipients move to the recap/description: suggestions insert
**Name <address>** into To/Cc/Bcc. Native text undo/redo, explicit sender
selection, complete multi-address contacts and sender-to-contact prefill
support the same daily composition flow.

## 07 — Forward with a personal note

**Keep formatting** places an editable Omagma-branded Markdown or plain-text
note above the read-only original email. Its HTML layout, tables, styling and
embedded images are retained. The light-mode browser preview makes the result
visible before sending, with a local sandbox and verified inline images.

Text quotes remain available; forwarding also offers an original .eml
attachment. The preserved inline original shown here does not require the
recipient to open a separate attachment. Broader HTML compatibility tolerates
usable imperfect markup without rebuilding the entire document.

Markdown composition itself was introduced before v0.2.7; this chapter's new
payoff is the preserved original and private final browser preview.

## 08 — Send with a safety net

Explicit send confirmation starts a local cancellation countdown. Undo returns
to the editable retained draft **before submission**. The default is ten
seconds, configurable from zero to thirty. This is cancellation of an unsent
intent, not recall of a message already accepted by the provider.

Interrupted queued sends stay paused after restart. Resume/Cancel requires an
explicit decision for the matching draft/account; uncertain submissions remain
protected rather than being automatically repeated.

## Closing recap

The two cards group smaller improvements that do not need their own long shots.
Help, saved searches, label colors and named recipients support the release
without interrupting the main demonstration with more popups.

| More everyday wins | Safer, smoother everywhere |
| --- | --- |
| Choose themes + search Help | Archive a message or whole thread |
| Save searches + color labels | Mark spam + discard local drafts |
| Names in To/Cc/Bcc + choose sender | Attachment reminders + Tab to buttons |
| Jump to unread + half-page scroll | Resume or cancel paused sends |

The archive line gives a concrete example of choosing message or conversation
scope. The same deliberate scope also supports Trash, labels and read-state
actions; it does not mean the client has a separate conversation-only mailbox.
Paused-send actions are explicit decisions after recovery, rather than automatic
resubmission. Discard here removes local drafts, not Gmail drafts.

Other release details belong in the description or documentation: readable
unread/star/label state, corrected invisible padding and stale display artifacts,
clean link underlines, missing-recipient checks, more complete contextual hints,
private fresh attachment destinations and explicit partial-failure reporting.
The shared CLI covers the corresponding account, label, file, RSVP and queue
operations.

The neutral ending names **What's new in v0.2.7** and the Omagma website. It
makes no publication-status, new memory-use or speed-measurement claim. The TUI
and CLI remain experimental on Linux and macOS; the Omarchy bar is Linux-only.

## Ninth final feature: update guide

The final prominent workflow shows the native upgrade notice and actual How to
update guide. It explains the host-specific source checkout/backend rebuild
steps and installs nothing. The version0.2.8 notice is an explicitly labelled
fixture on running0.2.7, not an announcement of a published0.2.8 release.
Saved update checks use a24-hour interval and need no new Gmail scope.

See [the ninth-scene production map](NINTH-SCENE.md) for exact footage, timing
and the preserved polished first-eight edit.
