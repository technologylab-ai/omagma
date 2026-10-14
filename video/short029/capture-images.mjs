// Rasterize genuine synchronized PTY states and literal CLI output.
import {mkdirSync,writeFileSync,readFileSync,existsSync} from 'node:fs';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {parseArgs} from 'node:util';
import {Tape} from '../web/term.js';
import {browser,reservation,root} from './cdp.mjs';
import {measureROIs} from './measure-rois.mjs';
const {values:options}=parseArgs({options:{'capture-root':{type:'string',default:'revision-02'}}});
const takeRoot=options['capture-root'];
if(!/^revision-\d{2}$/.test(takeRoot))throw Error('Use a new named capture revision');
await reservation();
const cache=join(root,'video/cache/short029'),takes=join(cache,takeRoot),out=join(takes,'assets');
if(existsSync(out))throw Error('Preserve existing revision assets; choose a fresh capture revision');
mkdirSync(out,{recursive:true});
const sha=x=>createHash('sha256').update(x).digest('hex');
const source=JSON.parse(readFileSync(join(takes,'calendar/capture-manifest.json')));
const jobs=Object.entries(source.assets).map(([key,row])=>({key,...row,tape:takeRoot+'/calendar/'+row.tape}));
const compact=JSON.parse(readFileSync(join(takes,'join-compact/capture-manifest.json')));
for(const [key,row] of Object.entries(compact.assets)){
 const job=jobs.find(x=>x.key===key);if(!job)throw Error('Unknown compact take '+key);
 Object.assign(job,row,{tape:takeRoot+'/join-compact/'+row.tape});
}
for(const [key,tape,mark] of [['vault.locked','locked','view'],['vault.unlock','unlock','view'],['vault.prompt','prompt','view'],['vault.agent','agent','view'],['vault.ready','tui','ready-mail']])jobs.push({key,tape:takeRoot+'/vault/'+tape+'.json',mark});
const unlock=JSON.parse(readFileSync(join(takes,'vault/unlock.json')));
for(let n=0;n<12;n++)jobs.push({key:'vault.type'+n,tape:takeRoot+'/vault/unlock.json',frame:Math.round(n*(unlock.frames.length-2)/11),mark:'typing'});
const agent=JSON.parse(readFileSync(join(takes,'vault/agent.json')));
for(let n=0;n<12;n++)jobs.push({key:'vault.agent_type'+n,tape:takeRoot+'/vault/agent.json',frame:Math.round(n*(agent.frames.length-2)/11),mark:'typing'});
// Stable before/after control focus states preserve the actual action order.
for(const [key,tape,mark] of [['rsvp.accept_focus','rsvp','accept-focus'],['rsvp.confirmed','rsvp','confirmed'],['rsvp.calendar_list','rsvp','calendar-list'],['draft.upload_focus','gmail','upload-focus']]){if(!jobs.some(job=>job.key===key))jobs.push({key,tape:takeRoot+'/calendar/'+tape+'.json',mark});}
const manifest={schema:'omagma.video.assets.v1',assets:{},captureReceipt:takeRoot+'/calendar/capture-manifest.json',vaultReceipt:takeRoot+'/vault/receipt.json'};
function roi(key){
 if(key.startsWith('vault.')&&key!=='vault.ready')return[0,0,1,1];
 if(key==='calendar.card'||key==='rsvp.calendar'||key.startsWith('join.'))return[.205,.035,.59,.57];
 if(key.startsWith('rsvp.')&&['rsvp.review','rsvp.accept_focus','rsvp.confirmed'].includes(key))return[.17,.12,.66,.75];
 if(['followup.schedule','followup.today'].includes(key))return[.244,.30,.513,.38];
 if(['draft.continue','draft.upload_focus','draft.handoff'].includes(key))return[.231,.18,.535,.65];
 if(key==='followup.message')return[.60,.04,.39,.66];
 if(key==='followup.list')return[0,.02,1,.60];
 if(key==='rsvp.invitation')return[.60,.04,.39,.66];
 return[0,0,1,1];
}
const b=await browser();
try{
 const p=await b.page('video/short029/capture-images.html',{scale:2});
 for(const job of jobs){
  if(!existsSync(join(cache,job.tape)))throw Error('Required genuine take missing '+job.tape);
  const tape=new Tape(JSON.parse(readFileSync(join(cache,job.tape))));
  const frame=job.frame??tape.mark(job.mark).frame;
  if(job.key==='rsvp.accept_focus'){
   const found=tape.find(frame,'[a Accept]');
   if(!found||tape.grid(frame)[found.y][found.x][1]?.[1]!== '#392b30')throw Error('Accept mark is not genuinely focused');
  }
  const rect=await p.evaluate('window.capture('+JSON.stringify(job.tape)+','+JSON.stringify(job.mark)+','+JSON.stringify(job.frame)+')');
  await p.evaluate('new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))');
  const matte=job.tape.includes('/vault/')&&job.key!=='vault.ready'?24:0;
  const clip={x:rect.left-matte,y:rect.top-matte,width:rect.columns*rect.cellW+2*matte,height:rect.rows*rect.cellH+2*matte,scale:1};
  const data=Buffer.from((await p.call('Page.captureScreenshot',{format:'png',clip})).data,'base64');
  const filename=job.key.replaceAll('.','-')+'.png';writeFileSync(join(out,filename),data);
  const rois={full:[0,0,1,1],focus:roi(job.key),result:[.002,.935,.99,.065]};
  if(job.key.startsWith('join.'))Object.assign(rois,job.rois);
  if(!matte){
   const pane=tape.panes(frame).at(-1);
   const bounds=p=>[p.x0/tape.columns,(p.y0+.08)/tape.rows,(p.x1-p.x0+1)/tape.columns,(p.y1-p.y0+.82)/tape.rows];
   if(pane&&['calendar.card','rsvp.review','rsvp.accept_focus','rsvp.confirmed','rsvp.calendar','followup.schedule','followup.today','draft.continue','draft.upload_focus','draft.handoff'].includes(job.key))rois.focus=bounds(pane);
   const sidebar=tape.panes(frame).find(p=>p.title.startsWith('Accounts'));
   if(sidebar){
    rois.sidebar=bounds(sidebar);
    const calendar=tape.find(frame,'Calendar · C'),followup=tape.find(frame,'Follow-ups');
    for(const [name,found] of [['calendar_entry',calendar],['followup_entry',followup]])if(found)rois[name]=[sidebar.x0/tape.columns,found.y/tape.rows,(sidebar.x1-sidebar.x0+1)/tape.columns,1/tape.rows];
    if(calendar&&followup){const top=Math.min(calendar.y,followup.y),bottom=Math.max(calendar.y,followup.y);rois.new_entries=[sidebar.x0/tape.columns,(top-1)/tape.rows,(sidebar.x1-sidebar.x0+1)/tape.columns,(bottom-top+3)/tape.rows];}
   }
   const accept=tape.find(frame,'[a Accept]');if(accept)rois.control=[accept.x/tape.columns,accept.y/tape.rows,10/tape.columns,1/tape.rows];
  }
  manifest.assets[job.key]={file:takeRoot+'/assets/'+filename,width:clip.width*2,height:clip.height*2,sha256:sha(data),rois,
   provenance:job.provenance||'Actual synthetic encrypted-service capture; literal CLI output or native PTY cells',
   tape:job.tape,mark:job.mark,frame:job.frame,panes:rect.panes};
 }
 await p.close();
}finally{await b.close();}
const logo=readFileSync(join(root,'video/assets/omagma-logo-master.png'));
manifest.assets.logo={file:'/video/assets/omagma-logo-master.png',width:logo.readUInt32BE(16),height:logo.readUInt32BE(20),sha256:sha(logo),provenance:'Existing approved Omagma logo'};
writeFileSync(join(cache,'assets-manifest.json'),JSON.stringify(measureROIs(manifest),null,2)+'\n');
console.log('Rasterized '+jobs.length+' genuine native/CLI states');
