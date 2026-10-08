import {mkdirSync,writeFileSync,existsSync,readdirSync,rmSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {parseArgs} from 'node:util';
import {browser,reservation,root} from './cdp.mjs';
const {values:o}=parseArgs({options:{stills:{type:'string'},out:{type:'string'},scale:{type:'string',default:'1'},workers:{type:'string',default:'3'},step:{type:'string',default:'1'}}});
await reservation();
const out=resolve(o.out||join(root,'video/cache/short026/frames')), allowed=[join(root,'video/cache/short026'),join(root,'video/out/short026')];
if(!allowed.some(a=>out.startsWith(a+'/')))throw Error('output must be owned short026 cache/out subdirectory');
if(existsSync(out)&&readdirSync(out).length&&!existsSync(join(out,'.short026-render')))throw Error('refuse to replace unowned directory');
if(!o.stills&&existsSync(out))rmSync(out,{recursive:true,force:true});mkdirSync(out,{recursive:true});writeFileSync(join(out,'.short026-render'),'owned media output\n');
const scale=Number(o.scale),workers=Number(o.workers),step=Number(o.step);
if(!(scale>=.1&&scale<=2&&Number.isInteger(workers)&&workers>=1&&workers<=6&&Number.isInteger(step)&&step>=1))throw Error('bad render options');
const b=await browser();
try{
  const pages=await Promise.all(Array.from({length:workers},()=>b.page('video/short026/film.html',{scale})));
  const film=await pages[0].evaluate('window.FILM');if(!film||film.fps!==30||film.width!==1920||film.height!==1080||Math.round(film.duration*30)!==952)throw Error('unexpected film dimensions/timing');const jobs=o.stills?o.stills.split(',').map(Number):Array.from({length:Math.ceil(Math.round(film.duration*film.fps)/step)},(_,i)=>i*step/film.fps);
  if(!jobs.length||jobs.some(t=>!Number.isFinite(t)||t<0||t>=film.duration))throw Error('invalid frame times');
  let done=0;
  await Promise.all(pages.map(async(p,w)=>{for(let i=w;i<jobs.length;i+=workers){const t=jobs[i];await p.evaluate('window.render('+t+');new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(()=>r(true))))');const data=await p.screenshot(o.stills?'png':'jpeg');writeFileSync(join(out,o.stills?'t'+t.toFixed(2).padStart(6,'0')+'.png':String(i).padStart(5,'0')+'.jpg'),data);if(++done%150===0)console.log(done+'/'+jobs.length+' frames');}}));
  writeFileSync(join(out,'render.json'),JSON.stringify({film,count:jobs.length,scale,step,workers},null,2));
  console.log('rendered '+jobs.length+' frames/stills');
}finally{await b.close();}
