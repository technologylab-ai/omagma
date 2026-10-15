import argparse,hashlib,json,os,pathlib,signal,subprocess,sys,time,shutil
r=pathlib.Path(__file__).resolve().parents[2];os.chdir(r)
p=argparse.ArgumentParser();p.add_argument('stage',choices=['stills','film','playback','deliver']);p.add_argument('--attempt',required=True);a=p.parse_args();cache=r/'video/cache/short0210';out=cache/('chapter-stage-'+a.stage+'-'+a.attempt);out.mkdir(parents=True,exist_ok=False)
lock=[sys.executable,'video/tools/host_lock.py'];token=subprocess.check_output(lock+['acquire','--pid',str(os.getpid()),'--purpose','v0.2.10 three-chapter film '+a.stage],text=True).strip();env=dict(os.environ,HOST_TOKEN=token)
def run(label,args,timeout=3600):
 with (out/(label+'.log')).open('w') as f:
  proc=subprocess.Popen(args,stdout=f,stderr=subprocess.STDOUT,env=env,start_new_session=True)
  try:code=proc.wait(timeout=timeout)
  except BaseException:
   try:os.killpg(proc.pid,signal.SIGTERM)
   except ProcessLookupError:pass
   try:proc.wait(timeout=8)
   except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait()
   raise
 if code:print((out/(label+'.log')).read_text()[-5000:],flush=True);raise SystemExit(code)
 print(label+' passed',flush=True)
def hashes():
 files=[r/'video/short0210'/name for name in ['chapters.html','chapters.js','chapters.css','chapter-motion.js','chapter-motion.css','chapter-plan.json','soundtrack-plan.json','render-chapters.mjs','encode-chapters.py','cdp.mjs']];files+=[f for f in (cache/'revision-08').rglob('*') if f.is_file()];manifest=json.loads((cache/'revision-08/assets-manifest.json').read_text())
 files += [cache/'audio-fix-13/soundtrack.m4a',cache/'audio-fix-13/verification.json'];files+=[r/x['file'].lstrip('/') for x in manifest['assets'].values() if x['file'].startswith('/')]
 return {str(f.relative_to(r)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files if f.is_file()}
try:
 if a.stage=='stills':
  times='0.4,1.1,2.4,5.5,10.5,15.7,18.6,21.4,24.8,28.5,30.2,31.6,33.5,35.8,38.4,39.9,42.4,44.5,46.9,49.2,52.9,55.9,59.5,62.7,65.6,67.7,70.5,73.9,75.9,79.3,82.2,84.4,87.3,90.3,94.4,96.4'
  run('chapter-stills',['node','video/short0210/render-chapters.mjs','--stills',times,'--out',str(cache/('chapter-stills-'+a.attempt))])
 elif a.stage=='film':
  before=hashes();(cache/('chapter-source-hashes-'+a.attempt+'.json')).write_text(json.dumps(before,indent=2)+'\n')
  run('chapter-frames',['node','video/short0210/render-chapters.mjs','--out',str(cache/('chapter-frames-'+a.attempt))])
  run('chapter-encode',[sys.executable,'video/short0210/encode-chapters.py','--frames',str(cache/('chapter-frames-'+a.attempt)),'--out','video/out/omagma-v0.2.10-chapters-'+a.attempt+'.mp4'])
  assert before==hashes(),'source mutation during render'
 elif a.stage=='playback':
  target=cache/('chapter-review-'+a.attempt+'.mp4');assert not target.exists();shutil.copy2(r/('video/out/omagma-v0.2.10-chapters-'+a.attempt+'.mp4'),target)
  run('chapter-playback',['node','video/short0210/review-chapters.mjs','--movie',target.name,'--out',str(cache/('chapter-playback-'+a.attempt))],240)
 elif a.stage=='deliver':
  run('chapter-deliver',[sys.executable,'video/short0210/deliver-chapters.py','--attempt',a.attempt])
finally:
 subprocess.run(lock+['release',token],check=True);print('Released own media reservation',flush=True)
