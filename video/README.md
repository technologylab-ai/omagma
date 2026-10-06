# Omagma launch film

Production sources for Omagma's social launch film. The film is built from
real captures of the published executable, using fictional fixtures only, and
cut to the beats of a measured song. [BRIEF.md](BRIEF.md) describes the concept
and shot list. [SUNO-PROMPT.md](SUNO-PROMPT.md) holds the music prompt.
[PRODUCTION-NOTES.md](PRODUCTION-NOTES.md) records sources, truth rules and
privacy checks.

None of this is part of the installed application. It is promo tooling in
Node.js, Python, HTML/CSS and FFmpeg, and nothing here is shipped or run by
Omagma.

## One command per stage

```sh
video/build.sh check                                   # syntax + cut-map validation (cheap)
video/build.sh capture                                 # real TUI takes, bar states, CLI cameo   [heavy]
video/build.sh analyze video/cache/music/<song>.mp3    # librosa measurement (uv)                [heavy]
python3 video/tools/cutmap.py --analysis video/tracks/<song>.analysis.json \
  --plan video/tracks/draft-110.json --landmarks groove=D4,build=D14,drop=D20,ending=D24,final=D25 \
  --out video/tracks/<song>.json                       # then edit scenes by eye and ear
video/build.sh sheet   video/tracks/<song>.json        # stills at every cut                      [heavy]
video/build.sh draft   video/tracks/<song>.json video/cache/music/<song>.mp3                     [heavy]
video/build.sh film    video/tracks/<song>.json video/cache/music/<song>.mp3                     [heavy]
video/build.sh preview video/tracks/<song>.json        # scrub in a browser (loopback only)
```

The current film is reproduced with the user's song saved as
`video/cache/music/slow-eruption.mp3` (its SHA-256 is recorded in the cut map):

```sh
HOST_TOKEN=<coordinator token> video/build.sh capture
HOST_TOKEN=<coordinator token> video/build.sh film video/tracks/slow-eruption.json video/cache/music/slow-eruption.mp3
```

`TAKES=main,stream` and `SIZE=132x36` limit or resize a capture. Helpers:
`python3 video/tools/tape_text.py TAPE [MARK…]` prints a tape's real screens;
`video/analyze/beat_table.py` (numpy, via `uv run --with numpy`) prints
beat-level kick/snare/onset evidence and fits local beat grids;
`video/tools/audio_edit.py` renders a cut map's soundtrack montage.

The film step writes `video/out/omagma-<song>.mp4`, plus a `-poster.png` and
`-poster.jpg`. It also writes `<song>.cuts.json`, with every scene, caption,
keycap and sync time resolved to seconds, and `.report.json`, which records
ffprobe, frame count and loudness. `video/cache/` and `video/out/` are
ignored by Git; music is never committed.

**Heavy steps** (capture, analyze, sheet, draft, film) run only inside the
cooperative host reservation from [docs/VERIFICATION.md](../docs/VERIFICATION.md).
Pass the coordinator's token as `HOST_TOKEN=…` (verified, never re-acquired), or
use `RESERVE=1` to have `tools/host_lock.py` inspect the host for existing
build/measurement/media work, take the reservation and release it when the
command ends. `check` and `preview` do not reserve the host.

Requirements: Node.js 24+, Chromium (`CHROMIUM=` overrides `/usr/bin/chromium`),
FFmpeg/ffprobe with libx264, ImageMagick, jq, Python 3, Quickshell for the bar
capture, `uv` for the analysis environment, and the fonts **Adwaita Sans**,
**JetBrainsMono Nerd Font** and **Noto Color Emoji**. No npm packages are
installed; the renderer uses the Chrome DevTools protocol over a pipe, with a
throwaway profile.

## Inputs

- **Executable:** `OMAGMA=` (default `zig-out/bin/omagma`). Use a verified
  release binary, or a build made with the exact pinned Zig 0.17.0 in
  `debug`/`safe` on a task-local `PATH`. `OMAGMA_SHA256=` makes the build refuse
  any other bytes. The current captures target published v0.2.4.
- **Logo:** the approved high-resolution artwork is included at
  `video/assets/omagma-logo-master.png` and copied into the render cache automatically.
  `LOGO_MASTER=/path/to/logo.png` can override it with another approved master.
- **Song:** the user's Suno download in `video/cache/music/`.

## How it works

1. **Capture** (`capture/`). `takes.py` drives `omagma tui --fixtures` in owned
   PTYs and records *tapes*, the real screen states (cells, colours,
   attributes, cursor) with timestamps and marks for every key, click and
   observed state. Like a terminal with synchronized output, a tape keeps only
   completed `?2026` update batches, never a half-drawn screen. The mailboxes
   in `promo_fixture.py` are fictional. The compose take must end with exactly
   one fixture send, counted against the take's own fixture root. `bar.py` grabs the
   real dropdown from the offscreen Quickshell test shell, with fictional
   injected snapshots. The CLI cameo is the exact
   `omagma mail list --fixtures …` command, pretty-printed by a real `jq .`.
   Every capture is scanned for local identities and for addresses outside
   the fixture's known fictional set (a pane may truncate or wrap one).
2. **Measure** (`analyze/analyze_track.py`) records duration, loudness, tempo,
   beats, kick/snare evidence for the downbeat phase, a per-bar energy table,
   section suggestions and a 30 fps energy envelope. Treat the suggestions as
   evidence: confirm the landmarks against the table before writing the cut
   map.
3. **Cut map** (`tracks/<song>.json`). The edit is data. Times are musical
   expressions: `D12` is bar 12, `B40` is beat 40, `@drop+2b` is two beats after
   a landmark, `@end-0.6s` is 0.6 seconds before the end.
   `tracks/draft-110.json` is the plan on a nominal grid. `tools/cutmap.py`
   moves that plan onto the measured beats and keeps the actual beat arrays,
   analyzer versions and audio offset. A cut map may instead carry an
   `audio.segments` montage of the source song (seams, crossfade, film/source
   mapping), as `tracks/slow-eruption.json` does; picture and sound are both
   generated from that one block. `poster` names a real tape state. `tools/check.mjs` validates every cue,
   checks that each caption stays on screen long enough to read, and confirms
   that every referenced tape mark exists.
4. **Render** (`web/`, `render.mjs`). `timeline.html` is the film as a page,
   and `render(t)` is pure. Terminal scenes repaint captured cells as DOM text
   with vector box borders, so camera zooms stay sharp. `sync` pins tape marks
   to beats, and the frames in between are re-timed linearly. Overlays only
   mark real events: keycaps for keys actually sent, a pointer for a click
   actually sent, and a pulse on borders the app drew. The film and poster
   render with `--strict`: a missing capture is an error, never a stand-in.
5. **Encode** (`build.sh`). The soundtrack uses only the song's first audio
   stream (`-map 0:a:0`, `-vn`; embedded cover art is ignored) with metadata
   stripped. Loudness is two-pass normalised to −14 LUFS integrated and
   −1.5 dBTP, with linear gain where possible. A montage keeps the song's own
   ending; a continuous section cut from inside a longer song gets a short
   fade. Video: H.264 High, yuv420p, BT.709 TV range, CRF 18, AAC 256 kb/s
   48 kHz, faststart, container metadata stripped.

## Drafting before the song exists

`node video/synth.mjs` writes a synthetic 110 BPM drafting track that matches
`tracks/draft-110.json`. `video/build.sh draft video/tracks/draft-110.json`
renders a labelled half-size review video with it. That track and grid are
placeholders: they only show how the edit moves and are never the soundtrack
or evidence about the real song.
