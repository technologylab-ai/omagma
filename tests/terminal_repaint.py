#!/usr/bin/env python3
"""Owned PTY physical repaint/reflow/account-label gates; host window required."""
import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import selectors
import shlex
import struct
import subprocess
import sys
import tempfile
import termios
import time

from build_info import build_mode, read_build_info
from terminal_cache import ProviderFixture, seed, metrics
from terminal_html import screen_capture
from terminal_integration import ACCOUNTS, ROOT, Client, require
from terminal_pty import Terminal, child_session, FIXTURES, cursor_after_source, source_location
from terminal_reader import reader_contains, reader_rectangle
from terminal_repaint_screen import PreservedScreen

CASES = ("physical-resize-clears-ghosts", "end-reflow-tail", "long-account-held-cache")
LONG_ACCOUNT = "personal@example.test"
MARKER = "Fictional plain repaint marker."
TAIL = "Fictional plain repaint tail."
BARS = {"│", "|", "▏"}


class RepaintTerminal(Terminal):
    def resize(self, columns, rows):
        require(20 <= columns <= 300 and 10 <= rows <= 100, "owned physical PTY size out of bounds")
        self.columns, self.rows = columns, rows
        self.screen.resized(columns, rows)
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, rows*20, columns*10))


class BuiltinTerminal(RepaintTerminal):
    """Same owned terminal transport, with literal argv omitting fixture-root."""
    def __init__(self, binary, directory, config, columns=160, rows=40,
                 account=LONG_ACCOUNT, screen_type=PreservedScreen):
        self.binary, self.directory = binary, Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.master, self.slave = os.openpty()
        self.columns, self.rows = columns, rows
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, rows*20, columns*10))
        self.settings = termios.tcgetattr(self.slave)
        self.output, self.output_total, self.history_limit = bytearray(), 0, None
        self.screen = screen_type(columns, rows)
        self.scan_offset = self.query_replies = 0
        self.editor_log = self.directory / "editor.json"
        self.injection_sentinel = self.directory / "must-not-exist"
        editor = [sys.executable, str(FIXTURES / "editor_fixture.py"), "--label", "literal owned fixture"]
        env = dict(os.environ, TERM="xterm-256color", LANG="C.UTF-8", LC_ALL="C.UTF-8",
                   TMPDIR=str(self.directory), EDITOR=shlex.join(editor),
                   OMAGMA_EDITOR_TEST_LOG=str(self.editor_log), COLORTERM="truecolor")
        for key in ("CONFIG", "CACHE", "DATA", "STATE"): env[f"XDG_{key}_HOME"] = str(self.directory / key.lower())
        runtime = self.directory / "runtime";runtime.mkdir(mode=0o700, exist_ok=True)
        env["XDG_RUNTIME_DIR"] = str(runtime)
        for key in ("DISPLAY", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS", "NO_COLOR"):
            env.pop(key, None)
        argv = [str(binary), "tui", "--fixtures", "--config", str(config), "--account", account,
                "--cache-dir", str(self.directory / "cache")]
        self.process = subprocess.Popen(argv,stdin=self.slave,stdout=self.slave,stderr=self.slave,
                                        cwd=self.directory,env=env,preexec_fn=child_session)
        os.set_blocking(self.master, False)
        self.selector = selectors.DefaultSelector();self.selector.register(self.master,selectors.EVENT_READ)


def panel_interiors(screen):
    result = []
    for y, row in enumerate(screen.cells):
        lefts = [x for x, char in enumerate(row) if char in {"╭", "┌", "╔"}]
        for left in lefts:
            right = next((x for x in range(left+1, screen.columns) if row[x] in {"╮", "┐", "╗"}), None)
            if right is None: continue
            bottom = next((yy for yy in range(y+1, screen.rows)
                           if screen.cells[yy][left] in {"╰", "└", "╚"} and screen.cells[yy][right] in {"╯", "┘", "╝"}), None)
            if bottom is not None: result.append((left+1, right, y+1, bottom))
    return result


def no_ghosts(terminal):
    panels = panel_interiors(terminal.screen)
    require(bool(panels), "repaint gate never observed actual framed panes")
    for left, right, top, bottom in panels:
        for y in range(top, bottom):
            require(not any(char in BARS for char in terminal.screen.cells[y][left:right]),
                    "plain no-bars pane contains a stale border/caret glyph")
    logical_columns = min(terminal.columns, 240)
    require(all(not char.strip() for row in terminal.screen.cells for char in row[logical_columns:]),
            "physical columns beyond application width retain terminal damage")
    return True


def plain_fixture(directory):
    fixture = ProviderFixture(directory)
    for account in ACCOUNTS:
        source = fixture.data[account]["baseline"]
        message = next(m for m in source["messages"] if m["id"] == "shared-msg-096")
        content = (f"{MARKER} {account}\n" +
                   "Owned clean line café emoji without divider marks. " * 5 + "\n" +
                   "\n".join(f"Owned row {i:03} without divider marks." for i in range(80)) + f"\n{TAIL}\n")
        require(not any(char in content for char in BARS), "plain fixture accidentally includes a tested ghost glyph")
        data = content.encode()
        message["payload"]["body"] = {"size":len(data), "data":base64.urlsafe_b64encode(data).decode().rstrip("=")}
        fixture.stage(account,"baseline")
    return fixture


def run_plain(binary, directory, reflow):
    fixture = plain_fixture(directory)
    seed(binary,directory,fixture,bodies=("shared-msg-096",))
    fixture.stage(ACCOUNTS[0],"baseline",held=True)
    terminal = None
    try:
        terminal = RepaintTerminal(binary,directory,extra=fixture.options(),screen_type=PreservedScreen,
                                  columns=100 if reflow else 225,rows=24 if reflow else 40)
        fixture.wait_entered(terminal.process,pump=terminal.pump)
        terminal.until(lambda:reader_contains(terminal.screen,MARKER))
        if reflow:
            terminal.send(b"lG")
            terminal.until(lambda:reader_contains(terminal.screen,TAIL))
            old = reader_rectangle(terminal.screen)
            terminal.resize(180,60)
            # No navigation key after resize: a single redraw must clamp and
            # repaint the complete same selected body immediately.
            terminal.until(lambda:reader_contains(terminal.screen,TAIL) and reader_rectangle(terminal.screen)!=old)
            no_ghosts(terminal)
            result={"endTailBeforeAndAfterResize":True,"navigationAfterResize":0,"physicalCellsPreserved":True}
        else:
            fixture.release()
            terminal.until(lambda:"Up to date" in terminal.text())
            terminal.send(b"c")
            terminal.until(lambda:"Compose" in terminal.text() and "Subject:" in terminal.text())
            terminal.send(b"\t\t\t\tiOwned composer text")
            terminal.until(lambda:source_location(terminal,"Owned composer text") is not None
                           and terminal.screen.state == "ground"
                           and {"row":terminal.screen.y,"column":terminal.screen.x}
                               == cursor_after_source(terminal,"Owned composer text"))
            old_clear = terminal.screen.full_physical_clears
            old_border = any(row[224]=="│" for row in terminal.screen.cells)
            require(old_border,"old225-column renderer border was never present")
            terminal.resize(251,40)
            require(any(row[224]=="│" for row in terminal.screen.cells),"harness reset hid actual old physical border")
            terminal.until(lambda:terminal.screen.full_physical_clears>old_clear and terminal.screen.locate("Owned composer text") is not None)
            terminal.send(b"\x1b");terminal.gap()
            no_ghosts(terminal)
            terminal.send(b"q")
            terminal.until(lambda:reader_rectangle(terminal.screen) is not None)
            no_ghosts(terminal)
            for layout in ("below","right"):
                terminal.send(b":layout "+layout.encode()+b"\r");terminal.gap(.15)
                terminal.until(lambda:reader_rectangle(terminal.screen) is not None)
                no_ghosts(terminal)
            terminal.send(b"lJ");terminal.gap(.15);no_ghosts(terminal)
            terminal.send(b"K");terminal.gap(.15);no_ghosts(terminal)
            result={"physicalColumns":251,"logicalColumnLimit":240,"physicalCellsPreserved":True,
                    "oldBorderAndCaretObserved":True,"fullPhysicalClearObserved":True,"paneInteriorsGhostFree":True}
        result.update(screen_capture(terminal))
        result.update(terminal.finish())
        return result
    except Exception as error:
        if terminal is not None: error.repaint_cells=screen_capture(terminal)
        raise
    finally:
        fixture.release()
        if terminal is not None:terminal.close()


def long_account(binary,directory):
    require(len(LONG_ACCOUNT)==21,"fictional long account not21characters")
    directory.mkdir(parents=True)
    config=directory/'fictional-config.json'
    config.write_text(json.dumps({"oauthClientFile":"","chrome":"/nonexistent/fictional-browser","chromeUserData":"",
        "accounts":[{"address":LONG_ACCOUNT,"profile":"Fictional profile","enabled":True,"required":False}]})+'\n')
    config.chmod(0o600)
    extra=("--fixtures","--config",str(config))
    with Client(binary,directory,fixtures=False,extra=extra) as client:
        client.request("mail.refresh",LONG_ACCOUNT,limit=32)
        before=client.request("cache.stats",LONG_ACCOUNT,cacheOnly=True)
        message=client.request("mail.read",LONG_ACCOUNT,messageId="demo-96",cacheOnly=True)
        require(LONG_ACCOUNT in message["bodyText"],"builtin synthetic body lost customaccount")
    base=directory/'cache/fixtures'/hashlib.sha256(LONG_ACCOUNT.encode()).hexdigest()
    lock_fd=os.open(base/'refresh.lock',os.O_RDWR|os.O_CLOEXEC|os.O_NOFOLLOW)
    fcntl.flock(lock_fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    terminal=None
    try:
        terminal=BuiltinTerminal(binary,directory,config)
        terminal.until(lambda:"Updating elsewhere · cached mail ready" in terminal.text())
        terminal.until(lambda:reader_contains(terminal.screen,f"Hello from {LONG_ACCOUNT}!"))
        title=terminal.screen.locate("Accounts / mailboxes")
        require(title is not None,"wide navigation pane absent")
        mail=terminal.screen.locate("Mail ·")
        require(mail is not None and mail['column']==30,"21-character account did not get27-column navigation")
        nav_rows=["".join(row[1:26]) for row in terminal.screen.cells[title['row']+1:terminal.rows-3]]
        require(sum(('> '+LONG_ACCOUNT) in row for row in nav_rows)==1,"selected complete21-character account is clipped/wrapped in navigation")
        with Client(binary,directory,fixtures=False,extra=extra) as client:
            during=client.request("cache.stats",LONG_ACCOUNT,cacheOnly=True)
        require(during['refreshInProgress'] is True and during['fixtureCalls']==before['fixtureCalls'],
                "held custom-account cache view fetched provider or released another owner's lease")
        result={"accountCharacters":21,"navigationColumns":27,"selectedAddressCompleteOneRow":True,
                "cachedFullReadWhileExternalLeaseHeld":True,"providerCallsDuringView":0}
        result.update(screen_capture(terminal))
        result.update(terminal.finish())
        with Client(binary,directory,fixtures=False,extra=extra) as client:
            require(client.request("cache.stats",LONG_ACCOUNT,cacheOnly=True)['fixtureSends']==0,"custom-account repaint submitted mail")
        return result
    except Exception as error:
        if terminal is not None:error.repaint_cells=screen_capture(terminal)
        raise
    finally:
        if terminal is not None:terminal.close()
        fcntl.flock(lock_fd,fcntl.LOCK_UN);os.close(lock_fd)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--build-mode',type=build_mode,default='debug')
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--case',action='append',choices=CASES)
    args=parser.parse_args();binary=args.binary.resolve()
    require(not args.output.exists(),'refusing previous repaint evidence overwrite')
    report={**read_build_info(binary,args.build_mode),'binarySha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
            'syntheticOnly':True,'liveWrites':False,'desktopUsed':False,'cases':[]}
    with tempfile.TemporaryDirectory(prefix='omagma-repaint-') as temporary:
        for name in CASES:
            if args.case and name not in args.case:continue
            started=time.monotonic();directory=Path(temporary)/name
            try:
                data=long_account(binary,directory) if name=='long-account-held-cache' else run_plain(binary,directory,name=='end-reflow-tail')
                item={'name':name,'passed':True,**data}
            except Exception as error:
                item={'name':name,'passed':False,'error':f'{type(error).__name__}: {error}'}
                if hasattr(error,'repaint_cells'):item['diagnostics']=error.repaint_cells
            item['elapsedSeconds']=round(time.monotonic()-started,4);report['cases'].append(item)
            print(json.dumps(item),flush=True)
            if not item['passed']:break
    report['passed']=bool(report['cases']) and all(c['passed'] for c in report['cases'])
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,indent=2)+'\n')
    return 0 if report['passed'] else 1


if __name__=='__main__':sys.exit(main())
