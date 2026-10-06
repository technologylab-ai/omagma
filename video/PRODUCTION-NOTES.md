# Production notes

## Method

The film uses the same collaborative method as the Omajot film: a visual
concept and a Suno prompt first, then the user's downloaded song, measured
analysis, and a cut locked to the measured beats. The technique (a deterministic
`render(t)` page, an explicit cut map, real footage and an optional synthetic
drafting track) is adapted from Omajot's `video/` tooling. No Omajot product
facts, scene times, dependencies or music are reused. Omagma's renderer has no
npm dependencies.

## Sources for everything shown

| On screen | Source |
| --- | --- |
| Terminal client | Real PTY states from the published v0.2.4 executable (`omagma tui --fixtures`), recorded by `capture/takes.py` |
| Mail, people, accounts | Invented in `capture/promo_fixture.py`. The smoke-test mail reuses the public fixture text from `tests/terminal_publication.py` |
| Bar dropdown | The repository's offscreen Quickshell test shell (`offscreen.qml`), with fictional snapshots injected as `tests/ui_capture.py --publication` does |
| Bar strip (workspaces, clock) | A neutral drawing of the host bar. It shows only the real Omagma icon, with no unread badge (the widget has none) |
| CLI cameo | The exact command `omagma mail list --fixtures --account work@example.com --limit 2 \| jq .` and its real stdout (display trimmed by lines/width only) |
| Logo | The approved envelope with flowing magma (`assets/omagma-logo.png`), rendered from a high-resolution copy of the same artwork. Only the interior of the magma blob is gently displaced; the silhouette and envelope are unchanged |
| Palette | `src/terminal/theme.zig` fallback palette; `website/site.css` magma/ink/text tokens |
| Captions | [BRIEF.md](BRIEF.md). Claims match README.md, docs/FEATURES.md and docs/TERMINAL.md |

## Truth rules applied in the edit

- Tapes are only re-timed. A `sync` anchor pins a real mark to a beat, and
  frames in between play faster or slower. Holds repeat a real state. No
  cell is edited.
- No durations, speed-ups or totals are claimed. The only memory figure is the
  source-qualified overlay described under "Memory overlay", which shows its
  scope on screen. The real
  `metadata 1/32` line is shown as the app drew it: a batch counter, not an
  Inbox total.
- Keycaps appear only for keys the harness actually sent. The pointer appears
  only for a mouse event actually sent at that cell. Border pulses follow
  borders the app drew, at moments where focus or sending really changed.
- The send is a fixture send. The compose take fails unless exactly one fixture
  send happened, after an explicit `y` in the review.
- The terminal tag reads "Real TUI · fictional mail". The outro states that the
  TUI and CLI are experimental and that demo accounts and mail are fictional.
- Platform scope stays accurate: the bar is Omarchy/Linux and read-only; the TUI
  and CLI run on Linux and macOS. There are no calendar views, label
  management or tmux.
- "Drafts save themselves" is used only if the compose take actually shows
  "Draft saved locally". Otherwise that caption is dropped.

## Memory overlay (memory revision)

The first cut had no memory stat. At the user's request, the memory revision
(`out/omagma-slow-eruption-memory.mp4`) adds one editorial overlay beside the
held smoke-test reader, at film time about 18.0–21.3 s:

- **3 accounts.** (kicker) / **~11 MB.** (molten figure)
- *Whole TUI process: 10.6 MB settled RSS*
- *Linux v0.2.4 · 3 fictional accounts · small mail*
- *Excludes terminal emulator, editor and bar*

The poster carries a shorter block: **3 accounts. ~11 MB** / *Whole TUI process,
Linux v0.2.4, fictional mail. Excludes terminal emulator, editor and bar.*

Source: [docs/MEMORY.md](../docs/MEMORY.md) and
[docs/evidence/terminal-0.2.4.md](../docs/evidence/terminal-0.2.4.md). The
measured executable is the packaged Linux x86_64 v0.2.4 static-musl build
(exact Zig 0.17.0, Safe), SHA-256 `5483e981…dc03`. That is the same binary used
for the footage. The workload had three fictional accounts and ordinary small
messages, with 100 warm-ups, 1,000 measured cycles and a 60-second quiet
interval. The TUI's whole-process settled RSS was **10,328 KiB = 10.58 MB**
(about 10.1 MiB); the public docs round this to about 11 MB.

This figure is total TUI process memory, including runtime, stacks and touched
storage. It is not incremental memory and not the application-owned heap. It
excludes the terminal emulator, any external editor and a separately running
bar. Large bodies and full caches are separate workloads and can use more.

