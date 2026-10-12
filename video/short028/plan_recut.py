#!/usr/bin/env python3
"""Benefit-led edit. Browser frames come from a separately accepted real window."""
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];CACHE=ROOT/'video/cache/short028'
def main():
 manifest=json.loads((CACHE/'assets-manifest.json').read_text());manifest['assets'].update(json.loads((CACHE/'recut-detail-assets.json').read_text()))
 a=manifest['assets'];a['send.now_focus']['rois']['action']=[.23,0,.28,.14]
 a['send.status_recut']['rois']['focus']=[0,0,.55,1]
 a['editor.view']['rois']['body']=[0,0,.84,.45];a['editor.paragraph']['rois']['body']=[0,0,.84,.45]
 parts=[]
 def add(id,start,end,chapter,asset,subtitle='',editorial=None,camera=None,**extra):
  p=dict(id=id,name=id,frameIn=round(start*30),frameOut=round(end*30),chapter=chapter,asset=asset,subtitle=subtitle,transition=.3,editorial=editorial,focus=None,camera=camera or dict(from_='full',to='full',moveFrom=0,moveUntil=0));p.update(extra);parts.append(p)
 def cam(begin='full',end='full',duration=.6,free=False):return {'from':begin,'to':end,'moveFrom':0,'moveUntil':duration,'freeCenter':free}
 add('intro',0,3,0,'reader.context',editorial='intro',camera=cam(),editorialText='Six improvements. One smoother flow.')
 add('mac-choices',3,10,1,None,'Keychain for your terminal. Private files for agents and SSH.',editorial='mac-choices',camera=cam())
 add('cli-overview',10,12.7,2,'cli.overview_recut','Progressive discovery, built into the CLI.',camera=cam())
 add('cli-scope',12.7,15,2,'cli.mail_recut','Ask for a namespace. Get just the matching commands.',camera=cam())
 add('cli-json',15,18,2,'cli.json_recut','Human-readable help. Machine-readable JSON.',camera=cam())
 add('reader-select',18,23,3,'reader.move','Select a paragraph. Copy it into your agent chat.',camera=cam('full','focus',.8),sequence=[{'offset':0,'asset':'reader.move'},{'offset':1.2,'asset':'reader.at_paragraph'},{'offset':1.9,'asset':'reader.marked'},{'offset':2.4,'asset':'reader.excerpt'}])
 add('reader-copy',23,25,3,'reader.copied','V · Space · y. Mouse selection works too.',camera=cam('focus','focus',0))
 add('editor-open',25,27.1,4,'editor.view','e opens the message in $EDITOR.',camera=cam('full','body',.6))
 add('editor-search',27.1,30,4,'editor.paragraph','Search, select and copy with your familiar tools.',camera=cam('body','body',0))
 add('send-review',30,32.1,5,'send.review','Review. Confirm.',camera=cam('full','focus',.5))
 add('send-countdown',32.1,34.3,5,'send.countdown','Ten seconds to undo — or send immediately.',camera=cam('full','focus',.6),sequence=[{'offset':0,'asset':'send.countdown'},{'offset':.8,'asset':'send.countdown_nine'},{'offset':1.6,'asset':'send.countdown_eight'}])
 add('send-now',34.3,38,5,'send.button_recut','Ctrl+S · Send now.',camera=cam(),frame=[485,450,950,180],backgroundAsset='send.now_focus',backgroundCamera=cam(),backgroundDim=.2)
 add('send-sent',38,40,5,'send.status_recut','Sent.',camera=cam('focus','focus',0,True),frame=[300,500,1320,180],backgroundAsset='send.receipt',backgroundCamera=cam(),backgroundDim=.3)
 # Replace these with actual toolbar-inclusive recordings once accepted.
 chrome_path=CACHE/'browser/chrome-assets-passed.json'
 if chrome_path.exists():
  chrome=json.loads(chrome_path.read_text());assert chrome['passed'] and chrome['realBrowserChrome']
  for row in chrome['assets']+chrome.get('frames',[]):
   a[row['name']]={k:row[k] for k in ['file','width','height','sha256','rois']};a[row['name']]['file']='/'+row['file'].lstrip('/')
  browser_parts=chrome['filmParts']
  for item in browser_parts:
   add(item['id'],item['start'],item['end'],6,item['asset'],item['subtitle'],editorial=item.get('editorial'),camera=cam(),browser=True,**{k:v for k,v in item.items() if k in ['sequence','editorialDelay','memoryQualifier']})
 else:
  add('browser-hero',40,48,6,'browser.context','Full circle. Powered by Zig + WebAssembly.',camera=cam(),browser=True)
  add('browser-compose',48,62,6,'browser.draft','The same composer, right in your browser.',camera=cam(),browser=True)
  add('browser-recover',62,68,6,'browser.reloaded','Reload. Pick up where you left off.',camera=cam(),browser=True)
  add('browser-memory',68,73.5,6,'browser.reloaded','Three accounts, one browser tab.',editorial='browser-observation',camera=cam(),browser=True,memoryQualifier='Different sessions, not a benchmark.')
 add('recap',73.5,79,0,None,editorial='recap',camera=cam(),editorialTitle='The little things, done better.',editorialRows=['Readable names and international text','A bad contact no longer breaks the list','Ctrl+Space works in classic terminals','Review label changes. Undo when needed.'])
 add('outro',79,2527/30,0,None,editorial='outro',camera=cam(),editorialTitle='Omagma v0.2.8',editorialText='Linux · macOS · TUI + agent CLI')
 for p in parts:p['camera'].pop('from_',None)
 chapters=[{'number':i+1,'title':t} for i,t in enumerate(['Your Mac. Your agents.','Agent-ready CLI.','Take just the part you need.','Open mail in your editor.','Ready? Send now.','Omagma, in your browser.'])]
 plan={'schema':'omagma.video.timeline.v1','revision':'short028-recut','width':1920,'height':1080,'fps':30,'frameCount':2527,'duration':2527/30,'chapters':chapters,'parts':parts}
 assert all(x['frameOut']==y['frameIn'] for x,y in zip(parts,parts[1:]));assert parts[-1]['frameOut']==2527
 (ROOT/'video/short028/recut-timeline.json').write_text(json.dumps(plan,indent=2)+'\n');(CACHE/'recut-assets-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 print('Recut planned: editor stays editor; clean Sent status; browser dominates finale')
if __name__=='__main__':main()
