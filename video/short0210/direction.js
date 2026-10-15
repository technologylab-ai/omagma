/* Editorial motion for Omagma v0.2.10, driven only by film time.
   Ivory keycaps, icy cyan ink and source-colored strands explain each action.
   film.html composites the genuine native captures; nothing here redraws app pixels. */
(function(){
'use strict';
const clamp=(x,a,b)=>Math.max(a,Math.min(b,x)),lerp=(a,b,p)=>a+(b-a)*p,isNum=Number.isFinite;
const EASE={smooth:x=>x*x*(3-2*x),out:x=>1-Math.pow(1-x,3),inOut:x=>x<.5?4*x*x*x:1-Math.pow(2-2*x,3)/2};
const P=(t,a,b,e)=>b<=a?(t>=b?1:0):EASE[e||'smooth'](clamp((t-a)/(b-a),0,1));
const r2=v=>Math.round(v*100)/100,r3=v=>Math.round(v*1000)/1000;
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const STRANDS=['#7aa2f7','#ff9e61','#bb9af7'],INK='#a3eff0',PLACES=['below','above','left','right'];
const PILLS=[[.06,64],[.19,108],[.34,52],[.5,92],[.66,70],[.83,118]];
function rgb(hex){const v=parseInt(hex.slice(1),16);return[v>>16&255,v>>8&255,v&255];}
function mix(a,b,p){const x=rgb(a),y=rgb(b);return'rgb('+x.map((v,i)=>Math.round(lerp(v,y[i],clamp(p,0,1)))).join(',')+')';}
function bez(p0,p1,p2,p3,u){const v=1-u;return[0,1].map(i=>v*v*v*p0[i]+3*v*v*u*p1[i]+3*v*u*u*p2[i]+u*u*u*p3[i]);}
function split(p0,p1,p2,p3,u){const L=(a,b)=>[lerp(a[0],b[0],u),lerp(a[1],b[1],u)],a=L(p0,p1),b=L(p1,p2),c=L(p2,p3),d=L(a,b),e=L(b,c);return[p0,a,d,L(d,e)];}
const cubic=q=>'M'+r2(q[0][0])+' '+r2(q[0][1])+' C'+q.slice(1).map(p=>r2(p[0])+' '+r2(p[1])).join(',');
const dashed=q=>'stroke-dasharray:1;stroke-dashoffset:'+r3(1-q);
function curve(ax,ay,bx,by){const mx=(ax+bx)/2;return'M'+r2(ax)+' '+r2(ay)+' C'+r2(mx)+' '+r2(ay)+','+r2(mx)+' '+r2(by)+','+r2(bx)+' '+r2(by);}

/* Keycaps sit beside the real control they operate. Each key travels down and up on press,
   turns cyan, and stays briefly so it carries across the action cut. */
function keyWidth(key){return key.length>3?key.length*20+52:Math.max(84,key.length*25+48);}
function drawCue(c,clock,ctx,index,out,qa){
 if(clock<c.show||clock>=c.hide)return;
 const appear=P(clock,c.show,c.show+.3,'out'),alpha=appear*(1-P(clock,Math.max(c.at,c.hide-.16),c.hide));if(alpha<=.002)return;
 const st=ctx.geom(index,Math.min(clock,c.at)).states[c.target.view],R=ctx.project(st,c.target.roi),pane=st.pane;
 const live=ctx.geom(index,clock).states[c.target.view],Q=ctx.project(live,c.target.roi),targetVisible=live.opacity>.98&&Q[0]>=live.pane[0]-1&&Q[1]>=live.pane[1]-1&&Q[0]+Q[2]<=live.pane[0]+live.pane[2]+1&&Q[1]+Q[3]<=live.pane[1]+live.pane[3]+1;
 const gap=c.gap===undefined?30:c.gap,off=c.offset||[0,0],kw=keyWidth(c.key),mid=R[1]+R[3]/2;
 const travel=P(clock,c.at,c.at+.09,'out')*(1-P(clock,c.at+.16,c.at+.34,'out')),pressed=clock>=c.at;
 let x,y,lead=null;
 if(c.place==='below'||c.place==='above'){x=clamp(R[0]+R[2]/2-kw/2,140,1500)+off[0];y=(c.place==='below'?pane[1]+pane[3]+gap:pane[1]-gap-84)+off[1];}
 else{x=(c.place==='right'?pane[0]+pane[2]+gap:pane[0]-gap)+off[0];y=clamp(mid-42,250,950)+off[1];}
 if(c.position){[x,y]=c.position;}
 y=clamp(y,236,990);
 if(c.place==='right')lead=[R[0]+R[2]+10,mid,x-12,y+42];if(c.place==='left')lead=[R[0]-10,mid,x+12,y+42];
 const cap=c.input==='mouse'?'<svg width="36" height="52" viewBox="0 0 36 52" aria-label="Mouse click"><rect x="3" y="2" width="30" height="48" rx="15" fill="none" stroke="#0b1017" stroke-width="3"/><path d="M4 22V17Q4 3 18 3V23H4Z" fill="#0b1017" opacity="'+(pressed?'1':'.25')+'"/><path d="M18 3V23M4 23H32" fill="none" stroke="#0b1017" stroke-width="2.5"/></svg>':esc(c.key);
 if(clock>=c.at-1e-7||!targetVisible||c.leader===false)lead=null;
 const pos=c.place==='left'?'right:'+r2(1920-x)+'px':'left:'+r2(x)+'px';
 out.html.push('<div class="cue '+c.place+'" style="'+pos+';top:'+r2(y)+'px;opacity:'+r3(alpha)+';transform:translateY('+r2((1-appear)*12)+'px)"><div class="key'+(c.key.length>3?' long':'')+(pressed?' pressed':'')+'" style="transform:translateY('+r2(travel*8)+'px);box-shadow:0 '+r2(8-7*travel)+'px 0 '+(pressed?'#5f9fa8':'#8b9a9c')+'">'+cap+'</div><div class="label">'+esc(c.label)+'</div></div>');
 if(lead){const q=P(clock,c.show+.15,c.show+.55,'out');out.svg.push('<path class="ink-line thin" pathLength="1" d="'+curve(...lead)+'" style="'+dashed(q)+';opacity:'+r3(alpha*.85)+'"/><circle class="ink-dot" cx="'+r2(lead[0])+'" cy="'+r2(lead[1])+'" r="5" style="opacity:'+r3(alpha*q)+'"/>');}
 qa.cues.push({part:ctx.parts[index].id,targetView:c.target.view,targetAsset:st.asset,liveAsset:live.asset,key:c.key,input:c.input||'keyboard',label:c.label,alpha:r3(alpha),pressed,travel:r3(travel),position:[r2(x),r2(y)],leader:!!lead,targetVisible,targetPane:live.pane.map(r2),targetRect:Q.map(r2)});
}

function intro(o,c,out){
 const t=c.local,lift=-36*c.exit,rise=(a,b,d)=>'opacity:'+r3(P(t,a,b))+';transform:translateY('+r2((1-P(t,a,b,'out'))*d+lift)+'px)';
 out.html.push('<div class="intro" style="opacity:'+r3(c.alpha)+'"><img class="intro-logo" alt="" src="'+esc(c.ctx.logo)+'" style="opacity:'+r3(P(t,0,.55))+';transform:translateY('+r2(lift)+'px) scale('+r3(lerp(.88,1,P(t,0,.8,'out')))+')"><div class="intro-word" style="'+rise(.15,.75,22)+'">Omagma</div><div class="intro-version" style="'+rise(.35,.9,16)+'">'+esc(o.version)+'</div><div class="intro-strap" style="'+rise(.55,1.1,12)+'">'+esc(o.strap)+'</div></div>');
 return true;
}

/* Signature 1: three source-colored strands, one per account, rise into the legend row
   of the genuine combined Week, which unfolds from that line. */
function merge(o,c,out){
 const t=c.local,g=c.g(),L=c.ctx.project(g.states[o.view],o.roi);
 const draw=P(t,o.draw[0],o.draw[1],'out'),conv=P(t,o.converge[0],o.converge[1],'inOut'),settle=P(t,o.settle[0],o.settle[1],'inOut'),fade=(1-settle)*c.alpha;
 let shown=false;
 if(fade>.002&&draw>0){shown=true;
  o.segments.forEach((seg,i)=>{
   const color=STRANDS[i],base=560+i*120,x0=lerp(230,L[0]+L[2]*seg[0]+10,conv),x1=lerp(1690,L[0]+L[2]*seg[1]-10,conv),ty=lerp(L[1]+L[3]/2,L[1]+L[3]+6,settle);
   const yAt=x=>lerp(base+20*Math.sin(x/(230+i*45)+i*2.1),ty,conv);
   let d='';for(let k=0;k<=40;k++){const x=lerp(x0,x1,k/40);d+=(k?' L':'M')+r2(x)+' '+r2(yAt(x));}
   out.svg.push('<path class="strand" pathLength="1" d="'+d+'" style="stroke:'+color+';stroke-width:'+r2(lerp(14,8,conv))+';opacity:'+r3(fade*.16)+';'+dashed(draw)+'"/><path class="strand" pathLength="1" d="'+d+'" style="stroke:'+color+';stroke-width:'+r2(lerp(4.5,3,conv))+';opacity:'+r3(fade)+';'+dashed(draw)+'"/>');
   PILLS.forEach(([f,w])=>{const at=clamp(f+i*.035,0,.97),vis=P(draw,at,at+.06)*(1-conv)*fade;if(vis<=.002)return;const x=lerp(x0,x1,at),y=yAt(x),pw=w*(1-.6*conv),ph=lerp(18,10,conv);out.svg.push('<rect x="'+r2(x-pw/2)+'" y="'+r2(y-ph/2)+'" width="'+r2(pw)+'" height="'+r2(ph)+'" rx="'+r2(ph/2)+'" style="fill:'+color+';opacity:'+r3(vis*.9)+'"/>');});
  });
 }
 if(o.echo){const q=P(t,o.echo[0],o.echo[0]+.5)*(1-P(t,o.echo[1]-.6,o.echo[1]))*c.alpha;if(q>.002){shown=true;const E=c.ctx.project(g.states[o.echoView],o.roi);o.segments.forEach((seg,i)=>{const a=E[0]+E[2]*seg[0]+8,b=E[0]+E[2]*seg[1]-8,w=P(t,o.echo[0]+i*.12,o.echo[0]+.55+i*.12,'out'),y=E[1]+E[3]+9;out.svg.push('<path class="strand" d="M'+r2(a)+' '+r2(y)+' L'+r2(lerp(a,b,w))+' '+r2(y)+'" style="stroke:'+STRANDS[i]+';stroke-width:3;opacity:'+r3(q*.9)+'"/>');});}}
 return shown;
}

function note(o,c,out){
 const t=c.local,st=c.g().states[o.view],vis=P(t,o.in,o.in+.35)*(1-P(t,o.out-.3,o.out))*c.alpha*st.opacity;if(vis<=.002)return false;
 const R=c.ctx.project(st,o.roi),pane=st.pane,left=o.side==='left',gap=o.gap===undefined?52:o.gap;
 const x=left?pane[0]-gap:pane[0]+pane[2]+gap,cy=clamp(R[1]+R[3]/2+(o.dy||0),290,980),q=P(t,o.in,o.in+.5,'out');
 const ax=left?R[0]-10:R[0]+R[2]+10,ay=R[1]+R[3]/2;
 out.svg.push('<path class="ink-line thin" pathLength="1" d="'+curve(ax,ay,left?x+14:x-14,cy)+'" style="'+dashed(q)+';opacity:'+r3(vis*.85)+'"/><circle class="ink-dot" cx="'+r2(ax)+'" cy="'+r2(ay)+'" r="5" style="opacity:'+r3(vis*q)+'"/>');
 out.html.push('<div class="note '+(left?'left':'right')+'" style="'+(left?'right:'+r2(1920-x):'left:'+r2(x))+'px;top:'+r2(cy)+'px;opacity:'+r3(vis)+';transform:translate('+r2((1-vis)*(left?-14:14))+'px,-50%)">'+(o.kicker?'<div class="note-kicker">'+esc(o.kicker)+'</div>':'')+'<div class="note-text">'+esc(o.text)+'</div>'+(o.sub?'<div class="note-sub">'+esc(o.sub)+'</div>':'')+'</div>');
 return true;
}

/* Signature 2: the editor collapses to its own account line and a cyan thread ties it to the
   Contacts picker's account line. The address book follows the chosen destination. */
function thread(o,c,out){
 const t=c.local,vis=P(t,o.in,o.in+.25)*(1-P(t,o.out-.35,o.out))*c.alpha;if(vis<=.002)return false;
 const g=c.g(),A=c.ctx.project(g.states[o.from.view],o.from.roi),B=c.ctx.project(g.states[o.to.view],o.to.roi),q=P(t,o.in,o.in+.35,'inOut');
 const sx=A[0]+Math.min(A[2]*.3,160),sy=A[1]+A[3]+8,ex=B[0]-12,ey=B[1]+B[3]/2,r=Math.min(40,Math.abs(ey-sy)/2,Math.abs(ex-sx)/2);
 const d=ey-sy>2*r&&ex-sx>2*r&&r>4?'M'+r2(sx)+' '+r2(sy)+' L'+r2(sx)+' '+r2(ey-r)+' Q'+r2(sx)+' '+r2(ey)+' '+r2(sx+r)+' '+r2(ey)+' L'+r2(ex)+' '+r2(ey):'M'+r2(sx)+' '+r2(sy)+' C'+r2(sx)+' '+r2((sy+ey)/2)+','+r2(ex)+' '+r2((sy+ey)/2)+','+r2(ex)+' '+r2(ey);
 out.svg.push('<circle class="ink-ring" cx="'+r2(sx)+'" cy="'+r2(sy)+'" r="7" style="opacity:'+r3(vis*P(t,o.in,o.in+.2))+'"/><path class="ink-line" pathLength="1" d="'+d+'" style="'+dashed(q)+';opacity:'+r3(vis)+'"/><circle class="ink-dot" cx="'+r2(ex)+'" cy="'+r2(ey)+'" r="6" style="opacity:'+r3(vis*P(t,o.in+.2,o.in+.35))+'"/>');
 if(o.label)out.html.push('<div class="thread-label" style="left:'+r2((sx+r+ex)/2)+'px;top:'+r2(ey-14)+'px;opacity:'+r3(vis*P(t,o.in+.15,o.in+.35))+'">'+esc(o.label)+'</div>');
 return true;
}

/* Signature 3: before and after Week panes stand side by side; a cyan arc travels from the
   real 10:30 event to the real 11:30 event. */
function move(o,c,out){
 const t=c.local,g=c.g(),B=g.states[o.before.view],A=g.states[o.after.view];let shown=false;
 const lab=P(t,o.labels[0],o.labels[0]+.4)*(1-P(t,o.labels[1]-.35,o.labels[1]))*c.alpha;
 if(lab>.002){shown=true;[[B,'before',o.beforeLabel],[A,'after',o.afterLabel]].forEach(([s,k,text])=>out.html.push('<div class="pane-label '+k+'" style="left:'+r2(s.pane[0]+4)+'px;top:'+r2(s.pane[1]-40)+'px;opacity:'+r3(lab*s.opacity)+'">'+esc(text)+'</div>'));}
 const vis=P(t,o.arc[0],o.arc[0]+.2)*(1-P(t,o.out-.4,o.out))*c.alpha*Math.min(A.opacity,B.opacity);
 if(vis>.002){shown=true;
  const R1=c.ctx.project(B,o.before.roi),R2=c.ctx.project(A,o.after.roi),start=[R1[0]+R1[2]+8,R1[1]+R1[3]/2],end=[R2[0]+R2[2]+8,R2[1]+R2[3]/2];
  // Route through the gutter, above the headers and around the right edge, away from native text.
  const gx=(B.pane[0]+B.pane[2]+A.pane[0])/2,rx=A.pane[0]+A.pane[2]+18,top=Math.min(B.pane[1],A.pane[1])-94,r=18,u=P(t,o.arc[0],o.arc[1],'inOut');
  const path='M'+start.join(' ')+' L'+(gx-r)+' '+start[1]+' Q'+gx+' '+start[1]+' '+gx+' '+(start[1]-r)+' L'+gx+' '+(top+r)+' Q'+gx+' '+top+' '+(gx+r)+' '+top+' L'+(rx-r)+' '+top+' Q'+rx+' '+top+' '+rx+' '+(top+r)+' L'+rx+' '+(end[1]-r)+' Q'+rx+' '+end[1]+' '+(rx-r)+' '+end[1]+' L'+end.join(' ');
  out.svg.push('<path class="ink-line bold" pathLength="1" d="'+path+'" style="'+dashed(u)+';opacity:'+r3(vis)+'"/><circle class="ink-ring" cx="'+r2(start[0])+'" cy="'+r2(start[1])+'" r="8" style="opacity:'+r3(vis)+'"/><circle class="ink-dot" cx="'+r2(end[0])+'" cy="'+r2(end[1])+'" r="8" style="opacity:'+r3(vis*P(u,.9,1))+'"/>');
  const chip=P(t,o.arc[0]+.45,o.arc[0]+.85,'out')*vis;if(chip>.002)out.html.push('<div class="chip" style="left:'+r2((gx+rx)/2)+'px;top:'+r2(top)+'px;opacity:'+r3(chip)+';transform:translate(-50%,-50%) scale('+r3(.92+.08*chip)+')">'+esc(o.chip)+'</div>');
 }
 return shown;
}

/* Native result above, editorial route below: account -> Chrome profile -> Google Calendar.
   No browser page is drawn; the route is explanation, the native line is the proof. */
function handoff(o,c,out){
 const t=c.local,vis=P(t,o.in,o.in+.45)*(1-P(t,o.out-.35,o.out))*c.alpha;if(vis<=.002)return false;
 const R=c.ctx.project(c.g().states[o.from.view],o.from.roi),xs=o.xs,y=o.y;
 let k=-1;o.runs.forEach((run,i)=>{if(t>=run.from)k=i;});
 const run=k>=0?o.runs[k]:null,next=o.runs[k+1],u=run?P(t,run.from,run.until,'inOut'):0,reset=next?1-P(t,next.from-.45,next.from-.1):1,lit=[.32,.66,1].map(th=>run?P(u,th-.07,th)*reset:0);
 const p0=[clamp(R[0]+R[2]*.5,200,1720),R[1]+R[3]+10],p1=[xs[0],y],q=[p0,[p0[0],lerp(p0[1],y,.6)],[xs[0],lerp(p0[1],y,.4)],p1];
 out.svg.push('<path class="lane" d="M'+xs[0]+' '+y+' L'+xs[2]+' '+y+'" style="opacity:'+r3(vis)+'"/>');
 if(run&&reset>.002){
  const routeAlpha=vis*(1-P(t,run.until,run.until+.35)),w=clamp(u/.32,.001,1),dot=u<=.32?split(...q,w)[3]:[lerp(xs[0],xs[2],(u-.32)/.68),y];
  out.svg.push('<path class="ink-line" d="'+cubic(split(...q,w))+'" style="opacity:'+r3(routeAlpha*reset)+'"/>');
  if(u>.32)out.svg.push('<path class="ink-line" d="M'+xs[0]+' '+y+' L'+r2(dot[0])+' '+y+'" style="opacity:'+r3(routeAlpha*reset)+'"/>');
  out.svg.push('<circle class="ink-dot" cx="'+r2(dot[0])+'" cy="'+r2(dot[1])+'" r="8" style="opacity:'+r3(routeAlpha*reset)+'"/>');
 }
 const subAlpha=run?(k===0?1:P(t,run.from-.1,run.from+.25))*(next?1-P(t,next.from-.45,next.from-.15):1):0;
 o.nodes.forEach((node,i)=>{
  const destination=i===2&&o.destination,changed=destination&&t>=destination.at,shown=changed?destination:node;
  const sub=i===2?(changed?destination.sub:run&&run.sub?run.sub:node.sub):node.sub;
  const sa=destination?(changed?P(t,destination.at,destination.at+.25):1-P(t,destination.at-.12,destination.at)):i===2&&run&&run.sub?subAlpha:1,l=lit[i];
  out.html.push('<div class="node" style="left:'+xs[i]+'px;top:'+y+'px;opacity:'+r3(vis)+';box-shadow:0 0 0 '+r2(1.5+l)+'px '+mix('#2b3b4d',INK,l)+',0 16px 40px rgba(0,0,0,.45)"><div class="k" style="color:'+mix('#8796a8',INK,l)+'">'+esc(shown.kicker)+'</div><div class="m" style="opacity:'+r3(i===2?sa:1)+'">'+esc(shown.text)+'</div><div class="s" style="opacity:'+r3(sa)+'">'+esc(sub||'')+'</div></div>');
 });
 return true;
}

function outro(o,c,out){
 const t=c.local,rise=(a,b,d)=>'opacity:'+r3(P(t,a,b))+';transform:translateY('+r2((1-P(t,a,b,'out'))*d)+'px)',conv=P(t,.9,1.5,'inOut');
 for(let i=0;i<3;i++){const dy=(i-1)*14*(1-conv),x0=lerp(700,860,conv),x1=lerp(1220,1060,conv),d=P(t,.4+i*.08,1.0+i*.08,'out');out.svg.push('<path class="strand" pathLength="1" d="M'+r2(x0)+' '+r2(540+dy)+' L'+r2(x1)+' '+r2(540+dy)+'" style="stroke:'+STRANDS[i]+';stroke-width:3;opacity:'+r3(c.alpha*(1-conv*.85))+';'+dashed(d)+'"/>');}
 out.svg.push('<path class="ink-line" d="M860 540 L1060 540" style="opacity:'+r3(c.alpha*conv)+'"/>');
 out.html.push('<div class="outro" style="opacity:'+r3(c.alpha)+'"><img class="outro-logo" alt="" src="'+esc(c.ctx.logo)+'" style="opacity:'+r3(P(t,.15,.75))+';transform:scale('+r3(lerp(.9,1,P(t,.15,.9,'out')))+')"><div class="outro-title" style="'+rise(.35,.95,18)+'">'+esc(o.title)+'</div><div class="outro-site" style="'+rise(.75,1.25,12)+'">'+esc(o.website)+'</div><div class="outro-scope" style="'+rise(.95,1.45,10)+'">'+esc(o.scope)+'</div><div class="outro-strap" style="'+rise(1.15,1.65,10)+'">'+esc(o.strap)+'</div></div>');
 return true;
}

const KINDS={intro,merge,note,thread,move,handoff,outro};
const REFS={intro:()=>[],outro:()=>[],merge:o=>[[o.view,o.roi]].concat(o.echo?[[o.echoView,o.roi]]:[]),note:o=>[[o.view,o.roi]],thread:o=>[[o.from.view,o.from.roi],[o.to.view,o.to.roi]],move:o=>[[o.before.view,o.before.roi],[o.after.view,o.after.roi]],handoff:o=>[[o.from.view,o.from.roi]]};
function check(part,api){
 const fail=m=>api.fail('Invalid editorial direction '+part.id+': '+m),dur=api.duration;
 const view=id=>{if(typeof id!=='string'||!api.hasView(id))fail('unknown view '+id);};
 const roi=r=>{if(!(typeof r==='string'&&/^[a-z][a-z0-9_-]*$/i.test(r))&&!(Array.isArray(r)&&r.length===4&&r.every(isNum)&&r[0]>=0&&r[1]>=0&&r[2]>0&&r[3]>0&&r[0]+r[2]<=1.000001&&r[1]+r[3]<=1.000001))fail('invalid ROI reference '+JSON.stringify(r));};
 const ref=x=>{if(!x||typeof x!=='object')fail('missing view reference');view(x.view);roi(x.roi);};
 const win=(a,b,name)=>{if(!isNum(a)||!isNum(b)||a<0||b<=a||a>dur+1)fail('invalid '+name+' window');};
 const pair=(w,name)=>{if(!Array.isArray(w)||w.length!==2)fail('invalid '+name);win(w[0],w[1],name);};
 const text=(s,name,optional)=>{if(optional&&s===undefined)return;if(typeof s!=='string'||(!optional&&!s.trim()))fail('invalid '+name);};
 part.cues.forEach(c=>{
  if(!c||typeof c!=='object')fail('invalid cue');text(c.key,'key');text(c.label,'cue label');
  if(!isNum(c.show)||!isNum(c.at)||!isNum(c.hide)||!(c.show>=0&&c.show<c.at&&c.at<c.hide&&c.at<=dur&&c.hide<=dur+1.5))fail('invalid cue timing '+c.key);
  if(!PLACES.includes(c.place))fail('invalid cue placement '+c.key);ref(c.target);
  if(c.input!==undefined&&!['keyboard','mouse'].includes(c.input))fail('invalid cue input '+c.key);
  if(c.offset!==undefined&&!(Array.isArray(c.offset)&&c.offset.length===2&&c.offset.every(isNum)))fail('invalid cue offset '+c.key);
  if(c.gap!==undefined&&!(isNum(c.gap)&&c.gap>=0))fail('invalid cue gap '+c.key);
  if(c.position!==undefined&&!(Array.isArray(c.position)&&c.position.length===2&&c.position.every(isNum)))fail('invalid fixed cue position '+c.key);
  if(c.leader!==undefined&&typeof c.leader!=='boolean')fail('invalid cue leader '+c.key);
 });
 part.overlays.forEach(o=>{
  if(!o||!KINDS[o.kind])fail('unknown overlay '+(o&&o.kind));
  switch(o.kind){
   case'intro':text(o.version,'version');text(o.strap,'strap');break;
   case'outro':['title','website','scope','strap'].forEach(k=>text(o[k],k));break;
   case'merge':ref(o);pair(o.draw,'draw');pair(o.converge,'converge');pair(o.settle,'settle');
    if(!Array.isArray(o.segments)||o.segments.length!==3||o.segments.some(s=>!Array.isArray(s)||s.length!==2||!s.every(isNum)||s[0]<0||s[1]>1||s[1]<=s[0]))fail('merge needs three legend segments');
    if(o.echo!==undefined){pair(o.echo,'echo');view(o.echoView);}break;
   case'note':ref(o);win(o.in,o.out,'note');text(o.text,'note text');text(o.kicker,'kicker',true);text(o.sub,'sub',true);
    if(o.side!==undefined&&o.side!=='left'&&o.side!=='right')fail('invalid note side');if(o.dy!==undefined&&!isNum(o.dy)||o.gap!==undefined&&!isNum(o.gap))fail('invalid note offset');break;
   case'thread':ref(o.from);ref(o.to);win(o.in,o.out,'thread');text(o.label,'thread label',true);break;
   case'move':ref(o.before);ref(o.after);pair(o.labels,'labels');pair(o.arc,'arc');if(!isNum(o.out)||o.out<=o.arc[0])fail('invalid move out');
    text(o.beforeLabel,'before label');text(o.afterLabel,'after label');text(o.chip,'chip');if(o.lift!==undefined&&!isNum(o.lift))fail('invalid lift');break;
   case'handoff':ref(o.from);win(o.in,o.out,'handoff');if(!isNum(o.y)||!Array.isArray(o.xs)||o.xs.length!==3||!o.xs.every(isNum))fail('invalid handoff layout');
    if(!Array.isArray(o.nodes)||o.nodes.length!==3)fail('handoff needs three nodes');o.nodes.forEach(n=>{text(n.kicker,'node kicker');text(n.text,'node text');text(n.sub,'node sub',true);});
    if(o.destination){if(!isNum(o.destination.at)||o.destination.at<0||o.destination.at>dur)fail('invalid handoff destination time');['kicker','text','sub'].forEach(k=>text(o.destination[k],'destination '+k));}
    if(!Array.isArray(o.runs)||!o.runs.length)fail('handoff needs runs');let last=-1;o.runs.forEach(run=>{win(run.from,run.until,'run');if(run.from<=last)fail('runs must ascend');last=run.until;text(run.sub,'run sub',true);});break;
  }
 });
}
function compose(out){return'<svg class="ink" viewBox="0 0 1920 1080" width="1920" height="1080">'+out.svg.join('')+'</svg>'+out.html.join('');}
function drawOverlays(part,local,index,alpha,exit,ctx,out,qa){
 let geometry=null;const g=()=>geometry||(geometry=ctx.geom(index,local));
 part.overlays.forEach(o=>{if(alpha<=.002)return;const shown=KINDS[o.kind](o,{local,alpha,exit,ctx,g},out);if(shown)qa.overlays.push({part:part.id,kind:o.kind,alpha:r3(alpha)});});
}
window.DIRECTION={
 validate:check,
 references(part){return part.cues.map(c=>[c.target.view,c.target.roi]).concat(...part.overlays.map(o=>REFS[o.kind](o)));},
 render(ctx,hosts){
  const qa={cues:[],overlays:[]},previous={svg:[],html:[]},current={svg:[],html:[]},keys={svg:[],html:[]};
  if(ctx.prev&&ctx.carry<1)drawOverlays(ctx.prev,ctx.prevLocal,ctx.index-1,1-ctx.carry,ctx.carry,ctx,previous,qa);
  drawOverlays(ctx.part,ctx.local,ctx.index,ctx.prev&&ctx.part.carry>0?ctx.carry:1,0,ctx,current,qa);
  if(ctx.prev)ctx.prev.cues.forEach(c=>drawCue(c,ctx.prevLocal,ctx,ctx.index-1,keys,qa));
  ctx.part.cues.forEach(c=>drawCue(c,ctx.local,ctx,ctx.index,keys,qa));
  hosts.previous.innerHTML=compose(previous);hosts.current.innerHTML=compose(current);hosts.cues.innerHTML=compose(keys);
  return qa;
 }
};
})();
