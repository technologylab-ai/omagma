// Measure editorial crops from genuine terminal cells. Never alter captured pixels.
import {readFileSync,writeFileSync} from 'node:fs';
import {resolve,dirname,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {Tape} from '../web/term.js';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
const cache=join(root,'video/cache/short029');
export function measureROIs(manifest){
 for(const [key,a] of Object.entries(manifest.assets)){
  if(!a.tape)continue;
  const t=new Tape(JSON.parse(readFileSync(join(cache,a.tape)))),f=a.frame??t.mark(a.mark).frame;
  const r=(x,y,w,h)=>[x/t.columns,y/t.rows,w/t.columns,h/t.rows];
  const pane=p=>r(p.x0,p.y0,p.x1-p.x0+1,p.y1-p.y0+1);
  const rois=a.rois,panes=t.panes(f);
  if(rois.calendar_entry&&rois.followup_entry){
   const c=rois.calendar_entry,u=rois.followup_entry,y=Math.min(c[1],u[1]);
   rois.destinations=[c[0],y,c[2],Math.max(c[1]+c[3],u[1]+u[3])-y];
   if(key!=='followup.list')rois.sidebar_portal=r(0,14,44,12);
  }
  if(['rsvp.invitation','followup.message'].includes(key)){
   const p=panes.find(p=>p.title.startsWith('Message'));if(!p)throw Error('Missing reader '+key);
   // Full bordered pane supplies context; the invitation card is a separate close-up.
   rois.reader=pane(p);
   if(key==='followup.message')rois.message_excerpt=r(p.x0,p.y0,p.x1-p.x0+1,23);
   const card=panes.find(p=>p.title==='Invitation');if(card)rois.invitation=pane(card);
  }
  if(key==='calendar.agenda'){
   const rows=t.grid(f).map((_,y)=>t.text(f,y));
   const first=rows.findIndex(s=>/^\s*\w{3} · \d{4}-\d{2}-\d{2}/.test(s));
   const last=rows.reduce((n,s,y)=>/\d{2}:\d{2}–\d{2}:\d{2}/.test(s)?y:n,-1);
   if(first<0||last<first)throw Error('Missing agenda rows');
   const width=Math.max(...rows.slice(first,last+1).map(s=>s.trimEnd().length))+2;
   rois.agenda=r(0,first,Math.min(width,t.columns),last-first+2);
  }
  if(key.startsWith('join.')){
   const p=panes.at(-1),hit=t.find(f,'[o Join]');if(!p||!hit)throw Error('Missing Join control');
   rois.join_control=r(hit.x-3,hit.y,11,1);
   // A gentle close-up preserves the full event; emphasis identifies the action.
   rois.card=pane(p);
   rois.join_close=r(78,0,32,9);
   const result=t.find(f,'Join target validated');
   if(result)rois.profile_result=r(result.x,result.y,t.text(f,result.y).trimEnd().length-result.x,1);
   if(result)rois.profile_close=r(0,25,34,1);
  }
  if(key.startsWith('notification.')){
   // Measure the same card geometry for the before/during/action sequence,
   // including the pre-arrival Mail frame which deliberately has no card.
   const source=manifest.assets['notification.upcoming'];
   const reference=new Tape(JSON.parse(readFileSync(join(cache,source.tape))));
   const frame=reference.mark(source.mark).frame;
   const card=reference.panes(frame).find(p=>p.title.startsWith('Upcoming meeting'));
   if(!card)throw Error('Missing native meeting reminder pane');
   const x=Math.max(0,card.x0-16),y=Math.max(0,card.y0-2);
   rois.card_context=r(x,y,Math.min(t.columns-x,card.x1-x+2),Math.min(t.rows-y,card.y1-y+2));
   rois.mail_context=r(0,2,t.columns,t.rows-2);
   rois.reminder_notice=pane(card);
   const joinControl=t.find(f,'[o Join]')||t.find(f,'[Join]');
   if(joinControl)rois.join_control=r(joinControl.x-2,joinControl.y,Math.min(11,t.columns-joinControl.x+2),1);
   const focus=t.find(f,'M Meeting actions');
   if(focus)rois.focus_control=r(focus.x,focus.y,17,1);
   const result=t.find(f,'Join target validated · Profile 1');
   if(result)rois.profile_close=r(result.x-1,result.y,36,1);
  }
  if(key==='rsvp.confirmed'){
   const first=t.find(f,'Your confirmed RSVP'),last=t.find(f,'Calendar updated');
   if(!first||!last)throw Error('Missing separate RSVP outcomes');
   const p=panes.at(-1);
   rois.outcomes=r(first.x,first.y,p.x1-first.x,last.y-first.y+1);
   rois.outcome_close=r(first.x-1,first.y,45,2);
  }
  if(key.startsWith('rsvp.')&&rois.control){
   const p=panes.at(-1);if(p)rois.action_close=r(p.x0,Math.max(p.y0,p.y1-7),58,8);
  }
  if(key==='rsvp.calendar'){
   const p=panes.at(-1);if(p)rois.event_summary=r(p.x0,p.y0,88,9);
  }
  if(['followup.sidebar','followup.list'].includes(key))rois.sidebar_and_list=r(0,2,97,25);
  if(key==='followup.list'){
   const p=panes.find(p=>p.title.startsWith('Follow-ups'));
   if(!p)throw Error('Missing Follow-ups pane');
   rois.followup_pane=pane(p);
   // Complete title, due date and sender; the overview retains the whole UI.
   rois.reminder=r(p.x0,p.y0,p.x1-p.x0+1,5);
   rois.reminder_close=r(p.x0,p.y0,73,5);
  }
  if(key==='followup.schedule'||key==='followup.today')rois.preset_close=r(40,14,76,13);
  if(key==='draft.handoff'){
   const text='Draft is available in Gmail.',hit=t.find(f,text);if(!hit)throw Error('Missing Gmail result');
   rois.gmail_result=r(hit.x-1,hit.y,text.length+1,1);
  }
  if(key==='draft.continue'||key==='draft.upload_focus')rois.upload_close=r(40,23,76,9);
 }
 return manifest;
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 const path=join(cache,'assets-manifest.json');
 writeFileSync(path,JSON.stringify(measureROIs(JSON.parse(readFileSync(path))),null,2)+'\n');
 console.log('Measured clean pane, invitation, Join, outcome and sidebar regions');
}
