# Omagma launch film: creative brief

Working title: **Slow Eruption**. 1920×1080, 30 fps, about 45–60 s; the measured
song sets the final length. Optional derivatives (a 15–20 s teaser and a 9:16 cut)
are assessed only after the main film works.

## Concept: pressure, release, calm

Omagma is a tiny volcano. It starts as a glowing icon in the Omarchy bar and
erupts, just a little, into a full mail client in the terminal. The film follows
that arc:

1. **Pressure.** The music's intro, no drums. A dark screen, one ember. The
   approved envelope logo resolves with its magma slowly flowing, then shrinks
   into its real place: the bar icon.
2. **Release.** On the first downbeat the icon erupts. A small pour of magma
   cools into the real bar dropdown. The heat then cracks the frame open along a
   molten seam, and the terminal client rises out of it.
3. **Flow.** Most of the film. Real TUI interactions land on the beat: accounts,
   Vim keys, the reader, HTML-only mail, older mail streaming in, search, a
   reply-all with local completion and attachments.
4. **Eruption.** At the song's drop, one key press: `y` in the send review. The
   mail goes out, and a pulse of magma runs once along the terminal's real pane
   borders. Caption: *A tiny volcano that sends mail.* (That line comes from the
   fictional smoke-test mail the viewer read earlier.)
5. **Calm.** The inbox is up to date. A brief nod to the agent CLI, then the
   logo, the name and the URL on the song's final hit.

The fictional mail **"Omagma smoke test: a very small eruption 🌋"** is the
film's through-line. The viewer reads it early ("…from a tiny volcano in the bar
to a tiny volcano that sends mail 🌋. The smoke is metaphorical. Your inbox is
not on fire."), and the climax pays it off by replying to it.

## Truth rules for the edit

- Every Omagma pixel comes from the real published v0.2.4 executable in fixture
  mode, driven through an owned PTY or the offscreen Quickshell UI. Accounts,
  people and mail are fictional (`example.com`/`.org`/`.net`).
- The film re-times genuine states to the music. It never claims a duration
  or speed-up, and never shows a UI state the app did not produce. Its only
  memory figure is the scoped overlay described below.
- Overlays mark real events only: keycaps show keys actually sent; a pointer
  shows a mouse event actually sent at that cell; the molten border pulse
  follows the borders the app drew. The pulse happens only when focus or
  sending actually changes.
- A small **"Real TUI · fictional mail"** tag appears when the terminal first
  appears. The outro states that the TUI and CLI are experimental.
- The bar is Linux/Omarchy-only and read-only. The TUI/CLI run on Linux and
  macOS. There are no calendar views, label management or tmux scenes.
- Memory: at the user's request, the memory revision adds one stat overlay
  ("3 accounts. ~11 MB.") beside the held smoke-test mail. This supersedes the
  first cut's "no stat card" choice. It is an editorial overlay grounded in the
  published v0.2.4 measurement, not an app widget. The overlay shows its scope
  on screen: the whole TUI process, 10.6 MB settled RSS, Linux v0.2.4, three
  fictional accounts with small mail, excluding the terminal emulator, editor
  and bar. Never attribute the bar's ≈31 MB to the TUI. Never present ~11 MB as
  an upper bound, a live real-account figure, a Mac figure or a browser
  comparison.

## Look

### Palette (from the TUI fallback palette and the site)

| Role | Hex | Source |
| --- | --- | --- |
| Night (frame) | `#0a0d14` → `#0e121b` | site `--ink-0/1` |
| Terminal background | `#111620` | `src/terminal/theme.zig` |
| Terminal foreground | `#e8ebf1` | theme |
| Magma accent / focused border | `#ff9e61` | theme accent |
| Warm selected row | `#392b30` | theme selection |
| Magma deep → core → high | `#b4461b` → `#ec7a35` → `#f6a467` | site `--magma*` |
| White-hot (sparingly) | `#ffd9a8` | new, for seam cores only |
| Cooling crust | `#1c110d`, `#2b1812` | new, for the pour as it cools |
| Captions | `#f4f0f7` / secondary `#b6b0c4` | site text tokens |

The TUI keeps its real colors, including cyan sender names and green status.
The film never recolors captured cells.

### Type

- Display and captions: **Adwaita Sans** (Inter-derived), 800–900, tracking
  −0.025em. Title 150 px, captions 64–76 px, secondary lines 30–34 px.
- Terminal cells, keycaps and commands: **JetBrainsMono Nerd Font**, the same
  family the publication captures use. Emoji: Noto Color Emoji.
- Copy is sentence case and short. One idea per caption, never a feature list.

### Motion language

- **Molten seam.** The signature device: a thin incandescent line (white-hot
  core, orange glow, dark crust edges). Captions emerge from below a seam as if
  pushed up by heat, then the seam cools. Scene transitions crack along a seam.
