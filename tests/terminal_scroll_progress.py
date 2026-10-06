#!/usr/bin/env python3
"""Owned-PTY automatic pagination and honest held fetch-progress regressions."""
import argparse
import base64
import json
from pathlib import Path
import re
import tempfile
import time

from terminal_cache import ProviderFixture, FETCH_COLOR, metrics, status_color
from terminal_integration import ACCOUNTS, Client, require
from terminal_mouse import MouseTerminal, report
from terminal_mouse_screen import MouseScreen
from terminal_reader import reader_contains
from probes.cache_refresh_fixture import repage


def fixture(directory):
    result = ProviderFixture(directory)
    for account in ACCOUNTS:
        key = account.split("@")[0]
        source = result.data[account]["baseline"]
        source["labels"] = [{"id": "INBOX", "name": "Inbox", "type": "system"}]
        for message in source["messages"]:
            number = int(message["id"].rsplit("-", 1)[1])
            body = f"Scroll fixture {account} body {number:03}.\nLiteral cached mail remains readable.\n".encode()
            message["labelIds"] = ["INBOX", "UNREAD"]
            message["snippet"] = f"Scroll fixture {key} message {number:03}"
            message["payload"] = {
                "partId": "", "mimeType": "text/plain", "filename": "",
                "headers": [
                    {"name": "From", "value": f"Fixture Sender <sender-{key}@example.test>"},
                    {"name": "To", "value": account},
                    {"name": "Subject", "value": f"Scroll fixture {key} {number:03}"},
                    {"name": "Message-ID", "value": f"<scroll-{key}-{number:03}@example.test>"},
                    {"name": "Content-Type", "value": "text/plain; charset=utf-8"},
                ],
                "body": {"size": len(body), "data": base64.urlsafe_b64encode(body).decode().rstrip("=")},
            }
        repage(source)
        result.stage(account, "baseline")
    return result


def options(source, count):
    return source.options("--metadata-limit", str(count), "--prefetch-bodies", "0")


def seed(binary, directory, source, count, accounts=(ACCOUNTS[0],)):
    with Client(binary, directory, extra=options(source, count)) as client:
        for account in accounts:
            client.request("mail.refresh", account, limit=count, prefetchLimit=0, label="INBOX")
            client.request("labels.list", account)
            require(metrics(client, account)["metadataEntries"] == count,
                    "fixture metadata count differs from independent retained-count oracle")
            for number in (96, 65, 64, 57, 33, 32, 1):
                # Reading a body outside newest-N retention can perturb the
                # bounded cache. Only warm retained targets for this case.
                if number >= 97 - count:
                    client.request("mail.read", account, messageId=f"shared-msg-{number:03}")


def start(binary, directory, source, count):
    return MouseTerminal(binary, directory, extra=options(source, count),
                         columns=160, rows=40, screen_type=MouseScreen,
                         environment={"NO_COLOR": None, "COLORTERM": "truecolor"})


def contains(terminal, number, account=ACCOUNTS[0]):
    return reader_contains(terminal.screen, f"Scroll fixture {account} body {number:03}.")


def settled(terminal, number, account=ACCOUNTS[0]):
    terminal.until(lambda: contains(terminal, number, account)
                   and "Up to date" in "".join(terminal.screen.cells[1])
                   and terminal.screen.mouse_modes == {1002, 1004, 1006})


def wheel(terminal, up=False):
    title = terminal.screen.locate("Mail ·")
    require(title is not None, "visible mail pane unavailable for wheel target")
    report(terminal, title["column"] + 3, title["row"] + 1, button=64 if up else 65)


def stats(binary, directory, source, count, account=ACCOUNTS[0]):
    with Client(binary, directory, extra=options(source, count)) as client:
        return metrics(client, account)


def tail(terminal, number):
    terminal.send(b"G")
    terminal.until(lambda: contains(terminal, number))


