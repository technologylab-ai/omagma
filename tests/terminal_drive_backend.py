#!/usr/bin/env python3
"""Synthetic Drive delivery, replay and daemon disconnect acceptance."""
import argparse, json, os, struct, tempfile, time
from pathlib import Path
from terminal_integration import Client, require, ACCOUNTS
from vault_foreground_priority import Service


def source(client, directory, label, *, bcc=False):
    path = directory / 'synthetic.bin'
    path.write_bytes(b'Synthetic Drive content')
    file = client.request('attachment.import', path=str(path), delivery='drive')
    return client.request('draft.create', draft=dict(to=['peer@example.test'], cc=['copy@example.test'],
                          bcc=['hidden@example.test'] if bcc else [], subject=label,
                          bodyText='A synthetic attachment.', attachments=[file]))


def selection_contract(binary, directory):
    with Client(binary,directory) as client:
        path=directory/'oversize.bin'
        with path.open('wb') as output:output.truncate(30*1024*1024)
        source=dict(to=[dict(address='peer@example.test',name='')],cc=[],bcc=[],bodyText='Synthetic.',
                    bodyFormat='markdown',attachments=[],recoveryFields=None,from_=None,original=None)
        source['from']=source.pop('from_')
        before=client.request('cache.stats')
        for mode in ('attach','auto'):
            plan=client.request('draft.selection-plan',draft=source,paths=[str(path)],delivery=mode)
            require(plan['selectionOverLimit'] and plan['selectedDriveCount']==(1 if mode=='auto' else 0),
                    'typed-null draft selection contract changed')
        after=client.request('cache.stats')
        require(after['blobCount']==before['blobCount']==0 and after['fixtureCalls']==before['fixtureCalls']==0,
                'selection plan imported or contacted provider')
    print('PASS Drive selection contract: typed null fields, aggregate split and no imports/network')


def lifecycle(binary, directory):
    for scenario in ('drive-enabled', 'drive-upload-interrupted', 'drive-share-interrupted',
                     'drive-unknown-send', 'drive-rejected-send'):
        root = directory / scenario
        with Client(binary, root, scenario=scenario) as client:
            draft = source(client, root, scenario)
            plan = client.request('draft.measure', draftId=draft['id'], operationId='drive-fixture-operation')['attachmentPlan']
            require(plan['driveFileCount'] == 1 and not plan['blockers'], 'connected Drive plan blocked')
            before = client.request('cache.stats')
            op = 'drive-fixture-operation'
            receipt = client.request('draft.send', draftId=draft['id'], operationId=op)
            if scenario.endswith('interrupted'):
                require(receipt['outcome'] == 'preparationStopped' and receipt['canRetryPreparation'], 'preparation failure lost retry receipt')
                require(client.request('cache.stats')['fixtureSends'] == before['fixtureSends'], 'interrupted preparation sent')
                require(client.request('operation.read', operationId=op)['outcome'] == 'preparationStopped', 'durable stopped read failed')
                client.restart()
                receipt = client.request('draft.send', draftId=draft['id'], operationId=op)
            expected = {'drive-unknown-send':'unknown', 'drive-rejected-send':'rejected'}.get(scenario,'applied')
            require(receipt['outcome'] == expected and len(receipt['driveFiles']) == 1, 'Drive send lost Gmail outcome/receipts')
            require(receipt['driveFiles'][0]['sharedWith'] == ['copy@example.test','peer@example.test'], 'grant receipts lost sorted To/Cc')
            after = client.request('cache.stats')
            require(after['fixtureSends'] == (1 if expected == 'applied' else 0), 'fixture Gmail dispatch count changed')
            again = client.request('draft.send', draftId=draft['id'], operationId=op)
            require(again == receipt, 'same operation replay changed receipt')
            require(client.request('cache.stats')['fixtureCalls'] == after['fixtureCalls'], 'replay redispatched')
            if expected == 'applied':
                sent = client.request('mail.read', messageId=receipt['messageId'], cacheOnly=True)
                require(not sent['attachments'] and 'https://drive.google.com/file/d/' in sent['bodyText'], 'Drive file remained attached/missing link')
                second = source(client, root, 'Next send compacts preparation ledger')
                client.request('draft.send', draftId=second['id'], operationId='second-drive-operation')
                settled_count = client.request('cache.stats')['fixtureCalls']
                require(client.request('operation.read', operationId=op) == receipt, 'ledger compaction changed archived Drive receipt')
                require(client.request('draft.send', draftId=draft['id'], operationId=op) == receipt, 'archived replay lost frozen Drive receipts')
                require(client.request('cache.stats')['fixtureCalls'] == settled_count, 'archived replay dispatched again')
            if expected == 'rejected':
                edited = dict(draft, to=['different@example.test'])
                client.request('draft.update', draftId=draft['id'], draft=edited)
                changed = client.request('draft.send', draftId=draft['id'], operationId='changed-recipients-operation')
                require(changed['driveFiles'][0]['driveFileId'] != receipt['driveFiles'][0]['driveFileId'], 'recipient edit reused previously shared file')
                require(client.request('operation.read', operationId=op) == receipt, 'recipient edit changed original grant receipt')
            if expected == 'unknown':
                require(client.request('draft.discard',draftId=draft['id'],ok=False)['code']=='UnknownOutcome',
                        'unknown Gmail source was discarded')
                require(client.request('operation.read',operationId=op)==receipt, 'discard attempt changed unknown receipt')
            require('upload_id' not in json.dumps(receipt) and 'accessToken' not in json.dumps(receipt), 'private transport data escaped')
    print('PASS Drive backend: stopped preparation/restart/retry, exact receipts, replay and Gmail unknown fence')