The overlay must not be presented as:

- an upper bound;
- a live measurement on real accounts;
- a Mac or all-platform figure;
- a browser comparison.

The fictional mail's "2 GB Gmail tab" line is a joke in fixture text, not a
measurement. Never attribute the bar's dated ≈31 MB estimate (v0.2.2) to the
TUI. The memory revision ran no new measurement, and dated evidence is
unchanged.

## Privacy

- Captures run in owned PTYs and an offscreen Qt shell, with an isolated
  `HOME`/XDG tree, no display variables and no session bus. Nothing maps a
  window, grabs input or touches the installed plugin or desktop
  configuration.
- The capture scratch root is a generic `/tmp/omagma-demo`. Its `files/` path
  is visible in the attachment prompt. It is created fresh and removed after
  capture.
- `capture/tape.py` refuses any tape or CLI output that contains an address
  outside `example.com/.org/.net`, the local user, the hostname or the home path.
- Chromium runs headless with a throwaway profile, and a loopback-only server
  that serves just `video/web`, `video/tracks`, `video/cache/capture`, the logo
  master and the public logo.
- Music, captures, frames, renders and receipts stay in the ignored
  `video/cache/` and `video/out/`.

## Music edit: Slow Eruption

The soundtrack is the user's Suno song, generated from the recommended prompt.
The user's listening note was that the beginning and end are very good and that
the middle, around one minute in, is less useful. The edit therefore keeps the
song's own opening and its own composed ending:

| Film | Source | Material |
| --- | --- | --- |
| 0.000–8.928 s | 0.000–8.928 s | first intro phrase (dark swell, bass enters about 4.6 s) |
| 8.928–35.306 s | 17.752–44.130 s | third and fourth intro phrases, then the first drum phrase (drums at film 26.53 s) |
| 35.306–61.937 s | 163.329–189.960 s | closing snare-roll riser, the drop (film 39.58 s), final phrases and the natural tail |

Each seam is a 30 ms equal-power crossfade that ends 5 ms before the incoming
phrase downbeat, so its attack is untouched. Seam and phrase downbeats are
measured onset peaks, not every-fourth-beat guesses. On a local constant-tempo
grid fit to kick and full-band onsets, librosa's predicted beats sat about 90 ms
late. The source tempo drifts from about 108.8–109.4 BPM in the opening to about
112.2–112.4 BPM at the end, so the second seam also steps the tempo by about
2.7 %. That step is inherent in the source sections and was not time-stretched.

Numerical checks on the rendered edit:

- the named phrase/downbeat anchors agree with detected edit onsets within ±1 ms;
  this mapping check is separate from the analyzer’s roughly 12 ms onset resolution;
- the largest sample step at each seam is below the surrounding 99.9th
  percentile; this check found no unusually large seam discontinuity;
- the raw edit peaks at −2.2 dBFS before loudness normalisation.

Whether the splice feels musical is the user's listening judgement. These
numbers only show that it is placed and rendered cleanly. `tracks/slow-eruption.json`
records segments, seams, the film/source mapping, beat arrays, the analysis
method and stated uncertainties.

## Capture facts that shaped the edit

- **Synchronized output.** The TUI draws inside `?2026` update batches. An
  early recorder snapshotted mid-batch and showed torn screens. Tapes now keep
  only completed batches, as a real terminal shows them.
- **Older mail.** Moving back onto cached rows while older mail is loading
  keeps the TUI usable, but it removes the placeholder rows and the batch
  counter. So the film shows placeholders and `metadata 1/32` while resting on
  the placeholder row. The real rows then replace them after the fixture
  provider is released. It does not claim the placeholders persist.
- **Cache search.** After Enter, the title becomes "Inbox / Cache search" while
  "Searching cached mail…" is still shown. The scene holds on the finished,
  filtered results.
- **Reader focus.** After a click and layout changes the reader keeps focus,
  so the take uses `J` (adjacent mail from the reader) as the UI's footer
  says.

## Status

- **Built:** the real captures (bar, three TUI takes, CLI), the measured
  montage cut map, contact sheets, the poster and the 1080p30 master. See the
  film's `.report.json` for the encoded checks.
- **Verified:**
  - strict renders (no stand-ins);
  - exactly one fixture send in the compose take;
  - clean TUI exits with terminal settings restored;
  - the capture privacy gate;
  - the frame count against duration;
  - loudness and true peak after encode.
- **Subjective review is the user's:** nothing here claims to have listened to
  the music or watched the film in real time.
