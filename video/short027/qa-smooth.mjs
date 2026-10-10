import {mkdirSync,readFileSync,writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {browser,reservation,root} from './cdp.mjs';

await reservation();
const out=join(root,'video/cache/short027/smooth-qa');mkdirSync(out,{recursive:true});
const plan=JSON.parse(readFileSync(join(root,'video/short027/smooth.json'),'utf8'));
const music=JSON.parse(readFileSync(join(root,'video/short027/soundtrack-smooth.json'),'utf8'));
if(plan.frameCount!==music.frameCount||plan.fps!==music.fps)throw Error('Picture/music duration mismatch');
const b=await browser(),sha=x=>createHash('sha256').update(x).digest('hex');
try{
 const pages=await Promise.all([b.page('video/short027/film-smooth.html'),b.page('video/short027/film-smooth.html')]);
 const render=async(p,t)=>p.evaluate('window.render('+t+');window.prepareFrame().then(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(()=>r(window.qa('+t+'))))))');
 // Check the actual compositor across every output frame. The inbox is a
 // permitted background only during launch and the action palette.
 const checks=await pages[0].evaluate(`(()=>{let last='',count=0;for(let f=0;f<window.FILM.frameCount;f++){const s=window.qa(f/30);if(s.globalFlash!==0)throw Error('Screen flash at '+f);if(s.visibleAssets.includes('main.png')&&!['inbox','palette untouched','palette typing','palette narrowed'].includes(s.phase))throw Error('Unrelated inbox at '+f);if(!['intro','recap','outro'].includes(s.phase)&&!s.visibleAssets.length)throw Error('Empty intermediate at '+f);if(s.phase!==last){count++;last=s.phase;}}return{frames:window.FILM.frameCount,phases:count};})()`);
 const shots=[];
 for(const part of plan.parts){
  const t=Math.min(part.frameIn/30+.8,(part.frameOut-1)/30),s=await render(pages[0],t),data=await pages[0].screenshot();
  const file=part.name.replaceAll(' ','-')+'.png';writeFileSync(join(out,file),data);shots.push({file,...s,sha256:sha(data)});
 }
 // Workers must render identical pixels even after unrelated seeks. Check
 // every chapter handoff, native substate change and moving camera at30fps.
 const probes=new Set(plan.parts.slice(1).flatMap(p=>[p.frameIn/30,(p.frameIn+1)/30,p.frameIn/30+Math.min(.2,(p.frameOut-p.frameIn-1)/30)]));
 for(const t of [6.15,10.6,24.9,32.2,46.5,53.8])probes.add(t);
 const deterministic=[];
 for(const t of probes){
  await render(pages[0],t);const before=await pages[0].screenshot(),expected=sha(before);
  await render(pages[1],83.6);await render(pages[1],.4);await render(pages[1],t);
  const after=await pages[1].screenshot(),actual=sha(after);let pixelDifference=null;
  if(expected!==actual){
   const a=join(out,'worker-before.png'),b=join(out,'worker-after.png');writeFileSync(a,before);writeFileSync(b,after);
   const diff=spawnSync('ffmpeg',['-hide_banner','-loglevel','error','-i',a,'-i',b,'-filter_complex','blend=all_mode=difference','-frames:v','1','-pix_fmt','rgb24','-f','rawvideo','pipe:1'],{maxBuffer:10*1024*1024});
   if(diff.status||diff.stdout.length!==1920*1080*3)throw Error('Unable to compare prepared pixels');
   let max=0,sum=0,significant=0;for(const x of diff.stdout){max=Math.max(max,x);sum+=x;if(x>2)significant++;}
   pixelDifference={max,mean:sum/diff.stdout.length,significantFraction:significant/diff.stdout.length};
   // Chromium may round a few anti-aliased border pixels differently after
   // different compositing histories. Reject visible changes, not a handful
   // of subpixel edge values (measured85dBPSNR in the initial diagnostic).
   if(max>16||pixelDifference.mean>.01||pixelDifference.significantFraction>.0001)throw Error('Visible worker/history-dependent pixels at '+t+' '+JSON.stringify(pixelDifference));
  }
  deterministic.push({t,sha256:actual,pixelDifference});
 }
 writeFileSync(join(out,'receipt.json'),JSON.stringify({checks,shots,deterministic,method:'Every-frame compositor checks plus actual prepared screenshots on two independent renderers at all handoffs; decoded movie playback is reviewed separately.'},null,2)+'\n');
 console.log('Checked all2520frames: no unrelated inbox or empty intermediate; '+deterministic.length+' cross-worker pixel probes passed.');
}finally{await b.close();}
