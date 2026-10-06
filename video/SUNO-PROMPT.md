# Suno prompt: Omagma launch film

The film is cut to the song you generate, so the song comes first. Please
generate an **instrumental**, download it (WAV if offered, otherwise the
highest-quality MP3) and put it at:

    video/cache/music/omagma-song.wav      (or .mp3, any name works with AUDIO=)

Then hand it back. Tempo, downbeats, section changes and duration are measured
from the actual file before any cut is locked. The timing table below is our
rough editing plan, not numeric timing instructions in the pasteable Suno
prompts. Copy those prompts as written; a longer song is fine, and we will
choose the edit from the track you actually get.

## Recommended: "Slow Eruption" (warm dark synthwave)

Paste into **Style of Music** (custom mode, Instrumental on):

```text
dark warm synthwave, instrumental, minor key, 110 BPM, driving analog bass pulse in eighth notes, deep round kick, gated reverb snare, tape-saturated warm pads, low brassy analog lead with slow attack, sub-bass swells, rising arpeggio build, confident and brooding, molten and heavy rather than icy, cinematic, tight mix, clean decisive ending
```

If the style field rejects that length, use this short form (under 200 characters):

```text
dark warm synthwave, instrumental, minor key, 110 BPM, driving analog bass, deep kick, gated snare, tape-warm pads, slow brassy lead, rising build, decisive ending
```

If your Suno version has **Exclude styles**, add:

```text
vocals, choir, spoken word, bright pop, happy, ukulele, festival EDM, supersaw drop, dubstep, trap hi-hats, lo-fi hiss, long fade out
```

Title suggestion: **Slow Eruption**.

### Arrangement direction (for the lyrics/structure box, if your mode shows it)

Use only bracketed tags. If they cause vocals, delete them and regenerate with
Instrumental on; the style prompt alone is enough.

```text
[Instrumental]
[Intro: low warm pad swell, filtered bass pulse rumbling underneath, no drums, pressure building]
[Main groove: kick and gated snare enter on a clear downbeat, driving eighth-note analog bass, warm and steady]
[Build: filter opens, rising arpeggio, low toms, tension climbing, short riser]
[Drop: full arrival, big warm lead, wide pads, heavy confident groove]
[Outro: one final big hit, short dark tail, clean stop]
[End]
```

### What the film needs from the song

| Section | Rough length | What happens on screen |
| --- | --- | --- |
| Intro, no drums | 6–9 s | Logo glows in the dark, shrinks into the bar icon, pressure builds |
| Main groove | 15–20 s | Small eruption from the bar, then the terminal client opens and we navigate on the beat |
| Build | 8–12 s | Older mail streaming in, search, composing a reply, attaching files |
| Drop / arrival | 10–15 s | The explicit send (`y`) lands on the drop, then calm |
| Ending | 3–5 s | Logo and URL on one decisive final hit |

The total is **about 45–60 s**. Please don't worry about hitting these numbers.
A clear, drum-free intro, an obvious first downbeat, a build you can hear, one
strong arrival and a **natural ending** (not a fade) matter more than exact times.

If Suno returns a longer song (typical: 2–3 minutes), send the full file anyway.
I can measure it and choose a continuous section that keeps its own ending.
You can also trim it in Suno's editor if you prefer a specific part.

When choosing between takes, prefer:

- warm, dark and confident rather than cheerful (like the Omajot track's mood, but warmer);
- a steady, audible kick, so the edit can lock to it;
- an ending that resolves on a hit or a held chord rather than a fade-out;
- no vocal artifacts in the mix.

## Alternative: "Pressure Front" (cinematic darkwave with low toms)

If the first prompt comes back too retro or too thin, this one is heavier and
more cinematic while staying dark and minor:

```text
cinematic darkwave, instrumental, minor key, 104 BPM, heavy pulsing analog bass, deep low toms and taiko-like hits, gated snare, warm distorted synth drones, slow-building tension, rumbling sub-bass, molten brass-like lead at the peak, brooding but powerful, tight modern mix, abrupt confident ending
```

Use the same Exclude list and structure tags.

## After you send the song

I measure the actual track: duration, loudness, tempo, beat and downbeat
phase (librosa in a throwaway environment, cross-checked against low-frequency
energy), and the real intro, build, drop and ending. I keep those numbers in a
track file and cut every scene change, key press and caption to them. I only
describe the song from measurements unless an actual listening tool was used;
your listening review stays the final judgment.