def queue_remote(terminal):
    tail(terminal, 65)
    terminal.send(b"j")
    terminal.until(lambda: contains(terminal, 64))
    tail(terminal, 57)
    terminal.send(b"j" * 20 + b"\x1b[B\x1b[6~")
    wheel(terminal)
    terminal.until(lambda: "Next page queued" in terminal.text())
    terminal.gap(.15)
    require(contains(terminal, 57), "queued remote boundary replaced usable cached reader early")


def cached_keys(binary, directory):
    source = fixture(directory)
    seed(binary, directory, source, 96)
    terminal = start(binary, directory, source, 96)
    try:
        settled(terminal, 96)
        for name, key in (("j", b"j"), ("Down", b"\x1b[B"), ("PageDown", b"\x1b[6~"), ("wheel", None)):
            tail(terminal, 65)
            if key is None:
                wheel(terminal)
            else:
                terminal.send(key)
            terminal.until(lambda: contains(terminal, 64))
            # The replacement contains the next32 rows; G must reach33, not
            # the original page's65 or an appended96-row historical list.
            tail(terminal, 33)
            terminal.send(b"j")
            terminal.until(lambda: contains(terminal, 32))
            tail(terminal, 1)
            terminal.send(b"j" * 6)
            wheel(terminal)
            terminal.gap(.1)
            require(contains(terminal, 1), "oldest real message disappeared at final page boundary")
            terminal.send(b"[")
            terminal.until(lambda: contains(terminal, 64))
            terminal.send(b"[")
            terminal.until(lambda: contains(terminal, 96))
            print(f"PASS scroll {name}:96 messages over three bounded32-row pages; oldest tail stops")
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()


def remote_coalescing(binary, directory):
    source = fixture(directory)
    seed(binary, directory, source, 40)
    before = stats(binary, directory, source, 40)
    source.stage(ACCOUNTS[0], "baseline", held=True)
    terminal = start(binary, directory, source, 40)
    try:
        source.wait_entered(terminal.process, pump=terminal.pump)
        terminal.until(lambda: contains(terminal, 96) and terminal.screen.mouse_modes == {1002, 1004, 1006})
        require(not re.search(r"(?:metadata|bodies) \d+/\d+", "".join(terminal.screen.cells[1])),
                "refresh entry fabricated a denominator before collecting batch IDs")
        queue_remote(terminal)
        held = stats(binary, directory, source, 40)
        require(held["fixtureCalls"] == before["fixtureCalls"], "boundary input issued provider calls while refresh was held")
        source.release()
        terminal.until(lambda: contains(terminal, 56) and "Next page queued" not in terminal.text())
        terminal.gap(.1)
        after = stats(binary, directory, source, 40)
        # One fixture list request + one body read for the first older row.
        require(after["fixtureCalls"] - before["fixtureCalls"] == 2,
                "repeated boundary keys fetched more than one provider page/body")
        require(contains(terminal, 56), "coalesced input skipped to a second older page")
        terminal.finish()
        print("PASS scroll coalescing:22 keys plus wheel retain cached tail then request one older page")
    except Exception:
        print(terminal.text())
        raise
    finally:
        source.release()
        terminal.close()


def account_isolation(binary, directory):
    source = fixture(directory)
    seed(binary, directory, source, 40, accounts=ACCOUNTS[:2])
    before = stats(binary, directory, source, 40)
    source.stage(ACCOUNTS[0], "baseline", held=True)
    terminal = start(binary, directory, source, 40)
    try:
        source.wait_entered(terminal.process, pump=terminal.pump)
        terminal.until(lambda: contains(terminal, 96) and terminal.screen.mouse_modes == {1002, 1004, 1006})
        queue_remote(terminal)
        terminal.send(b"2")
        terminal.until(lambda: contains(terminal, 96, ACCOUNTS[1]))
        source.release()
        settled(terminal, 96, ACCOUNTS[1])
        terminal.gap(.1)
        require(stats(binary, directory, source, 40)["fixtureCalls"] == before["fixtureCalls"],
                "an old account's queued page was fetched after switching account")
        terminal.send(b"1")
        terminal.until(lambda: contains(terminal, 57))
        require(stats(binary, directory, source, 40)["fixtureCalls"] == before["fixtureCalls"],
                "returning to the account revived a stale page intent")
        terminal.finish()
        print("PASS scroll account isolation: queued older page is discarded on account change")
    except Exception:
        print(terminal.text())
        raise
    finally:
        source.release()
        terminal.close()


