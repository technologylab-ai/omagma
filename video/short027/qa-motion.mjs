import {mkdirSync,readFileSync,writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {browser,reservation,root} from './cdp.mjs';

await reservation();
const cache=join(root,'video/cache/short027'),out=join(cache,'motion-qa');
const plan=JSON.parse(readFileSync(join(root,'video/short027/motion.json'),'utf8'));
const soundtrack=JSON.parse(readFileSync(join(root,'video/short027/soundtrack-motion.json'),'utf8'));
const captures=JSON.parse(readFileSync(join(cache,'forward-story-manifest.json'),'utf8'));
if(plan.frameCount!==soundtrack.frameCount||plan.fps!==soundtrack.fps)throw Error('Picture/music frame mismatch');
let next=0;for(const part of plan.parts){if(part.frameIn!==next||part.frameOut<=part.frameIn)throw Error('Non-contiguous phase '+part.name);next=part.frameOut;}
if(next!==plan.frameCount||plan.parts.filter(p=>p.chapter).map(p=>p.chapter).filter((n,i,a)=>a.indexOf(n)===i).join(',')!=='1,2,3,4,5,6,7,8,9')throw Error('Nine-chapter coverage mismatch');
if(plan.parts.find(p=>p.name==='received airline').titleLead)throw Error('Received context was replaced by a blank title');
if(captures.typingAssets.length<6)throw Error('Typing requires progressive native captured states');
mkdirSync(out,{recursive:true});
const b=await browser(),sha=bytes=>createHash('sha256').update(bytes).digest('hex');
try{
 const p=await b.page('video/short027/film-motion.html'),film=await p.evaluate('window.FILM');
 if(film.frameCount!==plan.frameCount||film.width!==1920||film.height!==1080)throw Error('Film source dimensions/timing mismatch');
 const render=t=>p.evaluate('window.render('+t+');new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(()=>r(window.qa('+t+')))))');
 const shots=[];
 for(const part of plan.parts){
  const t=(part.frameIn+part.frameOut)/(2*plan.fps),state=await render(t);
  if(!part.titleLead&&part.overlay&&!state.visibleAssets.length)throw Error('Empty editorial overlay '+part.name);
  const data=await p.screenshot();writeFileSync(join(out,part.name.replaceAll(' ','-')+'.png'),data);shots.push({time:t,...state,imageSha256:sha(data)});
 }
 const find=name=>plan.parts.find(p=>p.name===name).frameIn/plan.fps;
 const reveal=await render(find('inbox')+.35);if(!(reveal.motion.reveal>0&&reveal.motion.reveal<1))throw Error('TUI reveal is abrupt');
 const joinBefore=await render(find('join')+.02),joinAfter=await render(find('join')+.9);if(joinAfter.motion.joinCamera.scale<=joinBefore.motion.joinCamera.scale*1.2)throw Error('Join camera does not push toward the highlighted control');
 const empty=await render(find('empty note')+.5);if(!empty.visibleAssets.includes(captures.emptyAsset))throw Error('Empty native editable note missing');
 const received=await render(find('received airline')+.5);if(!received.captions.includes('Received airline email'))throw Error('Incoming airline context missing');
 const typeStart=await render(find('note typing')+.05),typing=plan.parts.find(p=>p.name==='note typing'),typeEnd=await render((typing.frameOut-1)/plan.fps);if(typeEnd.motion.typingIndex<=typeStart.motion.typingIndex)throw Error('Native note/preview typing did not advance');
 const scroll=plan.parts.find(p=>p.name==='browser scroll'),scrollMiddle=await render((scroll.frameIn+scroll.frameOut)/(2*plan.fps));if(!(scrollMiddle.motion.scrollProgress>0&&scrollMiddle.motion.scrollProgress<1))throw Error('Original HTML scrolling is abrupt');
 const deterministic=[];
 for(const t of [find('inbox')+.35,find('join')+.5,find('note typing')+.8,find('browser scroll')+.5,find('update guide')+.5]){
  await render(t);const before=sha(await p.screenshot());await render(plan.duration-.2);await render(.2);await render(t);const after=sha(await p.screenshot());if(before!==after)throw Error('Absolute render clock depends on playback history at '+t);deterministic.push({time:t,sha256:before,passed:true});
 }
 writeFileSync(join(out,'receipt.json'),JSON.stringify({film,samples:shots,checks:{reveal,joinBefore,joinAfter,received,empty,typeStart,typeEnd,scrollMiddle},deterministicHistoryChecks:deterministic},null,2)+'\n');
 console.log('Nine chapters, genuine forwarding progression, smooth reveal/Join/scroll and deterministic render checks passed.');
}finally{await b.close();}
