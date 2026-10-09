// Small media-only CDP harness. Reuses launch-film's isolated headless method.
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtempSync,readFileSync,existsSync,statSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve,relative,extname} from 'node:path';
export const root=resolve(new URL('.',import.meta.url).pathname,'../..');
export async function reservation() {
  const p=spawn('python3',[join(root,'video/tools/host_lock.py'),'verify',process.env.HOST_TOKEN||''],{stdio:'inherit'});
  await new Promise((ok,no)=>{p.once('error',no);p.once('exit',c=>c===0?ok():no(Error('matching live host reservation required')));});
}
export async function browser() {
  const allowed=['video/short027/','video/cache/short027/','video/web/term.js','video/assets/omagma-logo-master.png','assets/omagma-logo.png'];
  const types={'.html':'text/html','.js':'text/javascript','.mjs':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.jpg':'image/jpeg','.mp4':'video/mp4'};
  const server=createServer((req,res)=>{
    let rel;
    try {rel=decodeURIComponent(new URL(req.url,'http://x').pathname).replace(/^\/+/, '');} catch {res.writeHead(400);res.end();return;}
    const file=resolve(root,rel), safe=relative(root,file);
    if(safe.startsWith('..')||!allowed.some(x=>safe===x||safe.startsWith(x))||!existsSync(file)||!statSync(file).isFile()){res.writeHead(404);res.end();return;}
    const data=readFileSync(file),headers={'content-type':types[extname(file)]||'application/octet-stream','cache-control':'no-store','accept-ranges':'bytes'};
    if(req.headers.range){
      const m=/^bytes=(\d*)-(\d*)$/.exec(req.headers.range);
      if(!m){res.writeHead(416,{'content-range':'bytes */'+data.length});res.end();return;}
      const start=m[1]?Number(m[1]):Math.max(0,data.length-Number(m[2])),end=m[1]?(m[2]?Math.min(Number(m[2]),data.length-1):data.length-1):data.length-1;
      if(!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start<0||end<start||start>=data.length){res.writeHead(416,{'content-range':'bytes */'+data.length});res.end();return;}
      res.writeHead(206,{...headers,'content-range':'bytes '+start+'-'+end+'/'+data.length,'content-length':end-start+1});res.end(data.subarray(start,end+1));return;
    }
    res.writeHead(200,{...headers,'content-length':data.length});res.end(data);
  });
  await new Promise(ok=>server.listen(0,'127.0.0.1',ok));
  const origin='http://127.0.0.1:'+server.address().port, profile=mkdtempSync(join(tmpdir(),'omagma-short027-chrome-'));
  const chrome=spawn(process.env.CHROMIUM||'/usr/bin/chromium',['--headless','--remote-debugging-pipe','--user-data-dir='+profile,'--no-first-run','--no-default-browser-check','--disable-extensions','--disable-background-networking','--disable-sync','--mute-audio','--hide-scrollbars','--font-render-hinting=none','--force-color-profile=srgb','--disable-renderer-backgrounding','--disable-background-timer-throttling','--disable-backgrounding-occluded-windows','about:blank'],{detached:true,stdio:['ignore','ignore','pipe','pipe','pipe'],env:{...process.env,DISPLAY:'',WAYLAND_DISPLAY:'',DBUS_SESSION_BUS_ADDRESS:''}});
  const waiting=new Map(),listeners=[];let id=0,buffer='',gone=null,log='';
  function rejectAll(reason){gone=reason;for(const p of waiting.values())p.reject(Error(reason));waiting.clear();}
  chrome.on('error',e=>rejectAll(e.message));chrome.on('exit',(c,s)=>rejectAll('Chrome exited '+(s||c)));
  chrome.stderr.on('data',d=>log=(log+d).slice(-5000));
  chrome.stdio[3].on('error',()=>rejectAll('Chrome pipe closed'));
  chrome.stdio[4].setEncoding('utf8');chrome.stdio[4].on('data',chunk=>{
    buffer+=chunk;let end;
    while((end=buffer.indexOf('\0'))>=0){const m=JSON.parse(buffer.slice(0,end));buffer=buffer.slice(end+1);if(m.id&&waiting.has(m.id)){const p=waiting.get(m.id);waiting.delete(m.id);m.error?p.reject(Error(m.error.message)):p.resolve(m.result);}else for(const f of listeners)f(m);}
  });
  const send=(method,params={},sessionId,timeout=30000)=>{
    if(gone)return Promise.reject(Error(gone));const n=++id;
    return new Promise((resolve,reject)=>{const timer=setTimeout(()=>{waiting.delete(n);reject(Error(method+' timed out'));},timeout);waiting.set(n,{resolve:v=>{clearTimeout(timer);resolve(v);},reject:e=>{clearTimeout(timer);reject(e);}});chrome.stdio[3].write(JSON.stringify({id:n,method,params,...(sessionId?{sessionId}:{})})+'\0');});
  };
  async function close(){if(!gone){await send('Browser.close',{},undefined,3000).catch(()=>{});}if(chrome.exitCode===null){try{process.kill(-chrome.pid,'SIGTERM');}catch{}await new Promise(ok=>{chrome.once('exit',ok);setTimeout(ok,3000);});}if(chrome.exitCode===null){try{process.kill(-chrome.pid,'SIGKILL');}catch{}await new Promise(ok=>{chrome.once('exit',ok);setTimeout(ok,1000);});}server.closeAllConnections();server.close();rmSync(profile,{recursive:true,force:true});}
  async function page(path,{width=1920,height=1080,scale=1,ready=true}={}){
    const {targetId}=await send('Target.createTarget',{url:'about:blank',newWindow:true});
    const {sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});
    const call=(m,p={},timeout)=>send(m,p,sessionId,timeout), errors=[];
    listeners.push(m=>{
      if(m.sessionId!==sessionId)return;
      if(m.method==='Runtime.exceptionThrown')errors.push(m.params.exceptionDetails?.exception?.description||m.params.exceptionDetails.text);
      if(m.method==='Fetch.requestPaused'){
        const u=m.params.request.url;
        if(u.startsWith(origin+'/')||u.startsWith('data:'))call('Fetch.continueRequest',{requestId:m.params.requestId}).catch(()=>{});
        else call('Fetch.failRequest',{requestId:m.params.requestId,errorReason:'BlockedByClient'}).catch(()=>{});
      }
    });
    await call('Page.enable');await call('Runtime.enable');await call('Fetch.enable',{patterns:[{urlPattern:'*'}]});
    await call('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:scale,mobile:false});
    await call('Emulation.setEmulatedMedia',{features:[{name:'prefers-color-scheme',value:'light'}]});
    const loaded=new Promise((ok,no)=>{const f=m=>{if(m.sessionId===sessionId&&m.method==='Page.loadEventFired'){clearTimeout(timer);listeners.splice(listeners.indexOf(f),1);ok();}};const timer=setTimeout(()=>{listeners.splice(listeners.indexOf(f),1);no(Error('page load timed out'));},30000);listeners.push(f);});
    await call('Page.navigate',{url:origin+'/'+path});await loaded;
    const evaluate=async(expression)=>{const r=await call('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true},45000);if(r.exceptionDetails)throw Error(r.exceptionDetails.exception?.description||r.exceptionDetails.text);return r.result.value;};
    let info;
    if(ready)info=await evaluate('window.READY || window.ready');
    else await evaluate('Promise.all([document.fonts.ready,...Array.from(document.images).map(i=>i.complete?Promise.resolve():new Promise((r,j)=>{i.onload=r;i.onerror=j;}))])');
    return {call,evaluate,info,errors,close:()=>send('Target.closeTarget',{targetId}),screenshot:async(format='png',quality=94)=>{if(errors.length)throw Error(errors.join('\n'));const r=await call('Page.captureScreenshot',{format,...(format==='jpeg'?{quality}:{}),optimizeForSpeed:true});return Buffer.from(r.data,'base64');}};
  }
  return {page,close,origin,log:()=>log};
}
