#!/usr/bin/env python3
"""Real native macOS TUI over SSH, with a disposable fictional environment."""
from __future__ import annotations
import argparse, hashlib, json, os, shlex, shutil, subprocess, sys, tarfile, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path[:0]=[str(ROOT/'video/short028'),str(ROOT/'video/capture'),str(ROOT/'tests')]
from capture_native import setup, reserve, KNOWN, SUBJECT, WORK
from capture_fixture import options, seed
from tape import Recorder, save
from terminal_integration import require

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--host',required=True)
    p.add_argument('--binary',type=Path,required=True)
    a=p.parse_args();reserve()
    out=ROOT/'video/cache/short028'
    ssh=['ssh','-o','BatchMode=yes','-o','ConnectTimeout=8',a.host]
    code="import json,hashlib,subprocess;from pathlib import Path;p=(Path.home()/'.local/bin/omagma').resolve();print(json.dumps({'path':str(p),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'info':json.loads(subprocess.check_output([str(p),'build-info']))}))"
    r=subprocess.run([*ssh,'/usr/bin/python3 -c '+shlex.quote(code)],capture_output=True,text=True,timeout=15,check=True)
    info=json.loads(r.stdout);private_binary=info.pop('path')
    with tempfile.TemporaryDirectory(prefix='omagma-film028-ssh-') as tmp:
        d=Path(tmp);source,config,prefs=setup(a.binary.resolve(),d)
        # Seed with the captured Mac binary: development cache schemas may differ.
        shutil.rmtree(d/'cache')
        (d/'tokens').mkdir(mode=0o700)
        cfg=json.loads(config.read_text());cfg.update(credentialStore='file',credentialDirectory='/private'+str(d/'tokens'));config.write_text(json.dumps(cfg));config.chmod(0o600)
        archive=d/'fixture.tar'
        with tarfile.open(archive,'w') as t:
            for f in list(d.iterdir()):
                if f!=archive:t.add(f,arcname=f.name)
        remote=str(d)
        provision='umask 077; mkdir '+shlex.quote(remote)+' && tar -xf - -C '+shlex.quote(remote)
        subprocess.run([*ssh,provision],input=archive.read_bytes(),capture_output=True,timeout=20,check=True)
        try:
            wrapper=d/'ssh-capture'
            wrapper.write_text('#!'+sys.executable+'\n'+
                'import os,shlex,sys\n'+
                'args=sys.argv[1:]\n'+
                'mode="-tt" if args[0]=="tui" else "-T"\n'+
                'keys=["HOME","TMPDIR","TERM","COLORTERM","TZ","XDG_CONFIG_HOME","XDG_CACHE_HOME","XDG_DATA_HOME","XDG_STATE_HOME","XDG_RUNTIME_DIR"]\n'+
                'env=[k+"="+os.environ[k] for k in keys if k in os.environ]\n'+
                'command=shlex.join(["env",*env,'+repr(private_binary)+',*args])\n'+
                'os.execvp("ssh",["ssh",mode,"-o","BatchMode=yes","-o","LogLevel=ERROR",'+repr(a.host)+',command])\n')
            wrapper.chmod(0o700)
            seed(wrapper,d,source,config)
            rec=Recorder(wrapper,d,'mac',extra=options(source,config,'--account',WORK,'--ui-file',str(prefs)),columns=160,rows=42)
            try:
                rec.wait(lambda:'Up to date' in rec.text() and SUBJECT in rec.text());rec.gap(.3);rec.mark('context')
                rec.press('l','focus',show=False);rec.gap(.3);rec.mark('ssh-result')
                receipt=rec.finish(client_extra=options(source,config))
                save(out/'mac.json',rec.tape({'platform':'macOS arm64','transport':'SSH','sha256':info['sha256'],**info['info']}),known=KNOWN)
            finally:rec.close()
            info.update(capture=receipt,syntheticOnly=True,productionProviderWrites=0,allOwnedChildrenReaped=True)
            (out/'mac-receipt.json').write_text(json.dumps(info,indent=2)+'\n')
        finally:
            subprocess.run([*ssh,'rm -rf -- '+shlex.quote(remote)],capture_output=True,timeout=15,check=True)
    print('Captured genuine macOS arm64 TUI over SSH; fictional mail, private disposable files')

if __name__=='__main__':main()
