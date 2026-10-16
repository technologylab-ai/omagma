/* Absolute-time progressive captions and annotations, following actual Opus direction.
 * The approved short027 intro is preserved. Native screenshots and input/read clocks stay fixed.
 * Configure once from the plan; render after the native compositor. No CSS or wall-clock timers.
 */
(function(global){'use strict';
 const clamp=x=>Math.max(0,Math.min(1,x));
 const out=x=>1-(1-clamp(x))**3,inward=x=>clamp(x)**3,smooth=x=>{x=clamp(x);return x*x*(3-2*x);};
 const settle=x=>{const u=clamp(x)-1;return 1+2.2*u*u*u+1.2*u*u;};
 const progress=(t,a,b,ease=out)=>ease(b<=a?+(t>=b):clamp((t-a)/(b-a)));
 const fixed=n=>Number(n).toFixed(5);
 let dom,lastState;
 const contexts=new Map();
 const words=text=>String(text||'').match(/\S+\s*/g)||[];
 function configure(plan){
  contexts.clear();let previousWords=[],previousBirths=[],previousSubtitle='',previousSubtitleBorn=-100;
  for(const shot of plan.shots){
   if(!['native','browser'].includes(shot.kind)){previousWords=[];previousBirths=[];previousSubtitle='';continue;}
   const firstAction=shot.actions?.[0],urgent=!!firstAction?.key&&firstAction.press<=1.1;
   const title=words(shot.title),births=[];let shared=0;
   while(shared<title.length&&shared<previousWords.length&&title[shared]===previousWords[shared])shared++;
   const changed=shared<title.length||title.length!==previousWords.length;
   for(let i=0;i<title.length;i++)births.push(i<shared?previousBirths[i]:shot.in+.02+.16*(i-shared)/Math.max(1,title.length-shared-1));
   const subtitles=[];let lastSubtitle=previousSubtitle,lastBorn=previousSubtitleBorn;
   for(const state of shot.states){
    const text=state.subtitle===undefined?(shot.subtitle||''):state.subtitle;
    if(text!==lastSubtitle){lastBorn=shot.in+state.at+(state.at===0?(changed?(urgent?.44:.50):.04):.22);lastSubtitle=text;}
    subtitles.push({at:state.at,text,born:lastBorn,duration:state.at===0&&urgent?.12:.16});
   }
   const firstSubtitleChanged=subtitles[0].born>=shot.in;
   contexts.set(shot.id,{words:title,births,changed,shared,subtitles,actionDelay:changed?(urgent?.58:.72):firstSubtitleChanged?.22:.04});
   previousWords=title;previousBirths=births;previousSubtitle=lastSubtitle;previousSubtitleBorn=lastBorn;
  }
  return contexts.size;
 }
 function nativeSample(input){
  const shot=input.shot,local=Number(input.local)||0,t=shot.in+local,c=contexts.get(shot.id)||{words:words(shot.title),births:words(shot.title).map(()=>shot.in+.04),changed:true,shared:0,subtitles:[{at:0,text:shot.subtitle||'',born:shot.in+.50}],actionDelay:.72};
  let current=shot.states[0];for(const st of shot.states)if(st.at<=local+1e-7)current=st;
  const actualTitle=current.title||shot.title,actualWords=words(actualTitle);let births=c.births,shared=c.shared;
  if(actualTitle!==shot.title){shared=0;while(shared<actualWords.length&&actualWords[shared]===c.words[shared])shared++;births=actualWords.map((w,i)=>i<shared?c.births[i]:shot.in+current.at+.02+.16*(i-shared)/Math.max(1,actualWords.length-shared-1));}
  const parts=actualWords.map((text,i)=>{const p=progress(t,births[i],births[i]+.24);return {text,opacity:p,y:12*(1-p),born:births[i],settledAt:births[i]+.24};});
  let subtitle=c.subtitles[0];for(const a of c.subtitles)if(a.at<=local+1e-7)subtitle=a;
  const sub=progress(t,subtitle.born,subtitle.born+(subtitle.duration||.16)),action=(shot.actions||[]).find(a=>local>=a.from&&local<a.until),actionStart=action?(action.from===0?c.actionDelay:action.from+(action.key?0:.02)):0,actionDuration=(action&&action.key)?0.08:0.16,ap=action?progress(local,actionStart,actionStart+actionDuration):0;
  let pointer=null,result=null,focus=null,route=[];
  const marker=(kind,start,until)=>{const e=clamp((local-start)/.4),v=settle(e),exit=local<until?1:1-progress(local,until,until+.15,smooth),r=progress(local,start+.12,start+.62);return {kind,opacity:out(e/.6)*exit,x:-40*(1-v),y:0,scale:.72+.28*v,start,settledAt:start+.62,until,ripple:{opacity:local>=start+.12&&local<start+.62?.75*(1-r)*exit:0,radius:8+26*r}};};
  if(shot.pointer&&local>=shot.pointer.from&&local<shot.pointer.until){const p=shot.pointer,start=Math.max(p.from,(action?.from||0)+.20),d=Math.min(.18,Math.max(.08,p.press-start-.03)),v=progress(local,start,start+d);pointer={kind:'pointer',opacity:v,x:-12*(1-v),y:8*(1-v),scale:.92+.08*v,start,settledAt:start+d,pressed:local>=p.press};}
  if(shot.resultPoint&&local>=shot.pointAfter){const start=shot.markerAt??shot.pointAfter+.26;result=marker('result-marker',start,shot.out-shot.in);}
  if(shot.focus&&local>=shot.focus.from&&local<shot.focus.until+.15)focus=marker('focus-marker',shot.focus.from,shot.focus.until);
  if(shot.kind==='browser'&&local>=(shot.proofAt||0)){const base=(shot.proofAt||0)+.26;route=[0,1,2].map(i=>{const start=base+i*.26,v=progress(local,start,start+.18);return {kind:'route-node',index:i,opacity:v,y:8*(1-v),start,settledAt:start+.18};});}
  return {mode:'native',local,t,sectionEntry:!!shot.sectionEntry,title:{text:actualTitle,clock:'absolute',changed:c.changed||actualTitle!==shot.title,sharedWords:shared,parts,visible:parts.filter(p=>p.opacity>.01).map(p=>p.text).join('').trim(),settledAt:Math.max(...parts.map(p=>p.settledAt))},subtitle:{text:subtitle.text,clock:'absolute',opacity:sub,y:4*(1-sub),start:subtitle.born,settledAt:subtitle.born+(subtitle.duration||.16)},action:action?{text:action.text,clock:'local',key:action.key,opacity:ap,y:5*(1-ap),start:actionStart,settledAt:actionStart+actionDuration,press:action.press}:null,pointer,result,focus,route};
 }
 function duration(shot,fallback){const d=Number(shot.out)-Number(shot.in);return Number.isFinite(d)&&d>0?d:fallback;}
 function sample(input){
  const shot=input.shot||{},local=Number.isFinite(Number(input.local))?Number(input.local):0;
  if(shot.kind==='intro'){
   const d=duration(shot,97/30),exit=1-progress(local,d-.50,d-.15,inward);
   const logo=progress(local,.10,1.15),word=progress(local,.40,1.20),version=progress(local,.70,1.40),strap=progress(local,.60,1.10);
   return {mode:'intro',local,duration:d,exit,logo,word,version,strap,
    segments:[0,1,2].map(i=>progress(local,1.00+i*.08,1.30+i*.08,smooth)*exit),
    glow:1-progress(local,d-.45,d-.05,smooth)};
  }
  if(shot.kind==='chapter'){
   const d=duration(shot,1.9),enter=progress(local,0,.40);
   return {mode:'chapter',local,duration:d,enter,groupAlpha:enter,y:(1-enter)*16,rule:progress(local,.12,.52)};
  }
  if(['native','browser'].includes(shot.kind))return nativeSample(input);
  return {mode:'off',local};
 }
 function mount(){
  if(dom)return dom;
  const host=document.getElementById('motion')||document.createElement('div');host.id='motion';
  const make=(tag,cls,parent,text)=>{const e=document.createElement(tag);e.className=cls;if(text!==undefined)e.textContent=text;parent.appendChild(e);return e;};
  host.replaceChildren();
  const glow=make('div','cm-glow',host),intro=make('div','cm-intro',host);
  const logo=make('img','cm-logo',intro);logo.alt='Omagma';
  const word=make('div','cm-word',intro,'Omagma'),version=make('div','cm-version',intro,'v0.2.10'),strap=make('div','cm-strap',intro,'Calendar in your terminal');
  const bars=make('div','cm-segments',intro),segments=[0,1,2].map(()=>make('i','',bars));
  const divider=make('div','cm-divider',host),number=make('div','cm-number',divider),group=make('div','cm-divider-group',divider);
  const kicker=make('div','cm-kicker',group),title=make('h1','cm-title',group),rule=make('div','cm-rule',group);
  if(!host.isConnected)(document.getElementById('screen')||document.body).appendChild(host);
  return dom={host,glow,intro,logo,word,version,strap,segments,divider,number,group,kicker,title,rule};
 }
 function reset(d){
  d.host.style.display='none';d.intro.style.display='none';d.divider.style.display='none';
  for(const e of [d.glow,d.logo,d.word,d.version,d.strap,d.number,d.group,d.rule,...d.segments]){e.style.opacity='0';e.style.transform='none';}
 }
 function rise(el,p,alpha,pixels){el.style.opacity=fixed(p*alpha);el.style.transform='translateY('+fixed((1-p)*pixels)+'px)';}
 function render(input){
  const s=sample(input),d=mount();reset(d);d.host.dataset.mode=s.mode;
  lastState=s;
  if(s.mode==='off')return s;
  if(s.mode==='native'){
   const heading=document.getElementById('heading'),subtitle=document.getElementById('subheading'),action=document.getElementById('action');
   heading.className=s.sectionEntry?'section-entry':'';heading.replaceChildren();
   for(const part of s.title.parts){const span=document.createElement('span');span.className='cm-wordpart';span.textContent=part.text;span.style.opacity=fixed(part.opacity);span.style.transform='translateY('+fixed(part.y)+'px)';heading.appendChild(span);}
   for(const [el,v] of [[subtitle,s.subtitle],[action,s.action]]){el.style.opacity=fixed(v?.opacity||0);el.style.transform='translateY('+fixed(v?.y||0)+'px)';}
   for(const [id,v] of [['editorial-pointer',s.pointer],['editorial-result',s.result],['editorial-focus',s.focus]]){const e=document.getElementById(id);if(e&&v){e.style.opacity=fixed(v.opacity);e.style.transform='translate('+fixed(v.x)+'px,'+fixed(v.y)+'px) scale('+fixed(v.scale)+')';const ripple=e.querySelector('.marker-ripple');if(ripple&&v.ripple){ripple.setAttribute('r',fixed(v.ripple.radius/1.3));ripple.style.opacity=fixed(v.ripple.opacity);}}}
   document.querySelectorAll('.route .node').forEach((e,i)=>{const v=s.route[i];e.style.opacity=fixed(v?.opacity||0);e.style.transform='translateY('+fixed(v?.y||0)+'px)';});
   document.querySelectorAll('.route .arrow').forEach((e,i)=>{const v=s.route[i];e.style.opacity=fixed(v?progress(s.local,v.settledAt,v.settledAt+.08):0);});
   return s;
  }
  d.host.style.display='block';
  if(s.mode==='intro'){
   d.intro.style.display='block';const src=input.logo||'';if(src&&d.logo.getAttribute('src')!==src)d.logo.src=src;
   d.glow.style.opacity=fixed(s.glow);
   d.logo.style.opacity=fixed(s.logo*s.exit);d.logo.style.transform='translateY('+fixed((1-s.logo)*18)+'px) scale('+fixed((.90+.10*s.logo)*(1+.04*(1-s.exit)))+')';
   rise(d.word,s.word,s.exit,26);rise(d.version,s.version,s.exit,18);rise(d.strap,s.strap,s.exit,18);
   d.segments.forEach((el,i)=>{el.style.opacity=fixed(s.segments[i]);});
  }else{
   const shot=input.shot;d.divider.style.display='block';d.number.textContent=String(shot.chapter||'').padStart(2,'0');d.number.style.opacity=fixed(s.enter);
   d.kicker.textContent='CHAPTER '+String(shot.chapter||'').padStart(2,'0');d.title.textContent=shot.motionTitle||shot.title||'';
   d.group.style.opacity=fixed(s.groupAlpha);d.group.style.transform='translateY('+fixed(s.y)+'px)';
   d.rule.style.opacity='1';d.rule.style.transform='scaleX('+fixed(s.rule)+')';
  }
  return s;
 }
 global.CHAPTER_MOTION=Object.freeze({render,sample,configure,get lastState(){return lastState;},source:'Approved short027 opener; absolute-time progressive native captions'});
})(window);
