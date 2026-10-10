#!/usr/bin/env python3
"""Deliver preserved v0.2.7 master/poster/contact sheet to unique Videos paths."""
from __future__ import annotations
import argparse,datetime,hashlib,json,os,shutil,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'video/tools'))
from host_lock import owner,identity,start_ticks

def copy_new(source:Path,destination:Path):
    with source.open('rb') as src,destination.open('xb') as dst:shutil.copyfileobj(src,dst)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--destination',type=Path,default=Path.home()/'Videos/Omagma')
    p.add_argument('--revision',choices=('calmer','brisk','polished','nine','motion','smooth','continuation'),default='calmer')
    a=p.parse_args();value=owner();who=identity(value) if value else None
    if not value or value.get('token')!=os.environ.get('HOST_TOKEN') or not who or start_ticks(who[0])!=who[1]:raise RuntimeError('matching live host reservation required')
    cache=ROOT/'video/cache/short027';masters={'calmer':'omagma-v0.2.7-whats-new-calmer.mp4','brisk':'omagma-v0.2.7-brisk.mp4','polished':'omagma-v0.2.7-brisk-polished.mp4','nine':'omagma-v0.2.7-nine.mp4','motion':'omagma-v0.2.7-motion.mp4','smooth':'omagma-v0.2.7-smooth.mp4','continuation':'omagma-v0.2.7-continuation.mp4'};master=ROOT/'video/out'/masters[a.revision]
    report=json.loads(master.with_suffix('.report.json').read_text())
    if hashlib.sha256(master.read_bytes()).hexdigest()!=report['sha256']:raise RuntimeError('master differs from verified encode report')
    a.destination.mkdir(parents=True,exist_ok=True)
    stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S');stem='omagma-v0.2.7-whats-new-'+a.revision+'-'+stamp
    names=[a.destination/(stem+suffix) for suffix in ['.mp4','-poster.png','-contact-sheet.png','.report.json']]
    if any(n.exists() for n in names):raise RuntimeError('unique destination already exists; retry after one second')
    inputs=cache/('contact-inputs-'+a.revision);inputs.mkdir(exist_ok=True)
    times=([1.8,4.8,8.9,11.6,14,18.5,20.8,22.7,27,29,31.9,40,43.5,47.8,54.5,60.2] if a.revision=='brisk' else [2.5,7.5,17.4,24.8,32.7,37.5,41.8,49,58.2,71.2,74.8,81,87.5,91,98,104.7])
    frames=cache/('brisk-frames' if a.revision=='brisk' else 'calm-frames')
    if a.revision=='polished':
        times=[1.8,4.8,11.6,14,20.8,22.7,25.8,28.5,30.2,33,41,44.5,49.3,51.5,57,62.5]
        frames=cache/'brisk-polished-frames'
    if a.revision=='nine':
        times=[1.8,4.8,11.6,14,20.8,25.8,28.5,33,41,44.5,49.3,51.5,54.8,59,66.5,71.4]
        frames=cache/'nine-frames'
    if a.revision in ('motion','smooth','continuation'):
        timeline=json.loads((ROOT/'video/short027'/('motion.json' if a.revision=='motion' else 'smooth.json')).read_text())
        picks=['intro','bar','palette narrowed','find first','stage two','meeting review','join','files','received airline','empty note','note typing','browser note','original HTML','countdown','update guide','outro']
        parts={part['name']:part for part in timeline['parts']}
        times=[(parts[name]['frameIn']+parts[name]['frameOut'])/(2*timeline['fps']) for name in picks]
        times[0]=1.8
        frames=cache/(('smooth' if a.revision=='continuation' else a.revision)+'-frames')
    for i,t in enumerate(times):shutil.copyfile(frames/f'{round(t*30):05d}.jpg',inputs/f'{i:02d}.jpg')
    contact=cache/('contact-sheet-'+a.revision+'.png')
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-framerate','1','-i',str(inputs/'%02d.jpg'),'-vf','scale=480:270,tile=4x4:padding=20:margin=20:color=0x080605','-frames:v','1','-threads','1','-map_metadata','-1',str(contact)],check=True)
    poster=cache/'calm-review/t002.50.png';poster_time=2.5
    if a.revision in ('brisk','polished','nine','motion','smooth','continuation'):
        poster=cache/(a.revision+'-poster.png');poster_time=1.8
        subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-i',str(frames/'00054.jpg'),'-frames:v','1','-threads','1','-map_metadata','-1',str(poster)],check=True)
    copy_new(master,names[0]);copy_new(poster,names[1]);copy_new(contact,names[2])
    report['delivery']={'master':str(names[0]),'poster':str(names[1]),'contactSheet':str(names[2]),'posterFilmSeconds':poster_time,'contactFilmSeconds':times,'oldDeliveriesPreserved':True}
    if a.revision in ('brisk','polished','nine','motion','smooth','continuation'):
        if a.revision not in ('smooth','continuation'):report['basePictureSourceSha256']=hashlib.sha256((ROOT/'video/short027/film.html').read_bytes()).hexdigest()
        report['timeMapSha256']=hashlib.sha256((ROOT/'video/short027'/('smooth.json' if a.revision in ('smooth','continuation') else 'motion.json' if a.revision=='motion' else 'nine.json' if a.revision=='nine' else 'brisk.json')).read_bytes()).hexdigest()
    with names[3].open('x') as f:json.dump(report,f,indent=2);f.write('\n')
    receipt={'files':report['delivery'],'masterSha256':report['sha256'],'masterBytes':master.stat().st_size,'posterSha256':hashlib.sha256(poster.read_bytes()).hexdigest(),'contactSheetSha256':hashlib.sha256(contact.read_bytes()).hexdigest()}
    (cache/('delivery-'+a.revision+'.json')).write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt,indent=2))
if __name__=='__main__':main()