def cache_search_isolation(binary, directory):
    source = fixture(directory)
    seed(binary, directory, source, 40)
    before = stats(binary, directory, source, 40)
    source.stage(ACCOUNTS[0], "baseline", held=True)
    terminal = start(binary, directory, source, 40)
    try:
        source.wait_entered(terminal.process, pump=terminal.pump)
        terminal.until(lambda: contains(terminal, 96) and terminal.screen.mouse_modes == {1002, 1004, 1006})
        queue_remote(terminal)
        terminal.send(b"/")
        terminal.until(lambda: "Cache / " in terminal.text())
        terminal.send(b"subject:Scroll\r")
        terminal.until(lambda: "Cache search" in terminal.screen.lines()[0] and contains(terminal, 96))
        tail(terminal, 65)
        terminal.send(b"j")
        terminal.until(lambda: contains(terminal, 64))
        tail(terminal, 57)
        terminal.send(b"j" * 12 + b"\x1b[6~")
        wheel(terminal)
        terminal.gap(.15)
        require(contains(terminal, 57), "cache search crossed into provider-only older mail")
        require(stats(binary, directory, source, 40)["fixtureCalls"] == before["fixtureCalls"],
                "cache-only search tail fetched provider mail")
        source.release()
        terminal.gap(.15)
        require(contains(terminal, 57) and "Cache search" in terminal.screen.lines()[0],
                "an old mailbox intent replaced the current cache search")
        require(stats(binary, directory, source, 40)["fixtureCalls"] == before["fixtureCalls"],
                "releasing an old refresh revived a stale query page")
        terminal.finish()
        print("PASS scroll query isolation: cache-only search pages stop at retained tail without provider calls")
    except Exception:
        print(terminal.text())
        raise
    finally:
        source.release()
        terminal.close()


def held_progress(binary, directory, phase):
    source = fixture(directory)
    hold = source.root / "progress.hold"
    entered = source.root / "progress.entered"
    hold.write_text("owned synthetic progress gate\n")
    value = json.loads(source.path(ACCOUNTS[0]).read_text())
    value["sync"]["fixtureProgress"] = {"phase": phase, "completed": 1,
                                           "fixtureHold": hold.name, "fixtureEntered": entered.name}
    source.path(ACCOUNTS[0]).write_text(json.dumps(value))
    # A cold32-ID head from a source containing96 IDs has actual denominator32.
    extra = source.options("--metadata-limit", "32", "--prefetch-bodies", "32")
    terminal = MouseTerminal(binary, directory, extra=extra, columns=160, rows=40, screen_type=MouseScreen,
                             environment={"NO_COLOR": None, "COLORTERM": "truecolor"})
    try:
        deadline = time.monotonic() + 8
        while not entered.exists():
            require(terminal.process.poll() is None, "progress owner exited before acknowledged checkpoint")
            require(time.monotonic() < deadline, "actual completed progress step never reached held checkpoint")
            terminal.pump(.02)
        terminal.until(lambda: f"{phase} 1/32" in "".join(terminal.screen.cells[1]))
        status_color(terminal, f"{phase} 1/32", FETCH_COLOR)
        require("1/96" not in "".join(terminal.screen.cells[1]), "source result estimate was misrepresented as batch total")
        hold.unlink()
        settled(terminal, 96)
        require(not re.search(r"(?:metadata|bodies) \d+/\d+", "".join(terminal.screen.cells[1])),
                "completed job retained a stale fetch fraction")
        terminal.finish()
        print(f"PASS progress {phase}:actual completed1/32 held after GET/commit, fetching color, completion clears")
    except Exception:
        print(terminal.text())
        raise
    finally:
        hold.unlink(missing_ok=True)
        terminal.close()


