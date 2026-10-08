import {mkdirSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {join} from 'node:path';
import {browser,reservation,root} from './cdp.mjs';
await reservation();const b=await browser(),out=join(root,'video/cache/short026/qa');mkdirSync(out,{recursive:true});
const sha=b=>createHash('sha256').update(b).digest('hex');
try{
 const p=await b.page('video/short026/film.html');
 const render=t=>p.evaluate('window.render('+t+');new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(()=>r(true))))');
 await render(24.5);
 const qolLayout=await p.evaluate(`Array.from(document.querySelectorAll('.q-row')).map(row=>{const r=row.getBoundingClientRect();return{text:row.innerText.replace(/\\s+/g,' ').trim(),fontSize:getComputedStyle(row).fontSize,left:r.left,right:r.right,top:r.top,bottom:r.bottom,height:r.height};})`);
 if(qolLayout.length!==5||!qolLayout[0].text.includes('Ctrl+G jumps to body top'))throw Error('QoL shortcut explanation missing');
 if(qolLayout.some(r=>r.fontSize!=='39px'||r.left<0||r.right>1920||r.top<0||r.bottom>1080||r.height>52))throw Error('QoL copy wraps or overflows the1080p frame');
 const samples=[];
 for(const t of [1.6,6.6,9.8,11.8,15.4,18.4,20.6,23.5,27.4,30.2]){
  await render(t);
  const image=await p.screenshot();writeFileSync(join(out,'t'+t.toFixed(2)+'.png'),image);
  const state=await p.evaluate('({scene:window.qa?window.qa('+t+'):null,text:document.body.innerText,images:Array.from(document.images).map(i=>({src:i.getAttribute("src"),width:i.naturalWidth,height:i.naturalHeight}))})');
  if(state.images.some(i=>!i.width||!i.height))throw Error('missing picture image');
  samples.push({time:t,pictureSha256:sha(image),...state});
 }
 await render(5.5);const before=sha(await p.screenshot());
 await render(23.1);await render(5.5);const after=sha(await p.screenshot());
 await render(24.5);const qolBefore=sha(await p.screenshot());await render(30.2);await render(24.5);const qolAfter=sha(await p.screenshot());
 if(qolBefore!==qolAfter)throw Error("improvements scene depends on render history");
 if(before!==after)throw Error('render(t) depends on previous sampling history');
 writeFileSync(join(out,'receipt.json'),JSON.stringify({film:await p.evaluate('window.FILM'),qolLayout,deterministicHistoryCheck:{time:5.5,before,after,qolTime:24.5,qolBefore,qolAfter,passed:true},samples},null,2));
 console.log('all picture assets loaded; arbitrary-order deterministic frame check passed');
}finally{await b.close();}
