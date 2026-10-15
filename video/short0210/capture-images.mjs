// Rasterize completed native PTY frames. Application cells stay unchanged.
import {mkdirSync,writeFileSync,readFileSync,existsSync} from 'node:fs';
import {join,resolve,relative} from 'node:path';
import {createHash} from 'node:crypto';
import {parseArgs} from 'node:util';
import {Tape} from '../web/term.js';
import {browser,reservation,root} from './cdp.mjs';
const {values:o}=parseArgs({options:{revision:{type:'string',default:'revision-01'}}});
if(!/^revision-\d{2}$/.test(o.revision))throw Error('A fresh named capture revision is required');
await reservation();
const cache=join(root,'video/cache/short0210',o.revision),out=join(cache,'assets');
if(existsSync(out))throw Error('Preserve previous rasterization');
mkdirSync(out,{recursive:true});
const source=JSON.parse(readFileSync(join(cache,'capture-manifest.json'),'utf8'));
if(!source.assets||!Object.keys(source.assets).length)throw Error('No native asset marks');
const digest=data=>createHash('sha256').update(data).digest('hex');
const bounded=(path)=>{const target=resolve(cache,path),rel=relative(cache,target);if(rel.startsWith('..')||!rel.endsWith('.json'))throw Error('Unowned tape path');return target;};
const normalized=r=>Array.isArray(r)&&r.length===4&&r.every(Number.isFinite)&&r[0]>=0&&r[1]>=0&&r[2]>0&&r[3]>0&&r[0]+r[2]<=1.000001&&r[1]+r[3]<=1.000001;
const manifest={schema:'omagma.video.assets.v1',captureReceipt:'capture-manifest.json',assets:{},sequences:{}};
const b=await browser();
try{
 const p=await b.page('video/short0210/capture-images.html?revision='+encodeURIComponent(o.revision),{scale:2});
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
  manifest.assets[key]={file:'assets/'+file,width:data.readUInt32BE(16),height:data.readUInt32BE(20),sha256:digest(data),rois,tape:job.tape,tapeSha256:digest(raw),mark:job.mark,frame:index,columns:tape.columns,rows:tape.rows,provenance:'Unmodified completed native PTY cells from the frozen development executable with synthetic providers'};
  console.log('Rasterized '+key+' '+tape.columns+'x'+tape.rows);
 }
 await p.close();
}finally{await b.close();}
const logo=readFileSync(join(root,'video/assets/omagma-logo-master.png'));
manifest.assets.logo={file:'/video/assets/omagma-logo-master.png',width:logo.readUInt32BE(16),height:logo.readUInt32BE(20),sha256:digest(logo),rois:{full:[0,0,1,1]},provenance:'Approved existing logo'};
writeFileSync(join(cache,'assets-manifest.json'),JSON.stringify(manifest,null,2)+'\n');
console.log('Native raster manifest complete: '+Object.keys(source.assets).length+' assets');
