// Independent attention-order inspection. This never changes the film source or UI.
import {createHash} from 'node:crypto';
import {appendFileSync,existsSync,lstatSync,mkdirSync,readFileSync,writeFileSync} from 'node:fs';
import {dirname,isAbsolute,join,relative,resolve} from 'node:path';
import {parseArgs} from 'node:util';
import {browser,reservation,root} from './cdp.mjs';

const {values:options}=parseArgs({options:{out:{type:'string'},revision:{type:'string',default:'revision-27'},batch:{type:'string',default:'16'}}});
const FRAMES=2527,FPS=30,batch=Number(options.batch);
if(!options.out||!/^revision-\d{2}$/.test(options.revision)||!Number.isInteger(batch)||batch<1||batch>32)throw Error('Required fresh --out, --revision revision-XX, and --batch 1–32');
const out=resolve(options.out),base=join(root,'video/cache/short0218'),name=relative(base,out);
if(!name||name.startsWith('..')||isAbsolute(name))throw Error('--out must be a fresh directory under video/cache/short0218');
for(let path=out;path!==root;path=dirname(path))if(existsSync(path)&&lstatSync(path).isSymbolicLink())throw Error('Output must not traverse a symlink');
if(existsSync(out))throw Error('Preserve previous attention-check evidence; use a fresh --out');
await reservation();
mkdirSync(out,{recursive:true,mode:0o700});
const failuresPath=join(out,'failures.jsonl');
writeFileSync(failuresPath,'',{mode:0o600});
const digest=bytes=>createHash('sha256').update(bytes).digest('hex');
const sourcePaths=['film.html','film.css','film.js','film-plan.json','attention-check.mjs','cdp.mjs'].map(path=>'video/short0218/'+path);
const sources=Object.fromEntries(sourcePaths.map(path=>[path,digest(readFileSync(join(root,path)))]));
const plan=JSON.parse(readFileSync(join(root,'video/short0218/film-plan.json'),'utf8'));
const report={schema:'omagma.video.attention.v1',passed:false,revision:options.revision,sourceFiles:sources,
 framesExpected:FRAMES,framesChecked:0,batchSize:batch,minimumReadingLeadFrames:45,
 failures:[],failureDiagnostics:'failures.jsonl',beats:{},startedUtc:new Date().toISOString()};
const started=Date.now();
let engine,fatal;
const narration=value=>value?{kicker:value.kicker,headline:value.headline,sub:value.sub,footnote:value.footnote??null}:null;
const beatContract=value=>({id:value.id,kind:value.kind,in:value.in,out:value.out,
 announceStart:value.announceStart??null,textSettled:value.textSettled??null,
 demoStart:value.demoStart??null,demoEnd:value.demoEnd??null,narration:narration(value.narration),
 keys:(value.keys||[]).map(k=>({keys:k.keys,label:k.label,cue:k.cue,press:k.press}))});
const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);

