import {mkdirSync,writeFileSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {parseArgs} from 'node:util';
import {browser,reservation,root} from './cdp.mjs';
const {values:o}=parseArgs({options:{movie:{type:'string',default:'calm-watchability-preview.mp4'},out:{type:'string'},ranges:{type:'string',default:'labels,30,43.2;forward,64.4,82.4;undo,82.4,92.4'},interval:{type:'string',default:'1'}}});
if(!/^[a-z0-9][a-z0-9.-]*\.mp4$/.test(o.movie)||o.movie.includes('..'))throw Error('invalid local movie name');
const interval=Number(o.interval);if(!Number.isFinite(interval)||interval<.2||interval>2)throw Error('invalid review sampling interval');
const ranges=o.ranges.split(';').map(s=>{const [n,a,b]=s.split(',');return[n,Number(a),Number(b)];});
if(ranges.some(([n,a,b])=>!/^[a-z0-9-]+$/.test(n)||!Number.isFinite(a)||!Number.isFinite(b)||a<0||b<=a))throw Error('invalid review range');
const out=resolve(o.out||join(root,'video/cache/short027/calm-motion-review'));
if(!out.startsWith(join(root,'video/cache/short027')+'/'))throw Error('review output must be inside owned media cache');
await reservation();
const b=await browser();mkdirSync(out,{recursive:true});
const sleep=ms=>new Promise(r=>setTimeout(r,ms)),receipts=[];
try{
 const p=await b.page('video/short027/review-player.html?movie='+encodeURIComponent(o.movie),{width:1280,height:720});
 if(ranges.some(([,a,end])=>end>p.info.duration+.1))throw Error('review range exceeds movie duration');
 for(const [name,start,end] of ranges){
  await p.evaluate("(()=>{const v=document.getElementById('movie');v.pause();return new Promise(r=>{v.onseeked=()=>r(true);v.currentTime="+start+";});})()");
  await p.evaluate("(()=>{const v=document.getElementById('movie');v.playbackRate=1;return v.play().then(()=>new Promise(r=>v.requestVideoFrameCallback?v.requestVideoFrameCallback(()=>r(true)):requestAnimationFrame(()=>r(true))));})()");
  const wallStart=Date.now(),samples=[];
  for(let i=0;i<=Math.floor((end-start)/interval);i++){
   const target=wallStart+i*interval*1000;
   if(Date.now()<target)await sleep(target-Date.now());
   const state=await p.evaluate("(()=>{const v=document.getElementById('movie');return{sourceTime:v.currentTime,paused:v.paused,readyState:v.readyState,playbackRate:v.playbackRate};})()");
   const path=join(out,name+'-'+String(i).padStart(2,'0')+'.png');writeFileSync(path,await p.screenshot());
   samples.push({...state,wallSeconds:(Date.now()-wallStart)/1000,file:path});
  }
  await p.evaluate("document.getElementById('movie').pause()");
  const elapsed=samples.at(-1).sourceTime-samples[0].sourceTime,wall=samples.at(-1).wallSeconds-samples[0].wallSeconds;
  if(samples.some(s=>s.paused||s.playbackRate!==1)||Math.abs(elapsed-wall)>.6||samples[0].sourceTime<start-.15||samples[0].sourceTime>start+.5)throw Error('movie did not advance at the requested time and real-time speed');
  receipts.push({name,requestedTime:[start,end],realTime:true,elapsedSourceSeconds:elapsed,elapsedWallSeconds:wall,samples});
 }
 writeFileSync(join(out,'receipt.json'),JSON.stringify({movie:o.movie,interval,method:'Actual headless video playback at1x, consecutive wall-clock samples; no render(t) seek between samples.',receipts},null,2));
 console.log('Played '+ranges.length+' task sequences at1x; saved consecutive real-time decoded frames.');
}finally{await b.close();}
