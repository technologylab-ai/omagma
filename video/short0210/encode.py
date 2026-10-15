#!/usr/bin/env python3
"""Encode the v0.2.10 picture and copy the approved soundtrack packet for packet."""
import argparse,hashlib,json,os,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path[:0]=[str(ROOT/'video/short027'),str(ROOT/'video/tools')]
from encode_flow import audio_packets, run
from encode import faststart
from host_lock import owner,identity,start_ticks
FRAMES=2527;DURATION=FRAMES/30
APPROVED=ROOT/'video/out/omagma-v0.2.7-flow.mp4';APPROVED_SHA='a459f91f2d67f99f2e7bf68ec265047703dfce20bcdb68ab8568acc1d27179f9'
CACHE=ROOT/'video/cache/short0210'

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--frames',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
 lock=owner();who=identity(lock) if lock else None
 if not lock or lock.get('token')!=os.environ.get('HOST_TOKEN') or not who or start_ticks(who[0])!=who[1]:raise RuntimeError('matching live reservation required')
 if hashlib.sha256(APPROVED.read_bytes()).hexdigest()!=APPROVED_SHA:raise RuntimeError('approved source changed')
 frames=a.frames.resolve();out=a.out.resolve();report=out.with_suffix('.report.json')
 if not frames.is_relative_to(CACHE) or frames==CACHE or not (frames/'.short0210-render').exists():raise RuntimeError('owned short0210 render directory required')
 meta=json.loads((frames/'render.json').read_text());film=meta.get('film') or {}
 if meta.get('stills') or meta.get('partial') is not False or meta.get('count')!=FRAMES or meta.get('step')!=1 or meta.get('scale')!=1 or meta.get('from')!=0 or abs(meta.get('to',0)-DURATION)>1e-6 or meta.get('firstFrame')!=0 or meta.get('lastFrame')!=FRAMES:raise RuntimeError('complete full-resolution render required (partial proofs, stills and sampled renders are refused)')
 if film.get('frameCount')!=FRAMES or film.get('fps')!=30 or (film.get('width'),film.get('height'))!=(1920,1080):raise RuntimeError('render metadata does not match the film clock')
 pictures=sorted(x.name for x in frames.glob('*.jpg'))
 if pictures!=[f'{i:05d}.jpg' for i in range(FRAMES)]:raise RuntimeError('expected exactly 2527 consecutive JPEG frames')
 if out.suffix!='.mp4' or not out.is_relative_to(ROOT/'video/out') or out.exists() or report.exists():raise RuntimeError('new owned output below video/out required; earlier films are never overwritten')
 cmd=['ffmpeg','-hide_banner','-loglevel','error','-n','-framerate','30','-i',str(frames/'%05d.jpg'),'-i',str(APPROVED),'-map','0:v:0','-map','1:a:0','-frames:v',str(FRAMES),'-vf','scale=in_range=pc:out_range=tv:out_color_matrix=bt709,format=yuv420p','-c:v','libx264','-profile:v','high','-preset','slow','-crf','18','-threads','4','-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709','-color_range','tv','-c:a','copy','-map_metadata','-1','-movflags','+faststart',str(out)]
 run(cmd);audio=audio_packets(APPROVED)
 if audio_packets(out)!=audio:raise RuntimeError('approved audio packets/timestamps changed')
 probe=json.loads(run(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(out)]));v=next(s for s in probe['streams'] if s['codec_type']=='video')
 counted=int(json.loads(run(['ffprobe','-v','error','-select_streams','v:0','-count_frames','-show_entries','stream=nb_read_frames','-of','json',str(out)]))['streams'][0]['nb_read_frames'])
 if int(v['nb_frames'])!=FRAMES or counted!=FRAMES or (v['width'],v['height'],v['avg_frame_rate'],v['r_frame_rate'])!=(1920,1080,'30/1','30/1'):raise RuntimeError('incorrect video format, rate or frame count')
 receipt={'film':str(out),'sha256':hashlib.sha256(out.read_bytes()).hexdigest(),'durationSeconds':DURATION,'frames':FRAMES,'framesDecoded':counted,'musicCopiedExactly':True,'approvedSourceSha256':APPROVED_SHA,'audioPacketAndTimestampSha256':audio,'faststart':faststart(out),'render':{k:meta.get(k) for k in ('manifest','manifestSha256','sources','viewport')},'ffprobe':probe,'command':cmd,'publicationHeld':True}
 report.write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps({k:receipt[k] for k in ['film','durationSeconds','musicCopiedExactly','sha256','publicationHeld']}))
if __name__=='__main__':main()
