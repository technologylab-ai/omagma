import {mkdirSync,writeFileSync,copyFileSync} from 'node:fs';
import {join} from 'node:path';
import {browser,reservation,root} from './cdp.mjs';
await reservation();const out=join(root,'video/cache/short026/assets');mkdirSync(out,{recursive:true});
const b=await browser();
try{
 const p=await b.page('video/short026/capture-images.html',{scale:2});
 for(const [file,tape,mark] of [['notification','notification','hero'],['picker','compose','picker'],['attached','compose','attached'],['composer','compose','composer'],['composer-final','compose','composer-final']]){
   const rect=await p.evaluate('window.capture('+JSON.stringify(tape)+','+JSON.stringify(mark)+')');
   writeFileSync(join(out,file+'.png'),await p.screenshot());
   if(file==='notification'||file==='picker'){
     const pane=rect.panes.find(x=>x.title.includes(file==='notification'?'New mail':'Attach file'));
     if(!pane)throw Error('actual '+file+' pane missing');
     const margin=0;
     const clip={x:Math.max(0,rect.left+pane.x0*12-margin),y:Math.max(0,rect.top+pane.y0*24-margin),width:(pane.x1-pane.x0+1)*12+2*margin,height:(pane.y1-pane.y0+1)*24+2*margin,scale:1};
     const shot=await p.call('Page.captureScreenshot',{format:'png',clip});writeFileSync(join(out,file+'-detail.png'),Buffer.from(shot.data,'base64'));
   }
 }
 const q=await b.page('video/cache/short026/assets/browser.html',{width:980,height:1250,scale:2,ready:false});
 const geometry=await q.evaluate(`(()=>{const tags=new Set(['H1','H2','H3','UL','TABLE','PRE','P','A','IMG','SPAN']);const rects=Array.from(document.body.querySelectorAll('*')).filter(e=>tags.has(e.tagName)).map(e=>e.getBoundingClientRect()).filter(r=>r.width&&r.height);return{scrollHeight:document.documentElement.scrollHeight,clientHeight:innerHeight,images:Array.from(document.images).map(i=>({naturalWidth:i.naturalWidth,naturalHeight:i.naturalHeight})),body:document.body.innerText,bounds:{x:Math.min(...rects.map(r=>r.x)),y:Math.min(...rects.map(r=>r.y)),right:Math.max(...rects.map(r=>r.right)),bottom:Math.max(...rects.map(r=>r.bottom))}};})()`);
 if(geometry.scrollHeight>1250)throw Error('actual browser render exceeds viewport; increase browser viewport to preserve all ingredients');
 if(!geometry.body.includes('hello')||!geometry.body.includes('something')||!geometry.body.includes('Sent with omagma'))throw Error('actual HTML ingredients missing');
 writeFileSync(join(out,'browser-full.png'),await q.screenshot());
 const r=geometry.bounds,clip={x:Math.floor(r.x-24),y:Math.floor(r.y-24),width:Math.ceil(r.right-r.x+48),height:Math.ceil(r.bottom-r.y+48),scale:1};
 const shot=await q.call('Page.captureScreenshot',{format:'png',clip});writeFileSync(join(out,'browser.png'),Buffer.from(shot.data,'base64'));geometry.pictureCrop=clip;
 writeFileSync(join(root,'video/cache/short026/browser-geometry.json'),JSON.stringify(geometry,null,2));
 copyFileSync(join(root,'video/assets/omagma-logo-master.png'),join(out,'logo.png'));
 console.log('captured all actual UI and actual light HTML assets');
}finally{await b.close();}
