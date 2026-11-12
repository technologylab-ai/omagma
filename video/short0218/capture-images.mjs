// Rasterize completed native PTY frames. Application cells stay unchanged.
import {mkdirSync,writeFileSync,readFileSync,existsSync} from 'node:fs';
import {join,resolve,relative} from 'node:path';
import {createHash} from 'node:crypto';
import {parseArgs} from 'node:util';
import {Tape} from './term.js';
import {browser,reservation,root} from './cdp.mjs';
const {values:o}=parseArgs({options:{revision:{type:'string',default:'revision-01'}}});
if(!/^revision-\d{2}$/.test(o.revision))throw Error('A fresh named capture revision is required');
await reservation();
const cache=join(root,'video/cache/short0218',o.revision),out=join(cache,'assets');
if(existsSync(out))throw Error('Preserve previous rasterization');
mkdirSync(out,{recursive:true});
const source=JSON.parse(readFileSync(join(cache,'capture-manifest.json'),'utf8'));
if(!source.assets||!Object.keys(source.assets).length)throw Error('No native asset marks');
const digest=data=>createHash('sha256').update(data).digest('hex');
const bounded=(path)=>{const target=resolve(cache,path),rel=relative(cache,target);if(rel.startsWith('..')||!rel.endsWith('.json'))throw Error('Unowned tape path');return target;};
const normalized=r=>Array.isArray(r)&&r.length===4&&r.every(Number.isFinite)&&r[0]>=0&&r[1]>=0&&r[2]>0&&r[3]>0&&r[0]+r[2]<=1.000001&&r[1]+r[3]<=1.000001;
const manifest={schema:'omagma.video.assets.v1',captureReceipt:'capture-manifest.json',assets:{},sequences:{}};
// Ten genuine intermediate native frames make the recorded typing visible.
// This samples captured product output; it never constructs/retypes its text.
const clip=source.assets['clipboard.after'];
if(clip){
 const tape=new Tape(JSON.parse(readFileSync(bounded(clip.tape),'utf8')));
 const first=tape.mark('clipboard.paragraph-two').frame;
 const last=tape.mark('clipboard.paragraph-two:done').frame;
 if(last-first<10)throw Error('Insufficient real typing frames');
 const keys=[];
 for(let i=1;i<=10;i++){
  const frame=first+Math.round((last-first)*i/10),key='clipboard.typing-'+String(i).padStart(2,'0');
  source.assets[key]={...clip,frame};keys.push(key);
 }
 manifest.sequences.clipboardTyping=keys;
}


