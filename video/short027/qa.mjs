import {mkdirSync,writeFileSync,readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {join} from 'node:path';
import {browser,reservation,root} from './cdp.mjs';
await reservation();
const out=join(root,'video/cache/short027/qa');mkdirSync(out,{recursive:true});
const plan=JSON.parse(readFileSync(join(root,'video/short027/soundtrack.json'),'utf8'));
const sha=data=>createHash('sha256').update(data).digest('hex');
const b=await browser();
try {
 const p=await b.page('video/short027/film.html');
 const render=t=>p.evaluate('window.render('+t+');new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(()=>r(true))))');
 const film=await p.evaluate('window.FILM');
 if(film.width!==1920||film.height!==1080||film.fps!==30||Math.round(film.duration*30)!==plan.frameCount)throw Error('film timing/dimensions differ from sample plan');
 const samples=[];
 for(const t of [2.5,7.5,17.4,24.8,28,32.7,37.5,41.8,49,58.2,63,71.2,74.8,81,85,87.5,91,98,104.7]){
  await render(t);
  const img=await p.screenshot();writeFileSync(join(out,'t'+t.toFixed(2)+'.png'),img);
  const state=await p.evaluate('({scene:window.qa?window.qa('+t+'):null,images:Array.from(document.images).map(i=>({src:i.getAttribute("src"),width:i.naturalWidth,height:i.naturalHeight})),text:document.body.innerText})');
  if(state.images.some(i=>!i.width||!i.height))throw Error('missing or undecodable captured image');
  samples.push({time:t,sha256:sha(img),...state});
 }
 const histories=[];
 for(const t of [17.4,37.5,74.8,91,98]){
  await render(t);const before=sha(await p.screenshot());
  await render(104.7);await render(.2);await render(t);const after=sha(await p.screenshot());
  if(before!==after)throw Error('render(t) depends on sampling history at '+t);
  histories.push({time:t,before,after,passed:true});
 }
 writeFileSync(join(out,'receipt.json'),JSON.stringify({film,deterministicHistoryChecks:histories,samples},null,2));
 console.log('Picture assets loaded; eight-chapter sample and arbitrary-order deterministic checks passed.');
} finally {await b.close();}
