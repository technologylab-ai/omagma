#!/usr/bin/env python3
"""Encode the reordered picture while copying the approved music packets exactly."""
import argparse,hashlib,json,os,subprocess,sys
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'video/tools'))
from host_lock import owner,identity,start_ticks
sys.path.insert(0,str(ROOT/'video/short027'))
from encode import faststart

def run(args):
    r=subprocess.run(args,capture_output=True,text=True)
    if r.returncode:raise RuntimeError(r.stderr[-4000:])
    return r.stdout

def audio_packets(path):
    # Includes payload, timestamps and packet duration: no music re-encoding,
    # gain processing, trimming, shifting or encoder-priming change is allowed.
    data=run(['ffprobe','-v','error','-select_streams','a:0','-show_packets','-show_entries','packet=pts,dts,duration,data_hash,side_data_list','-show_data_hash','sha256','-of','json',str(path)])
    return hashlib.sha256(json.dumps(json.loads(data),sort_keys=True).encode()).hexdigest()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--approved',type=Path,required=True)
    p.add_argument('--expected-sha256',required=True)
    a=p.parse_args();lock=owner();who=identity(lock) if lock else None
    if not lock or lock.get('token')!=os.environ.get('HOST_TOKEN') or not who or start_ticks(who[0])!=who[1]:raise RuntimeError('matching live host reservation required')
    if hashlib.sha256(a.approved.read_bytes()).hexdigest()!=a.expected_sha256:raise RuntimeError('approved music/movie source changed')
    cache=ROOT/'video/cache/short027';source=cache/'aligned-frames';patch=cache/'flow-patch-frames';frames=cache/'flow-frames'
    plan=json.loads((ROOT/'video/short027/flow.json').read_text());meta=json.loads((patch/'render.json').read_text());n=plan['frameCount']
    first=round(meta['from']*30);last=round(meta['to']*30)
    if meta['scale']!=1 or meta['step']!=1 or meta['count']!=last-first or meta['film']['parts']!=plan['parts']:raise RuntimeError('wrong full-resolution reordered patch')
    if len(list(source.glob('*.jpg')))!=n or len(list(patch.glob('*.jpg')))!=last-first:raise RuntimeError('picture frame set incomplete')
    if frames.exists():raise RuntimeError('new output frame directory required')
    frames.mkdir(mode=0o700)
    for i in range(n):os.link((patch/f'{i-first:05d}.jpg') if first<=i<last else (source/f'{i:05d}.jpg'),frames/f'{i:05d}.jpg')
    (frames/'render.json').write_text(json.dumps({'count':n,'scale':1,'step':1,'sampleFps':30,'from':0,'to':plan['duration'],'film':{**meta['film'],'parts':plan['parts']},'replacedFrames':[first,last]},indent=2)+'\n')
    (frames/'.short027-render').write_text('owned media output\n')
    out=ROOT/'video/out/omagma-v0.2.7-flow.mp4'
    if out.exists():raise RuntimeError('preserve prior output movie')
    cmd=['ffmpeg','-hide_banner','-loglevel','error','-n','-framerate','30','-i',str(frames/'%05d.jpg'),'-i',str(a.approved),'-map','0:v:0','-map','1:a:0','-frames:v',str(n),'-vf','scale=in_range=pc:out_range=tv:out_color_matrix=bt709,format=yuv420p','-c:v','libx264','-profile:v','high','-preset','slow','-crf','18','-threads','4','-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709','-color_range','tv','-c:a','copy','-map_metadata','-1','-movflags','+faststart',str(out)]
    run(cmd)
    approved_audio=audio_packets(a.approved)
    if audio_packets(out)!=approved_audio:raise RuntimeError('approved music packets/timestamps changed')
    probe=json.loads(run(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(out)]));v=next(s for s in probe['streams'] if s['codec_type']=='video')
    if int(v['nb_frames'])!=n or v['width']!=1920 or v['height']!=1080 or v['avg_frame_rate']!='30/1' or abs(float(v['duration'])-plan['duration'])>1/30:raise RuntimeError('picture duration/format changed')
    receipt={'film':str(out),'sha256':hashlib.sha256(out.read_bytes()).hexdigest(),'durationSeconds':plan['duration'],'frames':n,'approvedSourceSha256':a.expected_sha256,'musicCopiedExactly':True,'audioPacketAndTimestampSha256':approved_audio,'changedPictureFrameRange':[first,last],'flowPlanSha256':hashlib.sha256((ROOT/'video/short027/flow.json').read_bytes()).hexdigest(),'ffprobe':probe,'faststart':faststart(out),'command':cmd}
    out.with_suffix('.report.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps({k:receipt[k] for k in ('film','sha256','durationSeconds','musicCopiedExactly','changedPictureFrameRange')},indent=2))

if __name__=='__main__':main()
