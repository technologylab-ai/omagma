#!/usr/bin/env python3
"""Convert genuine native screen_capture cells/styles into our unchanged tape format."""
from pathlib import Path
import json,hashlib
ROOT=Path(__file__).resolve().parents[2]
def color(v):
    if v[0]=='rgb':return '#'+''.join(f'{x:02x}' for x in v[1:4])
    if v[0]=='default':return None
    raise ValueError('unexpected native color encoding')
def main():
    directory=ROOT/'video/cache/short027/update-captures'
    styles=[];style_index={};frames=[];marks=[];sources=[]
    for i,name in enumerate(['updates-card','updates-card-focused','updates-guide']):
        path=directory/(name+'.json');d=json.loads(path.read_text());grid=d['cellGrid']
        assert len(grid)==40 and all(len(row)==160 for row in grid)
        rows=[[] for _ in grid]
        for y,a,b,s in d['currentStyleRuns']:
            fg,bg=color(s[0]),color(s[1]);mask=sum(flag for flag,on in zip([1,2,4,8],s[2:]) if on)
            item=[fg or '#e8ebf1',bg or '#111620',mask];key=tuple(item)
            if key not in style_index:style_index[key]=len(styles);styles.append(item)
            rows[y].append([a,''.join(grid[y][a:b]),style_index[key],b-a])
        frames.append({'t':i,'rows':rows,'cursor':None})
        marks.append({'name':name,'t':i,'frame':i})
        sources.append({'file':name+'.json','sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'stage':d['stage'],'exitCode':d['processExitCode']})
    tape={'tape':'updates','columns':160,'rows':40,'styles':styles,'defaults':{'fg':'#e8ebf1','bg':'#111620'},'frames':frames,'marks':marks,'binary':{'provenance':'native source receipt retained alongside DTOs; illustrative0.2.8 availability on0.2.7'}}
    (ROOT/'video/cache/short027/updates.json').write_text(json.dumps(tape,ensure_ascii=False)+'\n')
    (ROOT/'video/cache/short027/updates-conversion.json').write_text(json.dumps({'source':'unchanged native cellGrid/style runs; no text/cell edits','sources':sources,'cardRectangle':[113,2,46,6],'guideRectangle':[34,3,92,34]},indent=2)+'\n')
    print('Converted three native update screens without cell edits.')
if __name__=='__main__':main()
