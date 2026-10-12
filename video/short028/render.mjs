import {mkdirSync,writeFileSync,existsSync,readdirSync,readFileSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {parseArgs} from 'node:util';
import {browser,reservation,root} from './cdp.mjs';
const {values:o}=parseArgs({options:{stills:{type:'string'},out:{type:'string'},scale:{type:'string',default:'1'},workers:{type:'string',default:'3'},step:{type:'string',default:'1'},from:{type:'string'},to:{type:'string'},film:{type:'string',default:'film.html'},timeline:{type:'string',default:'timeline.json'},manifest:{type:'string',default:'assets-manifest.json'}}});
if(!['film.html','film-recut.html','film-story.html'].includes(o.film)||!['timeline.json','recut-timeline.json','story-timeline.json'].includes(o.timeline)||!['assets-manifest.json','recut-assets-manifest.json','story-assets-manifest.json'].includes(o.manifest))throw Error('unknown owned film source');
await reservation();
const plan=JSON.parse(readFileSync(join(root,'video/short028',o.timeline),'utf8'));
const out=resolve(o.out||join(root,'video/cache/short028/frames'));
if(!out.startsWith(join(root,'video/cache/short028')+'/'))throw Error('output must be owned short028 cache subdirectory');
if(existsSync(out)&&readdirSync(out).length)throw Error('preserve previous render directory');
mkdirSync(out,{recursive:true});writeFileSync(join(out,'.short028-render'),'owned media output\n');
const scale=Number(o.scale),workers=Number(o.workers),step=Number(o.step);
if(!(scale>=.1&&scale<=2&&Number.isInteger(workers)&&workers>=1&&workers<=4&&Number.isInteger(step)&&step>=1))throw Error('bad render options');
const b=await browser();
try{
 const pages=await Promise.all(Array.from({length:workers},()=>b.page('video/short028/'+o.film+'?timeline='+o.timeline+'&manifest=/video/cache/short028/'+o.manifest,{scale})));
 const film=await pages[0].evaluate('window.FILM');
 if(!film||film.fps!==30||film.width!==1920||film.height!==1080||Math.round(film.duration*film.fps)!==2527)throw Error('film dimensions/timing differ from approved audio');
 const start=o.from===undefined?0:Number(o.from),end=o.to===undefined?film.duration:Number(o.to);
 if(!Number.isFinite(start)||!Number.isFinite(end)||start<0||end>film.duration+1e-6||end<=start)throw Error('bad render range');
 const first=Math.ceil(start*30),last=Math.min(2527,Math.ceil(end*30));
 const jobs=o.stills?o.stills.split(',').map(Number):Array.from({length:Math.ceil((last-first)/step)},(_,i)=>(first+i*step)/30);
 if(!jobs.length||jobs.some(t=>!Number.isFinite(t)||t<0||t>=film.duration))throw Error('invalid frame times');
 let done=0;const qa=[];
 await Promise.all(pages.map(async(p,w)=>{for(let i=w;i<jobs.length;i+=workers){const t=jobs[i];await p.evaluate('window.render('+t+');Promise.resolve(window.prepareFrame?.()).then(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(()=>r(true)))))');const data=await p.screenshot(o.stills?'png':'jpeg');writeFileSync(join(out,o.stills?'t'+t.toFixed(2).padStart(6,'0')+'.png':String(i).padStart(5,'0')+'.jpg'),data);if(o.stills)qa.push(await p.evaluate('window.qa('+t+')'));if(++done%150===0)console.log(done+'/'+jobs.length+' frames');}}));
 writeFileSync(join(out,'render.json'),JSON.stringify({film,count:jobs.length,scale,step,workers,from:start,to:end,sampleFps:30/step,timeline:plan,qa},null,2));
 console.log('rendered '+jobs.length+' frames/stills');
}finally{await b.close();}
