#!/usr/bin/env python3
"""Media-only soundtrack/encode/QA stage for the 31.733 s release short film."""
import argparse,hashlib,json,os,re,struct,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/"video/tools"))
from host_lock import owner,identity,start_ticks
DURATION=952/30
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
    if len(list(a.frames.glob("*.jpg")))!=952:raise RuntimeError("expected exactly 952 picture frames")
    cache=ROOT/"video/cache/short026";cache.mkdir(parents=True,exist_ok=True);a.out.parent.mkdir(parents=True,exist_ok=True)
    raw=cache/"soundtrack-raw.wav";normalized=cache/"soundtrack.wav"
    run(["ffmpeg","-hide_banner","-loglevel","error","-y","-i",str(a.music),"-map","0:a:0","-vn","-af",f"atrim=start={189.96-DURATION:.9f}:end=189.960,asetpts=PTS-STARTPTS,apad=whole_dur={DURATION:.9f}","-t",f"{DURATION:.9f}","-ar","48000","-ac","2","-c:a","pcm_s24le","-map_metadata","-1",str(raw)])
    measure=loudness(raw)
    af="loudnorm=I=-14:TP=-1.5:LRA=11:measured_I="+measure["input_i"]+":measured_TP="+measure["input_tp"]+":measured_LRA="+measure["input_lra"]+":measured_thresh="+measure["input_thresh"]+":offset="+measure["target_offset"]+":linear=true"
    run(["ffmpeg","-hide_banner","-loglevel","error","-y","-i",str(raw),"-map","0:a:0","-vn","-af",af,"-ar","48000","-ac","2","-c:a","pcm_s24le","-map_metadata","-1",str(normalized)])
    command=["ffmpeg","-hide_banner","-loglevel","error","-y","-framerate","30","-i",str(a.frames/"%05d.jpg"),"-i",str(normalized),"-map","0:v:0","-map","1:a:0","-frames:v","952","-t",f"{DURATION:.9f}","-vf","scale=in_range=pc:out_range=tv:out_color_matrix=bt709,format=yuv420p","-c:v","libx264","-profile:v","high","-preset","slow","-crf","18","-threads","4","-color_primaries","bt709","-color_trc","bt709","-colorspace","bt709","-color_range","tv","-c:a","aac","-b:a","256k","-ar","48000","-ac","2","-map_metadata","-1","-movflags","+faststart",str(a.out)]
    run(command)
    probe=json.loads(run(["ffprobe","-v","error","-count_frames","-show_streams","-show_format","-of","json",str(a.out)]).stdout)
    v=next(s for s in probe["streams"] if s["codec_type"]=="video");audio=next(s for s in probe["streams"] if s["codec_type"]=="audio")
    if v["codec_name"]!="h264" or v["pix_fmt"]!="yuv420p" or int(v["nb_read_frames"])!=952 or v["width"]!=1920 or v["height"]!=1080:raise RuntimeError("film codec/frame gate failed")
    if audio["codec_name"]!="aac" or int(audio["sample_rate"])!=48000 or int(audio["channels"])!=2:raise RuntimeError("audio format gate failed")
    final_loud=loudness(a.out)
    if abs(float(final_loud["input_i"])+14)>.6 or float(final_loud["input_tp"])>-1.0:raise RuntimeError("social audio loudness/true-peak gate failed")
    capture=json.loads((cache/"capture-receipt.json").read_text())
    receipt={"film":str(a.out),"durationSeconds":DURATION,"frames":952,"binarySha256":capture["binarySha256"],"buildInfo":capture["buildInfo"],"musicSha256":MUSIC_SHA,"musicSourceInterval":[189.96-DURATION,189.96],"musicEnding":"original song ending retained; no montage seams","loudnessBefore":measure,"loudnessFinal":final_loud,"ffprobe":probe,"faststart":faststart(a.out),"pictureSourceSha256":hashlib.sha256((ROOT/'video/short026/film.html').read_bytes()).hexdigest(),"sha256":hashlib.sha256(a.out.read_bytes()).hexdigest(),"encodeCommand":command}
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