def queue_restart(binary, directory):
    with Client(binary,directory,scenario='drive-upload-interrupted') as client:
        draft=source(client,directory,'restart stopped queue')
        queue=client.request('draft.queue',draftId=draft['id'],operationId='restart-stopped-queue')
        stopped=client.request('queue.send-now',queueId=queue['queueId'])
        require(stopped['state']=='queued' and stopped['preparation']['outcome']=='preparationStopped', 'queue lost stopped preparation')
        client.restart()
        before=client.request('cache.stats')
        listed=client.request('queue.list')['queue']
        require(len(listed)==1 and listed[0]['queueId']==queue['queueId']
                and listed[0]['preparation']['outcome']=='preparationStopped'
                and listed[0]['preparation']['driveFiles']==stopped['preparation']['driveFiles'],
                'queue.list omitted preparation receipts needed to restore the TUI')
        after=client.request('cache.stats')
        require(before['generation']==after['generation'] and before['fixtureCalls']==after['fixtureCalls'], 'queue listing mutated source/provider state')
        receipt=client.request('queue.send-now',queueId=queue['queueId'])
        require(receipt['state']=='applied' and client.request('cache.stats')['fixtureSends']==1, 'explicit queue retry did not use the same operation')
    print('PASS Drive queue restart: real list restores receipts and explicit retry sends once')


