#!/usr/bin/env python3
"""Copy a newly encoded, normally played chapter film to the user's video folder."""
import argparse, datetime, hashlib, json, os
from pathlib import Path
import shutil, subprocess, sys
ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / 'video/cache/short0210'
sys.path.insert(0, str(ROOT / 'video/tools'))
from host_lock import owner, identity, start_ticks
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser();p.add_argument('--attempt',required=True);a=p.parse_args()
 lock=owner();who=identity(lock) if lock else None
 assert lock and lock.get('token')==os.environ.get('HOST_TOKEN') and who and start_ticks(who[0])==who[1]
 source=ROOT/('video/out/omagma-v0.2.10-chapters-'+a.attempt+'.mp4')
 report=json.loads(source.with_suffix('.report.json').read_text());review=CACHE/('chapter-playback-'+a.attempt)
 playback=json.loads((review/'receipt.json').read_text());hashes=json.loads((CACHE/('chapter-source-hashes-'+a.attempt+'.json')).read_text())
 assert playback['passed'] and report['musicCopiedExactly'] and sha(source)==report['sha256']
 assert all(sha(ROOT/f)==h for f,h in hashes.items()),'picture inputs changed after render'
 progressive=None
 if not any(s['kind']=='chapter' for s in json.loads((ROOT/'video/short0210/chapter-plan.json').read_text())['shots']):
  progressive=json.loads((CACHE/('progressive-audit-'+a.attempt+'.json')).read_text())
  assert progressive['passed'] and progressive['counts']['frames']==report['frames'] and progressive['errorCount']==0
  native_clock=json.loads((CACHE/('progressive-native-clock-'+a.attempt+'.json')).read_text())
  assert native_clock['allLaterNativeActionsUnchanged'] and native_clock['contactsAndReviewsPreserved']
 manifest=CACHE/'revision-08/assets-manifest.json';m=json.loads(manifest.read_text());capture=json.loads((manifest.parent/m['captureReceipt']).read_text())
 assert capture['syntheticOnly'] and capture['liveProviderWrites']==0
 for x in m['assets'].values():assert sha(ROOT/x['file'].lstrip('/'))==x['sha256']
 destination=Path.home()/'Videos/Omagma';destination.mkdir(parents=True,exist_ok=True)
 stem='omagma-v0.2.10-chapters-'+datetime.datetime.now().astimezone().strftime('%Y%m%d-%H%M%S')
 target=destination/(stem+'.mp4');assert not target.exists();shutil.copy2(source,target);assert sha(target)==sha(source)
 poster=destination/(stem+'-poster.png');subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-n','-ss','5.5','-i',str(target),'-frames:v','1',str(poster)],check=True)
 sheet=destination/(stem+'-contact-sheet.jpg');seconds=[1,5,9,14,19,21,27,32,36,39,43,47,54,58,62,66,69,73,78,83,88,94,96]
 subprocess.run(['magick','montage',*[str(review/('second-'+str(i).zfill(2)+'.png')) for i in seconds],'-set','label','%f','-font','/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf','-pointsize','18','-fill','#a3eff0','-background','#0b1017','-geometry','640x360+8+24','-tile','3x',str(sheet)],check=True)
 proof={k:report[k] for k in ['sha256','durationSeconds','frames','musicCopiedExactly','approvedSourceSha256','preparedSoundtrackSha256','soundtrackPlanSha256','continuousOriginalThrough','audioPacketAndTimestampSha256','faststart','publicationHeld']}
 proof.update(width=1920,height=1080,fps=30,sourceAppBinary=capture['binary'],pictureSourceHashes=hashes,normalSpeedPlaybackPassed=True,decodedFrames=playback['decodedFrames'],syntheticAccountsOnly=True,productionProviderWrites=0,reviewScope='Actual Opus5.5 xhigh progressive-motion direction and native-source PNG inspection; prior Opus/Astra story and composed-still reviews; root composed progressive proofs, all-frame geometry and shortcut-cue lead checks, then actual encoded1x muted playback. No audio-listening claim.',previousRejectedMovie='omagma-v0.2.10-chapters-20261016-001636.mp4')
 if progressive:proof.update(progressiveCaptionChecks=progressive['counts'],standaloneChapterCards=0,allLaterNativeActionsUnchanged=True,minimumSettledShortcutLeadSeconds=0.3)
 proof_path=destination/(stem+'-report.json');proof_path.write_text(json.dumps(proof,indent=2)+'\n')
 result=dict(movie=str(target),poster=str(poster),contactSheet=str(sheet),report=str(proof_path),sha256=sha(target),durationSeconds=report['durationSeconds'])
 (CACHE/'delivery.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if __name__=='__main__':main()
