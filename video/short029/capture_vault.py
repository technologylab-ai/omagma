#!/usr/bin/env python3
"""Capture an actual synthetic encrypted service, unlock, TUI and CLI session.

Passwords and recovery material never enter the saved tapes. Shell command
frames replay the literal command and its real stdout, including jq colors.
"""
from __future__ import annotations
import argparse, hashlib, json, os, subprocess, sys, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT/'tests'), str(ROOT/'video/capture'), str(ROOT/'video/tools')]
from tape import Recorder, TapeScreen, save
from vault_daemon import prompt, displayed_recovery, PASSWORD
from terminal_integration import require, ACCOUNTS
from build_info import read_build_info
from capture_calendar import StoryFixture, reserve, WORK

def literal_tape(name, command, output, info, prompt_only=False):
    r = Recorder.__new__(Recorder)
    r.columns, r.rows = 108, 22
    r.styles, r.style_index = [], {}
    frames, marks = [], []
    def frame(text, mark=None, stamp=0):
        r.screen = TapeScreen(r.columns, r.rows)
        r.screen.feed(text.replace('\n', '\r\n').encode())
        frames.append({'t': stamp, 'rows': [r.row_runs(y) for y in range(r.rows)], 'cursor': None})
        if mark: marks.append({'name': mark, 'frame': len(frames)-1, 't': stamp})
    lead = '\x1b[38;2;242;164;111m$\x1b[0m '
    frame(lead, 'empty')
    for index in range(1, len(command)+1):
        frame(lead+command[:index], stamp=index*.018)
    frame(lead+command+'\n\n'+output, 'view', stamp=len(command)*.018+.2)
    return {'tape':name,'columns':r.columns,'rows':r.rows,
            'defaults':{'fg':'#e8ebf1','bg':'#111620'},'styles':r.styles,
            'frames':frames,'marks':marks,'binary':info,
            'source':{'command':command,'literalStdout':True,
                      'stdoutSha256':hashlib.sha256(output.encode()).hexdigest()}}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True)
    a=p.parse_args(); reserve()
    binary=a.binary.resolve(); out=a.out.resolve(); out.mkdir(parents=True,exist_ok=True)
    require(not list(out.iterdir()), 'preserve earlier vault captures')
    info=read_build_info(binary); info['sha256']=hashlib.sha256(binary.read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory(prefix='omagma-video029-vault-') as folder:
        d=Path(folder); fixture=StoryFixture(d)
        env=dict(os.environ,HOME=str(d/'home'),XDG_CONFIG_HOME=str(d/'config'),
                 XDG_CACHE_HOME=str(d/'cache'),XDG_DATA_HOME=str(d/'data'),
                 XDG_STATE_HOME=str(d/'state'),TMPDIR=str(d),TZ='UTC0',TERM='xterm-256color')
        for name in ['DISPLAY','WAYLAND_DISPLAY','HYPRLAND_INSTANCE_SIGNATURE','DBUS_SESSION_BUS_ADDRESS','XDG_RUNTIME_DIR']:
            env.pop(name,None)
        for name in ['HOME','XDG_CONFIG_HOME','XDG_CACHE_HOME','XDG_DATA_HOME','XDG_STATE_HOME']:
            Path(env[name]).mkdir(mode=0o700,exist_ok=True)
        bindir=d/'bin';bindir.mkdir();(bindir/'omagma').symlink_to(binary)
        env['PATH']=str(bindir)+os.pathsep+env['PATH']
        vault=d/'vault'; backend=d/'ipc'/'socket'
        private=prompt(binary,['vault','init','--fixtures','--vault-dir',str(vault)],env,
                       [(b'New vault password: ',PASSWORD),(b'Confirm password: ',PASSWORD),
                        (b'Confirm recovery key: ',displayed_recovery)])
        private=b''
        daemon=subprocess.Popen([str(binary),'vault','serve','--fixtures','--fixture-root',str(fixture.root),
                                 '--vault-dir',str(vault),'--socket',str(backend)],env=env,
                                stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        def control(verb):
            r=subprocess.run([str(binary),'vault',verb,'--socket',str(backend)],env=env,capture_output=True,timeout=20)
            require(r.returncode==0, 'vault control failed '+verb)
            v=json.loads(r.stdout);require(v['ok'],'vault refused '+verb);return v['data']
        def request(cmd,account=WORK,**kw):
            v=dict(id='video-vault',cmd=cmd,account=account,**kw)
            r=subprocess.run([str(binary),'cli','--backend',str(backend)],env=env,
                             input=json.dumps(v).encode()+b'\n',capture_output=True,timeout=45)
            result=json.loads(r.stdout);require(result['ok'],str(result.get('error')));return result['data']
        try:
            deadline=time.monotonic()+12
            while not backend.exists():
                require(daemon.poll() is None,'private service exited')
                require(time.monotonic()<deadline,'private service startup timeout');time.sleep(.03)
            state=control('status');require(not state['unlocked'],'service should begin locked')
            config=Path(env['XDG_CONFIG_HOME'])/'omagma';config.mkdir(mode=0o700)
            marker=config/'native-vault.json'
            marker.write_text(json.dumps(dict(schema=1,vaultDirectory=str(vault),vaultId=state['vaultId'],socketPath=str(backend))))
            marker.chmod(0o600)
            command="omagma vault status | jq -C '.data | {unlocked}'"
            status=subprocess.run(['/usr/bin/bash','-c',command],env=env,capture_output=True,check=True,timeout=20).stdout.decode()
            save(out/'locked.json',literal_tape('locked',command,status,info))
            command="omagma vault unlock | jq -C '.data | {unlocked}'"
            output=prompt(Path('/usr/bin/bash'),['-c',command],env,[(b'Vault password: ',PASSWORD)]).decode().replace('\r\n','\n')
            require('OMR1-' not in output and PASSWORD.decode() not in output,'secret in unlock capture')
            save(out/'unlock.json',literal_tape('unlock',command,output,info))
            save(out/'prompt.json',literal_tape('prompt',command,output.split('\n',1)[0],info))
            require(control('status')['unlocked'],'unlock failed')
            for account in ACCOUNTS:
                request('mail.refresh',account,label='INBOX',limit=32,prefetchLimit=8)
                request('labels.list',account)
            request('preferences.set','',preferences={'theme':'omagma','lastAccount':WORK,'readerLayout':'right'})
            message=request('mail.read',messageId='launch-details',cacheOnly=True)
            require('last two screenshots' in message['bodyText'],'fixture message not read through encrypted service')
            # The normal CLI discovers the activated service without extra flags.
            (d/'read.json').write_text(json.dumps({'cmd':'mail.read','account':WORK,'messageId':'launch-details','cacheOnly':True})+'\n')
            command="omagma cli < read.json | jq -C '.data | {subject, bodyText}'"
            r=subprocess.run(['/usr/bin/bash','-c',command],cwd=d,env=env,capture_output=True,check=True,timeout=25)
            output=r.stdout.decode();require('last two screenshots' in output,'CLI did not share the unlocked service')
            require('null' not in output,'missing CLI fields in capture')
            save(out/'agent.json',literal_tape('agent',command,output,info))
            rec=Recorder(binary,d/'tui','vault',extra=('--backend',str(backend)),columns=156,rows=42)
            try:
                rec.wait(lambda:'Launch rehearsal' in rec.text(),name='ready')
                rec.press('j',show=False);rec.wait(lambda:'two screenshots before we share' in rec.text(),name='mail')
                rec.gap(.5);rec.mark('ready-mail')
                tape=rec.tape(info)
                receipt=rec.finish(client_extra=('--backend',str(backend)))
                save(out/'tui.json',tape)
            finally:rec.close()
            require(control('status')['unlocked'],'native client unexpectedly locked service')
            sealed=list(vault.rglob('*'))
            files=[f for f in sealed if f.is_file()]
            needle=b'Could you check the last two screenshots'
            require(all(needle not in f.read_bytes() for f in files),'mail plaintext leaked into vault files')
            (out/'receipt.json').write_text(json.dumps({'passed':True,'binary':info,'passwordEchoed':False,
                'recoveryMaterialPersisted':False,'unlockedServiceSharedByNativeTuiAndCli':True,
                'capturedMailMarkerAbsentFromVaultFiles':True,'vaultFileCount':len(files),
                'externalWrites':0,'tui':receipt},indent=2)+'\n')
            print('Captured real encrypted vault unlock, native TUI and separate agent CLI; no external writes',flush=True)
        finally:
            if daemon.poll() is None:
                try:control('stop');daemon.wait(timeout=5)
                except Exception:daemon.terminate();daemon.wait(timeout=5)
            daemon.stdout.close();daemon.stderr.close()

if __name__=='__main__':main()
