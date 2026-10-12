#!/usr/bin/env python3
"""Merge accepted, hash-verified captures and retime genuine browser frames."""
import copy,hashlib,json,struct
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
CACHE=ROOT/'video/cache/short028'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 native=json.loads((CACHE/'native-assets-manifest.json').read_text())
 def locate(tape,mark,literal):
  t=json.loads((CACHE/(tape+'.json')).read_text());end=next(m['frame'] for m in t['marks'] if m['name']==mark);rows=[[] for _ in range(t['rows'])]
  for f in t['frames'][:end+1]:
   for y,r in enumerate(f['rows']):
    if r is not None:rows[y]=r
  for y,r in enumerate(rows):
   line=[' ']*t['columns']
   for x,text,style,cells in r:
    for i,ch in enumerate(text):
     if x+i<len(line):line[x+i]=ch
   x=''.join(line).find(literal)
   if x>=0:return [x/t['columns'],y/t['rows'],len(literal)/t['columns'],1/t['rows']]
  raise AssertionError('actual control not found '+literal)
 control=locate('send','now-focus','[Send now Ctrl+S]')
 native['assets']['send.now_focus']['rois']['control']=control
 for key,meta in native['assets'].items():
  if key.startswith('reader.'):meta['rois']['focus']=[99/160,.035,61/160,.35]
 passage=locate('reader','excerpt','Copy this paragraph')
 passage[2]=.365;passage[3]=2/42
 native['assets']['reader.excerpt']['rois']['passage']=passage
 browser=json.loads((CACHE/'browser/assets-passed.json').read_text())
 assert browser['passed'] and browser['recoveryProofPassed']
 for row in browser['assets']+browser['frames']:
  p=ROOT/row['path'];assert sha(p)==row['sha256']
  key=row['name'] if not row['name'].startswith('frame-') else 'browser.'+row['name']
  native['assets'][key]={'file':'/'+row['path'],'width':row['width'],'height':row['height'],'sha256':row['sha256'],'platform':'Zig/WebAssembly','provenance':'Genuine browser application viewport; fictional accounts; external providers intercepted before network','rois':{'focus':[.027,.235,.946,.65],'format':[444/1440,408/900,540/1440,188/900]}}
 logo=ROOT/'video/assets/omagma-logo-master.png';w,h=struct.unpack('>II',logo.read_bytes()[16:24])
 native['assets']['logo']={'file':'/video/assets/omagma-logo-master.png','width':w,'height':h,'sha256':sha(logo),'platform':'branding','provenance':'Existing approved logo asset'}
 native['browserReceipt']=browser['captureReceipt']
 (CACHE/'assets-manifest.json').write_text(json.dumps(native,indent=2)+'\n')
 timeline=ROOT/'video/short028/timeline.json';plan=json.loads(timeline.read_text())
 frames=browser['frames']
 def sequence(groups):
  result=[];offset=0
  for state,duration in groups:
   rows=[f for f in frames if f['state']==state];assert rows
   first=rows[0]['timestamps']['sceneMs'];last=rows[-1]['timestamps']['sceneMs']
   for row in rows:
    progress=0 if last==first else (row['timestamps']['sceneMs']-first)/(last-first)
    result.append({'offset':round(offset+progress*(duration-1/60),7),'asset':'browser.'+row['name']})
   offset+=duration
  return result
 context=next(p for p in plan['parts'] if p['id']=='browser-context')
 context['sequence']=sequence([('browser.context',1),('cached-account-2',1),('cached-account-3',1),('received-reader',1.1)])
 context['transition']=0;context['subtitle']='Three accounts. The same Zig TUI, running in the browser.'
 draft=next(p for p in plan['parts'] if p['id']=='browser-draft')
 if not any(p['id']=='browser-format' for p in plan['parts']):
  choice=copy.deepcopy(draft);choice.update(id='browser-format',name='browser-format',frameIn=1908,frameOut=1968,subtitle='Reply in the browser. Keep the original formatting.',transition=0,readableHold=1.5,focus=None)
  choice['sequence']=sequence([('reply-format-choice',2)]);choice['asset']=choice['sequence'][0]['asset'];choice['camera']={'from':'full','to':'format','moveFrom':0,'moveUntil':.5}
  plan['parts'].insert(plan['parts'].index(draft),choice)
 draft.update(frameIn=1968,frameOut=2016,transition=0,subtitle='A short note. The preview updates as you type.',readableHold=1.6,focus=None)
 draft['sequence']=sequence([('browser.draft',1.3),('draft-saved',.3)]);draft['asset']=draft['sequence'][0]['asset'];draft['camera']={'from':'format','to':'focus','moveFrom':0,'moveUntil':.45};draft['transition']=.15
 recovered=next(p for p in plan['parts'] if p['id']=='browser-recovered');recovered['editorialDelay']=2
 # MOVE is deliberately unmarked, then the real caret moves to the paragraph.
 part=next(p for p in plan['parts'] if p['id']=='reader-move')
 part['sequence']=[{'offset':0,'asset':'reader.move'},{'offset':1.05,'asset':'reader.at_paragraph'}]
 for part in plan['parts']:
  if part['id'].startswith('reader-'):part['focus']='passage' if part['id']=='reader-excerpt' else None
  if part['id']=='send-now':part['focus']='control';part['highlightPadding']=[4,0]
  if part['id'].startswith('cli-') or part['id'] in ('mac-result','send-review','send-countdown','browser-recovered'):part['focus']=None
  if part['id']=='cli-index':part['subtitle']='omagma cli --help commands · complete command discovery'
  if part['id']=='cli-command':part['subtitle']='omagma cli --help mail.read · every field, offline'
  if part['id']=='cli-schema':part['subtitle']='omagma cli --schema mail.send · nested Draft fields'
  if part['id']=='editor-view':part['sequence']=[{'offset':0,'asset':'editor.view'},{'offset':2.6,'asset':'editor.paragraph'}]
 part=next(p for p in plan['parts'] if p['id']=='send-countdown')
 part['sequence']=[{'offset':0,'asset':'send.countdown'},{'offset':.8,'asset':'send.countdown_nine'},{'offset':1.6,'asset':'send.countdown_eight'}]
 timeline.write_text(json.dumps(plan,indent=2)+'\n')
 print('Accepted',len(native['assets']),'assets; genuine browser event order preserved')
if __name__=='__main__':main()
