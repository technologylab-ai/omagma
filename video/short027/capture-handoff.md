# v0.2.7 genuine capture assets

Media tooling only. All accounts, contacts, messages, bookings and on-disk files
are invented. No real mailbox/configuration, user browser profile, desktop input,
provider write or mail send is used. Native executable provenance is recorded in
`video/cache/short027/capture-receipt.json`: Omagma 0.2.7, Zig 0.17.0, Safe,
SHA-256 `4762a3c5a4b6e471bd611631cc45905f38c24e22975e41c19c0f234ccb05990a`.

With the coordinator's live cooperative `HOST_TOKEN` reservation, regenerate:

```sh
python3 video/short027/capture.py --binary "$OMAGMA" --expected-sha256 "$OMAGMA_SHA256"
python3 video/short027/capture_bar.py --binary "$OMAGMA"
python3 video/short027/capture_labels.py --binary "$OMAGMA" --expected-sha256 "$OMAGMA_SHA256"
node video/short027/capture-images.mjs
```

`capture.py --scene NAME` can replace only main, meeting, compose, forward or
newmail while preserving the other scene files and their cleanup receipts.
Each owned PTY exits zero, restores terminal settings and independently confirms
zero synthetic sends. All child processes are reaped by finally blocks.

Tapes preserve genuine terminal cells, attributes, cursor and the exact sent-key
marks. `capture-images.html` paints those cells through the existing TermView;
it never changes them. Full captures are 3520×1848 pixels, representing a
160×42 terminal at 11×22 logical pixels per cell and 2× raster scale. Exact native
pane crops use the `-detail.png` suffix. Recipient and countdown crops are
explicit rectangular regions of genuine source states. Crop bounds and hashes
are in `raster-receipt.json`.

Highlights and caveats:

- `main.json`: action palette filtered to label actions, searchable help, Omagma
  theme picker, orange label palette, two-message staged label checklist (two
  changes, then Cancel), scope chooser, actual Find 1/5 → 2/5 after leaving
  the mailbox cache search (no competing mailbox search highlights), and a
  separately re-run cache query for the saved-search state.
- `meeting.json`: friendly local-time invitation, normal native review and actual
  `o` Join activation, followed by optional advanced Details. The Join hero
  preserves the friendly review; it does not show raw UID/Sequence fields. Browser opening is deliberately dry in the fixture backend;
  the validated target is the fictional online meeting URL.
- `compose.json`: named Maya Chen completion, verified sender picker, actual
  text paste/undo, ten ERUPTION files with three checked, attachment list, send
  review, actual ten-second countdown and cancellation. The later normal composer
  state supplies `recipient-named-detail.png`, avoiding a transient editing hint.
- `files:check-three` really sends Tab×4 then Space, j, Space, j, Space while the
  list has focus. The later `files:retain-filter` restores Documents/ERUPTION and
  `files:list-focus` returns to the list. `files` is the final filtered selection
  summary. Do not depict Space being typed into Path during that restoration.
- `forward.json`: native Keep formatting choice and actual editable Markdown note
  above a frozen synthetic Ember Air booking. The generated sender signature is
  retained. `assets/browser.html` is a byte-for-byte copy of the actual private
  `draft.open-preview` artifact; its opaque sandboxed iframe contains the native
  renderer's personal note/footer plus original HTML, tables and two CID images.
  Chromium is headless with a fresh profile; remote requests are blocked. Local
  about:srcdoc/data transport is allowed so the real isolated preview can render.
  `browser.png` is 2000×3800 and `browser-top.png` is 2000×2000, light mode.
- `newmail.json`: two arrivals in the receiving work@example.com account, then
  genuine interaction-driven card hiding while keeping the selected message.
- `bar.png`: actual offscreen repository QML dropdown, work@example.com selected.
  IPC invokes the actual Open TUI button's clicked signal and handler, then checks
  popup closure. No pointer event or launcher process is fabricated. A separate
  evaluation of normal Model.tuiArgv verifies the same account for the match cut.
  Show a button highlight and cut to the genuine TUI; do not invent a cursor click.

Use `omagma tui` in editorial launch examples. Fixture flags belong only to this
private capture method. Existing videos, soundtrack and product sources remain
unchanged. Generated media/tapes/receipts live in ignored video/cache/short027.

The pacing revision adds a focused `labels.json` take from a fresh fictional
fixture home. The same native dialog and camera show initial checked/mixed
membership, Projects removal, Travel addition, and the real Apply control.
The backend independently verifies that staging was local and exactly the two
pinned messages received both changes; their content/read status and an
unselected message remain unchanged. `labels-applied.png` shows the native
two-message success receipt; `labels-result.png` and
`labels-result-second.png` show actual reader memberships after selecting the
two affected messages. These fixture-only label writes send no mail and never
reach a production provider. Their receipt is `labels-capture-receipt.json`.

To rasterize just that take while preserving unrelated assets and their hashes:

```sh
node video/short027/capture-images.mjs --tape labels
```

The source main take still contains its separate staged-and-canceled example;
the longer film should use the complete labels take for causal completion.

The shorter, normal-tempo pacing revision reuses the original main tape's
untouched Ctrl+P palette and each real typed prefix: `l`, `la`, `lab`, `labe`,
`label`. No new app input or provider call is needed. `capture_palette.py`
preserves the original frames/styles verbatim and adds observation marks; its
receipt retains the original input marks and exact source hash.

```sh
python3 video/short027/capture_palette.py --expected-sha256 "$OMAGMA_SHA256"
node video/short027/capture-images.mjs --tape palette
```

New full screenshots use names `palette-initial.png`, `palette-l.png`,
`palette-la.png`, `palette-lab.png`, `palette-labe.png`, `palette-label.png`
(3520×1848); exact natural dialog crops add `-detail`. Crop widths are all
1584px. Heights are respectively 836, 836, 484, 396, 396, 396px. Native dialogs
recenter as their result count falls; anchor the title/filter row of the detail
crops in the film without stretching them, so query typing remains readable
and stable. Original captures and other raster assets remain unchanged.
