#!/usr/bin/env python3
"""Replace a reviewed movie's soundtrack while copying its video unchanged."""
import argparse,hashlib,json,os,subprocess,sys
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'video/tools'))
from host_lock import owner,identity,start_ticks
sys.path.insert(0,str(ROOT/'video/short027'))
from encode import loudness,faststart

def run(args):
    r=subprocess.run(args,capture_output=True,text=True)
    if r.returncode:raise RuntimeError(r.stderr[-4000:])
    return r.stdout

def probe(path):
    return json.loads(run(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(path)]))

def video_hash(path):
    return run(['ffmpeg','-hide_banner','-loglevel','error','-i',str(path),'-map','0:v:0','-c:v','copy','-an','-f','hash','-hash','sha256','-']).strip()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--video',type=Path,required=True)
    p.add_argument('--expected-video-sha256',required=True)
    p.add_argument('--audio',type=Path,required=True)
    p.add_argument('--plan',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();lock=owner();who=identity(lock) if lock else None
    if not lock or lock.get('token')!=os.environ.get('HOST_TOKEN') or not who or start_ticks(who[0])!=who[1]:raise RuntimeError('matching live host reservation required')
    source_sha=hashlib.sha256(a.video.read_bytes()).hexdigest()
    if source_sha!=a.expected_video_sha256:raise RuntimeError('reviewed source movie differs from expected bytes')
    if a.out.resolve()==a.video.resolve() or a.out.exists():raise RuntimeError('output must be new and must preserve the reviewed source')
    plan=json.loads(a.plan.read_text());before=probe(a.video)
    v=next(s for s in before['streams'] if s['codec_type']=='video')
    duration=plan['frameCount']/plan['fps']
    if abs(float(v['duration'])-duration)>1/plan['fps'] or int(v['nb_frames'])!=plan['frameCount']:raise RuntimeError('soundtrack does not match reviewed picture duration')
    audio=probe(a.audio);wav=next(s for s in audio['streams'] if s['codec_type']=='audio')
    if wav['sample_rate']!='48000' or wav['channels']!=2 or abs(float(wav['duration'])-duration)>1/48000:raise RuntimeError('soundtrack duration/format mismatch')
    a.out.parent.mkdir(parents=True,exist_ok=True)
    command=['ffmpeg','-hide_banner','-loglevel','error','-n','-i',str(a.video),'-i',str(a.audio),'-map','0:v:0','-map','1:a:0','-c:v','copy','-c:a','aac','-b:a','256k','-ar','48000','-ac','2','-t',f'{duration:.9f}','-map_metadata','-1','-movflags','+faststart',str(a.out)]
    run(command);after=probe(a.out);av=next(s for s in after['streams'] if s['codec_type']=='video')
    keys=['codec_name','profile','width','height','pix_fmt','r_frame_rate','avg_frame_rate','nb_frames','duration','start_time','color_range','color_space','color_transfer','color_primaries']
    if any(v.get(k)!=av.get(k) for k in keys):raise RuntimeError('reviewed picture format/timing changed')
    original_video_hash=video_hash(a.video)
    if video_hash(a.out)!=original_video_hash:raise RuntimeError('compressed video packets changed')
    level=loudness(a.out)
    if abs(float(level['input_i'])+14)>.6 or float(level['input_tp'])>-1:raise RuntimeError('audio loudness/true-peak check failed')
    receipt={'film':str(a.out),'sha256':hashlib.sha256(a.out.read_bytes()).hexdigest(),'durationSeconds':duration,'frames':plan['frameCount'],'sourceMovieSha256':source_sha,'videoPacketSha256':original_video_hash,'videoCopiedWithoutReencoding':True,'pictureTimingUnchanged':True,'soundtrackPlanSha256':hashlib.sha256(a.plan.read_bytes()).hexdigest(),'soundtrackPlan':plan,'loudnessFinal':level,'ffprobe':after,'faststart':faststart(a.out),'command':command}
    a.out.with_suffix('.report.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps({k:receipt[k] for k in ('film','sha256','durationSeconds','videoCopiedWithoutReencoding','pictureTimingUnchanged')},indent=2))

if __name__=='__main__':main()
