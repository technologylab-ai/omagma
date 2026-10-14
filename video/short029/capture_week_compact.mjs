// Rasterize only the new native week; preserve every other approved capture.
import {readFileSync,writeFileSync,mkdirSync,existsSync} from 'node:fs';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {browser,reservation,root} from './cdp.mjs';
const cache=join(root,'video/cache/short029'),take='revision-04/week-compact';
await reservation();
const receipt=JSON.parse(readFileSync(join(cache,take,'capture-manifest.json')));
const original=JSON.parse(readFileSync(join(cache,'revision-02/calendar/capture-manifest.json')));
if(receipt.binary.sha256!==original.binary.sha256||!receipt.allSevenDaysVisible||!receipt.enterOpensSameJoinEvent)throw Error('Week continuity proof missing');
const out=join(cache,'revision-04/assets');if(existsSync(out))throw Error('Preserve prior assets');mkdirSync(out);
const b=await browser();
try {
 const p=await b.page('video/short029/capture-images.html',{scale:2});
 const rect=await p.evaluate(`window.capture(${JSON.stringify(take+'/week.json')},'week')`);
 await p.evaluate('new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))');
 const clip={x:rect.left,y:rect.top,width:rect.columns*rect.cellW,height:rect.rows*rect.cellH,scale:1};
 const data=Buffer.from((await p.call('Page.captureScreenshot',{format:'png',clip})).data,'base64');
 writeFileSync(join(out,'calendar-week.png'),data);
 const path=join(cache,'assets-manifest.json'),manifest=JSON.parse(readFileSync(path));
 manifest.assets['calendar.week']={file:'revision-04/assets/calendar-week.png',width:clip.width*2,height:clip.height*2,
  sha256:createHash('sha256').update(data).digest('hex'),rois:{full:[0,0,1,1],focus:[0,0,1,1]},
  tape:take+'/week.json',mark:'week',panes:rect.panes,
  provenance:'Actual native 132×28 PTY cells; same fictional week and selected Design review; no application rendering changes'};
 manifest.weekReceipt=take+'/capture-manifest.json';writeFileSync(path,JSON.stringify(manifest,null,2)+'\n');
 console.log('Rasterized compact week; all other native assets preserved');
}finally{await b.close();}
