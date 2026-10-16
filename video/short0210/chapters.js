(function(){'use strict';
const $=id=>document.getElementById(id),clamp=x=>Math.max(0,Math.min(1,x)),smooth=x=>{x=clamp(x);return x*x*(3-2*x);},esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const query=new URLSearchParams(location.search),manifestURL=new URL(query.get('manifest')||'/video/cache/short0210/revision-08/assets-manifest.json',location.href),images={};
let plan,manifest,current;
async function json(u){const r=await fetch(u,{cache:'no-store'});if(!r.ok)throw Error('Missing '+u);return r.json();}
function at(sequence,t){let a=sequence[0];for(const s of sequence)if(s.at<=t+1e-7)a=s;return a;}
function native(id,asset,roi,box){
 const p=$(id),img=id==='picture'?$('native'):$('native-second'),meta=manifest.assets[asset],r=roi||[0,0,1,1];
 const s=Math.min(box[2]/(meta.width*r[2]),box[3]/(meta.height*r[3])),w=meta.width*r[2]*s,h=meta.height*r[3]*s,x=Math.round(box[0]+(box[2]-w)/2),y=Math.round(box[1]+(box[3]-h)/2);
 p.style.cssText='display:block;left:'+x+'px;top:'+y+'px;width:'+Math.round(w)+'px;height:'+Math.round(h)+'px';
 img.src=images[asset].src;img.style.cssText='left:'+Math.round(-meta.width*r[0]*s)+'px;top:'+Math.round(-meta.height*r[1]*s)+'px;width:'+(meta.width*s)+'px;height:'+(meta.height*s)+'px';
 return {asset,crop:r,pane:[x,y,Math.round(w),Math.round(h)],opacity:1,scale:s};
}
function render(time){
 const t=Math.max(0,Math.min((plan.frames-1)/plan.fps,time)),shot=plan.shots.find(s=>t>=s.in&&t<s.out)||plan.shots.at(-1),local=t-shot.in,views=[],cues=[];
 current=shot;$('rail').innerHTML=plan.chapters.map((c,i)=>'<span class="'+(shot.chapter===i+1?'active':'')+'"><i>0'+(i+1)+'</i>'+esc(c)+'</span>').join('');
 $('picture').style.display='none';$('second').style.display='none';$('shade').style.display='none';$('chapter').style.display='none';$('heading').textContent='';$('subheading').textContent='';$('action').innerHTML='';$('editorial').innerHTML='';$('labels').innerHTML='';
 const marker=(id,x,y)=>'<svg id="'+id+'" class="pointer" width="52" height="52" viewBox="0 0 40 40" style="left:'+(x-65)+'px;top:'+(y-26)+'px"><circle class="marker-ripple" cx="20" cy="20" r="0" fill="none" stroke="#a3eff0" stroke-width="2"/><path d="M2 8 L22 8 L37 20 L22 32 L2 32 Z" fill="#a3eff0"/></svg>';
 if(shot.kind==='chapter'||shot.kind==='intro'){
  const c=$('chapter');c.style.display='block';$('number').textContent='0'+shot.chapter;$('chapter-kicker').textContent='OMAGMA 0.2.10 · CHAPTER 0'+shot.chapter;
  c.querySelector('h1').textContent=shot.title;c.querySelector('p').textContent=shot.subtitle||'';
  c.querySelector('h1').style.transform='translateY('+((1-smooth(local/.5))*22)+'px)';
  $('chapter-line').style.transform='scaleX('+smooth(local/.65)+')';
 }else if(shot.kind==='end'){
  $('editorial').innerHTML='<img class="end-logo" src="'+images.logo.src+'"><div class="end-title">omagma</div><div class="end-version">v0.2.10</div><div class="end-features">'+esc(shot.title)+'</div><div class="end-url">technologylab-ai.github.io/omagma</div>';
 }else{
  const state=at(shot.states,local),roi=state.roi||shot.roi||[0,0,1,1],box=state.box||shot.box||[100,230,1720,730];
  $('heading').textContent=state.title||shot.title;$('subheading').textContent=state.subtitle===undefined?(shot.subtitle||''):state.subtitle;
  views.push(native('picture',state.asset,roi,box));
  if(shot.second){const a=at(shot.second.states,local);views.push(native('second',a.asset,a.roi||shot.second.roi,shot.second.box));}
  if(shot.labels)$('labels').innerHTML=shot.labels.map(l=>'<div class="label" style="left:'+l.x+'px;top:'+l.y+'px">'+esc(l.text)+'</div>').join('');
  const action=(shot.actions||[]).find(a=>local>=a.from&&local<a.until);
  if(action){$('action').innerHTML=(action.key?'<span class="key '+(local>=action.press?'pressed':'')+'">'+esc(action.key)+'</span>':'')+'<span class="verb">'+esc(action.text)+'</span>'+(action.trail?'<span class="trail">'+esc(action.trail)+'</span>':'');if(action.key)cues.push({key:action.key,pressed:local>=action.press});}
  const spot=(shot.spots||[]).find(s=>local>=s.from&&local<s.until);
  if(spot){const v=views[0],m=manifest.assets[v.asset],r=spot.roi,p=$('shade');p.style.cssText='display:block;left:'+Math.round((r[0]-roi[0])*m.width*v.scale)+'px;top:'+Math.round((r[1]-roi[1])*m.height*v.scale)+'px;width:'+Math.round(r[2]*m.width*v.scale)+'px;height:'+Math.round(r[3]*m.height*v.scale)+'px';}
  if(shot.focus&&local>=shot.focus.from&&local<shot.focus.until+.15){const v=views[0],m=manifest.assets[v.asset],r=shot.focus.at,x=v.pane[0]+(r[0]-roi[0])*m.width*v.scale,y=v.pane[1]+(r[1]-roi[1])*m.height*v.scale;$('editorial').innerHTML=marker('editorial-focus',x,y);}
  const pointer=shot.pointer;
  if(pointer&&local>=pointer.from&&local<pointer.until){
   const v=views[0],m=manifest.assets[v.asset],x=v.pane[0]+(pointer.at[0]-roi[0])*m.width*v.scale,y=v.pane[1]+(pointer.at[1]-roi[1])*m.height*v.scale;
   $('editorial').innerHTML='<svg id="editorial-pointer" class="pointer" width="58" height="74" viewBox="0 0 58 74" style="left:'+x+'px;top:'+y+'px"><path d="M3 3 L3 49 L15 39 L25 63 L36 58 L25 35 L43 35 Z" fill="#f3f5f7" stroke="#0b1017" stroke-width="3"/>'+(local>=pointer.press?'<circle cx="4" cy="4" r="21" fill="none" stroke="#a3eff0" stroke-width="5"/>':'')+'</svg>';
  }
  if(shot.resultPoint&&local>=shot.pointAfter){
   const v=views[0],m=manifest.assets[v.asset],x=v.pane[0]+(shot.resultPoint[0]-roi[0])*m.width*v.scale,y=v.pane[1]+(shot.resultPoint[1]-roi[1])*m.height*v.scale;
   $('editorial').innerHTML=marker('editorial-result',x,y);
  }
  if(shot.kind==='browser'&&local>=(shot.proofAt||0)){
   $('editorial').innerHTML='<div class="route"><div class="node"><small>EVENT ACCOUNT</small><strong>work@example.com</strong></div><div class="arrow">→</div><div class="node"><small>CONFIGURED CHROME PROFILE</small><strong>Work</strong></div><div class="arrow">→</div><div class="node"><small>DESTINATION</small><strong>Selected event</strong></div></div>';
  }
 }
 const motion=window.CHAPTER_MOTION?.render({shot,local,t,logo:images.logo.src})||null;
 const overlays=motion?.mode==='native'?[{kind:'headline',...motion.title},{kind:'subtitle',...motion.subtitle},...(motion.action?[{kind:'action-cue',...motion.action}]:[]),...[motion.pointer,motion.result,motion.focus,...motion.route].filter(Boolean)]:[];
 const state={frame:Math.round(t*plan.fps),t,phase:shot.id,chapter:shot.chapter,visibleAssets:views.map(v=>v.asset),views,visibleCaptions:motion?.mode==='native'?[motion.title.visible,motion.subtitle.opacity>.01?motion.subtitle.text:''].filter(Boolean):[$('heading').textContent,$('subheading').textContent].filter(Boolean),cues,overlays,motion};return state;
}
window.render=render;window.qa=render;window.prepareFrame=()=>Promise.all([...document.images].map(i=>i.decode().catch(()=>{})));
window.READY=(async()=>{
 plan=await json(new URL('chapter-plan.json',location.href));window.CHAPTER_MOTION?.configure(plan);manifest=await json(manifestURL);const keys=new Set(['logo']);let end=0;
 for(const s of plan.shots){if(Math.abs(s.in-end)>1e-6||s.out<=s.in)throw Error('Timeline gap '+s.id);end=s.out;for(const st of [...(s.states||[]),...(s.second?.states||[])])keys.add(st.asset);if(s.states?.[0].at!==0&&s.states)throw Error('First state not at zero '+s.id);}
 if(Math.abs(end-plan.frames/plan.fps)>1e-6)throw Error('Incorrect picture clock');
 await Promise.all([...keys].map(async key=>{const a=manifest.assets[key];if(!a)throw Error('Missing native asset '+key);const r=await fetch(new URL(a.file,manifestURL));if(!r.ok)throw Error('Native fetch failed '+key);const bytes=await r.arrayBuffer(),hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');if(hash!==a.sha256)throw Error('Native SHA mismatch '+key);const img=new Image();img.src=URL.createObjectURL(new Blob([bytes]));await img.decode();if(img.naturalWidth!==a.width||img.naturalHeight!==a.height)throw Error('Native dimensions mismatch '+key);images[key]=img;}));
 await document.fonts.ready;window.FILM={ok:true,width:1920,height:1080,fps:plan.fps,frameCount:plan.frames,duration:plan.frames/plan.fps,story:'Three chapters; one native action at a time'};render(0);await window.prepareFrame();return window.FILM;
})().catch(e=>{$('failure').style.display='block';$('failure').textContent=e.stack;throw e;});
})();
