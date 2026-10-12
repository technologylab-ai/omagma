#!/usr/bin/env python3
"""Deliver only verified movie bytes to the user's Videos/Omagma directory."""
import argparse,datetime,hashlib,html,json,os,shutil,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];CACHE=ROOT/'video/cache/short028'
sys.path.insert(0,str(ROOT/'video/tools'))
from host_lock import owner,identity,start_ticks
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser();p.add_argument('--movie',type=Path,default=ROOT/'video/out/omagma-v0.2.8-whats-new-final-20261012.mp4');p.add_argument('--review',type=Path,default=CACHE/'playback-review');p.add_argument('--hashes',type=Path,default=CACHE/'final-source-hashes.json');p.add_argument('--tag',default='whats-new');p.add_argument('--poster-second',default='70');args=p.parse_args()
 lock=owner();who=identity(lock) if lock else None
 assert lock and lock.get('token')==os.environ.get('HOST_TOKEN') and who and start_ticks(who[0])==who[1], 'matching live reservation required'
 movie=args.movie.resolve();report=json.loads(movie.with_suffix('.report.json').read_text())
 playback=json.loads((args.review/'receipt.json').read_text());assert playback['passed'] and report['musicCopiedExactly'] and sha(movie)==report['sha256']
 hashes=json.loads(args.hashes.read_text());assert all(sha(ROOT/p)==h for p,h in hashes.items())
 assert args.tag in ['whats-new','whats-new-recut','whats-new-story']
 stamp=datetime.datetime.now().astimezone().strftime('%Y%m%d-%H%M%S');stem='omagma-v0.2.8-'+args.tag+'-'+stamp
 dest=Path.home()/'Videos/Omagma';dest.mkdir(parents=True,exist_ok=True);target=dest/(stem+'.mp4');assert not target.exists();shutil.copy2(movie,target);assert sha(target)==sha(movie)
 poster=dest/(stem+'-poster.png')
 subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-n','-ss',args.poster_second,'-i',str(target),'-frames:v','1',str(poster)],check=True)
 seconds=[0,6,11,14,16,20,23,26,28,31,33,36,39,42,46,50,53,56,59,62,66,70,76,81] if args.tag!='whats-new' else [0,7,12,17,20,24,30,32,34,38,42,44,47,50,53,55,58,61,62,64,66,68,70,76,81]
 # These are normal-speed decoded movie screenshots from the accepted review.
 files=[args.review/('second-'+str(t).zfill(2)+'.png') for t in seconds]
 sheet=dest/(stem+'-contact-sheet.jpg')
 subprocess.run(['magick','montage',*[str(p) for p in files],'-set','label','%f','-font','/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf','-pointsize','18','-fill','#ff9e61','-background','#111620','-geometry','640x360+8+24','-tile','3x',str(sheet)],check=True)
 watch=dest/(stem+'.html')
 watch.write_text('<!doctype html><html><head><meta charset="utf-8"><title>Omagma v0.2.8 · What’s new</title><style>body{margin:0;padding:32px;background:#07090d;color:#f3f5f7;font:18px system-ui}main{max-width:1600px;margin:auto}h1{color:#ff9e61}video{width:100%;display:block;border-radius:12px}p{color:#adb8c6}</style></head><body><main><h1>Omagma v0.2.8 · What’s new</h1><video controls playsinline preload="metadata" poster="'+html.escape(poster.name)+'" src="'+html.escape(target.name)+'"></video><p>v0.2.8 review copy · publication held. Browser tech demo · not for everyday use.</p></main></body></html>')
 public={k:report[k] for k in ['sha256','durationSeconds','frames','musicCopiedExactly','approvedSourceSha256','audioPacketAndTimestampSha256','faststart','publicationHeld']}
 public.update(width=1920,height=1080,fps=30,normalSpeedPlaybackPassed=True,observedDecodedFrames=playback['decodedFrames'],maxOuterCornerStep=playback['maxOuterCornerStep'],fictionalAccountsOnly=True,productionProviderWrites=0,sourceAppCommit='226365a295d2fcf2fc21fa0a559f62cc74faa9fb',pictureSourceHashes=hashes,browserTechDemo=True,memoryFigure='3 accounts · ~125 MB',visualReview='Actual Claude Opus5.5 review of story sources/stills with requested xhigh effort; root encoded playback and transition checks',realBrowserChrome=args.tag!='whats-new')
 proof=dest/(stem+'-report.json');proof.write_text(json.dumps(public,indent=2)+'\n')
 result={'movie':str(target),'watch':str(watch),'poster':str(poster),'contactSheet':str(sheet),'report':str(proof),'sha256':public['sha256']}
 (CACHE/({'whats-new-recut':'recut-delivery.json','whats-new-story':'story-delivery.json'}.get(args.tag,'delivery.json'))).write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if __name__=='__main__':main()
