import {mkdirSync,writeFileSync,readFileSync} from 'node:fs';import{join}from'node:path';import{createHash}from'node:crypto';import{browser,reservation,root}from'./cdp.mjs';
await reservation();const cache=join(root,'video/cache/short028'),out=join(cache,'recut-assets');mkdirSync(out,{recursive:true});const assets={};const b=await browser();
try{const p=await b.page('video/short028/capture-recut.html',{scale:2});
 const scenes=[['cli.overview_recut','cli-overview-recut','view'],['cli.mail_recut','cli-mail-recut','view'],['cli.json_recut','cli-json-recut','view'],['send.status_recut','send','receipt'],['send.button_recut','send','now-focus']];
 for(const[key,tape,mark]of scenes){const r=await p.evaluate('window.capture('+JSON.stringify(tape)+','+JSON.stringify(mark)+')');await p.evaluate('new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))');
  if(key==='send.button_recut')await p.evaluate(`(()=>{const h=document.getElementById('host');h.style.transformOrigin='0 0';h.style.transform='scale(4)';h.style.left='${20-51*r.cellW*4}px';h.style.top='${20-r.cellH*4}px';})()`);
  const clip=key==='send.status_recut'?{x:r.left,y:r.top+(r.rows-1)*r.cellH,width:95*r.cellW,height:r.cellH,scale:1}:key==='send.button_recut'?{x:20,y:20,width:17*r.cellW*4,height:r.cellH*4,scale:1}:{x:r.left-24,y:r.top-24,width:r.columns*r.cellW+48,height:r.rows*r.cellH+48,scale:1};
  const bytes=Buffer.from((await p.call('Page.captureScreenshot',{format:'png',clip})).data,'base64'),name=key.replaceAll('.','-')+'.png';writeFileSync(join(out,name),bytes);
  assets[key]={file:'recut-assets/'+name,width:clip.width*2,height:clip.height*2,sha256:createHash('sha256').update(bytes).digest('hex'),rois:{focus:[0,0,1,1]},provenance: 'Actual executable output / native status, no glyph edits',tape,mark};
 }
 await p.close();
}finally{await b.close();}
writeFileSync(join(cache,'recut-detail-assets.json'),JSON.stringify(assets,null,2)+'\n');console.log('Captured colored CLI and clean native success status');
