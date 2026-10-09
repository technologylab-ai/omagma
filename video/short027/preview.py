#!/usr/bin/env python3
"""Encode a real-time motion proxy from sparse deterministic movie frames."""
from __future__ import annotations
import argparse,json,os,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'video/tools'))
from host_lock import owner,identity,start_ticks

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--frames',type=Path,default=ROOT/'video/cache/short027/calm-preview-frames')
    p.add_argument('--out',type=Path,default=ROOT/'video/cache/short027/calm-watchability-preview.mp4')
    p.add_argument('--audio',type=Path,default=ROOT/'video/cache/short027/soundtrack-calmer.wav')
    a=p.parse_args();value=owner();who=identity(value) if value else None
    if not value or value.get('token')!=os.environ.get('HOST_TOKEN') or not who or start_ticks(who[0])!=who[1]:raise RuntimeError('matching live host reservation required')
    meta=json.loads((a.frames/'render.json').read_text())
    count=len(list(a.frames.glob('*.jpg')))
    if count!=meta['count']:raise RuntimeError('proxy frame count differs from render receipt')
    if not 5<=meta['sampleFps']<=30:raise RuntimeError('invalid real-time proxy fps')
    start,end=meta['from'],meta['to'];duration=end-start
    audio=a.audio
    command=['ffmpeg','-hide_banner','-loglevel','error','-y','-framerate',str(meta['sampleFps']),'-i',str(a.frames/'%05d.jpg'),'-ss',str(start),'-i',str(audio),'-map','0:v:0','-map','1:a:0','-t',str(duration),'-c:v','libx264','-preset','fast','-crf','19','-threads','3','-pix_fmt','yuv420p','-c:a','aac','-b:a','192k','-ar','48000','-ac','2','-map_metadata','-1','-movflags','+faststart',str(a.out)]
    subprocess.run(command,check=True)
    receipt={'file':str(a.out),'sourceFilmTime':[start,end],'duration':duration,'sampleFps':meta['sampleFps'],'count':count,'realTime':True,'renderReceipt':str(a.frames/'render.json'),'encoder':command}
    a.out.with_suffix('.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt,indent=2))
if __name__=='__main__':main()
