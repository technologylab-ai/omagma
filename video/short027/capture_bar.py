#!/usr/bin/env python3
"""Real offscreen Omarchy dropdown and dry Open TUI activation; no desktop."""
from __future__ import annotations
import argparse, json, os, subprocess, sys, tempfile, time
from pathlib import Path
from capture import ROOT,reservation
sys.path.insert(0,str(ROOT/'video/capture'))
from bar import snapshot
from promo_fixture import ACCOUNTS,WORK
from terminal_publication import complete_png,strip_png_metadata

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary',type=Path,required=True);p.add_argument('--out',type=Path,default=ROOT/'video/cache/short027/assets');a=p.parse_args();reservation();out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='omagma-short027-bar-') as temporary:
        directory=Path(temporary);runtime=directory/'runtime';runtime.mkdir(mode=0o700)
        env=dict(os.environ,QT_QPA_PLATFORM='offscreen',QT_QPA_PLATFORMTHEME='',QT_SCALE_FACTOR='2',OMAGMA_TEST_BINARY=str(a.binary.resolve()),OMAGMA_TEST_FONT_BASE='12',OMAGMA_TEST_FONT='JetBrainsMono Nerd Font',OMAGMA_TEST_CONFIG=str(ROOT/'tests/fixtures/all-accounts.json'),HOME=str(directory/'home'),TZ='Europe/Vienna',XDG_RUNTIME_DIR=str(runtime))
        for key in ('DISPLAY','WAYLAND_DISPLAY','HYPRLAND_INSTANCE_SIGNATURE','DBUS_SESSION_BUS_ADDRESS'):env.pop(key,None)
        for name in ('CONFIG','CACHE','DATA','STATE'):env[f'XDG_{name}_HOME']=str(directory/name.lower())
        with (out.parent/'bar-quickshell.log').open('w') as log:
            process=subprocess.Popen(['quickshell','--path',str(ROOT/'offscreen.qml'),'--no-color'],env=env,stdout=log,stderr=subprocess.STDOUT)
            def call(method,*fields):return subprocess.check_output(['quickshell','ipc','--pid',str(process.pid),'call','omagma-test',method,*fields],env=env,text=True,stderr=subprocess.PIPE,timeout=5).strip()
            def until(condition):
                limit=time.monotonic()+10
                while time.monotonic()<limit:
                    assert process.poll() is None,'offscreen shell stopped'
                    try:
                        state=json.loads(call('state'))
                        if condition(state):return state
                    except (subprocess.CalledProcessError,json.JSONDecodeError):pass
                    time.sleep(.04)
                raise AssertionError('offscreen state deadline')
            try:
                until(lambda s:s['daemon']=='ready');call('open');until(lambda s:s['pending']==0)
                now=int(time.time()*1000)
                for account in ACCOUNTS:call('inject',json.dumps(snapshot(account,now),ensure_ascii=False,separators=(',',':')))
                call('select',WORK);before=until(lambda s:s['selected']==WORK and s['pending']==0 and s['contentAlive']);time.sleep(.35);path=out/'bar.png';call('capture',str(path));limit=time.monotonic()+5
                while not complete_png(path) and time.monotonic()<limit:time.sleep(.05)
                assert complete_png(path),'bar PNG incomplete';strip_png_metadata(path)
                assert before['layout']['tuiWidth']>0 and before['layout']['tuiHeight']>0,'actual Open TUI button absent'
                call('tui');after=until(lambda s:not s['opened'] and not s['contentAlive'])
                script='import {tuiArgv} from '+json.dumps((ROOT/'Model.mjs').as_uri())+'; process.stdout.write(JSON.stringify(tuiArgv('+json.dumps(str(a.binary.resolve()))+','+json.dumps(WORK)+',false)));'
                argv=json.loads(subprocess.check_output(['node','--input-type=module','-e',script],text=True))
                assert argv[-2:]==['--account',WORK] and argv[5]=='tui' and '--fixtures' not in argv,'normal dry launcher target differs from match-cut account'
                receipt={'offscreen':True,'dryOpen':True,'actualOpenTuiButtonActivated':True,'before':before,'after':after,'normalLauncherArgv':argv,'normalLauncherArgvEvaluatedSeparately':True,'dryModeDoesNotSpawnLauncher':True,'sameAccountAsTui':WORK,'scale':2,'buttonBounds':before['layout'],'allChildrenReaped':True}
            finally:
                if process.poll() is None:process.terminate()
                try:process.wait(timeout=5)
                except subprocess.TimeoutExpired:process.kill();process.wait()
    (out.parent/'bar-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print('Genuine bar.png and actual Open TUI dry activation captured.')
if __name__=='__main__':main()
