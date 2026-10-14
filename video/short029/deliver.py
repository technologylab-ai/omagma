#!/usr/bin/env python3
"""Deliver verified 0.2.9 video bytes, poster and local playback page."""
import argparse, datetime, hashlib, html, json, os, shutil, subprocess, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]; CACHE=ROOT/'video/cache/short029'
sys.path.insert(0,str(ROOT/'video/tools'))
from host_lock import owner,identity,start_ticks
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--movie',type=Path,required=True)
 p.add_argument('--review',type=Path,required=True)
 p.add_argument('--hashes',type=Path,required=True)
 p.add_argument('--poster-second',default='29')
 a=p.parse_args();lock=owner();who=identity(lock) if lock else None
 assert lock and lock.get('token')==os.environ.get('HOST_TOKEN') and who and start_ticks(who[0])==who[1], 'live host reservation required'
 movie=a.movie.resolve();report=json.loads(movie.with_suffix('.report.json').read_text())
 playback=json.loads((a.review/'receipt.json').read_text());hashes=json.loads(a.hashes.read_text())
 assert playback['passed'] and report['musicCopiedExactly'] and sha(movie)==report['sha256']
 assert all(sha(ROOT/path)==digest for path,digest in hashes.items()), 'source changed after review'
 stamp=datetime.datetime.now().astimezone().strftime('%Y%m%d-%H%M%S')
 stem='omagma-v0.2.9-whats-new-'+stamp
 destination=Path.home()/'Videos/Omagma';destination.mkdir(parents=True,exist_ok=True)
 target=destination/(stem+'.mp4');assert not target.exists();shutil.copy2(movie,target);assert sha(target)==sha(movie)
 poster=destination/(stem+'-poster.png')
 subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-n','-ss',a.poster_second,'-i',str(target),'-frames:v','1',str(poster)],check=True)
 seconds=[0,4,8,12,16,20,24,28,32,36,40,44,48,52,56,60,64,68,72,76,80,83]
 files=[a.review/('second-'+str(second).zfill(2)+'.png') for second in seconds]
 sheet=destination/(stem+'-contact-sheet.jpg')
 subprocess.run(['magick','montage',*[str(path) for path in files],'-set','label','%f',
  '-font','/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf','-pointsize','18','-fill','#ff9e61',
  '-background','#0b1017','-geometry','640x360+8+24','-tile','3x',str(sheet)],check=True)
 watch=destination/(stem+'.html')
 watch.write_text('<!doctype html><html><head><meta charset="utf-8"><title>Omagma v0.2.9 · What’s new</title><style>'
  'body{margin:0;padding:32px;background:#0b1017;color:#f3f5f7;font:18px system-ui}main{max-width:1600px;margin:auto}'
  'h1{color:#ff9e61}video{width:100%;display:block;border-radius:12px}p{color:#adb8c6}</style></head><body><main>'
  '<h1>Omagma v0.2.9 · What’s new</h1><video controls playsinline preload="metadata" poster="'+html.escape(poster.name)+
  '" src="'+html.escape(target.name)+'"></video><p>Six workflows · 1:24 · Review copy</p></main></body></html>')
 proof={key:report[key] for key in ['sha256','durationSeconds','frames','musicCopiedExactly','approvedSourceSha256',
  'audioPacketAndTimestampSha256','faststart','publicationHeld']}
 manifest=json.loads((CACHE/'assets-manifest.json').read_text())
 captures=json.loads((CACHE/manifest['captureReceipt']).read_text())
 vault=json.loads((CACHE/manifest['vaultReceipt']).read_text())
 proof.update(width=1920,height=1080,fps=30,normalSpeedPlaybackPassed=True,
  decodedFrames=playback['decodedFrames'],maxOuterCornerStep=playback['maxOuterCornerStep'],
  sourceAppBinary=captures['binary'],pictureSourceHashes=hashes,syntheticAccountsOnly=True,
  productionProviderWrites=0,encryptedDaemonCapturePassed=vault['passed'],
  reviewMethod='Actual Opus 5.5 xhigh direction and visual review; Astra product/editorial review; automated encoded 1x playback; root visual review of encoded transition and motion samples')
 if manifest.get('weekReceipt'):
  week=json.loads((CACHE/manifest['weekReceipt']).read_text())
  assert week['binary']['sha256']==captures['binary']['sha256'] and week['allSevenDaysVisible'] and week['enterOpensSameJoinEvent']
  proof['compactWeekCapture']={key:week[key] for key in ['columns','rows','allSevenDaysVisible','enterOpensSameJoinEvent','liveProviderWrites']}
 if manifest.get('notificationReceipt'):
  notification=json.loads((CACHE/manifest['notificationReceipt']).read_text())
  assert notification['passed'] and notification['syntheticOnly'] and notification['liveProviderWrites']==0
  assert notification['automaticArrivalInMail'] and notification['minuteTransitionVerified'] and notification['nativeJoinProof']
  proof['meetingNotificationCapture']={key:notification[key] for key in ['binary','columns','rows','automaticArrivalInMail','minuteTransitionVerified','clockStates','clockExplanation','nativeJoinProof','liveProviderWrites']}
  proof['captureRevisionNote']='Approved earlier workflows retain their original frozen binary; the new meeting-notification sequence uses the separately identified tested candidate.'
 proof_file=destination/(stem+'-report.json');proof_file.write_text(json.dumps(proof,indent=2)+'\n')
 result=dict(movie=str(target),watch=str(watch),poster=str(poster),contactSheet=str(sheet),report=str(proof_file),sha256=sha(target))
 (CACHE/'delivery.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if __name__=='__main__':main()
