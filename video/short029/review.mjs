// Actual encoded video at normal speed. This verifies playback, not listening.
import {mkdirSync,writeFileSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {parseArgs} from 'node:util';
import {browser,reservation,root} from './cdp.mjs';
const {values:o}=parseArgs({options:{out:{type:'string'},movie:{type:'string',default:'final-review.mp4'}}});
if(!/^[a-z0-9][a-z0-9.-]*\.mp4$/.test(o.movie)||o.movie.includes('..'))throw Error('invalid movie filename');
await reservation();const out=resolve(o.out||join(root,'video/cache/short029/playback-review'));if(!out.startsWith(join(root,'video/cache/short029')+'/'))throw Error('owned review directory required');mkdirSync(out,{recursive:true});
const b=await browser(),sleep=ms=>new Promise(r=>setTimeout(r,ms)),samples=[];
try{
 const p=await b.page('video/short029/review-player.html?movie='+encodeURIComponent(o.movie),{width:1280,height:720});
 if(Math.abs(p.info.duration-2527/30)>.1)throw Error('wrong encoded duration');
 await p.evaluate(`(()=>{const v=document.getElementById('movie');window.decoded=[];const c=document.createElement('canvas');c.width=96;c.height=54;const x=c.getContext('2d',{willReadFrequently:true});const frame=(now,m)=>{x.drawImage(v,0,0,96,54);const d=x.getImageData(0,0,96,54).data;const corner=[];for(const i of [0,95,53*96,54*96-1])corner.push(...d.slice(i*4,i*4+3));window.decoded.push({time:m.mediaTime,presented:m.presentedFrames,wall:performance.now(),corner});if(!v.ended)v.requestVideoFrameCallback(frame);};v.requestVideoFrameCallback(frame);v.playbackRate=1;return v.play();})()`);
 const wallStart=Date.now();
 for(let i=0;i<=83;i++){
  const target=wallStart+i*1000;if(Date.now()<target)await sleep(target-Date.now());
  const state=await p.evaluate(`(()=>{const v=document.getElementById('movie');return {sourceTime:v.currentTime,paused:v.paused,playbackRate:v.playbackRate,quality:v.getVideoPlaybackQuality().toJSON?.()||{total:v.getVideoPlaybackQuality().totalVideoFrames,dropped:v.getVideoPlaybackQuality().droppedVideoFrames}};})()`);
  const file='second-'+String(i).padStart(2,'0')+'.png';writeFileSync(join(out,file),await p.screenshot());samples.push({...state,wallSeconds:(Date.now()-wallStart)/1000,file});
  if(i%15===0)console.log('Reviewed encoded playback '+i+'/84 seconds at1x');
 }
 await sleep(1300);const decoded=await p.evaluate('window.decoded');await p.evaluate('document.getElementById("movie").pause()');
 const sourceElapsed=samples.at(-1).sourceTime-samples[0].sourceTime,wallElapsed=samples.at(-1).wallSeconds-samples[0].wallSeconds;
 if(samples.some(s=>s.paused||s.playbackRate!==1)||Math.abs(sourceElapsed-wallElapsed)>.6||decoded.length<2400)throw Error('normal-speed playback stalled/dropped too many observed frames');
 let cornerStep=0;for(let i=1;i<decoded.length;i++)for(let j=0;j<12;j++)cornerStep=Math.max(cornerStep,Math.abs(decoded[i].corner[j]-decoded[i-1].corner[j]));
 if(cornerStep>6)throw Error('unexpected outer-background flash');
 writeFileSync(join(out,'receipt.json'),JSON.stringify({method:'Actual encoded headless video playback at1x, consecutive wall-clock screenshots and decoded-frame callbacks; muted; no claim of listening',passed:true,samples,decodedFrames:decoded.length,sourceElapsed,wallElapsed,maxOuterCornerStep:cornerStep,decoded},null,2)+'\n');
 console.log('Normal-speed encoded playback passed; '+decoded.length+' decoded frames observed');
}finally{await b.close();}
