#!/usr/bin/env python3
"""Encode the complete picture, preserving the approved AAC packets exactly."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'video/short0219'))
from resource_guard import verify
FRAMES = 2527
AUDIO = ROOT / 'video/cache/short0218/audio/approved-flow-84.m4a'
AUDIO_SHA = '4f849b3de93b24d841a81baa3a96177ef40deaeefeaefa07db768438c3fa854e'


def run(command):
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr[-4000:])
    return result.stdout


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def packets(path):
    value = json.loads(run(['ffprobe', '-v', 'error', '-select_streams', 'a:0',
        '-show_packets', '-show_entries', 'packet=pts,dts,duration,data_hash,side_data_list',
        '-show_data_hash', 'sha256', '-of', 'json', str(path)]))
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--frames', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    verify(os.environ.get('HOST_TOKEN', ''))
    if os.environ.get('OMAGMA_RESOURCE_GUARD') != 'short0219':
        raise ValueError('encode through resource_guard.py run')
    frames, out = args.frames.resolve(), args.out.resolve()
    if not frames.is_relative_to(ROOT / 'video/cache/short0219') or not (frames / '.short0219-render').is_file():
        raise ValueError('owned full render required')
    meta = json.loads((frames / 'render.json').read_text())
    if (meta.get('count'), meta.get('scale'), meta.get('step'), meta.get('pixelWidth'), meta.get('pixelHeight')) != (FRAMES, 1, 1, 1920, 1080):
        raise ValueError('complete full-resolution2527-frame render required')
    if meta.get('files') != [f'{i:05d}.jpg' for i in range(FRAMES)] or sorted(p.name for p in frames.glob('*.jpg')) != meta['files']:
        raise ValueError('frame sequence is incomplete')
    for name, expected in meta.get('sourceFiles', {}).items():
        if sha(ROOT / name) != expected:
            raise ValueError('film source changed after rendering')
    for kind in ('captureManifest', 'assetsManifest'):
        entry = meta[kind]
        if sha(ROOT / entry['path']) != entry['sha256']:
            raise ValueError('capture/asset manifest changed after rendering')
    if sha(AUDIO) != AUDIO_SHA:
        raise ValueError('approved audio changed')
    if out.suffix != '.mp4' or not out.is_relative_to(ROOT / 'video/out/short0219') or out.exists() or out.with_suffix('.report.json').exists():
        raise ValueError('fresh owned output below video/out/short0219 required')
    out.parent.mkdir(parents=True, exist_ok=True)
    command = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-n', '-filter_threads', '1',
        '-framerate', '30', '-i', str(frames / '%05d.jpg'), '-i', str(AUDIO),
        '-map', '0:v:0', '-map', '1:a:0', '-frames:v', str(FRAMES),
        '-vf', 'scale=in_range=pc:out_range=tv:out_color_matrix=bt709,format=yuv420p',
        '-c:v', 'libx264', '-profile:v', 'high', '-preset', 'medium', '-crf', '18', '-threads', '2',
        '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709', '-color_range', 'tv',
        '-c:a', 'copy', '-map_metadata', '-1', '-movflags', '+faststart', str(out)]
    run(command)
    audio_proof = packets(AUDIO)
    if packets(out) != audio_proof:
        raise ValueError('approved audio packets/timestamps changed')
    probe = json.loads(run(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(out)]))
    video = next(s for s in probe['streams'] if s['codec_type'] == 'video')
    count = int(json.loads(run(['ffprobe', '-v', 'error', '-threads', '1', '-select_streams', 'v:0',
        '-count_frames', '-show_entries', 'stream=nb_read_frames', '-of', 'json', str(out)]))['streams'][0]['nb_read_frames'])
    if (count, int(video['nb_frames']), video['width'], video['height'], video['avg_frame_rate']) != (FRAMES, FRAMES, 1920, 1080, '30/1'):
        raise ValueError('encoded video format/count differs')
    receipt = dict(film=out.name, sha256=sha(out), bytes=out.stat().st_size, durationSeconds=FRAMES/30,
        frames=FRAMES, framesDecoded=count, musicCopiedExactly=True, preparedAudioSha256=AUDIO_SHA,
        audioPacketAndTimestampSha256=audio_proof, render=meta, ffprobe=probe, command=command)
    out.with_suffix('.report.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({key: receipt[key] for key in ['film', 'sha256', 'bytes', 'durationSeconds', 'musicCopiedExactly']}))


if __name__ == '__main__':
    main()
