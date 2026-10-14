"""Owned-process steady-state RSS/PSS evidence for daemon, TUI and agent relay."""
import json
from pathlib import Path
import select
import subprocess
import time

from terminal_integration import require
from terminal_mouse import MouseTerminal
from terminal_mouse_screen import MouseScreen


def memory(pid):
    status = Path(f'/proc/{pid}/status').read_text()
    rss = next(int(line.split()[1]) for line in status.splitlines() if line.startswith('VmRSS:'))
    try:
        rollup = Path(f'/proc/{pid}/smaps_rollup').read_text()
        pss = next(int(line.split()[1]) for line in rollup.splitlines() if line.startswith('Pss:'))
    except PermissionError:
        pss = None  # PR_SET_DUMPABLE=0 intentionally denies this observation.
    return dict(rssKiB=rss, pssKiB=pss)


def run(binary, directory, backend, env, daemon_pid):
    terminal = MouseTerminal(binary, directory / 'resources-tui',
                             extra=('--backend', str(backend), '--prefetch-bodies', '0'),
                             environment=env, screen_type=MouseScreen, columns=120, rows=32)
    agent = None
    try:
        terminal.until(lambda: 'Up to date' in terminal.text(), seconds=20)
        terminal.gap(.5)
        agent = subprocess.Popen([str(binary), 'cli', '--backend', str(backend)], env=env,
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        agent.stdin.write(json.dumps(dict(id='resource-agent', cmd='accounts.list')).encode() + b'\n')
        agent.stdin.flush()
        require(select.select([agent.stdout], [], [], 15)[0], 'resource agent did not finish admission')
        require(json.loads(agent.stdout.readline())['ok'], 'resource agent request failed')
        for sample in range(3):
            terminal.gap(.2)
            values = dict(daemon=memory(daemon_pid), tui=memory(terminal.process.pid), agent=memory(agent.pid))
            total_rss = sum(value['rssKiB'] for value in values.values())
            total_pss = (sum(value['pssKiB'] for value in values.values())
                         if all(value['pssKiB'] is not None for value in values.values()) else None)
            print(json.dumps(dict(resourceSample=sample, processes=values, totalRssKiB=total_rss,
                                  totalPssKiB=total_pss, limitKiB=256 * 1024,
                                  phase='steady-after-large-operations')), flush=True)
            require(total_rss < 256 * 1024, 'combined daemon/TUI/agent RSS exceeded256MiB')
    finally:
        terminal.close()
        if agent is not None:
            if agent.stdin is not None:
                agent.stdin.close()
            try:
                agent.wait(timeout=5)
            except subprocess.TimeoutExpired:
                agent.kill()
                agent.wait()
            agent.stdout.close()
            agent.stderr.close()
    print('PASS native steady-state daemon+TUI+agent combined RSS below256MiB; PSS reported only where permitted', flush=True)