// Run in the page only after qa(t) has drawn the frame. Computed DOM state is
// measured independently of qa's phase, textMoving, camera and opacity claims.
async function inspectBatch(first,count){
 const rect=element=>{const r=element.getBoundingClientRect();return{x:r.x,y:r.y,width:r.width,height:r.height};};
 const properties=['display','visibility','opacity','transform','transformOrigin','clipPath','clip','filter',
  'fontFamily','fontSize','fontWeight','lineHeight','letterSpacing','color','webkitTextFillColor',
  'left','top','width','height','overflowX','overflowY'];
 const style=element=>{const css=getComputedStyle(element);return Object.fromEntries(properties.map(key=>[key,css[key]]));};
 const effective=element=>{let opacity=1,displayed=true;for(let node=element;node;node=node.parentElement){const css=getComputedStyle(node);opacity*=Number(css.opacity);if(css.display==='none'||css.contentVisibility==='hidden')displayed=false;}return{opacity,displayed};};
 const inset=(value,width,height)=>{
  if(value==='none')return{supported:true,edges:[0,0,0,0]};
  const match=/^inset\(([^)]+)\)$/.exec(value);if(!match)return{supported:false,edges:[0,0,0,0]};
  const tokens=match[1].split(/\s+round\s+/)[0].trim().split(/\s+/);
  if(tokens.length<1||tokens.length>4)return{supported:false,edges:[0,0,0,0]};
  const expanded=tokens.length===1?[tokens[0],tokens[0],tokens[0],tokens[0]]:tokens.length===2?[tokens[0],tokens[1],tokens[0],tokens[1]]:tokens.length===3?[tokens[0],tokens[1],tokens[2],tokens[1]]:tokens;
  if(expanded.some(token=>!/^[-+]?(?:\d+\.?\d*|\.\d+)(?:px|%)?$/.test(token)))return{supported:false,edges:[0,0,0,0]};
  return{supported:true,edges:expanded.map((token,index)=>parseFloat(token)*(token.endsWith('%')?(index%2?width:height)/100:1))};
 };
 const rows=[];
 for(let frame=first;frame<first+count;frame++){
  const qa=await window.qa(frame/30);
  const frames=[...document.querySelectorAll('#frames .frame')].map((element,index)=>{
   const css=style(element),bounds=rect(element),visibility=effective(element);
   const width=parseFloat(css.width)||0,height=parseFloat(css.height)||0,clip=inset(css.clipPath,width,height);
   const [top,right,bottom,left]=clip.edges;
   const visibleWidth=Math.max(0,width-left-right),visibleHeight=Math.max(0,height-top-bottom);
   const region={x:bounds.x+left*(width?bounds.width/width:0),y:bounds.y+top*(height?bounds.height/height:0),
    width:visibleWidth*(width?bounds.width/width:0),height:visibleHeight*(height?bounds.height/height:0)};
   const onStage=region.x+region.width>0&&region.y+region.height>0&&region.x<1920&&region.y<1080;
   const visible=visibility.displayed&&css.visibility==='visible'&&visibility.opacity>0&&region.width>0.001&&region.height>0.001&&onStage;
   return{index,className:element.className,style:css,effectiveOpacity:visibility.opacity,bounds,clip,
    visibleRegion:region,fullyClipped:visibleWidth<=0.001||visibleHeight<=0.001,visible};
  });
  const bands=[...document.querySelectorAll('.band')].map(element=>{
   const nodes=[['band',element],['kicker',element.querySelector('.kicker')],['kickerText',element.querySelector('.kicker span')],
    ['kickerLine',element.querySelector('.kicker i')],['headline',element.querySelector('.head')],
    ...[...element.querySelectorAll('.head .w')].map((word,index)=>['word'+index,word]),
    ['subline',element.querySelector('.sub')],['sublineText',element.querySelector('.sub span')],
    ['footnote',element.querySelector('.foot')],['footnoteText',element.querySelector('.foot span')]];
   const measured=nodes.map(([role,node])=>node?{role,text:node.textContent,style:style(node),bounds:rect(node),effective:effective(node)}:{role,missing:true});
   const root=measured[0];
   return{id:element.id,scene:element.dataset.scene,visible:root.effective.displayed&&root.style.visibility==='visible'&&root.effective.opacity>0,
    text:{kicker:element.querySelector('.kicker span')?.textContent,headline:element.querySelector('.head')?.textContent,
     sub:element.querySelector('.sub span')?.textContent,footnote:element.querySelector('.foot span')?.textContent||null},nodes:measured};
  });
  rows.push({frame,qa,dom:{frames,bands}});
 }
 return rows;
}