def retirement(binary, directory):
    """Cross the former128-entry/source lifetime cap through all abandonment
    routes. Receipts stay permanent; replay must not reserve another identity."""
    with Client(binary, directory, scenario='drive-share-interrupted') as client:
        path=directory/'retained.bin';path.write_bytes(b'Synthetic retirement content')
        file=client.request('attachment.import',path=str(path),delivery='drive')
        retired=[]
        for number in range(132):
            original=client.request('draft.create',draft=dict(to=['peer@example.test','copy@example.test'],
                bodyText=f'Retirement {number}',attachments=[file]))
            op=f'retired-{number}'
            if number%3==1:
                queue=client.request('draft.queue',draftId=original['id'],operationId=op)
                stopped=client.request('queue.send-now',queueId=queue['queueId'])['preparation']
                client.request('queue.cancel',queueId=queue['queueId'])
            else:
                stopped=client.request('draft.send',draftId=original['id'],operationId=op)
                if number%3==2:
                    client.request('draft.update',draftId=original['id'],draft=dict(original,bodyText='Superseded source'))
            require(stopped['outcome']=='preparationStopped' and stopped['driveFiles'], 'retirement source did not prepare')
            client.request('draft.discard',draftId=original['id'])
            receipt=client.request('operation.read',operationId=op)
            require(receipt['kind']=='drivePreparationRetired' and receipt['outcome']=='rejected'
                    and receipt['errorCode']=='DrivePreparationRetired' and not receipt['messageId']
                    and not receipt['rfcMessageId'] and receipt['driveFiles']==stopped['driveFiles'],
                    'retirement lost its identity, files or uncertain sharing')
            retired.append((op,original,receipt))
        client.restart()
        index=next((directory/'cache').glob('**/index.json'))
        before=json.loads(index.read_text())
        require(len(before.get('driveSources',[]))==0, 'retired source mappings exhausted active capacity')
        ledger=index.with_name('drive-uploads.json')
        require(not json.loads(ledger.read_text())['entries'] and ledger.stat().st_size<=1024*1024,
                'retired resumable ledger entries were not collected')
        for op,original,receipt in retired:
            require(client.request('operation.read',operationId=op)==receipt, 'archival changed a retirement receipt')
            require(client.request('mail.send',operationId=op,draft=original)==receipt,
                    'retired operation recreated a preparation')
        op,original,_=retired[0]
        require(client.request('mail.send',operationId=op,draft=dict(original,bodyText='Changed retired source'),ok=False)['code']=='OperationConflict',
                'changed content reused retired operation identity')
        after=json.loads(index.read_text())
        require(after['serial']==before['serial'] and client.request('cache.stats')['fixtureSends']==0
                and not json.loads(ledger.read_text())['entries'], 'retirement replay reserved, uploaded or sent again')
        fresh=client.request('draft.create',draft=dict(to=['peer@example.test'],bodyText='Fresh after132 abandonments',attachments=[file]))
        require(client.request('draft.send',draftId=fresh['id'],operationId='fresh-after-retirements')['outcome']=='preparationStopped',
                'cumulative retirement left Drive preparation locked out')
    print('PASS Drive retirement:132 edit/discard/cancel cycles, permanent frozen receipts and zero replay effects')


def protected_retirement(binary, directory):
    for same_draft in (False,True):
        root=directory/('same-draft' if same_draft else 'independent-drafts')
        with Client(binary,root,scenario='drive-upload-interrupted') as client:
            first=source(client,root,'Cancellation recovery')
            qa=client.request('draft.queue',draftId=first['id'],operationId='protected-first')
            stopped=client.request('queue.send-now',queueId=qa['queueId'])['preparation']
            # Seed the durable crash boundary: cancel saved, retirement not yet
            # published. No process owns a request/lease while this fixture is changed.
            index=next((root/'cache').glob('**/index.json'))
            state=json.loads(index.read_text())
            for entry in state['sendQueue']:
                if entry['queueId']==qa['queueId']:entry.update(state='canceled',preparationId=None)
            index.write_text(json.dumps(state))
            second=first if same_draft else client.request('draft.create',draft=first)
            qb=client.request('draft.queue',draftId=second['id'],operationId='protected-second')
            b_stopped=None
            if not same_draft:
                b_stopped=client.request('queue.send-now',queueId=qb['queueId'])['preparation']
                require(b_stopped['driveFiles'][0]['driveFileId']!=stopped['driveFiles'][0]['driveFileId'],
                        'independent queue stole the canceled preparation identity')
            if same_draft:
                require(client.request('queue.cancel',queueId=qa['queueId'],ok=False)['code']=='DraftQueued',
                        'cancel reported success while its preparation remained unfenced')
                require(client.request('operation.read',operationId='protected-first')['outcome']=='preparationStopped',
                        'same-source active queue lost protected preparation')
                client.request('queue.cancel',queueId=qb['queueId'])
            require(client.request('queue.cancel',queueId=qa['queueId'])['state']=='canceled',
                    'idempotent cancel failed to finish retirement')
            receipt=client.request('operation.read',operationId='protected-first')
            require(receipt['kind']=='drivePreparationRetired' and receipt['driveFiles']==stopped['driveFiles'],
                    'cancel recovery lost permanent file/access receipts')
            if not same_draft:
                listed=client.request('queue.read',queueId=qb['queueId'])
                require(listed['state']=='queued' and listed['preparation']['driveFiles']==b_stopped['driveFiles'],
                        'retirement changed another queue or its IDs')
                require(client.request('queue.send-now',queueId=qb['queueId'])['state']=='applied',
                        'independent queue could not resume after retirement')
            before=client.request('cache.stats')['fixtureCalls']
            require(client.request('mail.send',operationId='protected-first',draft=first)==receipt,
                    'canceled operation recreated its preparation after another queue settled')
            require(client.request('cache.stats')['fixtureCalls']==before,'cancellation recovery replay dispatched')
    print('PASS Drive cancellation recovery: permanent fence, own-source protection and independent queue IDs')


