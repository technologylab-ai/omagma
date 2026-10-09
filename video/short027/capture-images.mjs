import {mkdirSync,writeFileSync,readFileSync,existsSync,copyFileSync} from 'node:fs';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {browser,reservation,root} from './capture_cdp.mjs';
const tapeArg=process.argv.indexOf('--tape');const onlyTape=tapeArg>=0?process.argv[tapeArg+1]:null;
await reservation();const out=join(root,'video/cache/short027/assets');mkdirSync(out,{recursive:true});
const scenes=[
 ['updates-card','updates','updates-card','Upgrade available'],['updates-card-focused','updates','updates-card-focused','Upgrade available'],['updates-guide','updates','updates-guide','Updates · this installation'],
 ['palette-initial','palette','palette-initial','Actions'],['palette-l','palette','palette-l','Actions'],['palette-la','palette','palette-la','Actions'],['palette-lab','palette','palette-lab','Actions'],['palette-labe','palette','palette-labe','Actions'],['palette-label','palette','palette-label','Actions'],
 ['labels-context','labels','labels-context'],['labels-initial','labels','labels-initial','Labels · staged changes'],['labels-stage-one','labels','labels-stage-one','Labels · staged changes'],['labels-staged','labels','labels-staged','Labels · staged changes'],['labels-applied','labels','labels-applied'],['labels-result','labels','labels-result'],['labels-result-second','labels','labels-result-second'],
 ['main','main','main'],['palette','main','palette-filtered','Actions'],['help','main','help','Keyboard & mouse'],['theme','main','theme','Theme'],['labels','main','labels-staged','Labels · staged changes'],['label-colors','main','label-colors','Color ·'],['scope','main','scope','Mail action scope'],['find','main','find'],['find-next','main','find-next'],['saved-search','main','saved-search','Saved searches'],
 ['meeting','meeting','meeting'],['meeting-review','meeting','meeting-review','Meeting ·'],['meeting-details','meeting','meeting-details','Meeting ·'],['join','meeting','join','Meeting ·'],
 ['recipient','compose','recipient'],['recipient-named','compose','composer'],['sender','compose','sender','Choose sender'],['composer','compose','composer'],['composer-edit','compose','composer-edit'],['composer-undo','compose','composer-undo'],['files','compose','files','Attach file'],['attached','compose','attached'],['send-review','compose','send-review','Review send'],['countdown','compose','countdown'],['countdown-nine','compose','countdown-nine'],['send-canceled','compose','send-canceled'],
 ['forward','forward','forward'],['format-choice','forward','format-choice','Forward'],['newmail','newmail','newmail','New mail'],['newmail-hidden','newmail','newmail-hidden']];
const priorReceipt=join(root,'video/cache/short027/raster-receipt.json');
const receipt=onlyTape&&existsSync(priorReceipt)?JSON.parse(readFileSync(priorReceipt,'utf8')):{source:'actual captured PTY cells only, no cell edits',scale:2,assets:{}};
const b=await browser();
function asset(name,data,info){writeFileSync(join(out,name+'.png'),data);receipt.assets[name+'.png']={...info,sha256:createHash('sha256').update(data).digest('hex'),bytes:data.length};}
try{
 const p=await b.page('video/short027/capture-images.html',{scale:2});
 for(const [file,tape,mark,title] of scenes){
  if(onlyTape&&tape!==onlyTape)continue;
  const path=join(root,'video/cache/short027',tape+'.json');if(!existsSync(path))continue;
  const source=JSON.parse(readFileSync(path,'utf8'));if(!source.marks.some(m=>m.name===mark))continue;
  const rect=await p.evaluate('window.capture('+JSON.stringify(tape)+','+JSON.stringify(mark)+')');
  const full={x:rect.left,y:rect.top,width:rect.columns*rect.cellW,height:rect.rows*rect.cellH,scale:1};
  asset(file,Buffer.from((await p.call('Page.captureScreenshot',{format:'png',clip:full})).data,'base64'),{tape,mark,clip:full,width:full.width*2,height:full.height*2});
  if(title){const pane=rect.panes.filter(x=>x.title.includes(title)).at(-1);if(!pane)throw Error('actual pane missing '+file+' '+JSON.stringify(rect.panes));const clip={x:rect.left+pane.x0*rect.cellW,y:rect.top+pane.y0*rect.cellH,width:(pane.x1-pane.x0+1)*rect.cellW,height:(pane.y1-pane.y0+1)*rect.cellH,scale:1};asset(file+'-detail',Buffer.from((await p.call('Page.captureScreenshot',{format:'png',clip})).data,'base64'),{tape,mark,actualPane:pane,clip,width:clip.width*2,height:clip.height*2});}
  if(file==='recipient'||file==='recipient-named'){const clip={x:rect.left,y:rect.top+3*rect.cellH,width:96*rect.cellW,height:6*rect.cellH,scale:1};asset(file+'-detail',Buffer.from((await p.call('Page.captureScreenshot',{format:'png',clip})).data,'base64'),{tape,mark,sourceRegion:'actual compose header and native completion rows',clip,width:clip.width*2,height:clip.height*2});}
  if(file.startsWith('countdown')||file==='send-canceled'){const clip={x:rect.left,y:rect.top,width:rect.columns*rect.cellW,height:3*rect.cellH,scale:1};asset(file+'-detail',Buffer.from((await p.call('Page.captureScreenshot',{format:'png',clip})).data,'base64'),{tape,mark,clip,width:clip.width*2,height:clip.height*2});}
 }
 await p.close();
 if(!onlyTape&&existsSync(join(out,'browser.html'))){
  const q=await b.page('video/cache/short027/assets/browser.html',{width:1000,height:1900,scale:2,ready:false});
  const content=await q.evaluate(`(()=>{const f=document.querySelector('iframe');return {heading:document.querySelector('h1').textContent,sandbox:f.getAttribute('sandbox'),html:f.srcdoc,frameBounds:f.getBoundingClientRect().toJSON(),shellText:document.body.innerText};})()`);
  if(content.sandbox!==''||!content.html.includes('EMBER AIR')||!content.html.includes('Lisbon trip')||!content.html.includes('data:image/png;base64,')||!content.html.includes('<table'))throw Error('native browser preview lost formatted original or note/resources');
  await q.evaluate('new Promise(r=>setTimeout(r,700))');
  asset('browser',await q.screenshot(),{source:'unmodified native draft.open-preview artifact, opaque iframe',width:2000,height:3800,heading:content.heading,frameBounds:content.frameBounds});
  const clip={x:0,y:0,width:1000,height:1000,scale:1};asset('browser-top',Buffer.from((await q.call('Page.captureScreenshot',{format:'png',clip})).data,'base64'),{width:2000,height:2000,clip});
  receipt.browser={nativePreview:true,sandbox:content.sandbox,embeddedImages:(content.html.match(/data:image\/png;base64,/g)||[]).length,originalBookingAndMarkdownNote:true};await q.close();
 }
 if(!onlyTape)copyFileSync(join(root,'video/assets/omagma-logo-master.png'),join(out,'logo.png'));
 writeFileSync(join(root,'video/cache/short027/raster-receipt.json'),JSON.stringify(receipt,null,2)+'\n');console.log('Rendered '+Object.keys(receipt.assets).length+' genuine TUI/light-browser assets.');
}finally{await b.close();}