function settledBand(band,expected){
 const problems=[];
 if(!same(band.text,narration(expected.narration)))problems.push('actual band text differs from fixed plan narration');
 for(const node of band.nodes){
  if(node.missing){problems.push('missing narration node '+node.role);continue;}
  if(node.role.startsWith('footnote')&&!expected.narration.footnote)continue;
  if(!node.effective.displayed||node.style.visibility!=='visible'||Math.abs(node.effective.opacity-1)>1e-7)problems.push('narration is not fully opaque/visible: '+node.role);
  const matrix=node.style.transform;
  if(matrix!=='none'){
   const match=/^matrix\(([^)]+)\)$/.exec(matrix),values=match?.[1].split(',').map(Number),identity=[1,0,0,1,0,0];
   if(!values||values.length!==6||values.some((v,i)=>!Number.isFinite(v)||Math.abs(v-identity[i])>1e-7))problems.push('unsettled narration transform: '+node.role);
  }
  const clip=node.style.clipPath;
  if(clip!=='none'){
   const match=/^inset\(([^)]+)\)$/.exec(clip);
   if(!match||match[1].split(/\s+round\s+/)[0].trim().split(/\s+/).some(value=>!Number.isFinite(parseFloat(value))||parseFloat(value)>1e-7))problems.push('narration remains clipped: '+node.role);
  }
 }
 return problems;
}

