#!/usr/bin/env python3
"""Independent wire oracle for the real Meet serializer and HTTP policy."""
import argparse
import http.server
import json
import subprocess
import threading
import urllib.parse


def main():
    p=argparse.ArgumentParser();p.add_argument('--probe',required=True);args=p.parse_args()
    received=[];status=[200]
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self,*_):pass
        def request(self):
            body=self.rfile.read(int(self.headers.get('Content-Length','0')))
            received.append((self.command,self.path,{k.lower():v for k,v in self.headers.items()},body))
            if status[0]==299:self.close_connection=True;return
            response=b'{"name":"spaces/FictionalSpace","meetingCode":"abc-defg-hij"}'
            self.send_response(status[0])
            if status[0]==302:self.send_header('Location','http://127.0.0.1:1/do-not-follow')
            self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(response)));self.end_headers();self.wfile.write(response)
        do_GET=do_PATCH=request
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    origin=f'http://127.0.0.1:{server.server_address[1]}'
    try:
        for mode,code in [('get',200),('on',200),('on',401),('on',403),('on',503),('on',302),('on',299)]:
            status[0]=code;before=len(received)
            run=subprocess.run([args.probe,origin,mode],capture_output=True,text=True,check=True,timeout=30)
            result=json.loads(run.stdout)
            assert result['zigVersion']=='0.17.0' and result['optimizeMode']=='safe',result
            assert len(received)==before+1,'Meet request was retried'
            method,path,headers,body=received[-1];url=urllib.parse.urlsplit(path)
            assert url.path=='/v2/spaces/FictionalSpace',path
            assert headers['authorization']=='Bearer synthetic-omagma-meet-bearer'
            assert 'if-match' not in headers
            if mode=='get':assert method=='GET' and not body and not url.query
            else:
                assert method=='PATCH'
                assert urllib.parse.parse_qs(url.query)=={'updateMask':['config.artifactConfig.smartNotesConfig.autoSmartNotesGeneration,config.artifactConfig.transcriptionConfig.autoTranscriptionGeneration']},path
                assert json.loads(body)=={'name':'spaces/FictionalSpace','config':{'artifactConfig':{'smartNotesConfig':{'autoSmartNotesGeneration':'ON'},'transcriptionConfig':{'autoTranscriptionGeneration':'ON'}}}},body
                assert headers['content-type']=='application/json'
            if code==302:assert result['errorCode']=='RedirectRejected',result
            elif code==299:assert result['status']==0 and result['errorCode'],result
            else:assert result['status']==code,result
        print(json.dumps({'ok':True,'checks':7,'wireRequests':len(received),'duplicateWrites':0,'recordingSettingsTouched':False}))
    finally:server.shutdown();server.server_close();thread.join(timeout=5)


if __name__=='__main__':main()
