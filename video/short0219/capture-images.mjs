// Rasterize exact completed native v0.2.19 frames; never retype product UI.
import {mkdirSync,writeFileSync,readFileSync,existsSync} from 'node:fs';
import {join,resolve,relative} from 'node:path';
import {createHash} from 'node:crypto';
import {parseArgs} from 'node:util';
import {Tape} from './term.js';
import {browser,reservation,root} from './cdp.mjs';
const {values:o}=parseArgs({options:{revision:{type:'string',default:'revision-01'},development:{type:'boolean',default:false},'allow-candidate':{type:'boolean',default:false}}});
if(!/^revision-\d{2}$/.test(o.revision))throw Error('A fresh named capture revision is required');
await reservation();
const cache=join(root,'video/cache/short0219',o.revision),out=join(cache,'assets');
if(existsSync(out))throw Error('Preserve previous rasterization');
const source=JSON.parse(readFileSync(join(cache,'capture-manifest.json'),'utf8'));
if(!source.assets||!Object.keys(source.assets).length||source.failure)throw Error('Native capture is incomplete or failed');
if(o.development&&o['allow-candidate'])throw Error('Development and candidate permissions are distinct');
const frozenCandidate=source.sourceStatus==='frozen-release-candidate';
if(frozenCandidate){
 if(!o['allow-candidate']||source.sourceStatusAtCapture!=='frozen-release-candidate'||!source.candidateProof||source.publicationRequiredBeforeDelivery!==true)throw Error('Frozen candidate raster requires explicit --allow-candidate and immutable proof');
 const proofPath=resolve(cache,source.candidateProof.file),rel=relative(cache,proofPath);
 if(rel.startsWith('..')||rel!=='frozen-candidate-proof.json')throw Error('Unowned frozen artifact proof');
 const raw=readFileSync(proofPath),proof=JSON.parse(raw);
 if(createHash('sha256').update(raw).digest('hex')!==source.candidateProof.sha256||proof.schema!=='omagma.video.frozen-candidate.v1'||proof.binarySha256!==source.binarySha256||proof.jobConclusion!=='success'||proof.head!==source.candidateProof.head)throw Error('Frozen artifact proof changed');
}else if(!o.development&&(source.sourceStatus!=='published-v0.2.19'||source.buildInfo.appVersion!=='0.2.19'))throw Error('Production raster requires verified v0.2.19 captures');
const plan=JSON.parse(readFileSync(join(root,'video/short0219/film-plan.json'),'utf8'));
for(const key of plan.assetRequirements.required)if(!source.assets[key])throw Error('Missing required native state '+key);
mkdirSync(out,{recursive:true});
const digest=data=>createHash('sha256').update(data).digest('hex');
const bounded=path=>{const target=resolve(cache,path),rel=relative(cache,target);if(rel.startsWith('..')||!rel.endsWith('.json'))throw Error('Unowned tape path');return target;};
const manifest={schema:'omagma.video.assets.v1',captureReceipt:'capture-manifest.json',
 captureReceiptSha256:digest(readFileSync(join(cache,'capture-manifest.json'))),sourceStatus:source.sourceStatus,
 binarySha256:source.binarySha256,buildInfo:source.buildInfo,sourceStatusAtCapture:source.sourceStatusAtCapture,
 ...(frozenCandidate?{candidateProof:source.candidateProof,publicationRequiredBeforeDelivery:true}:{}),assets:{},sequences:{}};
const b=await browser({scale:2});
try{
 const p=await b.page('video/short0219/capture-images.html?revision='+encodeURIComponent(o.revision),{scale:2});
 try{
  for(const [key,job] of Object.entries(source.assets)){
   if(!/^[a-z0-9][a-z0-9.-]*$/.test(key))throw Error('Invalid native asset name '+key);
   const raw=readFileSync(bounded(job.tape)),tape=new Tape(JSON.parse(raw));
   const index=job.frame??tape.mark(job.mark).frame;
   if(!Number.isInteger(index)||index<0||index>=tape.frames.length)throw Error('Invalid native frame '+key);
   if(tape.mark(job.mark).frame!==index)throw Error('Mark/frame mismatch '+key);
   const rect=await p.evaluate('window.capture('+JSON.stringify(job.tape)+','+JSON.stringify(job.mark)+','+JSON.stringify(index)+')');
   await p.evaluate('new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))');
   const data=Buffer.from((await p.call('Page.captureScreenshot',{format:'png',clip:{x:rect.left,y:rect.top,width:rect.columns*rect.cellW,height:rect.rows*rect.cellH,scale:1}})).data,'base64');
   const width=data.readUInt32BE(16),height=data.readUInt32BE(20);
   if(width!==tape.columns*22||height!==tape.rows*44)throw Error('Native DPR2 cell geometry drift '+key);
   const file=key.replaceAll('.','-')+'.png';writeFileSync(join(out,file),data);
   const entry={file:'assets/'+file,width,height,sha256:digest(data),rois:{},cameraRois:{},tape:job.tape,
    tapeSha256:digest(raw),mark:job.mark,frame:index,columns:tape.columns,rows:tape.rows,
    provenance:'Unmodified completed native PTY cells from '+(frozenCandidate?'the checksum-verified frozen v0.2.19 release candidate (publication proof required before delivery)':o.development?'explicit development-only candidate':'the verified published v0.2.19 executable')+' with fictional reserved-domain providers'};
   const proof=key==='calendar.week'?source.proofs.calendar.weekNow:key==='calendar.day'?source.proofs.calendar.dayNow:null;
   if(proof){
    const pixels=await p.evaluate(`(async()=>{const image=new Image();image.src='data:image/png;base64,${data.toString('base64')}';await image.decode();const c=document.createElement('canvas');c.width=image.naturalWidth;c.height=image.naturalHeight;const x=c.getContext('2d');x.drawImage(image,0,0);const row=x.getImageData(0,${proof.row*44},c.width,44).data;let count=0;for(let i=0;i<row.length;i+=4)if(row[i]>140&&row[i]>row[i+1]*1.3&&row[i]>row[i+2]*1.1&&row[i+3]>200)count++;return count;})()`);
    if(pixels<50)throw Error('Actual raster has no visible native red current-time line '+key);
    entry.currentTimeLineRasterProof={nativeRow:proof.row,actualRedPixels:pixels};
   }
   manifest.assets[key]=entry;
   console.log('Rasterized '+key+' '+tape.columns+'x'+tape.rows);
  }
  if(p.errors.length)throw Error(p.errors.join('\n'));
 }finally{await p.close();}
}finally{await b.close();}
const logo=readFileSync(join(root,'video/assets/omagma-logo-master.png'));
manifest.assets.logo={file:'/video/assets/omagma-logo-master.png',width:logo.readUInt32BE(16),height:logo.readUInt32BE(20),sha256:digest(logo),rois:{full:[0,0,1,1]},provenance:'Approved existing logo'};
writeFileSync(join(cache,'assets-manifest.json'),JSON.stringify(manifest,null,2)+'\n');
console.log('Native raster manifest complete: '+Object.keys(source.assets).length+' states');
