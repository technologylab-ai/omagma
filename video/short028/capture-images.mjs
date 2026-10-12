// Rasterize unchanged captured PTY cells and literal offline command stdout.
import {mkdirSync,writeFileSync,readFileSync,existsSync} from 'node:fs';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {browser,reservation,root} from './cdp.mjs';
await reservation();
const cache=join(root,'video/cache/short028'),out=join(cache,'assets');mkdirSync(out,{recursive:true});
const sha=x=>createHash('sha256').update(x).digest('hex');
for(const name of ['cli-index','cli-command','cli-schema']){
 const data=readFileSync(join(cache,name+'.txt')),text=data.toString('utf8');
 const lines=text.replace(/\n$/,'').split('\n'),columns=160,rows=42;
 const start=name==='cli-schema'?Math.max(0,lines.findIndex(x=>x.includes('"Draft": {'))):0;
 const viewport=lines.slice(start,start+rows).map(x=>x.slice(0,columns));while(viewport.length<rows)viewport.push('');
 writeFileSync(join(cache,name+'.json'),JSON.stringify({tape:name,columns,rows,defaults:{fg:'#e8ebf1',bg:'#111620'},styles:[['#e8ebf1',null,0]],frames:[{t:0,rows:viewport.map(x=>[[0,x,0,x.length]]),cursor:[0,0,false,0]}],marks:[{name:'view',frame:0,t:0}],source:{literalStdout:true,sha256:sha(data),visibleLines:[start+1,Math.min(start+rows,lines.length)],fullLineCount:lines.length}}));
}
const scenes=[
 ['mac.context','mac','context'],['mac.ssh_result','mac','ssh-result'],
 ['cli.help_index','cli-index','view'],['cli.help_command','cli-command','view'],['cli.help_schema','cli-schema','view'],
 ['reader.context','reader','context'],['reader.move','reader','move'],['reader.at_paragraph','reader','at-paragraph'],['reader.marked','reader','marked'],['reader.excerpt','reader','excerpt'],['reader.copied','reader','copied'],
 ['editor.context','editor','context'],['editor.view','editor','view'],['editor.paragraph','editor','paragraph'],['editor.returned','editor','returned'],
 ['send.review','send','review'],['send.countdown','send','countdown'],['send.countdown_nine','send','countdown-nine'],['send.countdown_eight','send','countdown-eight'],['send.now_focus','send','now-focus'],['send.receipt','send','receipt']];
const manifest={schema:'omagma.video.assets.v1',assets:{},captureReceipt:'native-receipt.json'};
const b=await browser();
try{
 const p=await b.page('video/short028/capture-images.html',{scale:2});
 for(const [key,tape,mark] of scenes){
  if(!existsSync(join(cache,tape+'.json')))throw Error('required genuine take missing '+tape);
  const rect=await p.evaluate('window.capture('+JSON.stringify(tape)+','+JSON.stringify(mark)+')');
  await p.evaluate('new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))');
  // Editorial matte around literal CLI/editor output protects first glyphs
  // from the film's rounded mask. Every application cell remains unchanged.
  const matte=tape.startsWith('cli')||key==='editor.view'||key==='editor.paragraph'?24:0;
  const clip={x:rect.left-matte,y:rect.top-matte,width:rect.columns*rect.cellW+2*matte,height:rect.rows*rect.cellH+2*matte,scale:1};
  const data=Buffer.from((await p.call('Page.captureScreenshot',{format:'png',clip})).data,'base64');
  const filename=key.replaceAll('.','-')+'.png';writeFileSync(join(out,filename),data);
  let focus=[0,0,1,1];
  if(key.startsWith('reader.'))focus=[.625,.04,.37,.78];
  if(key==='editor.view'||key==='editor.paragraph')focus=[0,.02,.7,.60];
  if(key.startsWith('cli.'))focus=[0,0,.64,.78];
  if(key==='send.review'){const pane=rect.panes.find(x=>x.title.includes('Review send'));if(pane)focus=[pane.x0/rect.columns,pane.y0/rect.rows,(pane.x1-pane.x0+1)/rect.columns,(pane.y1-pane.y0+1)/rect.rows];}
  if(key.startsWith('send.countdown')||key==='send.now_focus')focus=[0,0,.76,.38];
  if(key==='send.receipt')focus=[0,.87,.76,.13];
  manifest.assets[key]={file:'assets/'+filename,width:clip.width*2,height:clip.height*2,sha256:sha(data),rois:{focus},platform:tape==='mac'?'macOS arm64 via SSH':'Linux',provenance:tape.startsWith('cli')?'Literal offline CLI stdout; unchanged viewport lines':'Actual native PTY cells; fictional provider',editorialMattePixels:matte*2,tape,mark};
 }
 await p.close();
}finally{await b.close();}
writeFileSync(join(cache,'native-assets-manifest.json'),JSON.stringify(manifest,null,2)+'\n');
console.log('Rasterized '+Object.keys(manifest.assets).length+' genuine native/CLI states');
