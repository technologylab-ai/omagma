#!/usr/bin/env python3
"""Encode new pictures and preserve the approved soundtrack packet for packet."""
import argparse,hashlib,json,os,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path[:0]=[str(ROOT/'video/short027'),str(ROOT/'video/tools')]
from encode_flow import audio_packets, run
from encode import faststart
from host_lock import owner,identity,start_ticks

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--frames',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
 lock=owner();who=identity(lock) if lock else None
 if not lock or lock.get('token')!=os.environ.get('HOST_TOKEN') or not who or start_ticks(who[0])!=who[1]:raise RuntimeError('matching live reservation required')
 approved=ROOT/'video/out/omagma-v0.2.7-flow.mp4';approvedsha='a459f91f2d67f99f2e7bf68ec265047703dfce20bcdb68ab8568acc1d27179f9'
 if hashlib.sha256(approved.read_bytes()).hexdigest()!=approvedsha:raise RuntimeError('approved source changed')
 frames=a.frames.resolve();out=a.out.resolve();meta=json.loads((frames/'render.json').read_text())
 if not (frames/'.short028-render').exists() or meta['count']!=2527 or meta['step']!=1 or meta['scale']!=1 or len(list(frames.glob('*.jpg')))!=2527:raise RuntimeError('incomplete full-resolution picture')
 if not str(out).startswith(str(ROOT/'video/out')+'/') or out.exists():raise RuntimeError('new owned output required')
 cmd=['ffmpeg','-hide_banner','-loglevel','error','-n','-framerate','30','-i',str(frames/'%05d.jpg'),'-i',str(approved),'-map','0:v:0','-map','1:a:0','-frames:v','2527','-vf','scale=in_range=pc:out_range=tv:out_color_matrix=bt709,format=yuv420p','-c:v','libx264','-profile:v','high','-preset','slow','-crf','18','-threads','4','-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709','-color_range','tv','-c:a','copy','-map_metadata','-1','-movflags','+faststart',str(out)]
 run(cmd);audio=audio_packets(approved)
 if audio_packets(out)!=audio:raise RuntimeError('approved audio packets/timestamps changed')
 probe=json.loads(run(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(out)]));v=next(s for s in probe['streams'] if s['codec_type']=='video')
 if int(v['nb_frames'])!=2527 or (v['width'],v['height'],v['avg_frame_rate'])!=(1920,1080,'30/1'):raise RuntimeError('incorrect video format')
 receipt={'film':str(out),'sha256':hashlib.sha256(out.read_bytes()).hexdigest(),'durationSeconds':2527/30,'frames':2527,'musicCopiedExactly':True,'approvedSourceSha256':approvedsha,'audioPacketAndTimestampSha256':audio,'faststart':faststart(out),'ffprobe':probe,'command':cmd,'publicationHeld':True}
 out.with_suffix('.report.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps({k:receipt[k] for k in ['film','durationSeconds','musicCopiedExactly','sha256']}))
if __name__=='__main__':main()
