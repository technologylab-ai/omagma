#!/usr/bin/env python3
"""Capture concise, real offline discovery output and actual jq ANSI colors."""
import hashlib,json,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];CACHE=ROOT/'video/cache/short028'
sys.path[:0]=[str(ROOT/'video/capture'),str(ROOT/'tests')]
from tape import Recorder,TapeScreen,privacy_scan
binary=CACHE/'bin/omagma'
def run(args,data=None):
 r=subprocess.run([str(x) for x in args],input=data,capture_output=True,check=True);assert not r.stderr;return r.stdout
def capture(name,data,command):
 privacy_scan([data.decode()],known=['launch@example.test'])
 columns=64 if name=='cli-json-recut' else 110;rows_count=13 if name=='cli-json-recut' else 30
 screen=TapeScreen(columns,rows_count);screen.feed(data.replace(b'\n',b'\r\n'))
 rec=Recorder.__new__(Recorder);rec.screen=screen;rec.columns=columns;rec.rows=rows_count;rec.styles=[];rec.style_index={}
 rows=[rec.row_runs(y) for y in range(rows_count)]
 tape={'tape':name,'columns':columns,'rows':rows_count,'defaults':{'fg':'#e8ebf1','bg':'#111620'},'styles':rec.styles,'frames':[{'t':0,'rows':rows,'cursor':None}],'marks':[{'name':'view','t':0,'frame':0}],'source':{'command':command,'rawSha256':hashlib.sha256(data).hexdigest(),'realExecutableStdout':True}}
 (CACHE/(name+'.ansi')).write_bytes(data);(CACHE/(name+'.json')).write_text(json.dumps(tape)+'\n')
def main():
 capture('cli-overview-recut',run([binary,'cli','--help']), 'omagma cli --help')
 capture('cli-mail-recut',run([binary,'cli','--help','mail']), 'omagma cli --help mail')
 schema=run([binary,'cli','--schema','mail.read'])
 projection='{command:.title,example:.examples[0]}'
 colored=run(['jq','-C',projection],schema)
 capture('cli-json-recut',colored,'omagma cli --schema mail.read | jq -C '+projection)
 print('Captured progressive offline help and actual jq-colored JSON')
if __name__=='__main__':main()
