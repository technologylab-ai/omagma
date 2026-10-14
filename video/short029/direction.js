/* Deterministic direction, driven by film time rather than CSS wall clocks. */
(function(){
'use strict';
const clamp=x=>Math.max(0,Math.min(1,x));
const ease=x=>{x=clamp(x);return x*x*(3-2*x);};
const p=(t,a,b)=>ease((t-a)/(b-a));
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let root,carry;
const check='<svg viewBox="0 0 64 64"><path class="direction-check" pathLength="1" d="M12 33 L26 47 L53 17"/></svg>';
const calendar='<svg class="icon" viewBox="0 0 48 48"><g fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><rect x="6" y="9" width="36" height="34" rx="5"/><path d="M6 20h36M15 5v9M33 5v9M15 29h4M28 29h4M15 36h4"/></g></svg>';
const returnIcon='<svg class="icon" viewBox="0 0 48 48"><g fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M10 18a17 17 0 1 1 0 18M10 6v12h12M25 14v12l8 5"/></g></svg>';
function build(part){
 let h='';
 if(part.director==='destinations')h='<div class="destination" id="dest-cal" style="top:360px">'+calendar+'<div class="dir-kicker">New destination 01</div><div class="name">Calendar</div><div class="detail">Your meetings, inside Omagma.</div></div><div class="destination" id="dest-fu" style="top:635px">'+returnIcon+'<div class="dir-kicker">New destination 02</div><div class="name">Follow-ups</div><div class="detail">Emails you want to return to.</div></div>';
 if(part.director==='followups')h='<div class="destination" id="dest-fu" style="top:410px">'+returnIcon+'<div class="dir-kicker">Back to the second destination</div><div class="name">Follow-ups</div><div class="detail">Set a date for an email.<br>Find it here when it’s due.</div></div>';
 if(part.director==='profile')h='<div class="profile-story"><div class="dir-kicker">Chrome profile, selected for you</div><div class="profile-icon">W</div><div class="identity">work@example.com</div><h2>Work meeting.<br>Work profile.</h2><p>The meeting opens in the browser<br>profile linked to this account.</p></div>';
 if(part.director==='rsvp-result')h='<div class="result-pair"><div class="result-item" id="reply-result">'+check+'<span>Reply sent</span></div><div class="result-item" id="calendar-result">'+check+'<span>Calendar updated</span></div></div>';
 if(part.director==='reminder-result')h='<div class="completion">'+check+'<div class="dir-kicker" style="margin-top:24px">Ready when you are</div><h2>The email.<br>The right day.</h2><p>Your reminder is in Follow-ups.</p></div>';
 if(part.director==='gmail-result')h='<div class="draft-route"><div class="draft-end source"><div class="draft-icon">≡</div><h2>Local draft</h2><p>Original kept</p></div><svg class="draft-path" viewBox="0 0 800 150"><path class="direction-line" d="M30 75H770m-18 -13 18 13-18 13"/><g id="travelling-draft"><rect x="-24" y="-30" width="48" height="60" rx="7" fill="#a3eff0"/><path d="M-12 -12h24M-12 0h24M-12 12h16" stroke="#153442" stroke-width="4"/></g></svg><div class="draft-end target"><div class="draft-icon">'+check+'</div><h2>Gmail draft</h2><p>Continue there</p></div></div>';
 if(part.cue)h+='<div class="press">'+(part.cue.command?'<div class="typed-command"></div>':'')+'<div class="key">'+esc(part.cue.key)+'</div><div class="label">'+esc(part.cue.label)+'</div></div>';
 h+='<svg id="direction-vector" viewBox="0 0 1920 1080" style="position:absolute;inset:0;width:1920px;height:1080px;overflow:visible"><path id="direction-connector" class="direction-line" pathLength="1"/><circle id="direction-dot" r="5" fill="#a3eff0"/><path id="direction-connector-two" class="direction-line" pathLength="1"/><circle id="direction-dot-two" r="5" fill="#a3eff0"/></svg>';
 return h;
}
function reveal(el,t,a,b,dx=0,dy=0){if(!el)return;const q=p(t,a,b);el.style.opacity=q;el.style.transform='translate('+((1-q)*dx)+'px,'+((1-q)*dy)+'px)';}
function target(part,t,ctx,name){const key=ctx.assetAt(part,t),c=ctx.camera(key,part,t),r=ctx.roiFor(key,name),m=ctx.manifest.assets[key];return{x:c.frame[0]+c.translate[0]+(r[0]+r[2]/2)*m.width*c.scale,y:c.frame[1]+c.translate[1]+(r[1]+r[3]/2)*m.height*c.scale,w:r[2]*m.width*c.scale,h:r[3]*m.height*c.scale};}
window.drawDirection=function(part,t,alpha,ctx){
 if(!root){root=document.createElement('div');root.id='direction';document.getElementById('screen').append(root);}
 if(root.dataset.part!==part.id){root.innerHTML=build(part);root.dataset.part=part.id;}
 root.style.opacity=alpha;
 if(!carry){carry=document.createElement('div');carry.id='direction-carry';document.getElementById('screen').append(carry);}const prev=ctx.previous;carry.style.display=prev?.cue&&t<.4?'block':'none';if(prev?.cue&&t<.4){const c=prev.cue;carry.innerHTML='<div class="press" style="left:'+c.x+'px;top:'+c.y+'px">'+(c.command?'<div class="typed-command">'+esc(c.command)+'</div>':'')+'<div class="key" style="background:#a3eff0">'+esc(c.key)+'</div><div class="label">'+esc(c.label)+'</div></div>';carry.style.opacity=1-p(t,0,.4);}
 const line=root.querySelector('#direction-connector'),dot=root.querySelector('#direction-dot');line.style.display='none';dot.style.display='none';root.querySelector('#direction-connector-two').style.display='none';root.querySelector('#direction-dot-two').style.display='none';
 const link=(x,y,tx,ty,q)=>{line.style.display='block';dot.style.display='block';line.setAttribute('d',`M${x} ${y} C${(x+tx)/2} ${y},${(x+tx)/2} ${ty},${tx} ${ty}`);line.style.strokeDasharray=1;line.style.strokeDashoffset=1-q;line.style.opacity=q;dot.setAttribute('cx',tx);dot.setAttribute('cy',ty);dot.style.opacity=q;};
 if(part.director==='destinations'){
  reveal(root.querySelector('#dest-cal'),t,1,1.35,35);reveal(root.querySelector('#dest-fu'),t,1.05,1.4,35);
  for(const [name,y,a,suffix] of [['calendar_entry',440,.8,''],['followup_entry',715,1,'-two']]){
   const r=target(part,t,ctx,name),q=p(t,a,a+.5)*(1-p(t,3.7,4.05));
   const line=root.querySelector('#direction-connector'+suffix),dot=root.querySelector('#direction-dot'+suffix),tx=r.x+r.w*.25,ty=r.y;
   line.style.display='block';dot.style.display='block';line.setAttribute('d',`M925 ${y} C865 ${y},830 ${ty},${tx} ${ty}`);line.style.strokeDasharray=1;line.style.strokeDashoffset=1-q;line.style.opacity=q;dot.setAttribute('cx',tx);dot.setAttribute('cy',ty);dot.style.opacity=q;
  }
 }
 if(part.director==='followups')reveal(root.querySelector('#dest-fu'),t,.35,.9,35);
 if(part.director==='profile')reveal(root.querySelector('.profile-story'),t,.6,1,30);
 if(part.director==='rsvp-result'){
  for(const [id,a] of [['reply-result',.85],['calendar-result',1.25]]){const e=root.querySelector('#'+id);reveal(e,t,a,a+.4,0,18);const path=e.querySelector('path');path.style.strokeDasharray=1;path.style.strokeDashoffset=1-p(t,a+.05,a+.5);}
 }
 if(part.director==='gmail-result'){const e=root.querySelector('.draft-route');reveal(e,t,.4,.85,0,18);const q=p(t,.9,1.9);root.querySelector('#travelling-draft').setAttribute('transform','translate('+(30+740*q)+' 75)');root.querySelector('#travelling-draft').style.opacity=1-p(t,1.85,2.1);const path=e.querySelector('.target .direction-check');path.style.strokeDasharray=1;path.style.strokeDashoffset=1-p(t,1.9,2.3);}
 if(part.director==='reminder-result'){
  const e=root.querySelector('.completion');reveal(e,t,.65,1.25,35);const path=e.querySelector('path');path.style.strokeDasharray=1;path.style.strokeDashoffset=1-p(t,.9,1.55);
 }
 if(part.cue){
  const c=part.cue,e=root.querySelector('.press'),k=e.querySelector('.key'),at=c.at??1.7,show=p(t,c.show??.5,(c.show??.5)+.35),press=p(t,at,at+.1)*(1-p(t,at+.2,at+.36));
  Object.assign(e.style,{left:c.x+'px',top:c.y+'px',opacity:show,transform:'translateY('+((1-show)*12)+'px)'});
  if(c.command){const q=p(t,c.show??.5,(c.show??.5)+.8);e.querySelector('.typed-command').textContent=c.command.slice(0,Math.ceil(c.command.length*q))+(q<1?'▏':'');}
  k.style.transform='translateY('+(press*7)+'px) scale('+(1-.06*press)+')';k.style.boxShadow='0 '+(8-press*7)+'px 0 #839698';k.style.background=t>=at?'#a3eff0':'#f2f4ee';
  if(c.target){const r=target(part,t,ctx,c.target);link(c.x+45,c.y-20,r.x,r.y+r.h/2+12,p(t,(c.show??.5)+.2,(c.show??.5)+.7));}
 }
};
})();
