#!/usr/bin/env python3
"""Focused account-scoped batch/undo, cached body, recovery and forward checks."""
import argparse
import tempfile
from pathlib import Path
from terminal_integration import Client, ACCOUNTS, require


def run(binary, directory):
    with Client(binary, directory) as client:
        page = client.request('mail.refresh', label='INBOX', limit=32, prefetchLimit=32)
        ids = [mail['id'] for mail in page['messages'][:2]]
        require(len(ids) == 2, 'fixture Inbox missing batch candidates')
        before = {id: client.request('mail.read', messageId=id)['labels'] for id in ids}
        batch = client.request('mail.batch', messageIds=ids + ['missing-message'], action='archive')
        require(batch['appliedCount'] == 2 and batch['partial'], 'partial batch outcomes lost')
        require(batch['outcomes'][-1]['outcome'] == 'rejected', 'missing message was treated as applied')
        client.request('mail.mark', messageId=ids[0], starred=True)
        undone = client.request('mail.undo', undoToken=batch['undoToken'])
        require(undone['restoredCount'] == 2, 'undo did not restore successful entries')
        for id in ids:
            labels = client.request('mail.read', messageId=id)['labels']
            expected = set(before[id]) | ({'STARRED'} if id == ids[0] else set())
            require(set(labels) == expected, 'undo missed actual previous membership')
        require('STARRED' in client.request('mail.read', messageId=ids[0])['labels'], 'undo removed unrelated concurrent label')
        denied = client.request('mail.undo', account=ACCOUNTS[1], undoToken=batch['undoToken'], ok=False)
        require(denied['code'] == 'UndoNotFound', 'undo token crossed accounts')
        repeated = client.request('mail.undo', undoToken=batch['undoToken'])
        require(repeated['restoredCount'] == 2, 'already applied undo was replayed')
        invalid = client.request('mail.batch', messageIds=ids * 51, action='archive', ok=False)
        require(invalid['code'] == 'InvalidBatchSize', 'batch selection exceeded its bound')
        query = client.request('mail.search', cacheOnly=True, query='body:café', limit=100)
        require(query['searchScope'] == 'metadata-and-cached-bodies', 'body search reported metadata-only scope')
        require(query['messages'] and query['searchMatches'], 'downloaded body search omitted results/highlights')
        require('bodyText' not in query['searchMatches'][0], 'body search returned unbounded body in highlights')
        stats = client.request('cache.stats')
        client.request('mail.search', cacheOnly=True, query='body:nonexistent-needle')
        require(client.request('cache.stats')['fixtureCalls'] == stats['fixtureCalls'], 'local search made provider calls')
        labels = client.request('labels.list')['labels']
        require(any(label['id'] == 'INBOX' for label in labels), 'labels list omitted system labels')
        client.request('mail.mark', messageId=ids[0], addLabels=['Projects'])
        project_rows = client.request('mail.list', label='Projects')['messages']
        require(ids[0] in [mail['id'] for mail in project_rows], 'fixture label name did not resolve to its provider ID')
        cached_project_rows = client.request('mail.search', cacheOnly=True, query='label:Projects')['messages']
        require(ids[0] in [mail['id'] for mail in cached_project_rows], 'cached predicate could not resolve label name')
        client.request('mail.batch', messageIds=[ids[0]], action='mark', removeLabels=['Projects'])
        require('Label_demo' not in client.request('mail.read', messageId=ids[0])['labels'], 'batch label name did not use canonical ID')
        identities = client.request('accounts.identities')['identities']
        require(any(identity['address'] == ACCOUNTS[0] for identity in identities), 'primary outgoing identity omitted')
        forwarded = client.request('mail.forward', messageId='shared-msg-003')
        require(forwarded['subject'].startswith('Fwd:') and forwarded['attachments'], 'forward lost subject or attachment')
        require(not forwarded['to'] and not forwarded['threadId'], 'forward silently addressed recipient or joined old thread')
        recovery = client.request('draft.recovery-save', draft={'recoveryFields': ['alex@', '', '', 'Unfinished', 'Some unfinished text'], 'attachments': []})
        loaded = client.request('draft.read', draftId=recovery['id'])
        require(loaded['recoveryFields'][0] == 'alex@', 'partial recipient was not recoverable')
        refused = client.request('draft.send', draftId=recovery['id'], operationId='never-send-recovery', ok=False)
        require(refused['code'] == 'UnfinishedDraft', 'raw recovery draft was allowed to send')
        require(client.request('cache.stats')['fixtureSends'] == 0, 'backend behavior check sent fixture mail')
    print('PASS batch outcomes/undo isolation, cached body search, labels/identities, forward and partial draft recovery')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='omagma-wishlist-backend-') as temporary:
        run(args.binary.resolve(), Path(temporary))


if __name__ == '__main__':
    main()
