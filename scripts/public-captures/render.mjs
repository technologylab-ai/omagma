// Rasterize unmodified, completed native PTY cells. No app UI is reconstructed.
import {readFileSync,writeFileSync,existsSync} from 'node:fs';
import {resolve,relative,join} from 'node:path';
import {parseArgs} from 'node:util';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {Tape} from '../../video/web/term.js';
import {browser,reservation,root} from '../../video/short0210/cdp.mjs';
const {values:o}=parseArgs({options:{capture:{type:'string'}}});
const directory=resolve(o.capture||''), cacheRoot=join(root,'video/cache/short0210');
if(!directory.startsWith(cacheRoot+'/'))throw Error('Capture directory must be an owned, ignored cache');
await reservation();
const manifest=JSON.parse(readFileSync(join(directory,'capture-manifest.json'),'utf8'));
if(manifest.release!=='0.2.10'||!manifest.syntheticOnly||manifest.liveProviderWrites!==0)throw Error('Invalid synthetic release capture');
const digest=bytes=>createHash('sha256').update(bytes).digest('hex');
const fontFamily=execFileSync('fc-match',['-f','%{family}','JetBrainsMono Nerd Font'],{encoding:'utf8'}).trim();
if(!fontFamily.includes('JetBrainsMono Nerd Font'))throw Error('Install JetBrainsMono Nerd Font before public capture');
manifest.rasterizer={fontFamily,cellWidth:12,cellHeight:24,deviceScaleFactor:1,applicationCellsEdited:false};
const html=`<!doctype html><meta charset="utf-8"><style>
*{box-sizing:border-box}html,body{margin:0;background:#111620;overflow:hidden}
.term-grid{position:relative;font-family:"JetBrainsMono Nerd Font","Noto Color Emoji",monospace;font-variant-ligatures:none;font-feature-settings:"liga" 0,"calt" 0}
.term-text .run{position:absolute;white-space:pre;overflow:visible;height:inherit}.term-text .run.wide{text-align:center}
.term-lines{position:absolute;left:0;top:0;overflow:visible}.term-cursor{position:absolute}
</style><div id="host"></div><script type="module">
import {Tape,TermView} from '/video/web/term.js';let view;window.READY=document.fonts.ready.then(()=>true);
window.capture=async(path,mark)=>{const response=await fetch(path);if(!response.ok)throw Error('Missing tape');const tape=new Tape(await response.json());
document.body.replaceChildren(Object.assign(document.createElement('div'),{id:'host'}));view=new TermView(document.querySelector('#host'),{cellW:12,cellH:24,columns:tape.columns,rows:tape.rows});
view.show(tape,tape.mark(mark).frame,{blink:false});await document.fonts.ready;return {width:tape.columns*12,height:tape.rows*24,font:document.fonts.check('20px "JetBrainsMono Nerd Font"')};};
</script>`;
const pageFile=join(directory,'rasterize.html');
if(existsSync(pageFile))throw Error('Preserve previous rasterization');
writeFileSync(pageFile,html);
const b=await browser();
try{
 const page=await b.page(relative(root,pageFile),{width:1584,height:960,scale:1});
 for(const [name,asset] of Object.entries(manifest.assets)){
  const tapePath=resolve(directory,asset.tape);
  if(!tapePath.startsWith(directory+'/'))throw Error('Unowned tape');
  const bytes=readFileSync(tapePath),tape=new Tape(JSON.parse(bytes));
  const rect=await page.evaluate('window.capture('+JSON.stringify('/'+relative(root,tapePath))+','+JSON.stringify(asset.mark)+')');
  if(!rect.font)throw Error('Required native Nerd Font unavailable');
  await page.evaluate('new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))');
  const png=Buffer.from((await page.call('Page.captureScreenshot',{format:'png',clip:{x:0,y:0,width:rect.width,height:rect.height,scale:1}})).data,'base64');
  const output=join(root,'docs/images',asset.file);
  writeFileSync(output,png);
  Object.assign(asset,{width:png.readUInt32BE(16),height:png.readUInt32BE(20),sha256:digest(png),tapeSha256:digest(bytes),frame:tape.mark(asset.mark).frame,
      provenance:'Unmodified completed native PTY cells from released v0.2.10, fictional providers only'});
  console.log(name+': '+asset.width+'x'+asset.height+' '+asset.sha256);
 }
 if(page.errors.length)throw Error(page.errors.join('\n'));
 await page.close();
}finally{await b.close();}
writeFileSync(join(directory,'raster-manifest.json'),JSON.stringify(manifest,null,2)+'\n');
