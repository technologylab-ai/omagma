# Where Omagma goes next

Omagma covers the daily-work batch: action discovery,
current-message find, cached unread navigation, search history/named searches,
staged labels and colors, reviewed conversation targets, native text undo,
verified sender choice, named recipients, private browser preview, file
multi-selection/streamed saving, friendly invitation details, complete contact
addresses, local draft discard, Spam/Not spam and cancellable sending.
These controls remain experimental; the [feature catalogue](FEATURES.md) and
[terminal guide](TERMINAL.md) describe their behavior. The next priorities are
larger follow-ups that build on those workflows.

## Snooze and follow-up reminders

Bring a selected message back at a chosen time with a clear account and target.
A useful design needs explicit local ownership, restart behavior and controls
for inspecting or cancelling reminders. It must distinguish local reminders
from changes to Gmail and retain bounded storage rather than accumulating
unlimited message history.

## Scheduled sending and outbox automation

Today's grace period cancels before submission and the durable queue requires
explicit processing after restart. Future scheduled delivery would need a
separate owner/worker, host-running expectations, timezone handling and a clear
way to inspect, edit or cancel scheduled content. Unknown or submitting
outcomes must remain protected from automatic retry. The read-only background
cache service should retain its existing role.

## Optional Gmail draft synchronization

Continue a draft in the browser with explicit upload, stable remote identity
and conflict-safe replacement. Synchronization should preserve local recovery
and formatted originals, and make clear which version is local or remote.
It is separate from today's private local drafts and browser preview.

## Persistent filters and broader organization

Account-scoped Gmail filter management could follow label management, with
permission review and an explicit explanation of each rule's persistent
effect. Larger organization tools might include saved-query management,
broader search-operator support and useful bulk workflows. Cache search must
continue identifying its supported subset and must never silently substitute
an incomplete local result for a Gmail query.

## Richer calendar work

Invitation inspection, join links and RSVP email are implemented. Calendar
views, calendar edits and conflict-aware event management would be separate
features with their own permissions and reviewed effects. Meeting mail should
remain readable even when its timezone or scheduling data cannot be resolved.

Keep the Omarchy bar read-only, accounts separate and backend operations shared
between TUI and CLI. Each extension should preserve explicit targets, bounded
storage, usable compact controls and inspectable operation outcomes.
