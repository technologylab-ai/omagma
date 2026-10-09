#!/usr/bin/env python3
"""Make the shorter-hold film from genuine rendered frames and normal-tempo music.

Development media tooling. No installed application uses this helper.
"""
import argparse
import datetime
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'video/tools'))
from host_lock import owner, identity, start_ticks
from encode import loudness, faststart


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args):
    subprocess.run(args, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--frames', type=Path, default=ROOT / 'video/cache/short027/calm-frames')
    parser.add_argument('--palette-frames', type=Path)
    parser.add_argument('--destination', type=Path, default=Path.home() / 'Videos/Omagma')
    args = parser.parse_args()
    lock = owner()
    who = identity(lock) if lock else None
    if not lock or lock.get('token') != os.environ.get('HOST_TOKEN') or not who or start_ticks(who[0]) != who[1]:
        raise RuntimeError('matching live host reservation required')

    plan_path = ROOT / 'video/short027/holds-2s.json'
    plan = json.loads(plan_path.read_text())
    fps = plan['fps']
    metadata = json.loads((args.frames / 'render.json').read_text())
    if (metadata['count'] != plan['sourceFrameCount'] or metadata['step'] != 1 or metadata['scale'] != 1
            or metadata['film']['fps'] != fps or metadata['film']['width'] != 1920 or metadata['film']['height'] != 1080):
        raise RuntimeError('expected the complete full-resolution source frame set')
    removed = set()
    for cut in plan['cuts']:
        indices = set(range(cut['startFrame'], cut['endFrame']))
        if not indices or removed & indices or max(indices) >= plan['sourceFrameCount']:
            raise RuntimeError('invalid or overlapping hold cuts')
        removed.update(indices)
    keep = [n for n in range(plan['sourceFrameCount']) if n not in removed]
    if len(keep) != plan['frameCount']:
        raise RuntimeError('edit frame count mismatch')
    override = plan['paletteOverride']
    if args.palette_frames:
        info = json.loads((args.palette_frames / 'render.json').read_text())
        if (info['count'] != override['endFrame'] - override['startFrame'] or info['step'] != 1 or info['scale'] != 1
                or round(info['from'] * fps) != override['startFrame'] or round(info['to'] * fps) != override['endFrame']):
            raise RuntimeError('expected the full-resolution palette sequence range')

    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    cache = ROOT / 'video/cache/short027' / ('holds-2s-' + stamp)
    frames = cache / 'frames'
    frames.mkdir(parents=True, mode=0o700, exist_ok=False)
    for number, source_number in enumerate(keep):
        source = args.frames / f'{source_number:05d}.jpg'
        if args.palette_frames and override['startFrame'] <= source_number < override['endFrame']:
            source = args.palette_frames / f'{source_number - override["startFrame"]:05d}.jpg'
        os.link(source, frames / f'{number:05d}.jpg')

    audio = plan['soundtrack']
    music = ROOT / 'video/cache/music/slow-eruption.mp3'
    if sha(music) != audio['sourceSha256'] or audio['rate'] != 1.0:
        raise RuntimeError('original normal-tempo soundtrack required')
    segments = audio['sourceSegmentsSamples']
    samples = sum(end - start for start, end in segments) - audio['crossfadeSamples'] * (len(segments) - 1)
    if samples * fps != len(keep) * audio['sampleRate']:
        raise RuntimeError('music edit does not fit the picture')
    graph = '[0:a]aresample=48000,asplit=3[s0][s1][s2];'
    graph += ';'.join(f'[s{i}]atrim=start_sample={start}:end_sample={end},asetpts=PTS-STARTPTS[a{i}]' for i, (start, end) in enumerate(segments))
    graph += ';[a0][a1]acrossfade=ns=1440:c1=qsin:c2=qsin[ab];[ab][a2]acrossfade=ns=1440:c1=qsin:c2=qsin[audio]'
    raw = cache / 'music.wav'
    run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-n', '-i', str(music), '-filter_complex', graph,
         '-map', '[audio]', '-ar', '48000', '-ac', '2', '-c:a', 'pcm_s24le', '-map_metadata', '-1', str(raw)])
    measured = loudness(raw)
    gain = min(-14 - float(measured['input_i']), -1.5 - float(measured['input_tp']))
    args.destination.mkdir(parents=True, exist_ok=True)
    out = args.destination / f'omagma-v0.2.7-shorter-holds-normal-music-{stamp}.mp4'
    duration = len(keep) / fps
    command = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-n', '-framerate', str(fps), '-i', str(frames / '%05d.jpg'),
               '-i', str(raw), '-map', '0:v:0', '-map', '1:a:0', '-frames:v', str(len(keep)), '-t', f'{duration:.9f}',
               '-vf', 'scale=in_range=pc:out_range=tv:out_color_matrix=bt709,format=yuv420p', '-af', f'volume={gain:.9f}dB',
               '-c:v', 'libx264', '-profile:v', 'high', '-preset', 'slow', '-crf', '18', '-threads', '4',
               '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709', '-color_range', 'tv',
               '-c:a', 'aac', '-b:a', '256k', '-ar', '48000', '-ac', '2', '-map_metadata', '-1', '-movflags', '+faststart', str(out)]
    print(f'Encoding {duration:.3f}s film with normal-tempo music...', flush=True)
    run(command)
    probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(out)], text=True))
    video = next(s for s in probe['streams'] if s['codec_type'] == 'video')
    if int(video['nb_frames']) != len(keep) or video['width'] != 1920 or video['height'] != 1080:
        raise RuntimeError('final picture format or frame count mismatch')
    if abs(float(probe['format']['duration']) - duration) > .05:
        raise RuntimeError('final duration mismatch')
    report = {'film': str(out), 'durationSeconds': duration, 'frames': len(keep), 'fps': fps,
              'musicRate': 1.0, 'motionRate': 1.0, 'musicSha256': sha(music), 'pictureSourceSha256': sha(ROOT / 'video/short027/film.html'),
              'editPlanSha256': sha(plan_path), 'plan': plan, 'sourceFrameMap': keep, 'paletteOverrideUsed': bool(args.palette_frames),
              'sha256': sha(out), 'staticGainDb': gain, 'loudnessFinal': loudness(out), 'faststart': faststart(out),
              'ffprobe': probe, 'encodeCommand': command}
    out.with_suffix('.report.json').write_text(json.dumps(report, indent=2) + '\n')
    (cache / 'receipt.json').write_text(json.dumps(report, indent=2) + '\n')
    (ROOT / 'video/cache/short027/holds-2s-delivery.json').write_text(json.dumps({'film': str(out), 'report': str(out.with_suffix('.report.json')), 'durationSeconds': duration, 'cache': str(cache)}, indent=2) + '\n')
    print(json.dumps({'film': str(out), 'durationSeconds': duration, 'musicRate': 1.0}, indent=2), flush=True)


if __name__ == '__main__':
    main()