def same_draft_operation(binary, directory):
    with Client(binary,directory,scenario='drive-upload-interrupted') as client:
        draft=source(client,directory,'Stable preparation operation')
        stopped=client.request('draft.send',draftId=draft['id'],operationId='original-preparation')
        before=client.request('cache.stats')['fixtureCalls']
        # Preparation reserves the operation across mutation namespaces.
        require(client.request('mail.send',operationId='original-preparation',draft=dict(to=['peer@example.test'],bodyText='Different plain message'),ok=False)['code']=='OperationConflict',
                'ordinary send took over an unfinished Drive operation')
        require(client.request('labels.create',operationId='original-preparation',name='Synthetic collision',ok=False)['code']=='OperationConflict',
                'label mutation took over an unfinished Drive operation')
        other=client.request('draft.create',draft=dict(to=['peer@example.test'],bodyText='Different queued message'))
        require(client.request('draft.queue',draftId=other['id'],operationId='original-preparation',ok=False)['code']=='OperationConflict',
                'another queue took over an unfinished Drive operation')
        blocked=client.request('draft.send',draftId=draft['id'],operationId='fresh-operation-same-draft')
        require(blocked['outcome']=='preparationStopped' and blocked['errorCode']=='DrivePreparationActive'
                and not blocked['canRetryPreparation'] and not blocked['driveFiles'],
                'fresh operation orphaned another preparation on the same unchanged draft')
        require(client.request('operation.read',operationId='original-preparation')['driveFiles']==stopped['driveFiles']
                and client.request('cache.stats')['fixtureCalls']==before,'refused operation changed the original preparation')
        client.restart()
        retried=client.request('draft.send',draftId=draft['id'],operationId='original-preparation')
        require(retried['outcome']=='applied' and retried['driveFiles'][0]['driveFileId']==stopped['driveFiles'][0]['driveFileId'],
                'original preparation could not resume with its stable operation identity')
    print('PASS Drive same-draft guard: fresh operation refused before effects; original operation resumes')


def separate_preparations(binary, directory):
    with Client(binary,directory,scenario='drive-upload-interrupted') as client:
        first=source(client,directory,'Independent preparations')
        stopped=client.request('draft.send',draftId=first['id'],operationId='independent-first')
        second=client.request('draft.create',draft=first)
        other=client.request('draft.send',draftId=second['id'],operationId='independent-second')
        if other['outcome']=='preparationStopped':other=client.request('draft.send',draftId=second['id'],operationId='independent-second')
        original_id=stopped['driveFiles'][0]['driveFileId']
        require(other['outcome']=='applied' and other['driveFiles'][0]['driveFileId']!=original_id,
                'different operation took over a live preparation identity')
        require(client.request('operation.read',operationId='independent-first')['driveFiles']==stopped['driveFiles'],
                'settling another operation removed active receipt identities')
        retried=client.request('draft.send',draftId=first['id'],operationId='independent-first')
        require(retried['outcome']=='applied' and retried['driveFiles'][0]['driveFileId']==original_id,
                'explicit first-operation retry reserved a duplicate file')
    print('PASS Drive operation ownership: parallel preparations retain separate IDs and same-operation retry reuses its original')


