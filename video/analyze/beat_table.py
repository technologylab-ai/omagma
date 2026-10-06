#!/usr/bin/env python3
"""Beat-level evidence for choosing musical seams and cue points.

    uv run --no-project --with numpy python video/analyze/beat_table.py AUDIO BEATS.json 0:45 150:190

BEATS.json holds a "beats" array (seconds), e.g. from analyze_track.py. For each
predicted beat inside the ranges it prints the strongest full-band onset, the
kick-band (30-150 Hz) and snare-band (1.5-5 kHz) flux within ±WINDOW s (default 0.05), the
offset of that onset peak from the predicted beat, and the RMS around it. Kick
and snare columns show which beats carry which drum; they are evidence for
the downbeat phase, not proof of it. Numbers only: this does not listen.

With GRID=1 it also fits a local constant-tempo grid per range (period and
phase that collect the most kick+full-band onset energy) and prints each grid
beat's kick/snare values, so cue points can sit on actual onsets.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

import numpy as np

SR, HOP, N = 22050, 256, 2048


def decode(path):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-map", "0:a:0", "-vn", "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32)


def stft_power(y):
    window = np.hanning(N).astype(np.float32)
    frames = 1 + (len(y) - N) // HOP
    out = np.empty((N // 2 + 1, frames), dtype=np.float32)
    for start in range(0, frames, 4096):
        idx = np.arange(start, min(frames, start + 4096))
        segs = np.stack([y[i * HOP:i * HOP + N] * window for i in idx], axis=1)
        out[:, idx] = np.abs(np.fft.rfft(segs, axis=0)) ** 2
    return out


def flux(power, freqs, lo, hi):
    band = np.log1p(power[(freqs >= lo) & (freqs < hi)])
    f = np.maximum(0, np.diff(band, axis=1, prepend=band[:, :1])).sum(axis=0)
    return f / (np.percentile(f, 99.5) + 1e-9)


def main():
    audio, beats_path, *ranges = sys.argv[1:]
    beats = np.array(json.load(open(beats_path))["beats"])
    y = decode(audio)
    power = stft_power(y)
    freqs = np.fft.rfftfreq(N, 1 / SR)
    full, kick, snare = flux(power, freqs, 30, 11000), flux(power, freqs, 30, 150), flux(power, freqs, 1500, 5000)
    rms = np.sqrt(np.convolve(y ** 2, np.ones(HOP) / HOP, mode="same")[::HOP] + 1e-12)
    w = int(round(float(os.environ.get("WINDOW", "0.05")) * SR / HOP))
    to_frame = lambda t: int(round(t * SR / HOP))
    for item in ranges:
        lo, hi = (float(v) for v in item.split(":"))
        print(f"\n# beats {lo:g}-{hi:g} s   (n, predicted, onset-peak offset ms, onset, kick, snare, rms dB, gap ms)")
        chosen = [i for i, b in enumerate(beats) if lo <= b < hi]
        for i in chosen:
            f = to_frame(beats[i])
            if f + w + 1 >= full.size:
                break
            seg = slice(max(0, f - w), f + w + 1)
            peak = seg.start + int(np.argmax(full[seg]))
            gap = (beats[i] - beats[i - 1]) * 1000 if i else 0
            db = 20 * np.log10(rms[max(0, f - 4):f + 5].mean())
            print(f"{i:4d} {beats[i]:8.3f} {(peak - f) * HOP / SR * 1000:+6.0f} {full[seg].max():5.2f} {kick[seg].max():5.2f} "
                  f"{snare[seg].max():5.2f} {db:6.1f} {gap:6.0f}")


def local_grid(env, lo, hi, periods=np.arange(0.50, 0.585, 0.0005)):
    fps = SR / HOP
    a, b = int(lo * fps), int(hi * fps)
    seg = env[a:b]
    t = np.arange(len(seg)) / fps
    best = (-1, 0, 0)
    for period in periods:
        for phase in np.arange(0, period, 1 / fps / 2):
            idx = (phase + np.arange(0, (hi - lo - phase) / period) * period) * fps
            score = np.interp(idx, np.arange(len(seg)), seg).sum() / len(idx)
            if score > best[0]:
                best = (score, period, phase)
    return best[1], lo + best[2]


def grids(audio, ranges):
    y = decode(audio)
    power = stft_power(y)
    freqs = np.fft.rfftfreq(N, 1 / SR)
    full, kick, snare = flux(power, freqs, 30, 11000), flux(power, freqs, 30, 150), flux(power, freqs, 1500, 5000)
    fps = SR / HOP
    w = int(round(0.03 * fps))
    for item in ranges:
        lo, hi = (float(v) for v in item.split(":"))
        period, first = local_grid(kick + full, lo, hi)
        print(f"\n# grid {lo:g}-{hi:g} s: period {period * 1000:.1f} ms ({60 / period:.2f} BPM), first beat {first:.3f} s")
        print("#  beat   time   kick snare  onset")
        t, n = first, 0
        while t < hi:
            f = int(round(t * fps))
            seg = slice(max(0, f - w), f + w + 1)
            print(f"{n:4d} {t:8.3f} {kick[seg].max():5.2f} {snare[seg].max():5.2f} {full[seg].max():6.2f}")
            t += period
            n += 1


if __name__ == "__main__" and os.environ.get("GRID"):
    grids(sys.argv[1], sys.argv[3:])
elif __name__ == "__main__":
    main()