try{
 if(plan.format?.frames!==FRAMES||plan.format?.fps!==FPS||plan.format?.width!==1920||plan.format?.height!==1080)throw Error('Plan must describe exactly 2527 frames at 1920×1080/30fps');
 const beats=plan.beats;
 if(!Array.isArray(beats)||!beats.length||beats[0].in!==0||beats.at(-1).out!==FRAMES||new Set(beats.map(b=>b.id)).size!==beats.length)throw Error('Plan must cover all frames with unique beats');
 for(let index=0;index<beats.length;index++){
  const beat=beats[index];
  if(!Number.isInteger(beat.in)||!Number.isInteger(beat.out)||beat.in>=beat.out||(index&&beats[index-1].out!==beat.in))throw Error('Non-contiguous plan beat '+beat.id);
  if(beat.narration&&(!Number.isInteger(beat.textSettled)||beat.announceStart!==beat.in||beat.textSettled<beat.in||beat.textSettled>=beat.out))throw Error('Invalid narration timing '+beat.id);
  if(beat.kind==='feature'&&(!Number.isInteger(beat.demoStart)||!Number.isInteger(beat.demoEnd)||beat.demoStart-beat.textSettled<45||beat.demoEnd<=beat.demoStart||beat.demoEnd>beat.out))throw Error('Feature needs at least 45 reading frames '+beat.id);
  report.beats[beat.id]={kind:beat.kind,in:beat.in,out:beat.out,framesChecked:0,phases:{},
   plannedReadingLeadFrames:beat.demoStart==null?null:beat.demoStart-beat.textSettled,
   firstVisibleNativeFrame:null,lastVisibleNativeFrame:null,actualSettledFrame:null,
   narrationSignature:null,stableFramesChecked:0};
 }
 engine=await browser({scale:1});
 const page=await engine.page('video/short0218/film.html?revision='+encodeURIComponent(options.revision),{width:1920,height:1080,scale:1});
 const metadata=await page.evaluate('({film:window.FILM,plan:window.FILM_PLAN})');
 report.film=metadata.film;report.runtimePlan=metadata.plan;
 if(metadata.film?.fps!==FPS||metadata.film?.width!==1920||metadata.film?.height!==1080||Math.round(metadata.film.duration*FPS)!==FRAMES||metadata.plan?.frames!==FRAMES||metadata.plan?.revision!==options.revision)throw Error('FILM/FILM_PLAN format or revision differs from frozen plan');
 if(!same(beats.map(beatContract),metadata.plan.beats?.map(beatContract)))throw Error('FILM_PLAN timeline/narration differs from film-plan.json');
 for(let first=0;first<FRAMES;first+=batch){
  const rows=await page.evaluate(`(${inspectBatch.toString()})(${first},${Math.min(batch,FRAMES-first)})`);
  for(const row of rows){
   const {frame,qa,dom}=row,expected=beats.find(b=>frame>=b.in&&frame<b.out),stats=report.beats[expected.id],problems=[];
   if(frame!==report.framesChecked)throw Error('Missing, duplicate or reordered inspected frame');
   report.framesChecked++;stats.framesChecked++;
   const phase=qa.beat?.phase;stats.phases[phase]=(stats.phases[phase]||0)+1;
   if(qa.frame!==frame||qa.scene!==expected.id||!same(beatContract(qa.beat||{}),beatContract(expected)))problems.push('qa frame/beat contract differs from plan');
   if(qa.warnings?.length)problems.push(...qa.warnings.map(warning=>'qa: '+warning));
   const actualFrames=dom.frames.filter(item=>item.visible),actualBands=dom.bands.filter(item=>item.visible);
   const textOnly=expected.kind!=='feature'||frame<expected.demoStart||['announce','read','hold'].includes(phase);
   if(textOnly&&actualFrames.length)problems.push('native frame is actually visible during text-only '+phase);
   if(expected.kind==='feature'){
    const plannedPhase=frame<expected.textSettled?'announce':frame<expected.demoStart?'read':frame<expected.demoEnd?'demo':'exit';
    if(phase!==plannedPhase)problems.push('qa phase differs from independent timeline phase '+plannedPhase);
   }
   if(actualFrames.length){
    stats.firstVisibleNativeFrame??=frame;stats.lastVisibleNativeFrame=frame;
    if(expected.kind==='feature'&&stats.actualSettledFrame!=null&&frame-stats.actualSettledFrame<45)problems.push('actual native frame precedes 45-frame settled reading lead');
   }
   const fixed=expected.narration&&frame>=expected.textSettled&&(expected.demoEnd!=null?frame<expected.demoEnd:phase==='hold');
   if(fixed){
    if(actualBands.length!==1)problems.push('expected exactly one visible fixed narration band');
    else{
     const band=actualBands[0],issues=settledBand(band,expected);problems.push(...issues);
     const signature=digest(JSON.stringify({text:band.text,nodes:band.nodes}));
     if(!issues.length){
      stats.actualSettledFrame??=frame;stats.stableFramesChecked++;
      if(stats.narrationSignature&&stats.narrationSignature!==signature)problems.push('actual narration text/style/geometry signature changed during fixed read/demo');
      stats.narrationSignature??=signature;
     }
    }
   }
   if(frame===expected.demoStart&&(stats.actualSettledFrame==null||frame-stats.actualSettledFrame<45))problems.push('fewer than 45 actually settled reading frames before demoStart');
   if(problems.length){
    const failure={frame,time:frame/FPS,beat:expected.id,phase,problems:[...new Set(problems)]};
    report.failures.push(failure);appendFileSync(failuresPath,JSON.stringify({...failure,qa,dom})+'\n');
   }
  }
  if(report.framesChecked%256===0||report.framesChecked===FRAMES)console.log(`Attention checked ${report.framesChecked}/${FRAMES} frames`);
 }
 for(const beat of beats){
  const stats=report.beats[beat.id];
  stats.actualReadingLeadFrames=stats.firstVisibleNativeFrame==null||stats.actualSettledFrame==null?null:stats.firstVisibleNativeFrame-stats.actualSettledFrame;
  if(beat.kind==='feature'&&stats.firstVisibleNativeFrame==null)report.failures.push({beat:beat.id,problems:['feature demo contains no actually visible native frame']});
 }
 if(page.errors.length)throw Error(page.errors.join('\n'));
 for(const [path,hash]of Object.entries(sources))if(digest(readFileSync(join(root,path)))!==hash)throw Error('Source changed during attention inspection: '+path);
}catch(error){fatal=String(error.stack||error);}
finally{
 if(engine)try{await engine.close();}catch(error){fatal=(fatal?fatal+'\n':'')+'Cleanup: '+String(error);}
 report.error=fatal||null;report.failureCount=report.failures.length;
 report.passed=!fatal&&!report.failureCount&&report.framesChecked===FRAMES;
 report.wallSeconds=(Date.now()-started)/1000;report.completedUtc=new Date().toISOString();
 writeFileSync(join(out,'attention.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});
 console.log(`Attention check ${report.passed?'PASS':'FAIL'}: ${report.framesChecked}/${FRAMES} frames, ${report.failureCount} failed frames`);
 if(!report.passed)process.exitCode=1;
}
