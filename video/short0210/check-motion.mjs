// Temporal invariants for native action cuts and editorial anchors. Requires the shared media reservation.
import {writeFileSync,readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {resolve} from 'node:path';
import {parseArgs} from 'node:util';
import {browser,reservation,root} from './cdp.mjs';
const {values:o}=parseArgs({options:{out:{type:'string'}}});
if(!o.out||!resolve(o.out).startsWith(root+'/video/cache/short0210/'))throw Error('owned motion-check output required');
await reservation();const b=await browser();
try{
 const p=await b.page('video/short0210/film.html');
 const result=await p.evaluate(`(()=>{
  const errors=[],counts={frames:0,nativePairs:0,captionPairs:0,cueLeaders:0,savedFrames:0,comparisonFrames:0,legendFrames:0};
  const overlap=(a,b)=>Math.max(0,Math.min(a[0]+a[2],b[0]+b[2])-Math.max(a[0],b[0]))*Math.max(0,Math.min(a[1]+a[3],b[1]+b[3])-Math.max(a[1],b[1]));
  const err=(s,m)=>{if(errors.length<60)errors.push({time:s.t,phase:s.phase,message:m});};
  for(let f=0;f<2527;f++){
   const s=window.render(f/30);counts.frames++;
   for(const [name,c]of Object.entries(s.textSlots)){counts.captionPairs++;if(c.incoming>.002&&c.outgoing>.002)err(s,'caption double exposure: '+name);}
   const views=s.views.filter(v=>v.opacity>.04);
   for(let a=0;a<views.length;a++)for(let d=a+1;d<views.length;d++){
    counts.nativePairs++;const x=views[a],y=views[d];
    if(overlap(x.pane,y.pane)>400&&!(s.phase==='together'&&x.asset===y.asset&&[x.id,y.id].includes('legend')))err(s,'intersecting native text planes '+x.id+'/'+y.id);
   }
   for(const c of s.cues){if(c.alpha>.02&&!views.some(v=>v.id===c.targetView)&&!(s.phase==='guests'&&c.key==='Ctrl+Space'))err(s,'cue persists after its native pane disappears '+c.key);if(c.leader){counts.cueLeaders++;if(!c.targetVisible||c.pressed&&c.travel>.7)err(s,'detached/late cue leader '+c.key);}}
   for(const v of views)if(['event.saved','event.rescheduled','event.all-day-saved'].includes(v.asset)){
    counts.savedFrames++;if(v.spot&&v.spot.alpha>.05&&(v.spot.crop[1]>4/32+.001||v.spot.crop[1]+v.spot.crop[3]<9/32-.001))err(s,'saved outcome leaves header dimmed');
   }
   if(s.phase==='reschedule'){
    const before=views.find(v=>v.id==='before');if(before){counts.comparisonFrames++;const label=document.querySelector('.pane-label.before');if(!label||Number(label.style.opacity)<.9)err(s,'unlabelled historical Week');}
    if(s.local>=11.8&&document.querySelector('.chip'))err(s,'comparison chip persists into camera expansion');
   }
   if(s.phase==='together'&&s.local>=3.4){counts.legendFrames++;if(!views.find(v=>v.id==='legend'&&v.opacity>.99))err(s,'native legend disappears during extraction');}
  }
  const geometry=[];
  for(const t of [6,6.6,7,30.35,31.5,32.6,33.2,34.3,35.2,36.2,37.8,38.6,40.9,44.2,47.5,48,52.5,61.7,63.2,66,68.8,70.8,72,77.3,79.6]){
   const s=window.render(t);const rects=[...document.querySelectorAll('.cue,.note,.chip,.pane-label')].map(e=>{const r=e.getBoundingClientRect();return {text:e.textContent,opacity:Number(e.style.opacity),rect:[r.x,r.y,r.width,r.height]};});
   rects.forEach(r=>{if(r.opacity>.05&&(r.rect[0]<0||r.rect[1]<0||r.rect[0]+r.rect[2]>1920||r.rect[1]+r.rect[3]>1080))err(s,'editorial label outside frame: '+r.text);});geometry.push({time:t,phase:s.phase,labels:rects});
  }
  return{passed:errors.length===0,counts,errors,geometry};
 })()`);
 result.sources=Object.fromEntries(['film.html','direction.js','direction.css','timeline.json'].map(n=>[n,createHash('sha256').update(readFileSync(root+'/video/short0210/'+n)).digest('hex')]));
 writeFileSync(resolve(o.out),JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify({passed:result.passed,counts:result.counts,errors:result.errors}));if(!result.passed)process.exitCode=1;
}finally{await b.close();}
