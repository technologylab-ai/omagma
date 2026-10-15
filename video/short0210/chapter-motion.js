/* Absolute-time integration of the approved video/short027/film.html opener.
 * Only #motion is owned here. Native frames, cues and read holds never move.
 * Load this helper and CSS, then call CHAPTER_MOTION.render after base render.
 */
(function(global){'use strict';
 const clamp=x=>Math.max(0,Math.min(1,x));
 const out=x=>1-(1-clamp(x))**3,inward=x=>clamp(x)**3,smooth=x=>{x=clamp(x);return x*x*(3-2*x);};
 const progress=(t,a,b,ease=out)=>ease(b<=a?+(t>=b):clamp((t-a)/(b-a)));
 const fixed=n=>Number(n).toFixed(5);
 let dom;
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
  if(s.mode==='off')return s;
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
 global.CHAPTER_MOTION=Object.freeze({render,sample,source:'video/short027/film.html approved opener'});
})(window);