async function previewContent(engine,page,expected){
 const tree=await page.call('Page.getFrameTree'),parentId=tree.frameTree.frame.id;
 const child=tree.frameTree.childFrames?.find(item=>item.frame.url==='about:srcdoc');
 let sessionId,contextId,call=page.call;
 if(child){
  const world=await page.call('Page.createIsolatedWorld',{frameId:child.frame.id,worldName:'omagma-promo-preview-qa'});
  contextId=world.executionContextId;
 }else{
  // Sandboxed srcdoc has an opaque origin. Chrome may put it in a separate
  // renderer, where it is absent from the parent session's Page frame tree.
  let targets=[];
  for(let attempt=0;attempt<40;attempt++){
   const result=await engine.call('Target.getTargets');
   targets=result.targetInfos.filter(t=>t.type==='iframe'&&t.url==='about:srcdoc'&&t.parentId===parentId);
   if(targets.length)break;
   await new Promise(resolve=>setTimeout(resolve,50));
  }
  if(targets.length!==1)throw Error('Actual preview must have one attached sandboxed content frame');
  ({sessionId}=await engine.call('Target.attachToTarget',{targetId:targets[0].targetId,flatten:true}));
  call=(method,params={},timeout)=>engine.call(method,params,sessionId,timeout);
  await call('Runtime.enable');
 }
 try{
  const literals=JSON.stringify([expected.before,expected.after]);
  const result=await call('Runtime.evaluate',{...(contextId?{contextId}:{}),awaitPromise:true,returnByValue:true,expression:`(async()=>{
   let timer;try{
    await Promise.race([Promise.all([document.fonts.ready,...[...document.images].map(i=>i.complete?(i.naturalWidth?Promise.resolve():Promise.reject(Error('Image failed to decode'))):new Promise((r,j)=>{i.addEventListener('load',r,{once:true});i.addEventListener('error',()=>j(Error('Image failed to load')),{once:true});}))]),new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('Actual image readiness timed out')),8000);})]);
    const rect=e=>{const r=e.getBoundingClientRect();return{x:r.x,y:r.y,width:r.width,height:r.height}};
    const textRect=literal=>{if(!literal)return null;const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);let node;while(node=walker.nextNode()){const index=node.textContent.indexOf(literal);if(index>=0){const range=document.createRange();range.setStart(node,index);range.setEnd(node,index+literal.length);return rect(range);}}return null;};
    return{url:location.href,devicePixelRatio,images:[...document.images].map(i=>({alt:i.alt,source:i.currentSrc||i.src,width:i.naturalWidth,height:i.naturalHeight,rect:rect(i)})),text:document.body.innerText,textRects:${literals}.map(textRect)};
   }finally{clearTimeout(timer);}
  })()`},12000);
  if(result.exceptionDetails)throw Error('Actual inline preview failed: '+JSON.stringify(result.exceptionDetails));
  return result.result.value;
 }finally{if(sessionId)await engine.call('Target.detachFromTarget',{sessionId});}
}

