# Public Calendar screenshots

These four images in `docs/images/` show the **released v0.2.10 native TUI**,
running in owned 132-column PTYs with fictional providers. They show a combined
Week across three accounts, a new-event review with two guests selected from
Contacts and Google Meet generation requested, an automatic meeting reminder
over Mail, and an invitation card in Mail. Week uses a real compact 32-row
viewport; the other views use 38 rows. Mail uses the native persistent
`listWidthPercent: 40` preference so its reader can show the bordered card
while retaining both the sidebar and message list.

The fixture week is the current UTC week, beginning Monday. The published
capture shows 19–25 October 2026. The reminder clock freezes the actual UTC
capture time, preserving seconds; its appointment starts exactly ten minutes
later and lasts one hour. The same future appointment appears in Week. The host
clock and the application's actual sync timestamps stay unchanged. Invitations
and new-event reviews use a future date derived from the same week and current
day. Normal Inbox selection opens the invitation, without search highlighting.

Accounts are
`personal@example.com`, `work@example.com` and `optional@example.com`. People,
mail, appointments, invitations and join targets are fictional. The screenshots
contain no live account data. The review is before saving: Google generates a
Meet link after confirmation, so the image does not invent a pre-save URL.

The capture script drives the real executable and records only completed
synchronized terminal frames. The existing film renderer paints those unchanged
cells, colors and borders. It adds no application controls, labels or state.
The native Nerd Font video-camera glyph is retained. No desktop window or real
browser profile is opened; the rasterizer is isolated headless Chromium and
blocks non-loopback requests. No mail is sent and no Calendar event is written.

The reproduction tooling runs on Linux. First download the v0.2.10 Linux
executable for your architecture and verify its release checksum. From the
repository root, run:

```sh
python3 scripts/public-captures/capture.py \
  --binary /path/to/verified/omagma \
  --expected-sha256 RELEASE_EXECUTABLE_SHA256 \
  --out video/cache/short0210/public-calendar-fresh
```

Use a new output directory for each run. Requirements are Python 3, Node.js,
Chromium and JetBrainsMono Nerd Font, matching the existing native film pipeline.
The script acquires the cooperative host reservation, isolates HOME/XDG and
provider state, validates the release version/compiler, checks that Contacts and
Calendar stayed unchanged, checks clean TUI exits and restored terminal settings,
and privacy-scans every tape before publishing its four PNGs. The reservation is
released after PTY and headless-browser cleanup. When a live coordinator supplies
`HOST_TOKEN`, the script verifies and uses that delegated reservation; the
coordinator retains ownership and releases it after all delegated work finishes.

Raw tapes, complete provenance/checksum receipts and diagnostic text remain in
the ignored capture directory. Only the four reviewed PNGs and this generic
reproduction recipe are public. Timestamps such as “Synced” reflect the actual
capture time; application cells are never edited to conceal them.
