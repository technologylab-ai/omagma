#!/usr/bin/env python3
"""Recapture only the promo picker in an owned synthetic PTY; no mail sends."""
import argparse,base64,hashlib,json,tempfile
from pathlib import Path
from capture import ROOT,BODY,reservation
from picker_fixture import create,record,attach_selected,SELECTED,NOTES
from tape import Recorder,save
from promo_fixture import fixture,seed,WORK,ACCOUNTS
from terminal_integration import Client,require
from build_info import read_build_info

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--binary",type=Path,required=True)
    p.add_argument("--expected-sha256",required=True)
    p.add_argument("--out",type=Path,default=ROOT/"video/cache/short026/picker-revision")
    a=p.parse_args();reservation()
    binary=a.binary.resolve();sha=hashlib.sha256(binary.read_bytes()).hexdigest()
    require(sha==a.expected_sha256,"picker binary changed")
    info=read_build_info(binary);out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="omagma-short026-picker-") as temporary:
        directory=Path(temporary);source=fixture(directory);seed(binary,directory,source)
        manifest=create(directory,ROOT);(directory/"home").mkdir(exist_ok=True)
        rec=Recorder(binary,directory,"picker",extra=source.options("--account",WORK),columns=160,rows=42)
        try:
            rec.wait(lambda:"Up to date" in rec.text(),name="ready")
            rec.press("c","compose:open")
            rec.wait(lambda:"Subject:" in rec.text() and "Body:" in rec.text())
            rec.press("imaya@example.test\t\t\tSmall eruptions, big ideas\t","compose:headers",show=False)
            rec.press(b"\x1b[200~"+BODY.encode()+b"\x1b[201~","compose:paste",show=False)
            rec.wait(lambda:"hello()" in rec.text() and "something" in rec.text(),name="body:ready")
            rec.press(b"\x1b","compose:normal",show=False);rec.gap(.2)
            audit=record(rec)
            attach_selected(rec)
            rec.press(b"\x13","review",show=False)
            rec.wait(lambda:"Review send" in rec.text() and "Sending account:" in rec.text())
            with Client(binary,directory,extra=source.options()) as client:
                drafts=client.request("draft.list",WORK)["drafts"];require(len(drafts)==1,"picker changed draft count")
                draft=client.request("draft.read",WORK,draftId=drafts[0]["id"])
                require(draft["bodyText"]==BODY and draft["bodyFormat"]=="markdown","picker altered the source")
                files=draft["attachments"];require(len(files)==1 and files[0]["filename"]==SELECTED,"selected file differs from subsequent attachment shot")
                require(base64.urlsafe_b64decode(files[0]["data"]+"===")==NOTES,"selected file bytes differ from previous47B attachment")
                require(client.request("cache.stats",WORK)["fixtureSends"]==0,"picker capture sent mail")
            cleanup=rec.finish(client_extra=source.options())
            save(out/"picker.json",rec.tape(info),known=(*ACCOUNTS,"maya@example.test"))
        finally:rec.close()
    receipt={"binarySha256":sha,"buildInfo":info,"files":manifest,"pickerAudit":audit,
             "actualAttachedFilename":SELECTED,"actualAttachedBytes":len(NOTES),"matchesExistingAttachmentShot":True,
             "synthetic":True,"fixtureSends":0,"liveProviderWrites":0,"cleanup":cleanup}
    (out/"capture-receipt.json").write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+"\n")
    print("Captured ten actual matching files with retained ERUPTION query and selected47B eruption-notes.md; no sends.")
if __name__=="__main__":main()
