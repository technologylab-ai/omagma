#!/usr/bin/env python3
"""Fit a reviewed frame set to music by extending only its settled final still."""
import argparse,json,os,sys
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'video/tools'))
from host_lock import owner,identity,start_ticks

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--frames',type=Path,default=ROOT/'video/cache/short027/smooth-frames')
    p.add_argument('--timeline',type=Path,default=ROOT/'video/short027/aligned.json')
    p.add_argument('--out',type=Path,default=ROOT/'video/cache/short027/aligned-frames')
    a=p.parse_args();lock=owner();who=identity(lock) if lock else None
    if not lock or lock.get('token')!=os.environ.get('HOST_TOKEN') or not who or start_ticks(who[0])!=who[1]:raise RuntimeError('matching live host reservation required')
    source=json.loads((a.frames/'render.json').read_text());plan=json.loads(a.timeline.read_text())
    old=source['film'];n=source['count'];extra=plan['frameCount']-n
    if source['step']!=1 or source['scale']!=1 or len(list(a.frames.glob('*.jpg')))!=n:raise RuntimeError('complete approved full-resolution source frames required')
    if not 0<extra<=30 or plan['fps']!=old['fps'] or plan['parts'][:-1]!=old['parts'][:-1]:raise RuntimeError('only a short settled final hold may change')
    last=plan['parts'][-1];prior=old['parts'][-1]
    if last['name']!='outro' or {k:v for k,v in last.items() if k!='frameOut'}!={k:v for k,v in prior.items() if k!='frameOut'}:raise RuntimeError('final still must retain its original start and scene')
    if a.out.resolve()==a.frames.resolve() or a.out.exists():raise RuntimeError('new frame directory required; preserve approved source')
    a.out.mkdir(parents=True,mode=0o700)
    for i in range(plan['frameCount']):os.link(a.frames/f'{min(i,n-1):05d}.jpg',a.out/f'{i:05d}.jpg')
    meta={**source,'film':{**old,'frameCount':plan['frameCount'],'duration':plan['duration'],'parts':plan['parts']},'count':plan['frameCount'],'to':plan['duration'],'revision':'aligned','approvedSourceFrames':str(a.frames),'sourceFrameCount':n,'extraFinalStillFrames':extra,'allEarlierFramesUnchanged':True}
    (a.out/'render.json').write_text(json.dumps(meta,indent=2)+'\n')
    (a.out/'.short027-render').write_text('owned media output\n')
    print(json.dumps({'frames':plan['frameCount'],'extraFinalStillFrames':extra,'allEarlierFramesUnchanged':True}))

if __name__=='__main__':main()
