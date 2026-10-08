#!/usr/bin/env python3
"""Media-only soundtrack/encode/QA stage for the explicit-cue release short film."""
import argparse,hashlib,json,os,re,struct,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/"video/tools"))
from host_lock import owner,identity,start_ticks
PLAN=json.loads((ROOT/"video/short026/soundtrack.json").read_text())
FRAMES=int(PLAN["frameCount"])
DURATION=FRAMES/int(PLAN["fps"])
MUSIC_SHA="13e575b81fe74e7e4888cc5c59fe54841c57fc99156cb54bd5a5a8e223c8d754"
def run(args):
    result=subprocess.run(args,capture_output=True,text=True)
    if result.returncode: raise RuntimeError(result.stderr[-8000:])
    return result
def loudness(path):
    result=run(["ffmpeg","-hide_banner","-nostats","-i",str(path),"-map","0:a:0","-vn","-af","loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json","-f","null","-"])
    values=re.findall(r"\{\s*\"input_i\".*?\}",result.stderr,re.S)
    if not values: raise RuntimeError("missing loudness receipt")
    return json.loads(values[-1])
def faststart(path):
    boxes=[]
    with path.open('rb') as source:
        total=path.stat().st_size
        while source.tell()+8<=total:
            offset=source.tell();size,kind=struct.unpack('>I4s',source.read(8))
            if size==1:size=struct.unpack('>Q',source.read(8))[0]
            if size==0:size=total-offset
            if size<8 or offset+size>total:raise RuntimeError('invalid MP4 box size')
            boxes.append({'kind':kind.decode('ascii'),'offset':offset,'bytes':size});source.seek(offset+size)
    names=[box['kind'] for box in boxes]
    if names.index('moov')>=names.index('mdat'):raise RuntimeError('MP4 is not faststart')
    return {'passed':True,'topLevelBoxes':boxes}
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument("--music",type=Path,default=ROOT/"video/cache/music/slow-eruption.mp3");p.add_argument("--frames",type=Path,default=ROOT/"video/cache/short026/frames");p.add_argument("--out",type=Path,default=ROOT/"video/out/omagma-v0.2.6-short.mp4");a=p.parse_args()
    value=owner();who=identity(value) if value else None
    if not value or value.get("token")!=os.environ.get("HOST_TOKEN") or not who or start_ticks(who[0])!=who[1]:raise RuntimeError("matching live host reservation required")
    if hashlib.sha256(a.music.read_bytes()).hexdigest()!=MUSIC_SHA:raise RuntimeError("existing song bytes changed")
    if len(list(a.frames.glob("*.jpg")))!=FRAMES:raise RuntimeError("picture frame count differs from explicit soundtrack plan")
    cache=ROOT/"video/cache/short026";cache.mkdir(parents=True,exist_ok=True);a.out.parent.mkdir(parents=True,exist_ok=True)
    raw=cache/"soundtrack-raw.wav";normalized=cache/"soundtrack.wav"
    if PLAN["sourceSha256"]!=MUSIC_SHA or abs(float(PLAN["duration"])-DURATION)>1/48000:raise RuntimeError("soundtrack plan duration/hash mismatch")
    segments=PLAN["segments"];crossfade_samples=round(float(PLAN["crossfadeSeconds"])*48000)
    if len(segments)!=2 or PLAN["sampleRate"]!=48000:raise RuntimeError("expected explicit two-segment48k plan")
    lengths=[]
    for segment in segments:
        start,end=segment["sourceSamples48k"]
        if round(float(segment["sourceIn"])*48000)!=start or round(float(segment["sourceOut"])*48000)!=end:raise RuntimeError("cue sample/time mismatch")
        if start<0 or end<=start or abs((end-start)/48000-(segment["filmOut"]-segment["filmIn"]))>1/48000:raise RuntimeError("invalid source/film mapping")
        lengths.append(end-start)
    if sum(lengths)-crossfade_samples!=round(DURATION*48000) or segments[-1]["sourceOut"]!=189.96:raise RuntimeError("explicit sample duration/natural end mismatch")
    graph="[0:a:0]aresample=48000,asplit=2[s0][s1];"
    graph+=";".join(f"[s{i}]atrim=start_sample={segment['sourceSamples48k'][0]}:end_sample={segment['sourceSamples48k'][1]},asetpts=PTS-STARTPTS[a{i}]" for i,segment in enumerate(segments))
    graph+=f";[a0][a1]acrossfade=ns={crossfade_samples}:c1=qsin:c2=qsin[raw]"
    run(["ffmpeg","-hide_banner","-loglevel","error","-y","-i",str(a.music),"-filter_complex",graph,"-map","[raw]","-vn","-ar","48000","-ac","2","-c:a","pcm_s24le","-map_metadata","-1",str(raw)])
    measure=loudness(raw)
    gain_db=-14-float(measure["input_i"])
    if float(measure["input_tp"])+gain_db>-1:raise RuntimeError("static gain would exceed true-peak ceiling")
    # One static gain preserves the source's composed swell; no compression,
    # limiter, per-segment lift or dynamic loudness processing.
    run(["ffmpeg","-hide_banner","-loglevel","error","-y","-i",str(raw),"-map","0:a:0","-vn","-af",f"volume={gain_db:.9f}dB","-ar","48000","-ac","2","-c:a","pcm_s24le","-map_metadata","-1",str(normalized)])
    command=["ffmpeg","-hide_banner","-loglevel","error","-y","-framerate","30","-i",str(a.frames/"%05d.jpg"),"-i",str(normalized),"-map","0:v:0","-map","1:a:0","-frames:v",str(FRAMES),"-t",f"{DURATION:.9f}","-vf","scale=in_range=pc:out_range=tv:out_color_matrix=bt709,format=yuv420p","-c:v","libx264","-profile:v","high","-preset","slow","-crf","18","-threads","4","-color_primaries","bt709","-color_trc","bt709","-colorspace","bt709","-color_range","tv","-c:a","aac","-b:a","256k","-ar","48000","-ac","2","-map_metadata","-1","-movflags","+faststart",str(a.out)]
    run(command)
    probe=json.loads(run(["ffprobe","-v","error","-count_frames","-show_streams","-show_format","-of","json",str(a.out)]).stdout)
    v=next(s for s in probe["streams"] if s["codec_type"]=="video");audio=next(s for s in probe["streams"] if s["codec_type"]=="audio")
    if v["codec_name"]!="h264" or v["pix_fmt"]!="yuv420p" or int(v["nb_read_frames"])!=FRAMES or v["width"]!=1920 or v["height"]!=1080:raise RuntimeError("film codec/frame gate failed")
    if audio["codec_name"]!="aac" or int(audio["sample_rate"])!=48000 or int(audio["channels"])!=2:raise RuntimeError("audio format gate failed")
    final_loud=loudness(a.out)
    if abs(float(final_loud["input_i"])+14)>.6 or float(final_loud["input_tp"])>-1.0:raise RuntimeError("social audio loudness/true-peak gate failed")
    capture=json.loads((cache/"capture-receipt.json").read_text())
    receipt={"film":str(a.out),"durationSeconds":DURATION,"frames":FRAMES,"binarySha256":capture["binarySha256"],"buildInfo":capture["buildInfo"],"musicSha256":MUSIC_SHA,"musicSourceSegments":[[segment["sourceIn"],segment["sourceOut"]] for segment in segments],"musicCrossfadeSeconds":PLAN["crossfadeSeconds"],"musicEnding":"original natural ending retained; explicit30ms intro-to-roll seam","soundtrackPlanSha256":hashlib.sha256((ROOT/"video/short026/soundtrack.json").read_bytes()).hexdigest(),"staticGainDb":gain_db,"loudnessBefore":measure,"loudnessFinal":final_loud,"ffprobe":probe,"faststart":faststart(a.out),"pictureSourceSha256":hashlib.sha256((ROOT/'video/short026/film.html').read_bytes()).hexdigest(),"sha256":hashlib.sha256(a.out.read_bytes()).hexdigest(),"encodeCommand":command}
    if not capture.get("pickerAudit"):
        picker_receipt=cache/"picker-revision/capture-receipt.json"
        if picker_receipt.exists():
            picker=json.loads(picker_receipt.read_text())
            expected=picker.get("rasterAssets",{}).get("picker-detail.png",{}).get("sha256")
            actual=hashlib.sha256((cache/"assets/picker-detail.png").read_bytes()).hexdigest()
            if expected and expected==actual:
                receipt["sceneCaptureProvenance"]={"base":{"binarySha256":capture["binarySha256"],"buildInfo":capture["buildInfo"]},"picker":{"binarySha256":picker["binarySha256"],"buildInfo":picker["buildInfo"],"query":picker["pickerAudit"]["query"],"visibleFilenames":picker["pickerAudit"]["visibleFilenames"],"assetSha256":actual,"selectedFilename":picker["actualAttachedFilename"],"selectedBytes":picker["actualAttachedBytes"]}}
    a.out.with_suffix(".report.json").write_text(json.dumps(receipt,indent=2))
    print(json.dumps({k:receipt[k] for k in ["film","durationSeconds","frames","sha256","loudnessFinal"]},indent=2))
if __name__=="__main__":main()
