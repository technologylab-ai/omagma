# Omagma v0.2.18 — social post copy

Film: **Heavy Lifting** (`video/short0218/film.html`, 84.233 s, approved v0.2.7
Slow Eruption soundtrack unchanged; every feature is announced, then shown).
Copy by actual Claude Opus 5.5 at xhigh.

## Post

Omagma v0.2.18 is out 🌋 Paste images straight into your mail, add booking
emails to your calendar, send files too big to attach via Drive, and switch on
Meet AI notes while you plan. All from the terminal.

New since v0.2.10:

- **Paste images with Ctrl+V while writing a Markdown body.** They land in the mail exactly where your cursor was. (Pasted in a Plain body or a header field, they become a normal attachment.)
- **Too big to attach? Send it via Drive.** Choose Drive per file; the link is shared only with your To and Cc, viewer-only, and nothing uploads until you send.
- **Booked a haircut by email? Press A and it becomes your own appointment** in your calendar, after one quick check.
- **Switch on Meet AI notes and a transcript** for a new event with a Google Meet link. Eligible Google Workspace plans.
- **A red now line** across today in the week view, between what's done and what's next.

Smaller wins:

- Link lists show each link's title above its full address
- Calendar guests suggested from people you recently mailed
- Move an event's start and its end follows, until you set the end yourself
- Scroll the send review with your mouse wheel
- Reply without the original, or with it folded away
- Large, ever-growing reply threads stay easy to read and answer
- Long Outlook and Teams invitations handled cleanly, with recovery when a calendar action is interrupted
- Recover a local draft after a save conflict
- Send history for what you sent recently
- `:version` shows the build you're running
- Smoother window resizing
- Clearer sign-in diagnostics
- CLI: mix attached and Drive-delivered files with `--attach-file` and `--upload-file`

TUI and CLI are experimental. Linux & macOS.
👉 technologylab-ai.github.io/omagma

## Short variant (≤280 characters)

Omagma v0.2.18 🌋 Paste images inline with Ctrl+V. Send too-big files via Drive, shared only with your recipients. Add booking emails to your calendar. Turn on Meet AI notes. technologylab-ai.github.io/omagma

## Copy decisions

- Booking copy is about personal appointments (a haircut confirmation) becoming
  your own calendar entry. It deliberately makes no "no reply" claim, so it can't
  be read as advice against answering meeting invitations.
- The inline-paste claim is scoped to the Markdown body, which is what the film
  shows (`MD · Body`). Plain bodies and header fields attach the image normally.
- The Drive subline in the film says "even past the mail limit", not "however
  big": Drive sends what attaching can't, without claiming unlimited size.
- Every line names the capability and its benefit. No tracking-URL "removal"
  claim: link lists add the title above the complete address.
- Drive copy says the link is shared with exactly the visible To and Cc as
  viewers. It doesn't call the link public and doesn't claim a file size.
- Meet copy says Omagma switches the settings on with Google. It doesn't claim
  finished notes, meeting monitoring or delivery after disconnect. The plan
  requirement appears once, as a short footnote.
- The post leaves out fixtures, demo data, benchmarks and memory figures; that
  provenance belongs in the production records only.
- Bcc handling with Drive is left out of the post. Drive delivery refuses Bcc
  rather than sending it, which is a safeguard, not a selling point.
