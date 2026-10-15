#!/usr/bin/env python3
"""Deliver the reviewed MP4, with exact native and soundtrack provenance."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / 'video/cache/short0210'
sys.path.insert(0, str(ROOT / 'video/tools'))
from host_lock import owner, identity, start_ticks


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--movie', type=Path, required=True)
    p.add_argument('--review', type=Path, required=True)
    p.add_argument('--hashes', type=Path, required=True)
    p.add_argument('--manifest', type=Path, required=True)
    p.add_argument('--poster-second', default='18.6')
    a = p.parse_args()
    lock = owner()
    who = identity(lock) if lock else None
    assert lock and lock.get('token') == os.environ.get('HOST_TOKEN') and who and start_ticks(who[0]) == who[1], 'matching live reservation required'
    movie = a.movie.resolve()
    report = json.loads(movie.with_suffix('.report.json').read_text())
    playback = json.loads((a.review / 'receipt.json').read_text())
    hashes = json.loads(a.hashes.read_text())
    assert playback['passed'] and report['musicCopiedExactly'] and sha(movie) == report['sha256']
    assert all(sha(ROOT / path) == digest for path, digest in hashes.items()), 'source changed after review'
    manifest_path = a.manifest.resolve()
    manifest = json.loads(manifest_path.read_text())
    capture = json.loads((manifest_path.parent / manifest['captureReceipt']).read_text())
    assert capture['syntheticOnly'] and capture.get('liveProviderWrites', 0) == 0
    for asset in manifest['assets'].values():
        path = ROOT / asset['file'].lstrip('/') if asset['file'].startswith('/') else manifest_path.parent / asset['file']
        assert sha(path) == asset['sha256'], 'native picture changed'
    stamp = datetime.datetime.now().astimezone().strftime('%Y%m%d-%H%M%S')
    destination = Path.home() / 'Videos/Omagma'
    destination.mkdir(parents=True, exist_ok=True)
    stem = 'omagma-v0.2.10-whats-new-' + stamp
    target = destination / (stem + '.mp4')
    assert not target.exists()
    shutil.copy2(movie, target)
    assert sha(target) == sha(movie)
    poster = destination / (stem + '-poster.png')
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-n', '-ss', a.poster_second, '-i', str(target), '-frames:v', '1', str(poster)], check=True)
    seconds = [0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 60, 64, 68, 72, 76, 80, 83]
    sheet = destination / (stem + '-contact-sheet.jpg')
    files = [a.review / ('second-' + str(second).zfill(2) + '.png') for second in seconds]
    subprocess.run(['magick', 'montage', *map(str, files), '-set', 'label', '%f', '-font', '/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf', '-pointsize', '18', '-fill', '#ff9e61', '-background', '#0b1017', '-geometry', '640x360+8+24', '-tile', '3x', str(sheet)], check=True)
    proof = {key: report[key] for key in ['sha256', 'durationSeconds', 'frames', 'musicCopiedExactly', 'approvedSourceSha256', 'audioPacketAndTimestampSha256', 'faststart', 'publicationHeld']}
    proof.update(width=1920, height=1080, fps=30, sourceAppBinary=capture['binary'], pictureSourceHashes=hashes, normalSpeedPlaybackPassed=True, decodedFrames=playback['decodedFrames'], maxOuterCornerStep=playback['maxOuterCornerStep'], syntheticAccountsOnly=True, productionProviderWrites=0, captureReceipt=str(manifest_path.parent / manifest['captureReceipt']), reviewMethod='Actual Opus5.5 xhigh visual direction and review; Astra product and capture continuity review; root temporal picture review; actual encoded 1x muted playback and exact approved-audio packet verification')
    proof_path = destination / (stem + '-report.json')
    proof_path.write_text(json.dumps(proof, indent=2) + '\n')
    result = dict(movie=str(target), poster=str(poster), contactSheet=str(sheet), report=str(proof_path), sha256=sha(target))
    (CACHE / 'delivery.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
