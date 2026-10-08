# Where Omagma goes next

Omagma already has cache-first browsing and search, full thread reading,
Markdown mail, attachments, contacts, batch actions and undo, invitation
replies, and per-account arrival notifications. The next goal is to make daily
mail work dependable and easy to discover, then close useful Gmail gaps.
These priorities came from a source audit and an Opus 5.5 review. They are
proposals, not promises that every item is implemented.

## Correctness and safety first

- **Maintain predictable dialogs and help.** Keep the complete
  Tab/Shift+Tab and Enter contract as new controls are added, with one clear
  focus and text input separate from shortcuts. Keep Help searchable and
  shortcut descriptions current. Reviews must start on Back or
  Cancel and preserve protection for pending or uncertain submissions.
- **Correct action targets and stable position.** Read/star toggles currently
  derive their new state from the mail-list row even when a different thread
  message is focused. Fix that mismatch and verify that triage in an older
  cached window preserves the selected message or its neighbour. A position
  reset after triage still needs a focused reproduction.
- **Honest Trash and label reviews.** Pin the message IDs being reviewed and
  show the actual selection count. Show whether a label is applied or mixed
  across selected mail; keep destructive mailbox actions separate from custom
  label assignment.
- **Preserve complete contacts.** The current contact editor loads the first
  email address and saves a one-address list. Verify the provider update path
  and preserve additional addresses before expanding contact editing. Contact
  selection should offer every saved address, while retaining etag conflict
  checks.

## Practical TUI and CLI parity

- **Expose existing actions in the TUI.** The CLI already supports local draft
  discard and Spam/Not spam. Add clear TUI actions and confirmations; the Spam
  view should restore with Not spam rather than the Trash restore action.
- **Extend custom labels.** Add colour selection and staged assignment of
  several labels in one Apply action. Create, rename and reviewed deletion now
  share the TUI/CLI executor. Stable IDs and shared
  executor operations should keep TUI and CLI behavior consistent. The
  existing `gmail.modify` scope supports label creation and updating;
  additional consent is unnecessary for those operations.
  [Google label create](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.labels/create),
  [label update](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.labels/update).
- **Find and act faster.** Add find within the current message, next/previous
  unread, and a searchable action palette. Improve search with operator hints,
  bounded account-specific history, saved views and local date predicates.
  Cache and server scope must stay visible. Shared query improvements should
  also work through the CLI.
  [Gmail search operators](https://support.google.com/mail/answer/7190?hl=en).
- **Make conversation scope explicit.** Offer message-versus-thread triage,
  conversation counts and reviewed targets, while preserving per-message
  outcomes, bounded expansion and undo. Share the scope with the CLI.
  [Google thread modification](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.threads/modify).
- **Smooth composition and files.** Consider an alias chooser, sender-to-contact
  prefill, multi-address contacts, native editing undo, and safe batch attachment
  saving/selection. Existing recipient completion, multiple attachments,
  Markdown previews and `$EDITOR` remain the foundation.

## Larger follow-ups

**A local send grace period** could make a mistaken send cancellable before
submission. It must never claim to recall delivered mail. A durable local
outbox or scheduler would need explicit queue ownership, cancellation and CLI
inspection, clear host-running behavior, and no automatic retry of uncertain
submissions. The read-only background refresh service must stay read-only.
[Gmail send cancellation](https://support.google.com/mail/answer/2819488?hl=en).

**Optional Gmail draft synchronization** would let users continue a draft in
the browser. It needs conflict-safe replacements, stable remote draft identity
and an explicit choice to upload locally saved content; it is separate from
today's private local recovery. The API supports it under `gmail.modify`.
[Google draft guide](https://developers.google.com/workspace/gmail/api/guides/drafts),
[draft update](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.drafts/update).

**Optional Gmail filter management** could follow label management. This one
requires an additional permission, `gmail.settings.basic`, and explicit review
of persistent rules.
[Google filter authorization](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.settings.filters/create).

The Omarchy bar remains read-only. Backend capabilities should remain shared
between TUI and CLI, with explicit accounts, bounded storage and recoverable
operation outcomes.
