#!/usr/bin/env python3
"""Replay the captured native launch command and its sanitized actual stdout."""
import hashlib,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];CACHE=ROOT/'video/cache/short028'
sys.path[:0]=[str(ROOT/'video/capture'),str(ROOT/'tests')]
from tape import Recorder,TapeScreen,privacy_scan
def main():
 proof=json.loads((CACHE/'browser/server-connect-assets-passed.json').read_text())
 assert proof['passed'] and proof['actualNativeServer'] and proof['command']=='omagma server'
 output=(ROOT/proof['nativeServerStdout']).read_bytes()
 assert output.decode().strip()==proof['serverOrigin']+'/' and b'omagma-session' not in output
 privacy_scan([output.decode()])
 rec=Recorder.__new__(Recorder);rec.columns=72;rec.rows=10;rec.styles=[];rec.style_index={}
 frames=[];marks=[];sequence=[];command=proof['command']
 for i in range(len(command)+2):
  final=i>len(command);prefix=command[:min(i,len(command))]
  ansi='\x1b[38;2;255;158;97m$ \x1b[38;2;232;235;241m'+prefix
  if final:ansi+='\r\n\r\n\x1b[38;2;91;165;215m'+output.decode().replace('\n','\r\n')
  rec.screen=TapeScreen(rec.columns,rec.rows);rec.screen.feed(ansi.encode())
  frames.append({'t':round(i*.06,3),'rows':[rec.row_runs(y) for y in range(rec.rows)],'cursor':None})
  mark='output' if final else 'typed'+str(i);marks.append({'name':mark,'frame':i,'t':round(i*.06,3)})
  sequence.append({'offset':round(i*.06,3),'asset':'server.launch' if final else 'server.launch.'+mark})
 tape={'tape':'server-launch-story','columns':rec.columns,'rows':rec.rows,'defaults':{'fg':'#e8ebf1','bg':'#111620'},'styles':rec.styles,'frames':frames,'marks':marks,'source':{'method':'Editorial command typing replay using captured native argv and actual sanitized stdout','command':command,'stdoutSha256':hashlib.sha256(output).hexdigest(),'captureReceipt':proof['captureReceipt'],'fragmentRedacted':True}}
 (CACHE/'server-launch-story.json').write_text(json.dumps(tape)+'\n');(CACHE/'server-launch-sequence.json').write_text(json.dumps(sequence,indent=2)+'\n')
 print('Captured native launch command/output prepared for a 0.84s typing replay')
if __name__=='__main__':main()