def bounded_queue_list(binary, directory):
    with Client(binary,directory,scenario='drive-share-interrupted') as client:
        path=directory/'one.bin';path.write_bytes(b'X')
        file=client.request('attachment.import',path=str(path),delivery='drive')
        expected=[]
        for group in range(32):
            recipients=[f'recipient-{group:02}-{number:03}-'+'x'*22+'@example.test' for number in range(500)]
            selected=dict(file,filename=f'queued-{group:02}.bin')
            draft=client.request('draft.create',draft=dict(to=recipients,subject=f'Bounded paused {group}',attachments=[selected]))
            queue=client.request('draft.queue',draftId=draft['id'],operationId=f'bounded-{group}')
            stopped=client.request('queue.send-now',queueId=queue['queueId'])
            require(stopped['state']=='queued' and stopped['preparation']['driveFiles'], 'wide fixture did not pause')
            expected.append(queue['queueId'])
        client.restart()
        listed=client.request('queue.list')['queue']
        require([q['queueId'] for q in listed]==expected and all(q.get('preparation',{}).get('driveFiles') for q in listed),
                'large shared ledger silently lost paused receipts')
        stats=client.request('cache.stats')
        require(stats['rejectedAllocations']==0 and stats['fixtureSends']==0, 'queue.list exhausted its ordinary allocator or sent mail')
    print('PASS Drive bounded queue list: 32 paused sends, 500 viewers each, one shared ledger and no rejected allocations')


def frame(peer):
    def exact(size):
        out = b''
        while len(out) < size:
            part = peer.recv(size-len(out))
            require(part, 'Drive daemon lost progress response')
            out += part
        return out
    header = exact(16)
    require(header[:8] == b'OMAVIPC1' and header[8] in (128,129), 'invalid Drive daemon frame')
    length = struct.unpack('<I',header[12:])[0]
    require(length <= (1024 if header[8] == 129 else 32*1024*1024), 'progress frame exceeds cap')
    return header[8],json.loads(exact(length))


def daemon_without_progress(binary, directory):
    directory.mkdir()
    service=Service(binary,directory,dict(os.environ),scenario='drive-enabled')
    try:
        draft=source(service,directory,'No progress transport')
        # No _progress flag: the budget still advances, and beforeMail must
        # never wait for a writer or send an unrequested progress frame.
        result=service.request('draft.send',draftId=draft['id'],operationId='no-progress-drive')
        require(result['outcome']=='applied' and len(result['driveFiles'])==1,
                'Drive budget without progress stalled or lost its receipt')
        require(service.request('cache.stats')['fixtureSends']==1,'no-progress send dispatch count changed')
    finally:service.close()
    print('PASS Drive vault without progress: independent phase budget and one final response')


def daemon_stop(binary, directory, scenario, *, queued=False):
    directory.mkdir()
    service = Service(binary,directory,dict(os.environ),scenario=scenario)
    try:
        draft = source(service,directory,'owned Drive stop')
        op = 'owned-drive-stop'
        params = dict(operationId=op,draftId=draft['id'],_progress=True,_cancelOnDisconnect=True)
        command = 'draft.send'
        if queued:
            queue = service.request('draft.queue',draftId=draft['id'],operationId=op)
            params = dict(queueId=queue['queueId'],_progress=True,_cancelOnDisconnect=True)
            command = 'queue.send-now'
        peer = service.submit(command,**params)
        try:
            deadline = time.monotonic()+20
            while True:
                require(time.monotonic()<deadline,'Drive progress never reached cancellation boundary')
                kind,data = frame(peer)
                require(kind==129,'send completed before held cancellation boundary')
                if scenario=='drive-progress' and data['phase']=='drive_uploading' and data['completed']>0:break
                if scenario=='drive-submit-progress' and data['phase']=='mail_submitting' and data['completed']==1:break
                if scenario=='drive-share-progress' and data['phase']=='drive_sharing' and data['completed']==data['total']:break
        finally:peer.close()
        # New owner read must wait for the old operation's cancellation AND JOIN.
        receipt = service.request('operation.read',operationId=op)
        expected = 'unknown' if scenario=='drive-submit-progress' else 'preparationStopped'
        require(receipt['outcome']==expected,'disconnect crossed Gmail retry fence')
        require(service.request('cache.stats')['fixtureSends']==0,'disconnected preparation dispatched Gmail')
        if queued:
            q = service.request('queue.read',queueId=queue['queueId'])
            require(q['state']=='queued' and q['resumeRequired'], 'queue cancellation lost paused preparation')
            service.request('queue.cancel',queueId=queue['queueId'])
        time.sleep(.2)
        require(service.request('cache.stats')['fixtureSends']==0,'joined worker made a late Gmail dispatch')
        # A fresh local mutation verifies the owner/lane/workspace was released.
        require(service.request('draft.create',draft=dict(to=['peer@example.test'],subject='after Stop'))['id'], 'lane unusable after Stop')
    finally:service.close()
    print('PASS Drive vault disconnect:',scenario,'queued' if queued else 'direct')


