#!/usr/bin/env python3
"""Deliver only verified movie bytes to the user's Videos/Omagma directory."""
import datetime,hashlib,html,json,os,shutil,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];CACHE=ROOT/'video/cache/short028'
sys.path.insert(0,str(ROOT/'video/tools'))
from host_lock import owner,identity,start_ticks
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 lock=owner();who=identity(lock) if lock else None
 assert lock and lock.get('token')==os.environ.get('HOST_TOKEN') and who and start_ticks(who[0])==who[1], 'matching live reservation required'
 movie=ROOT/'video/out/omagma-v0.2.8-whats-new-final-20261012.mp4';report=json.loads(movie.with_suffix('.report.json').read_text())
 playback=json.loads((CACHE/'playback-review/receipt.json').read_text());assert playback['passed'] and report['musicCopiedExactly'] and sha(movie)==report['sha256']
 hashes=json.loads((CACHE/'final-source-hashes.json').read_text());assert all(sha(ROOT/p)==h for p,h in hashes.items())
 stamp=datetime.datetime.now().astimezone().strftime('%Y%m%d-%H%M%S');stem='omagma-v0.2.8-whats-new-'+stamp
 dest=Path.home()/'Videos/Omagma';dest.mkdir(parents=True,exist_ok=True);target=dest/(stem+'.mp4');assert not target.exists();shutil.copy2(movie,target);assert sha(target)==sha(movie)
 poster=dest/(stem+'-poster.png')
 subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-n','-ss','70','-i',str(target),'-frames:v','1',str(poster)],check=True)
 shots=CACHE/'delivery-stills';shots.mkdir(mode=0o700)
 seconds=[0,7,12,17,20,24,30,32,34,38,42,44,47,50,53,55,58,61,62,64,66,68,70,76,81]
 # These are normal-speed decoded movie screenshots from the accepted review.
 files=[CACHE/'playback-review'/('second-'+str(t).zfill(2)+'.png') for t in seconds]
 sheet=dest/(stem+'-contact-sheet.jpg')
 subprocess.run(['magick','montage',*[str(p) for p in files],'-set','label','%f','-font','/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf','-pointsize','18','-fill','#ff9e61','-background','#111620','-geometry','640x360+8+24','-tile','3x',str(sheet)],check=True)
 watch=dest/(stem+'.html')
 watch.write_text('<!doctype html><html><head><meta charset="utf-8"><title>Omagma v0.2.8 · What’s new</title><style>body{margin:0;padding:32px;background:#080605;color:#f7ede5;font:18px system-ui}main{max-width:1600px;margin:auto}h1{color:#ff9e61}video{width:100%;display:block;border-radius:12px}p{color:#cbb7a9}</style></head><body><main><h1>Omagma comes full circle.</h1><video controls playsinline preload="metadata" poster="'+html.escape(poster.name)+'" src="'+html.escape(target.name)+'"></video><p>v0.2.8 review copy · publication held. Browser build: experimental, not for everyday use. RAM figures are the author’s observations of different sessions and workloads.</p></main></body></html>')
 public={k:report[k] for k in ['sha256','durationSeconds','frames','musicCopiedExactly','approvedSourceSha256','audioPacketAndTimestampSha256','faststart','publicationHeld']}
 public.update(width=1920,height=1080,fps=30,normalSpeedPlaybackPassed=True,observedDecodedFrames=playback['decodedFrames'],maxOuterCornerStep=playback['maxOuterCornerStep'],phaseHandoffFrames=json.loads((CACHE/'decoded-boundaries/receipt.json').read_text())['count'],fictionalAccountsOnly=True,productionProviderWrites=0,sourceAppCommit='226365a295d2fcf2fc21fa0a559f62cc74faa9fb',pictureSourceHashes=hashes,browserExperimental=True,memoryFigure='Author observation; not a benchmark',visualReview='Two completed actual Claude Opus5.5 still/source reviews with requested xhigh effort, followed by root corrections and encoded playback checks')
 proof=dest/(stem+'-report.json');proof.write_text(json.dumps(public,indent=2)+'\n')
 result={'movie':str(target),'watch':str(watch),'poster':str(poster),'contactSheet':str(sheet),'report':str(proof),'sha256':public['sha256']}
 (CACHE/'delivery.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if __name__=='__main__':main()