- **Ember keycaps.** Real key presses appear as small mono keycaps that flash
  warm on the beat, then cool and fade. Chords read as `Ctrl` `N`.
- **Border pulse.** When focus moves, a short bead of light runs along the
  pane border the app just turned orange. At the drop, every border carries it
  once.
- **Camera.** Slow push-ins (1.00 → 1.04 over a bar) and cuts on downbeats;
  confident zooms into the pane that matters, so text is large enough on a
  phone. No whip pans, shakes or spins.
- **Heat.** A faint warm glow from below the frame breathes with the bass.
  Light, deterministic film grain. Heat shimmer only touches the logo and seams,
  never terminal text.
- **Restraint.** No warning colors or triangles, no alarm flashing, no stock
  volcano footage. The one big burst is at the drop and lasts under a second.

## Scenes (tentative order; times come from the measured song)

Bars are only proportions until the song is measured. Scenes marked *optional*
are the first cuts if the song is short.

| # | Scene | Music | Picture | Caption |
| --- | --- | --- | --- | --- |
| 0 | Ember | intro | Darkness, one ember; logo resolves, magma flowing; wordmark rises from a seam | **omagma** / *Gmail, one account at a time.* |
| 1 | Bar | first downbeat | Logo flies into a minimal bar strip and becomes the icon; on the hit it erupts: a pour cools into the real dropdown; account and selection steps on beats | **A tiny volcano in your Omarchy bar.** / *Three accounts at a glance. Read-only.* |
| 2 | Crack | bar line | The dropdown dims; a seam splits the frame and the terminal rises out of the light; `omagma tui` typed | — |
| 3 | Cache first | groove | Real startup: cached inbox immediately, status refreshes to "Up to date" | **Cached mail first. Gmail catches up.** + tag *Real TUI · fictional mail* |
| 4 | Accounts | groove | `1` `2` `3` on beats; sidebar and list change; lands on work | **Three accounts. Never mixed.** |
| 5 | Read | groove | `j` `j` `j` then a click on the smoke-test row; push into the reader; hold for reading | **Vim keys. Or just click.** then no caption: the mail reads itself |
| 6 | Layouts *(optional)* | groove | `v` reader below, `z` expanded | **Beside. Below. Full screen.** |
| 7 | HTML | groove | An HTML-only newsletter with headings, a list and a table in the native reader | **HTML-only mail, as clean text.** / *Tables and lists kept. Nothing remote loads.* |
| 8 | Stream | build starts | Past the cache: animated placeholders and the real `metadata n/m` line; cached rows still move | **Keep scrolling. Older mail flows in.** / *Cached mail stays usable.* |
| 9 | Search *(optional)* | build | `/volcano` then Enter; highlighted cached results | **`/` searches the cache. `\` asks Gmail.** |
| 10 | Reply-all | build | `R` on the smoke-test mail; Cc `ce` + `Ctrl` `N` completion; a one-line reply is typed | **Reply-all. Addresses complete locally.** |
| 11 | Attach | build peak | `A`, Tab completion, two files listed with sizes | **Attach files. Drafts save themselves.** |
| 12 | Review | riser | `Ctrl` `S`: account, From, recipients, subject, attachments | **Nothing sends until you press `y`.** |
| 13 | Eruption | **drop** | `y` keycap hits on the drop; the real result; magma pulse along every border, then cooling | **A tiny volcano that sends mail.** |
| 14 | Calm *(optional)* | drop | Inbox up to date; slow pull back | — |
| 15 | Agents | drop tail | A side panel with the real `omagma mail list … --fixtures` command and its first JSON lines | **Plus a JSONL CLI for your agents.** / *Experimental* |
| 16 | Outro | ending hit | Logo with flowing magma; name; tagline; platforms; URL; fine print | **omagma** / *Gmail, one account at a time.* / *Omarchy bar · Linux & macOS terminal · Agent CLI* / `technologylab-ai.github.io/omagma` / *TUI and CLI are experimental. Fictional demo mail.* |

The received-file picker, draft recovery after restart, contacts, labels and
invitation replies are deliberately left out. They are real, but showing them
would turn the film into a checklist. "Drafts save themselves" is only shown
if the real autosave appears on screen in that take; otherwise that line is
dropped.

## Shot list and capture plan

| Take | Source | Contents |
| --- | --- | --- |
| `bar` | offscreen Quickshell (`offscreen.qml`, test IPC) at 2× | Open; select personal → work; message selection moves; preview. Fictional snapshots injected exactly like `tests/ui_capture.py --publication`. |
| `startup` | owned PTY, `omagma tui --fixtures` | Cold start over a pre-seeded cache: first cached frame through "Up to date". |
| `main` | same session continued | Account keys; `j`/`k`; a mouse click on the smoke-test row; `v`/`z`; open the HTML newsletter; `/` search. |
| `stream` | separate session (fixture hold) | Past the cached tail with the real fixture checkpoint, as `tests/terminal_publication.py` does; placeholders plus `metadata 1/32`, then release. |
| `compose` | separate session | `R` reply-all on the smoke-test mail, Cc completion, typed reply, `A` ×2 with Tab completion, `Ctrl+S` review, `y`; fixture send count must be exactly 1. |
| `cli` | subprocess | `omagma mail list --fixtures --account work@example.com --limit 3`; real stdout, trimmed in the frame only by line count. |

Terminal size for the hero takes: 132×36 cells (decided at first capture review;
the renderer handles any size). Rendering at 1080p uses vector box borders and
DOM text, so camera zooms stay sharp.

## Poster

Default poster: the terminal on the smoke-test mail, warm selected row, the logo
small top-left and the line **A tiny volcano that sends mail.** It is rendered
as a still from the same timeline, not composed separately, so it always matches
the film. A 1:1/4:5 crop is produced only if the vertical assessment says it helps.

## Derivatives (assessed after the main cut)

- **Teaser (15–20 s):** Ember (short) → bar eruption → smoke-test read → review
  `y` on the drop → outro. Same song, a measured section with its own ending.
- **Vertical 9:16:** only with separate narrow-terminal captures (about 72
  columns, reader below), never by squeezing the 16:9 frame. Do it only if the
  narrow TUI still looks good.

## As built: the Slow Eruption cut (61.9 s)

The table above was the plan. This is the delivered edit, timed to the measured
montage of the user's song (`tracks/slow-eruption.json`). Search and layouts
moved after the drop, where their short, snappy interactions suit the climax.
Calmer reading stays in the quiet opening.

| Film (s) | Music | Scene | Caption |
| --- | --- | --- | --- |
| 0.0–4.5 | dark swell | Logo in the dark, wordmark rises from a seam, logo flies into the bar | — |
| 4.5–8.9 | bass enters | A molten wave pours from the icon and cools into the real dropdown; account switch; `omagma tui --fixtures` typed on a seam | **A tiny volcano in your Omarchy bar.** / *Three Gmail accounts at a glance. Read-only.* |
| 8.9–13.3 | intro steps up | The terminal opens out of the seam; real cache-first startup, "Refreshing cached mail" → "Up to date" | **Cached mail first.** / *Gmail catches up.* + *Real TUI · fictional mail* |
| 13.3–15.5 | | `1` `3` `2` | **Three accounts. Never mixed.** |
| 15.5–21.6 | phrase accent on the click | `j` `j` `j`, a click on the smoke-test row, then the reader framed on the right | **Vim keys. Or just click.**, then the memory stat (memory revision): **3 accounts.** / **~11 MB.** / *Whole TUI process: 10.6 MB settled RSS · Linux v0.2.4 · 3 fictional accounts · small mail · Excludes terminal emulator, editor and bar* |
| 21.6–25.4 | | `J` to the newsletter, `z` expands the real table | **HTML-only mail, as clean text.** / *Tables and lists kept. Nothing remote loads.* |
| 25.4–29.8 | drums enter at 26.5 | Fast scroll to the cache tail, real placeholders with `metadata 1/32`, real older rows arrive | **Keep scrolling. Older mail flows in.** / *Placeholders turn into real rows.* |
| 29.8–33.1 | | `R`, Cc `ced` → `Ctrl` `N` → Enter, the reply typed; "saved locally · not sent" | **Reply-all. Addresses complete locally.** / *The draft saves locally. Nothing is sent yet.* |
| 33.1–35.3 | | `A` + Tab completion, twice; both files listed with sizes | **Attach files. Tab completes paths.** |
| 35.3–39.6 | snare-roll riser | The explicit review screen, slow push-in | **Nothing sends until you press `y`.** |
| 39.6–43.9 | **drop** | `y` → "Saved by mock provider"; heat ring and border pulse | **A tiny volcano that sends mail.** |
| 43.9–48.1 | | `/volcano` → real filtered cache results | **`/` searches the cache. `\` asks Gmail.** |
| 48.1–53.5 | phrase | `v` reader below, `z` full-screen smoke-test mail | **Read beside, below, or full screen.** |
| 53.5–56.7 | | The exact `omagma mail list … --fixtures \| jq .` and its output | **Plus a JSONL CLI for your agents.** / *omagma cli · experimental* |
| 56.7–61.9 | last phrase, stop, tail | Logo, name, tagline, platforms, URL, experimental/fictional fine print; flare on the music's stop | — |

The memory revision's poster adds one restrained block under the headline:
**3 accounts. ~11 MB**, with *Whole TUI process, Linux v0.2.4, fictional mail.
Excludes terminal emulator, editor and bar.*

The poster is a separate composition of one real tape state: the smoke-test
mail in the reader, the warm selected row, the logo, the name, the line
**A tiny volcano that sends mail.** and the URL. There is no vertical cut or
teaser yet.
