#!/usr/bin/env python3
"""Focused cache-relative reverse/forward windows; synthetic fixtures only."""
import argparse
import tempfile
from pathlib import Path
from terminal_integration import Client, ACCOUNTS, require


def run(binary, directory):
    extra = ('--metadata-limit', '40')
    with Client(binary, directory, extra=extra) as client:
        first = client.request('mail.list', label='INBOX', limit=32)
        older = client.request('mail.list', label='INBOX', limit=32, cursor=first['nextCursor'])
        boundary = next(mail for mail in older['messages'] if mail['id'] == 'shared-msg-056')
        before_calls = client.request('cache.stats')['fixtureCalls']
        previous = client.request('mail.list', cacheOnly=True, label='INBOX', limit=32,
                                  beforeMessageId=boundary['id'], boundaryReceivedAt=boundary['receivedAt'])
        require(previous['boundaryFallback'] and previous['cacheWindow'] == 'before', 'evicted boundary did not identify its retained fallback')
        require(previous['messages'][-1]['id'] == 'shared-msg-057', 'reverse window skipped immediate retained predecessor')
        require(len(previous['messages']) == 32 and previous['hasMoreCachedBefore'], 'reverse retained window has incorrect bounds')
        require(not previous['hasMoreCachedAfter'], 'cache tail incorrectly advertises more retained rows')
        exact = client.request('mail.list', cacheOnly=True, label='INBOX', limit=32, beforeMessageId='shared-msg-081')
        require(exact['messages'][-1]['id'] == 'shared-msg-082' and not exact['boundaryFallback'], 'exact predecessor window is not adjacent')
        after = client.request('mail.list', cacheOnly=True, label='INBOX', limit=32, afterMessageId='shared-msg-081')
        require(after['messages'][0]['id'] == 'shared-msg-080', 'successor window repeated/skipped anchor')
        searched = client.request('mail.search', cacheOnly=True, query='subject:Synthetic personal', limit=32,
                                  beforeMessageId=boundary['id'], boundaryReceivedAt=boundary['receivedAt'])
        require(searched['messages'][-1]['id'] == 'shared-msg-057' and searched['cursor'].startswith('K:'), 'local search did not reverse through its retained hit set')
        missing = client.request('mail.list', cacheOnly=True, label='INBOX', beforeMessageId=boundary['id'], ok=False)
        require(missing['code'] == 'CacheBoundaryGone', 'missing boundary silently substituted the head')
        foreign = client.request('mail.list', account=ACCOUNTS[1], cacheOnly=True, beforeMessageId='shared-msg-081',
                                 boundaryReceivedAt=boundary['receivedAt'])
        require(not foreign['messages'], 'boundary imported another account cache')
        require(client.request('cache.stats')['fixtureCalls'] == before_calls, 'cache window made provider requests')
    with Client(binary, directory, extra=extra) as restarted:
        calls = restarted.request('cache.stats')['fixtureCalls']
        restored = restarted.request('mail.list', cacheOnly=True, label='INBOX', beforeMessageId='shared-msg-081', limit=32)
        require(restored['messages'][-1]['id'] == 'shared-msg-082', 'restart required previous UI history to reverse')
        require(restarted.request('cache.stats')['fixtureCalls'] == calls, 'restart reverse fetched provider data')
    print('PASS cache-relative windows: evicted provider boundary, exact up/down, search, account isolation and restart; no provider fetch')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='omagma-cache-windows-') as temporary:
        run(args.binary.resolve(), Path(temporary))


if __name__ == '__main__': main()