// Chrome's base scale also reaches sandboxed OOPIF renderers. A top-level
// Emulation override alone leaves their backing surface at DPR1 and upscales
// the text into an otherwise DPR2 screenshot.
const b=await browser({scale:2});
try{
 const p=await b.page('video/short0218/capture-images.html?revision='+encodeURIComponent(o.revision),{scale:2});
 for(const [key,job] of Object.entries(source.assets)){
  if(!/^[a-z0-9][a-z0-9.-]*$/.test(key))throw Error('Invalid native asset name '+key);
  const tapePath=bounded(job.tape),raw=readFileSync(tapePath),tape=new Tape(JSON.parse(raw));
  const index=job.frame??tape.mark(job.mark).frame;
  if(!Number.isInteger(index)||index<0||index>=tape.frames.length)throw Error('Invalid frame '+key);
  const rect=await p.evaluate('window.capture('+JSON.stringify(job.tape)+','+JSON.stringify(job.mark)+','+JSON.stringify(job.frame)+')');
  await p.evaluate('new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))');
  const clip={x:rect.left,y:rect.top,width:rect.columns*rect.cellW,height:rect.rows*rect.cellH,scale:1};
  const data=Buffer.from((await p.call('Page.captureScreenshot',{format:'png',clip})).data,'base64');
  const file=key.replaceAll('.','-')+'.png';writeFileSync(join(out,file),data);
  const panes=tape.panes(index),pane=panes.filter(p=>p.x1-p.x0>25&&p.y1-p.y0>4).at(-1);
  const bounds=p=>[p.x0/tape.columns,p.y0/tape.rows,(p.x1-p.x0+1)/tape.columns,(p.y1-p.y0+1)/tape.rows];
  const rois={full:[0,0,1,1],context:[0,0,1,1],focus:pane?bounds(pane):[0,0,1,1],form:pane?bounds(pane):[0,0,1,1],result:[0,Math.max(0,(tape.rows-5)/tape.rows),1,Math.min(5,tape.rows)/tape.rows],legend:[0,0,1,Math.min(8,tape.rows)/tape.rows],...job.rois};
  if(job.cellROIs)for(const [name,r]of Object.entries(job.cellROIs))rois[name]=[r[0]/tape.columns,r[1]/tape.rows,r[2]/tape.columns,r[3]/tape.rows];
  for(const [name,r]of Object.entries(rois))if(!normalized(r))throw Error('Invalid native ROI '+key+'.'+name);
  manifest.assets[key]={file:'assets/'+file,width:data.readUInt32BE(16),height:data.readUInt32BE(20),sha256:digest(data),rois,tape:job.tape,tapeSha256:digest(raw),mark:job.mark,frame:index,columns:tape.columns,rows:tape.rows,provenance:'Unmodified completed native PTY cells from the released v0.2.18 executable with synthetic providers'};
  console.log('Rasterized '+key+' '+tape.columns+'x'+tape.rows);
 }
 await p.close();
// Capture the unchanged application-generated browser preview, including its
// sandboxed child document. The outer document alone cannot prove image load.
if(source.browser){
 if(!/^[a-z0-9][a-z0-9.-]*\.html$/.test(source.browser.file)||digest(readFileSync(join(cache,source.browser.file)))!==source.browser.sourceSha256)throw Error('Actual preview source hash changed');
 const browserPath='video/cache/short0218/'+o.revision+'/'+source.browser.file;
 const page=await b.page(browserPath,{width:900,height:900,scale:2,ready:false});
 try{
  const content=await previewContent(b,page,source.browser);
  content.parentDevicePixelRatio=await page.evaluate('devicePixelRatio');
  if(content.devicePixelRatio!==2||content.parentDevicePixelRatio!==2)throw Error('Actual preview parent and sandboxed content must both rasterize at DPR2');
  for(const image of content.images){
   if(!/^data:image\/[a-z0-9.+-]+;base64,/i.test(image.source))throw Error('Actual preview image must remain embedded');
   image.sourceSha256=digest(Buffer.from(image.source.slice(image.source.indexOf(',')+1),'base64'));delete image.source;
  }
  const pasted=content.images.find(i=>i.alt===source.browser.imageAlt&&i.sourceSha256===source.browser.imageSha256&&i.width>0&&i.height>0);
  if(!pasted)throw Error('Exact pasted PNG not decoded in actual preview');
  if(!content.text.includes(source.browser.before)||!content.text.includes(source.browser.after)||content.textRects.some(r=>!r))throw Error('Actual preview text surrounding the pasted image is missing');
  const [before,after]=content.textRects;
  if(before.y+before.height>pasted.rect.y+.5||pasted.rect.y+pasted.rect.height>after.y+.5)throw Error('Actual preview image is not between its surrounding text');
  const frame=await page.evaluate(`(()=>{const r=document.querySelector('iframe').getBoundingClientRect();return{x:r.x,y:r.y,width:r.width,height:r.height}})()`);
  const data=await page.screenshot('png');writeFileSync(join(out,'browser-inline.png'),data);
  const w=data.readUInt32BE(16),h=data.readUInt32BE(20);
  const imageROI=[(frame.x+pasted.rect.x)/900,(frame.y+pasted.rect.y)/900,pasted.rect.width/900,pasted.rect.height/900];
  if(!normalized(imageROI))throw Error('Actual pasted image is outside the captured viewport');
  manifest.assets['browser.inline']={file:'assets/browser-inline.png',width:w,height:h,sha256:digest(data),rois:{full:[0,0,1,1],content:[frame.x/900,frame.y/900,frame.width/900,Math.min(frame.height,900-frame.y)/900],image:imageROI},provenance:'Unchanged application-generated HTML preview with actual pasted image',sourceHtmlSha256:source.browser.sourceSha256,contentProof:content};
  console.log('Rasterized browser.inline with decoded real pasted PNG');
 }finally{await page.close();}
}
}finally{await b.close();}
const logo=readFileSync(join(root,'video/assets/omagma-logo-master.png'));
manifest.assets.logo={file:'/video/assets/omagma-logo-master.png',width:logo.readUInt32BE(16),height:logo.readUInt32BE(20),sha256:digest(logo),rois:{full:[0,0,1,1]},provenance:'Approved existing logo'};
writeFileSync(join(cache,'assets-manifest.json'),JSON.stringify(manifest,null,2)+'\n');
console.log('Native raster manifest complete: '+Object.keys(source.assets).length+' assets');
