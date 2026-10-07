#!/usr/bin/env python3
"""One mailbox q must cancel a real held fixture refresh and restore its PTY.

Synthetic only. Run inside the coordinator's cooperative host reservation.
The runtime uses its normal fixtureProgress gate, with no private accounts,
desktop window or custom application test hooks.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import time

from build_info import build_mode, read_build_info
from terminal_cache import ProviderFixture, cached, metrics
from terminal_integration import ACCOUNTS, ROOT, Client, require
from terminal_pty import Terminal
from terminal_reader import reader_contains


class ExitFailure(Exception):
    def __init__(self, message, diagnostics):
        super().__init__(message)
        self.diagnostics = diagnostics


def session_members(session_id):
    """Only expose members of the session created by this test's owned PTY."""
    require(sys.platform == "linux", "this focused cancellation gate requires Linux")
    members = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdecimal():
            continue
        try:
            fields = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
        except (OSError, IndexError):
            continue
        if int(fields[3]) == session_id:
            members.append(int(entry.name))
    return sorted(members)


def run_case(binary, directory):
    source = ProviderFixture(directory)
    # All 32 newest messages belong to Inbox, so the normal startup prefetch
    # has exactly 32 missing bodies and its last one is message 065.
    for account in ACCOUNTS:
        for message in source.data[account]['baseline']['messages']:
            message['labelIds'] = ['INBOX', 'UNREAD']
        source.stage(account, 'baseline')
    hold = source.root / 'exit-bodies31.hold'
    entered = source.root / 'exit-bodies31.entered'
    hold.write_text('Fictional prefetch held after body 31 of 32\n')
    path = source.path(ACCOUNTS[0])
    staged = json.loads(path.read_text())
    staged['sync']['fixtureProgress'] = {
        'phase': 'bodies', 'completed': 31,
        'fixtureHold': hold.name, 'fixtureEntered': entered.name,
    }
    path.write_text(json.dumps(staged) + '\n')
    terminal = Terminal(binary, directory, extra=source.options('--prefetch-bodies', '32'),
                        environment={'NO_COLOR': None, 'COLORTERM': 'truecolor', 'TZ': 'UTC0'})
    session_id = terminal.process.pid
    started = None
    result = None
    try:
        terminal.until(lambda: entered.is_file())
        terminal.until(lambda: 'bodies 31/32' in ''.join(terminal.screen.cells[1]))
        terminal.until(lambda: reader_contains(terminal.screen, 'Synthetic personal@example.com message 096.'))
        with Client(binary, directory, extra=source.options()) as client:
            require(cached(client, 'cache.refresh-status')['refreshInProgress'] is True,
                    'fixture hold did not retain the owned refresh lease')
            before = metrics(client)
            require(before['syncBodyGets'] == 31 and before['historyId'] == '' and before['fixtureSends'] == 0,
                    'hold did not occur before the final body/checkpoint')
        require(client.process.returncode == 0 and not client.stderr, 'pre-quit snapshot child failed cleanup')
        # The cold fixture reaches body 31 faster than the normal observer's
        # one-second period. Keep the provider held through a watcher tick so
        # quitting also joins an observer that has read the real changed index.
        terminal.gap(1.2)
        require(hold.is_file() and 'bodies 31/32' in ''.join(terminal.screen.cells[1]),
                'observer setup released or advanced the held prefetch')
        started = time.monotonic()
        terminal.send(b'q')
        deadline = started + 5
        while terminal.process.poll() is None and time.monotonic() < deadline:
            terminal.pump(min(.05, max(0, deadline - time.monotonic())))
        require(terminal.process.poll() is not None, 'single mailbox q did not exit within5s')
        exit_seconds = time.monotonic() - started
        # Reuse the established clean-exit, complete termios, zero-send and
        # shell-injection oracles; this sends no extra q/Esc/signal input.
        result = terminal.finish(already_exited=True)
        require(hold.is_file() and entered.is_file(), 'quit completed only after the provider hold was released')
        with Client(binary, directory, extra=source.options()) as client:
            require(cached(client, 'cache.refresh-status')['refreshInProgress'] is False,
                    'exited TUI retained a refresh lease')
            after = metrics(client)
            require(after['historyId'] == '' and after['syncBodyGets'] == 31,
                    'quit completed the held final body or advanced its checkpoint')
            error = cached(client, 'mail.read', messageId='shared-msg-065', ok=False)
            require(error['code'] == 'CacheMiss', 'held final body became cached during quit')
            require(after['fixtureSends'] == 0, 'quit sent fixture mail')
        require(client.process.returncode == 0 and not client.stderr, 'post-quit snapshot child failed cleanup')
        require(not session_members(session_id), 'quit left owned session children detached')
        result.update(singleMailboxQuitKeys=1, additionalQuitKeys=0, quitDeadlineSeconds=5,
                      exitSeconds=round(exit_seconds, 5), heldBodies='31/32',
                      providerHoldPreserved=True, refreshLeaseReleased=True,
                      historyCheckpointAdvanced=False, finalBodyCached=False,
                      detachedSessionChildren=0)
        return result
    except Exception as error:
        diagnostics = {'currentCells': terminal.screen.lines(), 'exitCode': terminal.process.poll(),
                       'providerHoldPresent': hold.is_file(), 'providerEntered': entered.is_file(),
                       'quitIssued': started is not None,
                       'elapsedSinceQuit': None if started is None else round(time.monotonic() - started, 5),
                       'ownedSessionMembers': session_members(session_id)}
        raise ExitFailure(str(error), diagnostics) from error
    finally:
        # Preserve the blocked provider until the owned terminal/session has
        # stopped; cleanup must never make a quit failure pass by releasing it.
        terminal.close()
        hold.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--build-mode', type=build_mode, default='debug')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    require(sys.platform == 'linux', 'this focused cancellation gate requires Linux')
    binary = args.binary.resolve()
    output = args.output or ROOT / 'tests/results' / f'terminal-exit-refresh-{args.build_mode}.json'
    require(not output.exists(), 'refusing to overwrite preserved refresh-exit evidence')
    report = {**read_build_info(binary, args.build_mode),
              'binarySha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
              'syntheticOnly': True, 'desktopUsed': False, 'realCredentialUse': False}
    with tempfile.TemporaryDirectory(prefix='omagma-exit-refresh-') as temporary:
        began = time.monotonic()
        case = {'name': 'single-q-during-held-body-prefetch'}
        try:
            case.update(run_case(binary, Path(temporary)), passed=True)
        except Exception as error:
            case.update(passed=False, error=f'{type(error).__name__}: {error}')
            if isinstance(error, ExitFailure):
                case['diagnostics'] = error.diagnostics
        case['elapsedSeconds'] = round(time.monotonic() - began, 5)
        report.update(cases=[case], passed=case['passed'])
        print(json.dumps(case), flush=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + '\n')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
