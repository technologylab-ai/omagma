import{mkdirSync,writeFileSync,readFileSync}from'node:fs';import{join}from'node:path';import{createHash}from'node:crypto';import{browser,reservation,root}from'./cdp.mjs';
await reservation();const cache=join(root,'video/cache/short028'),out=join(cache,'story-assets');mkdirSync(out,{recursive:true});const assets={};const b=await browser();
try{const p=await b.page('video/short028/capture-story.html',{scale:2});
 const jobs=[['cli.overview_story','cli-overview-story','view'],['cli.mail_story','cli-mail-story','view'],['send.timer10_story','send','countdown'],['send.timer9_story','send','countdown-nine'],['send.timer8_story','send','countdown-eight'],['send.complete_story','send','receipt'],...JSON.parse(readFileSync(join(cache,'server-launch-story.json'))).marks.map(m=>[m.name==='output'?'server.launch':'server.launch.'+m.name,'server-launch-story',m.name])];
 for(const[key,tape,mark]of jobs){
  const r=await p.evaluate('window.capture('+JSON.stringify(tape)+','+JSON.stringify(mark)+')');let clip;
  if(tape==='send'){
   const row=mark==='receipt'?r.rows-1:1;
   await p.evaluate(`(()=>{const h=document.getElementById('host');h.style.transformOrigin='0 0';h.style.transform='scale(3)';h.style.left='20px';h.style.top='${20-row*r.cellH*3}px';})()`);
   clip={x:20,y:20,width:(mark==='receipt'?13:14)*r.cellW*3,height:r.cellH*3,scale:1};
  }else {await p.evaluate("document.getElementById('host').style.transform='none'");clip={x:r.left-24,y:r.top-24,width:r.columns*r.cellW+48,height:r.rows*r.cellH+48,scale:1};}
  await p.evaluate('new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))');const data=Buffer.from((await p.call('Page.captureScreenshot',{format:'png',clip})).data,'base64');const file=key.replaceAll('.','-')+'.png';writeFileSync(join(out,file),data);assets[key]={file:'story-assets/'+file,width:clip.width*2,height:clip.height*2,sha256:createHash('sha256').update(data).digest('hex'),rois:{focus:[0,0,1,1]},provenance:tape==='send'?'Actual native timer row, counter10→9→8':'Spaced abridged actual command output, ellipsis explicitly marks omission'};
 }
 await p.close();
}finally{await b.close();}
writeFileSync(join(cache,'story-detail-assets.json'),JSON.stringify(Object.fromEntries(Object.entries(assets).filter(([k])=>!k.startsWith('server.'))),null,2)+'\n');writeFileSync(join(cache,'server-launch-assets.json'),JSON.stringify(Object.fromEntries(Object.entries(assets).filter(([k])=>k.startsWith('server.'))),null,2)+'\n');console.log('Spaced CLI, readable countdown and actual launch command replay captured');
