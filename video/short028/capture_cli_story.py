#!/usr/bin/env python3
"""Spaced, explicitly abridged help excerpts from actual offline output."""
import hashlib,json,re,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];CACHE=ROOT/'video/cache/short028'
sys.path[:0]=[str(ROOT/'video/capture'),str(ROOT/'tests')]
from tape import Recorder,TapeScreen,privacy_scan
def command(*args):
 r=subprocess.run([str(CACHE/'bin/omagma'),'cli',*args],capture_output=True,check=True);assert not r.stderr;return r.stdout
def save(name,data,columns,rows_count,source):
 privacy_scan([data.decode()]);screen=TapeScreen(columns,rows_count);screen.feed(data.replace(b'\n',b'\r\n'))
 rec=Recorder.__new__(Recorder);rec.screen=screen;rec.columns=columns;rec.rows=rows_count;rec.styles=[];rec.style_index={}
 rows=[rec.row_runs(y) for y in range(rows_count)]
 tape={'tape':name,'columns':columns,'rows':rows_count,'defaults':{'fg':'#e8ebf1','bg':'#111620'},'styles':rec.styles,'frames':[{'t':0,'rows':rows,'cursor':None}],'marks':[{'name':'view','frame':0,'t':0}],'source':source}
 (CACHE/(name+'.json')).write_text(json.dumps(tape)+'\n');(CACHE/(name+'.ansi')).write_bytes(data)
def main():
 raw=command('--help');lines=raw.decode().splitlines();chosen=[]
 for match in ['omagma cli --help commands','omagma cli --help mail ','omagma cli --help mail.read','omagma cli --schema mail.read']:
  chosen.append(next(s.strip() for s in lines if match in s))
 text='\n\n'.join(chosen)+'\n\n…\n'
 save('cli-overview-story',text.encode(),104,15,{'actualStdoutSha256':hashlib.sha256(raw).hexdigest(),'abridged':True,'selectedLines':chosen,'onlyWhitespaceAndEllipsisAdded':True})
 raw=command('--help','mail');lines=raw.decode().splitlines();names=['mail.list','mail.read','mail.reply','mail.forward']
 chosen=[next(s.strip() for s in lines if re.match(re.escape(n)+r'\s',s.strip())) for n in names]
 text='Omagma · mail commands\n\n'+'\n\n'.join(chosen)+'\n\n…\n'
 save('cli-mail-story',text.encode(),108,16,{'actualStdoutSha256':hashlib.sha256(raw).hexdigest(),'abridged':True,'selectedLines':chosen,'onlyWhitespaceAndEllipsisAdded':True})
 print('Spaced abridged command excerpts captured; unchanged meaning, no dense help dump')
if __name__=='__main__':main()
