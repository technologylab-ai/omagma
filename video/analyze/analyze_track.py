#!/usr/bin/env python3
"""Measure a music track for cutting the film to it.

    uv run --no-project --with librosa --with soundfile \
        python video/analyze/analyze_track.py video/cache/music/<song>.wav --out video/tracks/<song>.analysis.json

Numbers only: ffprobe format data, EBU R128 loudness and true peak (FFmpeg),
librosa beat tracking, kick/snare band onsets at every beat, downbeat-phase
scores, per-bar energy and section suggestions, and a 30 fps low-band energy
envelope for visuals. The downbeat phase and the section landmarks are
evidence to review, not an oracle; the cut map records which were accepted.
This tool does not listen to the music.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile

import librosa
import numpy as np
import scipy

SR = 22050
HOP = 256


def probe(path):
    result = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                             "format=duration,bit_rate,format_name:stream=codec_name,sample_rate,channels",
                             "-of", "json", str(path)], capture_output=True, text=True, check=True)
    data = json.loads(result.stdout)
    stream = next((s for s in data.get("streams", []) if "sample_rate" in s), {})
    fmt = data.get("format", {})
    return {"duration": float(fmt.get("duration", 0)), "format": fmt.get("format_name"), "bit_rate": int(fmt.get("bit_rate", 0) or 0),
            "codec": stream.get("codec_name"), "sample_rate": int(stream.get("sample_rate", 0) or 0), "channels": stream.get("channels")}


def loudness(path):
    result = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(path), "-af", "ebur128=peak=true", "-f", "null", "-"],
                            capture_output=True, text=True)
    summary = result.stderr[result.stderr.rfind("Summary:"):]
    grab = lambda label: float(re.search(r"\b" + label + r":\s+(-?[\d.]+|-inf)", summary).group(1))
    return {"integrated_lufs": grab("I"), "range_lu": grab("LRA"), "true_peak_dbtp": grab("Peak")}


def band_flux(S, freqs, lo, hi):
    rows = (freqs >= lo) & (freqs < hi)
    energy = np.log1p(S[rows].sum(axis=0))
    flux = np.maximum(0, np.diff(energy, prepend=energy[:1]))
    return flux / (np.percentile(flux, 99) + 1e-9)


def at_times(curve, times, window=0.04):
    frames = librosa.time_to_frames(times, sr=SR, hop_length=HOP)
    w = int(round(window * SR / HOP))
    return np.array([curve[max(0, f - w):f + w + 1].max() if f < len(curve) else 0 for f in frames])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("audio", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--start-bpm", type=float, default=110)
    args = parser.parse_args()
    audio = args.audio.resolve()
    info = probe(audio)
    loud = loudness(audio)
    with tempfile.TemporaryDirectory() as temporary:
        wav = Path(temporary) / "mono.wav"
        subprocess.run(["ffmpeg", "-v", "error", "-i", str(audio), "-ac", "1", "-ar", str(SR), "-c:a", "pcm_f32le", str(wav)], check=True)
        y, _ = librosa.load(wav, sr=SR, mono=True)
    duration = len(y) / SR

    onset = librosa.onset.onset_strength(y=y, sr=SR, hop_length=HOP, aggregate=np.median)
    tempo, beat_frames = librosa.beat.beat_track(onset_envelope=onset, sr=SR, hop_length=HOP, start_bpm=args.start_bpm, tightness=120)
    beats = librosa.frames_to_time(beat_frames, sr=SR, hop_length=HOP)
    tempo = float(np.atleast_1d(tempo)[0])
    pulse = librosa.beat.plp(onset_envelope=onset, sr=SR, hop_length=HOP)
    plp_beats = librosa.frames_to_time(np.flatnonzero(librosa.util.localmax(pulse)), sr=SR, hop_length=HOP)

    S = np.abs(librosa.stft(y, n_fft=2048, hop_length=HOP)) ** 2
    freqs = librosa.fft_frequencies(sr=SR, n_fft=2048)
    kick = band_flux(S, freqs, 30, 150)
    snare = band_flux(S, freqs, 1500, 5000)
    low_energy = np.sqrt(S[(freqs >= 20) & (freqs < 200)].sum(axis=0))
    kick_at, snare_at = at_times(kick, beats), at_times(snare, beats)

    # Drums enter where kick onsets on beats become consistently strong.
    strong = kick_at > 0.35 * np.median(kick_at[len(kick_at) // 3:])
    first_drum = next((i for i in range(len(beats) - 4) if strong[i:i + 4].all()), 0)

    # Downbeat phase: kick on 1/3 and snare on 2/4 fixes the phase modulo 2;
    # harmonic change and bar-level energy jumps distinguish 1 from 3.
    chroma = librosa.feature.chroma_cqt(y=y, sr=SR, hop_length=HOP)
    sync = librosa.util.sync(chroma, beat_frames, aggregate=np.median)
    # Column j of `sync` is the segment ending at beat j, so diff[j] is the change at beat j.
    change = np.linalg.norm(np.diff(sync, axis=1), axis=0)[:len(beats)]
    rms = librosa.feature.rms(y=y, hop_length=HOP)[0]
    rms_at = at_times(rms, beats, 0.1)
    jump = np.r_[0, np.maximum(0, np.diff(librosa.amplitude_to_db(rms_at + 1e-9)))]
    scores = []
    drums = slice(first_drum, None)
    for phase in range(4):
        idx = np.arange(len(beats))
        pos = (idx - phase) % 4
        kd, sd = kick_at[drums], snare_at[drums]
        pd = pos[drums]
        pattern = kd[(pd == 0) | (pd == 2)].mean() - kd[(pd == 1) | (pd == 3)].mean() + sd[(pd == 1) | (pd == 3)].mean() - sd[(pd == 0) | (pd == 2)].mean()
        harmony = change[pos == 0].mean() - change[pos != 0].mean()
        energy = jump[pos == 0].mean() - jump[pos != 0].mean()
        scores.append({"phase": phase, "kick_snare": round(float(pattern), 4), "harmonic_change": round(float(harmony), 4),
                       "energy_jump": round(float(energy), 4), "total": round(float(pattern + 2 * harmony + .5 * energy), 4)})
    phase = max(scores, key=lambda s: s["total"])["phase"]
    downbeats = beats[phase::4]

    # Per-bar table: the evidence for intro/groove/build/drop/ending.
    bars = []
    for i, start in enumerate(downbeats):
        end = downbeats[i + 1] if i + 1 < len(downbeats) else duration
        a, b = librosa.time_to_frames([start, end], sr=SR, hop_length=HOP)
        seg = slice(a, max(a + 1, b))
        bars.append({"bar": i, "start": round(float(start), 4), "rms_db": round(float(librosa.amplitude_to_db(np.array([rms[seg].mean() + 1e-9]))[0]), 2),
                     "low_db": round(float(librosa.amplitude_to_db(np.array([low_energy[seg].mean() + 1e-9]))[0]), 2),
                     "kick": round(float(kick[seg].mean()), 3), "snare": round(float(snare[seg].mean()), 3),
                     "onsets": int((librosa.util.localmax(onset[seg]) & (onset[seg] > np.median(onset) * 1.5)).sum())})
    db = np.array([b["rms_db"] for b in bars])
    groove_bar = int(np.searchsorted(downbeats, beats[first_drum] - 0.05)) if len(downbeats) else 0
    later = np.arange(len(bars)) > groove_bar + 2
    rise = np.r_[0, np.diff(db)]
    drop_bar = int(np.argmax(np.where(later, rise, -np.inf))) if later.any() else None
    loud_bars = np.flatnonzero(db > db.max() - 18)
    ending_bar = int(loud_bars[-1]) if len(loud_bars) else len(bars) - 1
    tail = onset[librosa.time_to_frames(duration * .8, sr=SR, hop_length=HOP):]
    final_hit = duration * .8 + float(np.argmax(tail)) * HOP / SR if len(tail) else None
    audible = np.flatnonzero(librosa.amplitude_to_db(rms + 1e-9, ref=np.max) > -50)
    audible_end = float((audible[-1] + 1) * HOP / SR) if len(audible) else duration

    # Low-band energy envelope at film frame rate for heat/glow.
    times = np.arange(0, duration, 1 / args.fps)
    env = np.interp(times, librosa.frames_to_time(np.arange(len(low_energy)), sr=SR, hop_length=HOP), low_energy)
    lo, hi = np.percentile(env, 5), np.percentile(env, 98)
    env = np.clip((env - lo) / (hi - lo + 1e-9), 0, 1)
    smooth = np.zeros_like(env)
    for i, v in enumerate(env):
        prev = smooth[i - 1] if i else v
        smooth[i] = v if v > prev else prev + (v - prev) * (1 - np.exp(-1 / (args.fps * .15)))

    gaps = np.diff(beats)
    result = {
        "file": audio.name, "sha256": hashlib.sha256(audio.read_bytes()).hexdigest(), "probe": info, "loudness": loud,
        "analyzer": {"tool": "video/analyze/analyze_track.py", "python": platform.python_version(), "librosa": librosa.__version__,
                     "numpy": np.__version__, "scipy": scipy.__version__, "sr": SR, "hop": HOP,
                     "method": "librosa.beat.beat_track (tightness 120) on a median onset envelope; PLP cross-check; downbeat phase from kick/snare band onsets, harmonic change and bar energy jumps"},
        "duration": round(duration, 4), "tempo_bpm": round(tempo, 3), "beat_s": round(float(np.median(gaps)), 5),
        "beat_jitter_ms": round(float(np.std(gaps) * 1000), 2),
        "plp_agreement": round(float(np.mean([np.min(np.abs(plp_beats - b)) < 0.05 for b in beats])) if len(plp_beats) else 0, 3),
        "first_drum_beat": {"index": int(first_drum), "time": round(float(beats[first_drum]), 4)},
        "downbeat_phase": int(phase), "downbeat_scores": scores,
        "beats": [round(float(b), 4) for b in beats], "downbeats": [round(float(d), 4) for d in downbeats],
        "bars": bars,
        "suggested_landmarks": {"groove": f"D{groove_bar}", "drop": None if drop_bar is None else f"D{drop_bar}", "ending": f"D{ending_bar}",
                                "final_hit_s": None if final_hit is None else round(final_hit, 3), "audible_end_s": round(audible_end, 3)},
        "energy": {"fps": args.fps, "source": "20-200 Hz STFT magnitude, 5th-98th percentile scaled, 150 ms release", "values": [round(float(v), 3) for v in smooth]},
    }
    args.out.write_text(json.dumps(result, indent=1) + "\n")
    print(f"{audio.name}: {duration:.3f} s, {info['sample_rate']} Hz x{info['channels']} {info['codec']}, "
          f"{loud['integrated_lufs']} LUFS, {loud['true_peak_dbtp']} dBTP")
    print(f"tempo {tempo:.2f} BPM (median beat {np.median(gaps):.4f} s, jitter {np.std(gaps) * 1000:.1f} ms, PLP agreement {result['plp_agreement']})")
    print(f"first drum beat {beats[first_drum]:.3f} s; downbeat phase {phase}: " + ", ".join(f"{s['phase']}:{s['total']}" for s in scores))
    print("bar  start    rms dB  low dB  kick  snare onsets")
    for b in bars:
        print(f"{b['bar']:>3} {b['start']:>8.3f} {b['rms_db']:>7.1f} {b['low_db']:>7.1f} {b['kick']:>5.2f} {b['snare']:>5.2f} {b['onsets']:>4}")
    print("suggested:", json.dumps(result["suggested_landmarks"]))


if __name__ == "__main__":
    sys.exit(main())