def warm_retained(binary, directory, source, count, accounts=(ACCOUNTS[0],)):
    """Make every navigation target local, so provider-counter deltas are exact."""
    with Client(binary, directory, extra=options(source, count)) as client:
        for account in accounts:
            for number in range(96, 96 - count, -1):
                client.request("mail.read", account, messageId=f"shared-msg-{number:03}")


def no_provider_since(binary, directory, source, count, before, message):
    require(stats(binary, directory, source, count)["fixtureCalls"] == before["fixtureCalls"], message)


def bidirectional_window(binary, directory):
    # Exact adjacent-reader identities across all96 rows establish order, not
    # merely that another plausible page appeared after scrolling.
    walk = directory / "walk"
    walk.mkdir()
    source = fixture(walk)
    seed(binary, walk, source, 96)
    warm_retained(binary, walk, source, 96)
    terminal = start(binary, walk, source, 96)
    try:
        settled(terminal, 96)
        before = stats(binary, walk, source, 96)
        for number in range(95, 0, -1):
            terminal.send(b"j")
            terminal.until(lambda number=number: contains(terminal, number))
        for number in range(2, 97):
            terminal.send(b"k")
            terminal.until(lambda number=number: contains(terminal, number))
        terminal.send(b"k\x1b[A\x1b[5~")
        wheel(terminal, up=True)
        terminal.gap(.1)
        require(contains(terminal, 96), "newest-cache boundary replaced the usable reader")
        no_provider_since(binary, walk, source, 96, before, "walking down/up all96 cached messages fetched provider mail")
        for name, key in (("k", b"k"), ("Up", b"\x1b[A"), ("PageUp", b"\x1b[5~"), ("wheelUp", None)):
            tail(terminal, 65)
            terminal.send(b"j")
            terminal.until(lambda: contains(terminal, 64))
            if key is None:
                wheel(terminal, up=True)
            else:
                terminal.send(key)
            terminal.until(lambda: contains(terminal, 65))
            no_provider_since(binary, walk, source, 96, before, f"{name} reverse boundary fetched provider mail")
            print(f"PASS bidirectional {name}:cached predecessor window selects adjacent65 after64")
        # End at the FIRST row of a middle window. Restart clears the transient
        # cursor stack; the persisted selected identity still has a predecessor.
        terminal.send(b"j")
        terminal.until(lambda: contains(terminal, 64))
        terminal.finish()
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()
    terminal = start(binary, walk, source, 96)
    try:
        settled(terminal, 64)
        before = stats(binary, walk, source, 96)
        terminal.send(b"k")
        terminal.until(lambda: contains(terminal, 65))
        no_provider_since(binary, walk, source, 96, before, "restored middle anchor relied on a provider or old cursor history")
        terminal.finish()
        print("PASS bidirectional order/restart:96 down+up identities contiguous; middle anchor reverses with fresh process")
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()

    remote = directory / "remote"
    remote.mkdir()
    source = fixture(remote)
    seed(binary, remote, source, 40)
    warm_retained(binary, remote, source, 40)
    terminal = start(binary, remote, source, 40)
    try:
        settled(terminal, 96)
        tail(terminal, 65)
        terminal.send(b"j")
        terminal.until(lambda: contains(terminal, 64))
        tail(terminal, 57)
        terminal.send(b"j")
        terminal.until(lambda: contains(terminal, 56))
        before = stats(binary, remote, source, 40)
        terminal.send(b"k")
        terminal.until(lambda: contains(terminal, 57))
        no_provider_since(binary, remote, source, 40, before,
                          "reversing from a provider page beyond newest40 retention fetched provider mail")
        terminal.finish()
        print("PASS bidirectional remote:evicted provider anchor56 returns cached adjacent57 without network")
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()

    cached_query = directory / "cached-query"
    cached_query.mkdir()
    source = fixture(cached_query)
    seed(binary, cached_query, source, 96)
    warm_retained(binary, cached_query, source, 96)
    terminal = start(binary, cached_query, source, 96)
    try:
        settled(terminal, 96)
        before = stats(binary, cached_query, source, 96)
        terminal.send(b"/")
        terminal.until(lambda: "Cache / " in terminal.text())
        terminal.send(b"subject:Scroll\r")
        terminal.until(lambda: "Cache search" in terminal.screen.lines()[0] and contains(terminal, 96))
        tail(terminal, 65)
        terminal.send(b"j")
        terminal.until(lambda: contains(terminal, 64))
        terminal.send(b"k")
        terminal.until(lambda: contains(terminal, 65))
        require("Cache search" in terminal.screen.lines()[0], "reverse boundary left the local search scope")
        no_provider_since(binary, cached_query, source, 96, before, "cache search reverse fetched provider mail")
        terminal.finish()
        print("PASS bidirectional cache search:local before/after windows preserve query and issue zero provider calls")
    except Exception:
        print(terminal.text())
        raise
    finally:
        terminal.close()

    pending = directory / "pending"
    pending.mkdir()
    source = fixture(pending)
    seed(binary, pending, source, 40, accounts=ACCOUNTS[:2])
    warm_retained(binary, pending, source, 40, accounts=ACCOUNTS[:2])
    before = stats(binary, pending, source, 40)
    source.stage(ACCOUNTS[0], "baseline", held=True)
    terminal = start(binary, pending, source, 40)
    try:
        source.wait_entered(terminal.process, pump=terminal.pump)
        terminal.until(lambda: contains(terminal, 96) and terminal.screen.mouse_modes == {1002, 1004, 1006})
        queue_remote(terminal)
        terminal.send(b"k")
        terminal.until(lambda: contains(terminal, 58))
        terminal.send(b"\x1b[Hk")
        terminal.until(lambda: contains(terminal, 65))
        require(source.is_held(), "reverse navigation waited until the unrelated refresh released")
        no_provider_since(binary, pending, source, 40, before, "reverse navigation during held refresh fetched provider mail")
        terminal.send(b"2")
        terminal.until(lambda: contains(terminal, 96, ACCOUNTS[1]))
        source.release()
        settled(terminal, 96, ACCOUNTS[1])
        no_provider_since(binary, pending, source, 40, before, "cancelled forward demand revived after account switch")
        terminal.send(b"1")
        terminal.until(lambda: contains(terminal, 65))
        terminal.send(b"/")
        terminal.until(lambda: "Cache / " in terminal.text())
        terminal.send(b"subject:Scroll\r")
        terminal.until(lambda: "Cache search" in terminal.screen.lines()[0])
        terminal.gap(.1)
        no_provider_since(binary, pending, source, 40, before, "cancelled forward demand revived in a new local query")
        terminal.finish()
        print("PASS bidirectional pending:up cancels queued older fetch, reverses during refresh, stays isolated by account/query")
    except Exception:
        print(terminal.text())
        raise
    finally:
        source.release()
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--case", choices=("cached-keys", "remote-coalescing", "account-isolation", "cache-search", "metadata-progress", "bodies-progress", "bidirectional-window"))
    args = parser.parse_args()
    cases = {"cached-keys": cached_keys, "remote-coalescing": remote_coalescing,
             "account-isolation": account_isolation, "cache-search": cache_search_isolation,
             "metadata-progress": lambda binary, directory: held_progress(binary, directory, "metadata"),
             "bodies-progress": lambda binary, directory: held_progress(binary, directory, "bodies"),
             "bidirectional-window": bidirectional_window}
    with tempfile.TemporaryDirectory(prefix="omagma-scroll-progress-") as temporary:
        for name in ([args.case] if args.case else cases):
            directory = Path(temporary) / name
            directory.mkdir(mode=0o700)
            cases[name](args.binary.resolve(), directory)


if __name__ == "__main__":
    main()
