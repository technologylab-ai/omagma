// Deterministic frames/stills for the v0.2.10 film. Heavy: requires the live shared-host reservation.
import {mkdirSync,writeFileSync,existsSync,readdirSync,readFileSync} from 'node:fs';
import {resolve,join,isAbsolute,sep} from 'node:path';
import {createHash} from 'node:crypto';
import {parseArgs} from 'node:util';
import {browser,reservation,root} from './cdp.mjs';
const {values:o}=parseArgs({options:{stills:{type:'string'},out:{type:'string'},scale:{type:'string',default:'1'},workers:{type:'string',default:'3'},step:{type:'string',default:'1'},from:{type:'string'},to:{type:'string'},manifest:{type:'string',default:'revision-05/assets-manifest.json'}}});
const cache=join(root,'video/cache/short0210'),source=join(root,'video/short0210');
if(isAbsolute(o.manifest)||o.manifest.split('/').includes('..')||!/^[A-Za-z0-9][A-Za-z0-9._-]*(\/[A-Za-z0-9][A-Za-z0-9._-]*)*\.json$/.test(o.manifest))throw Error('--manifest must be a JSON path relative to video/cache/short0210/');
const manifestFile=join(cache,o.manifest);if(!existsSync(manifestFile))throw Error('missing manifest video/cache/short0210/'+o.manifest);
const out=resolve(o.out||join(cache,'revision-05',o.stills?'stills':'frames'));
if(!out.startsWith(cache+sep))throw Error('output must be a subdirectory of video/cache/short0210/');
if(existsSync(out)&&readdirSync(out).length)throw Error('preserve previous render: output directory is not empty');
const scale=Number(o.scale),workers=Number(o.workers),step=Number(o.step);
if(!(scale>=.1&&scale<=2&&Number.isInteger(workers)&&workers>=1&&workers<=4&&Number.isInteger(step)&&step>=1))throw Error('bad render options');
if(o.stills&&(o.from!==undefined||o.to!==undefined||step!==1))throw Error('--stills cannot be combined with --from, --to or --step');
const sha=file=>createHash('sha256').update(readFileSync(file)).digest('hex');
const sources=Object.fromEntries(['film.html','direction.js','direction.css','timeline.json','render.mjs','cdp.mjs'].map(name=>[name,sha(join(source,name))]));
await reservation();
mkdirSync(out,{recursive:true});writeFileSync(join(out,'.short0210-render'),'owned media output\n');
const b=await browser();
try{
 const url='video/short0210/film.html?manifest='+encodeURIComponent('/video/cache/short0210/'+o.manifest);
 const pages=await Promise.all(Array.from({length:workers},()=>b.page(url,{width:1920,height:1080,scale})));
 const film=pages[0].info;
 if(!film||film.ok!==true||film.width!==1920||film.height!==1080||film.fps!==30||film.frameCount!==2527||Math.abs(film.duration-2527/30)>1e-9)throw Error('film metadata differs from the approved 2,527-frame soundtrack clock');
 for(const p of pages){const size=await p.evaluate('[innerWidth,innerHeight,devicePixelRatio]');if(size[0]!==1920||size[1]!==1080||size[2]!==scale)throw Error('viewport must stay 1920x1080 at the requested scale');}
 const start=o.from===undefined?0:Number(o.from),end=o.to===undefined?film.duration:Number(o.to);
 if(!Number.isFinite(start)||!Number.isFinite(end)||start<0||end>film.duration+1e-9||end<=start)throw Error('bad render range');
 const first=Math.ceil(start*30-1e-6),last=Math.min(2527,Math.ceil(end*30-1e-6));
 const jobs=o.stills?o.stills.split(',').map(s=>Number(s.trim())):Array.from({length:Math.ceil((last-first)/step)},(_,i)=>(first+i*step)/30);
 if(!jobs.length||jobs.some(t=>!Number.isFinite(t)||t<0||t>=film.duration))throw Error('invalid frame times');
 const partial=!o.stills&&(first!==0||last!==2527);
 let done=0;const qa=new Array(jobs.length);
 await Promise.all(pages.map(async(p,w)=>{for(let i=w;i<jobs.length;i+=workers){
  const t=jobs[i],state=await p.evaluate('(async()=>{const s=window.render('+t+');await window.prepareFrame();await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(()=>r())));return s;})()');
  const name=o.stills?'t'+t.toFixed(3).padStart(7,'0'):String(i).padStart(5,'0');
  writeFileSync(join(out,name+(o.stills?'.png':'.jpg')),await p.screenshot(o.stills?'png':'jpeg',100));
  if(o.stills)writeFileSync(join(out,name+'.qa.json'),JSON.stringify(state,null,2)+'\n');
  qa[i]={output:name,frame:state.frame,t:state.t,phase:state.phase,assets:state.visibleAssets,crops:state.views.map(v=>({asset:v.asset,crop:v.crop,pane:v.pane,opacity:v.opacity})),captions:state.visibleCaptions,cues:state.cues.map(c=>c.key),overlays:state.overlays.map(x=>x.kind)};
  if(++done%150===0)console.log(done+'/'+jobs.length+' frames');
 }}));
 writeFileSync(join(out,'qa.jsonl'),qa.map(x=>JSON.stringify(x)).join('\n')+'\n');
 writeFileSync(join(out,'render.json'),JSON.stringify({film,count:jobs.length,stills:!!o.stills,partial,scale,step,workers,from:start,to:end,firstFrame:o.stills?null:first,lastFrame:o.stills?null:last,sampleFps:30/step,times:o.stills?jobs:null,viewport:{width:1920,height:1080,deviceScaleFactor:scale},manifest:o.manifest,manifestSha256:sha(manifestFile),sources},null,2)+'\n');
 console.log('rendered '+jobs.length+(o.stills?' stills':' frames')+(partial?' (partial proof; not encodable)':''));
}finally{await b.close();}
