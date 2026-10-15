// Cheap source/asset integrity checks before any full movie render.
import {readFileSync,existsSync,writeFileSync} from 'node:fs';
import {resolve,dirname,join} from 'node:path';
import {createHash} from 'node:crypto';
import {parseArgs} from 'node:util';
const {values:o}=parseArgs({options:{manifest:{type:'string',default:'video/cache/short0210/revision-05/assets-manifest.json'},timeline:{type:'string',default:'video/short0210/timeline.json'},out:{type:'string'}}});
const root=resolve(new URL('../..',import.meta.url).pathname),path=resolve(o.manifest),manifest=JSON.parse(readFileSync(path)),plan=JSON.parse(readFileSync(resolve(o.timeline)));
const sha=data=>createHash('sha256').update(data).digest('hex');
const capture=JSON.parse(readFileSync(join(dirname(path),manifest.captureReceipt)));
if(manifest.schema!=='omagma.video.assets.v1'||!capture.syntheticOnly||capture.liveProviderWrites!==0)throw Error('Native provenance scope invalid');
if(capture.binary.sha256!=='fc9d4d1cd62f62a3d2595236f6304ca7d282bb52dc4b89049ce9630b491f58fb')throw Error('Unexpected frozen native binary');
let previous=0;const ids=new Set(),used=new Set();
const bad=/fictional provider|author observed|not a benchmark|know what to ask|your mac\. your agents|📹|🎥|📷|never miss (a |another )?meeting/i;
for(const p of plan.parts){
 if(ids.has(p.id)||p.frameIn!==previous||p.frameOut<=p.frameIn||!Number.isInteger(p.frameIn)||!Number.isInteger(p.frameOut))throw Error('Non-contiguous phase '+p.id);
 ids.add(p.id);previous=p.frameOut;
 for(const value of [p.headline,p.subtitle,p.editorialTitle,p.editorialText,...(p.editorialRows||[])])if(typeof value==='string'&&bad.test(value))throw Error('Rejected on-screen copy '+value);
 for(const key of [p.asset,...(p.captures||[]),...(p.sequence||[]).map(x=>x.asset),...(p.views||[]).flatMap(v=>[v.asset,...(v.sequence||[]).map(x=>x.asset)])])if(key)used.add(key);
 let offset=-1;for(const row of p.sequence||[]){if(row.offset<=offset||row.offset<0||row.offset>=(p.frameOut-p.frameIn)/30)throw Error('Bad sequence '+p.id);offset=row.offset;}
 for(const view of p.views||[]){let at=-1;for(const row of view.sequence||[]){if(!Number.isFinite(row.at)||row.at<=at||row.at<0||row.at>=(p.frameOut-p.frameIn)/30)throw Error('Bad native view sequence '+p.id+'/'+view.id);at=row.at;}}
}
if(previous!==2527||plan.frameCount!==2527||plan.fps!==30||plan.width!==1920||plan.height!==1080)throw Error('Film clock differs from approved music');
for(const [key,a]of Object.entries(manifest.assets)){
 const file=a.file.startsWith('/')?join(root,a.file.replace(/^\/+/,'')):join(dirname(path),a.file);
 if(!existsSync(file))throw Error('Missing native picture '+key);
 const data=readFileSync(file);if(sha(data)!==a.sha256)throw Error('Native picture hash '+key);
 if(data.readUInt32BE(16)!==a.width||data.readUInt32BE(20)!==a.height)throw Error('Picture dimensions '+key);
 if(a.tape){const raw=readFileSync(join(dirname(path),a.tape));if(sha(raw)!==a.tapeSha256)throw Error('Native tape hash '+key);}
}
for(const key of used)if(!manifest.assets[key])throw Error('Timeline requires missing native asset '+key);
const report={passed:true,phases:plan.parts.length,referencedAssets:used.size,verifiedAssets:Object.keys(manifest.assets).length,frameCount:2527,duration:2527/30,nativeBinary:capture.binary,syntheticOnly:true,productionWrites:0};
if(o.out)writeFileSync(resolve(o.out),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify(report));