def auth_gap(binary, directory, action):
    from terminal_cache import ProviderFixture
    directory.mkdir()
    fixture = ProviderFixture(directory)
    hold = fixture.root / 'drive-auth.hold';entered = fixture.root / 'drive-auth.entered'
    hold.write_text('Synthetic authentication boundary')
    value=json.loads(fixture.path(ACCOUNTS[0]).read_text())
    value['sync']['fixtureProgress']=dict(phase='drive_reserving',completed=0,fixtureHold=hold.name,fixtureEntered=entered.name)
    fixture.path(ACCOUNTS[0]).write_text(json.dumps(value))
    with Client(binary,directory,scenario='drive-auth-gap',extra=fixture.options()) as sender:
        draft=source(sender,directory,'superseded preparation')
        queue=sender.request('draft.queue',draftId=draft['id'],operationId='superseded-preparation')
        request=dict(id='held-send',cmd='queue.send-now',account=ACCOUNTS[0],queueId=queue['queueId'])
        sender.raw(json.dumps(request).encode()+b'\n')
        try:
            deadline=time.monotonic()+5
            while not entered.exists():
                require(time.monotonic()<deadline,'auth-gap fixture did not release the source');time.sleep(.01)
            with Client(binary,directory,scenario='drive-enabled') as other:
                changed=other.request('queue.'+action,queueId=queue['queueId'])
                require(changed['state']==('canceled' if action=='cancel' else 'queued'),'new preparation intent was not staged')
        finally:hold.unlink(missing_ok=True)
        response=sender.receive()
        require(response['ok'] and response['data']['state']==('canceled' if action=='cancel' else 'queued'),'old worker overwrote the superseding queue intent')
        require(sender.request('cache.stats')['fixtureCalls']==0,'revoked preparation made a provider call')
        sender.request('queue.cancel',queueId=queue['queueId'])
    print('PASS Drive auth gap:',action,'revokes stale sender before provider effects')


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--binary',type=Path,required=True)
    args=parser.parse_args();binary=args.binary.resolve()
    with tempfile.TemporaryDirectory(prefix='omagma-drive-backend-') as tmp:
        root=Path(tmp);selection_contract(binary,root/'selection');lifecycle(binary,root);queue_restart(binary,root/'queue-restart');bounded_queue_list(binary,root/'bounded-list')
        retirement(binary,root/'retirement')
        protected_retirement(binary,root/'protected-retirement')
        separate_preparations(binary,root/'separate-preparations')
        same_draft_operation(binary,root/'same-draft-operation')
        daemon_without_progress(binary,root/'vault-no-progress')
        daemon_stop(binary,root/'vault-before','drive-progress')
        daemon_stop(binary,root/'vault-queue','drive-progress',queued=True)
        daemon_stop(binary,root/'vault-after','drive-submit-progress')
        daemon_stop(binary,root/'vault-shared','drive-share-progress')
        for action in ('cancel','resume'):auth_gap(binary,root/('auth-gap-'+action),action)
if __name__=='__main__':main()
