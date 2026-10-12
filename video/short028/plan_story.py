#!/usr/bin/env python3
"""Explicit feature headlines; browser launch/connect shown as a surprise tech demo."""
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];CACHE=ROOT/'video/cache/short028'
def main():
 m=json.loads((CACHE/'recut-assets-manifest.json').read_text());m['assets'].update(json.loads((CACHE/'story-detail-assets.json').read_text()));a=m['assets']
 parts=[]
 def cam(start='full',end='full',move=.6):return {'from':start,'to':end,'moveFrom':0,'moveUntil':move}
 def add(id,start,end,chapter,asset=None,headline=None,subtitle='',**extra):
  p={'id':id,'name':id,'frameIn':round(start*30),'frameOut':round(end*30),'chapter':chapter,'asset':asset,'headline':headline,'subtitle':subtitle,'transition':.3,'editorial':None,'focus':None,'camera':cam()};p.update(extra);parts.append(p)
 add('intro',0,2.5,0,'reader.context',editorial='intro',editorialText='What’s new in v0.2.8')
 add('mac-setup',2.5,7,1,None,'macOS setup: two options',editorial='mac-choices')
 add('cli-discover',7,9.8,2,'cli.overview_story','Progressive CLI discovery for agents')
 add('cli-narrow',9.8,12,2,'cli.mail_story','Discover only the commands you need')
 add('cli-json',12,14,2,'cli.json_recut','Machine-readable commands for agents')
 add('copy-select',14,19.5,3,'reader.move','Copy text from emails','With the keyboard or mouse.',camera=cam('full','focus',.8),sequence=[{'offset':0,'asset':'reader.move'},{'offset':1,'asset':'reader.at_paragraph'},{'offset':1.7,'asset':'reader.marked'},{'offset':2.1,'asset':'reader.excerpt'}])
 add('copy-done',19.5,21.5,3,'reader.copied','Copy text from emails','Ready to paste into your agent chat.',camera=cam('focus','focus',0))
 add('editor-open',21.5,23.6,4,'editor.view','Open emails in your editor','e → $EDITOR',camera=cam('full','body',.6))
 add('editor-use',23.6,26.5,4,'editor.paragraph','Open emails in your editor','Search, select and copy with your familiar tools.',camera=cam('body','body',0))
 add('send-review',26.5,28,5,'send.review','Skip the 10-second send delay','Review the message first.',camera=cam('full','focus',.5))
 add('send-ticking',28,30.2,5,'send.timer10_story','Skip the 10-second send delay','The countdown is still running.',frame=[545,490,830,180],backgroundAsset='send.countdown',backgroundCamera=cam(),backgroundDim=.18,backgroundSequence=[{'offset':0,'asset':'send.countdown'},{'offset':1,'asset':'send.countdown_nine'},{'offset':2,'asset':'send.countdown_eight'}],sequence=[{'offset':0,'asset':'send.timer10_story'},{'offset':1,'asset':'send.timer9_story'},{'offset':2,'asset':'send.timer8_story'}])
 add('send-now',30.2,33,5,'send.button_recut','Skip the countdown. Send now.','Ctrl+S',frame=[485,450,950,180],backgroundAsset='send.now_focus',backgroundCamera=cam(),backgroundDim=.2)
 add('send-done',33,35,5,'send.complete_story','Sent.',frame=[545,490,830,180],backgroundAsset='send.receipt',backgroundCamera=cam(),backgroundDim=.18)
 add('browser-surprise',35,41.5,6,None,'And one more thing…',headlineLarge=True,centerHeadline=True,browser=False,headlineReveal=[{'offset':0,'text':'And one more thing…'},{'offset':1.1,'text':'Omagma comes full circle.'},{'offset':2.3,'text':'Thanks to Zig + WebAssembly…'},{'offset':3.5,'text':'It even runs in the browser.'},{'offset':4.9,'text':'A tech demo. Not for everyday use.'}])
 launch=CACHE/'server-launch-assets.json'
 assert launch.exists(), 'Actual server launch assets required'
 a.update(json.loads(launch.read_text()))
 add('browser-launch',41.5,44,6,'server.launch','Start it with omagma server',browser=True,sequence=json.loads((CACHE/'server-launch-sequence.json').read_text()))
 connect=CACHE/'browser/server-connect-assets-passed.json'
 if connect.exists():
  c=json.loads(connect.read_text());assert c['passed'] and c['realBrowserChrome']
  for r in c['assets']+c.get('frames',[]):a[r['name']]={k:r[k] for k in ['file','width','height','sha256','rois']};a[r['name']]['file']='/'+r['file'].lstrip('/')
  connect_keys={'button':'browser.server-connect-button','loading':'browser.server-connect-loading','connected':'browser.server-connected-three'}
 else:raise AssertionError('Actual native Connect Gmail capture required')
 a[connect_keys['button']]['rois']['connect']=[.69,.227,.068,.028]
 add('browser-connect-button',44,46.2,6,connect_keys['button'],'Connect Gmail in the browser',browser=True,focus='connect',highlightPadding=[8,4])
 add('browser-connect-load',46.2,48.2,6,connect_keys['loading'],'Connecting your accounts…',browser=True)
 add('browser-connected',48.2,51.2,6,connect_keys['connected'],'Connected. Your inbox is here.',browser=True)
 add('browser-read',51.2,55,6,'browser.reader','Open a message',browser=True)
 add('browser-compose',55,57.5,6,'browser.composer-empty','Start a reply',browser=True)
 old=json.loads((CACHE/'browser/chrome-assets-passed.json').read_text());typed=next(p['sequence'] for p in old['filmParts'] if p['id']=='browser-real-type');last=typed[-1]['offset']
 fast=[{'offset':round(s['offset']/last*1.15,6),'asset':s['asset']} for s in typed]
 add('browser-type',57.5,59,6,'browser.composer-empty','Type a note. Watch it render.',browser=True,sequence=fast)
 add('browser-preview',59,62,6,'browser.draft','See the live preview',browser=True)
 add('browser-saved',62,65,6,'browser.autosaved','Draft saved',browser=True)
 add('browser-recovery',65,69,6,'browser.reloaded','Reload. Your draft is still here.',browser=True)
 add('browser-memory',69,73.5,6,'browser.reloaded','3 accounts. About 125 MB.','Gone are the days of 2 GB browser tabs per account.',browser=True,subtitleLarge=True)
 add('recap',73.5,79,0,editorial='recap',editorialTitle='The little things, done better.',editorialRows=['Readable names and international text','A bad contact no longer breaks the list','Ctrl+Space works in classic terminals','Review label changes. Undo when needed.'])
 add('outro',79,2527/30,0,editorial='outro',editorialTitle='Omagma v0.2.8',editorialText='Linux · macOS · TUI + agent CLI')
 for p in parts:
  if p.get('sequence') is None:p.pop('sequence',None)
 titles=['macOS setup: two options','Progressive CLI discovery for agents','Copy text from emails','Open emails in your editor','Skip the 10-second send delay','One more thing…']
 plan={'schema':'omagma.video.timeline.v1','revision':'short028-story','width':1920,'height':1080,'fps':30,'frameCount':2527,'duration':2527/30,'chapters':[{'number':i+1,'title':t} for i,t in enumerate(titles)],'parts':parts}
 assert all(x['frameOut']==y['frameIn'] for x,y in zip(parts,parts[1:]));assert parts[-1]['frameOut']==2527
 (ROOT/'video/short028/story-timeline.json').write_text(json.dumps(plan,indent=2)+'\n');(CACHE/'story-assets-manifest.json').write_text(json.dumps(m,indent=2)+'\n')
 print('Explicit-headline story planned; timer ticks2s, browser typing1.15s, no RAM footnote')
if __name__=='__main__':main()
