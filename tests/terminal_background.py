#!/usr/bin/env python3
"""Native background/cache-lease tests, synthetic only; requires host lock."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import tempfile
import time

from build_info import build_mode, read_build_info
from terminal_cache import ProviderFixture, seed, cached, metrics, contains_body, status_color, FETCH_COLOR
from terminal_integration import ACCOUNTS, Client, no_core_dump, require
from terminal_pty import Terminal
from terminal_status_screen import StatusScreen

CASES = ("native-first-and-quiet-coalesce", "held-lease-cli-tui", "native-signal-restart",
         "refresh-lease-file-safety", "age-and-persisted-policy", "automatic-read-only-gates",
         "activity-arrivals-and-isolation", "activity-failed-refresh", "activity-checkpoint-replay")
OUTCOMES = {"refreshed", "fresh", "in_progress", "auth_needed", "offline", "local_failure"}


class Native:
    def __init__(self, binary, directory, fixture, *extra):
        self.stdout, self.stderr = bytearray(), bytearray()
        self.selector = selectors.DefaultSelector()
        env = dict(os.environ, HOME=str(directory / "home"))
        for name in ("CONFIG", "CACHE", "DATA", "STATE"): env[f"XDG_{name}_HOME"] = str(directory / name.lower())
        runtime = directory / "runtime"
        runtime.mkdir(mode=0o700, exist_ok=True)
        env["XDG_RUNTIME_DIR"] = str(runtime)
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS"): env.pop(name, None)
        self.process = subprocess.Popen([str(binary), "cache-refresh", "--fixtures", "--fixture-root", str(fixture.root),
                                         "--cache-dir", str(directory / "cache"), "--interval", "300", *extra],
                                        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        env=env, cwd=directory, start_new_session=True, preexec_fn=no_core_dump)
        for stream in (self.process.stdout, self.process.stderr):
            os.set_blocking(stream.fileno(), False)
            self.selector.register(stream, selectors.EVENT_READ)

    def pump(self, seconds=.02):
        for key, _ in self.selector.select(seconds):
            data = os.read(key.fileobj.fileno(), 4096)
            if not data:
                self.selector.unregister(key.fileobj)
                continue
            target = self.stdout if key.fileobj is self.process.stdout else self.stderr
            target.extend(data)
            require(len(target) <= 16384, "native anonymous output exceeded16KiB cap")

    def wait(self, seconds=120, quiet=False):
        deadline = time.monotonic() + seconds
        while self.process.poll() is None or self.selector.get_map():
            require(time.monotonic() < deadline, "native background outer deadline")
            self.pump()
        require(self.process.returncode == 0 and not self.stderr, "native background exit/stderr failed")
        if quiet:
            require(not self.stdout, "--quiet wrote output")
            return None
        value = json.loads(self.stdout)
        require(isinstance(value, dict) and set(value) == {"version", "ok", "interrupted", "slots"}, "native response fields not anonymous")
        require(value["version"] == 1 and type(value["ok"]) is bool and type(value["interrupted"]) is bool,
                "native response scalar types changed")
        require(isinstance(value["slots"], list) and len(value["slots"]) <= 3, "native response slot count invalid")
        for item in value["slots"]:
            require(set(item) == {"slot", "outcome"} and type(item["slot"]) is int and 1 <= item["slot"] <= 3 and item["outcome"] in OUTCOMES,
                    "native response leaked account/message data")
        require(not any(account.encode() in self.stdout for account in ACCOUNTS) and b"@" not in self.stdout,
                "native output contains mailbox identity")
        return value

    def close(self):
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
            try: self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=3)
        self.selector.close()
        for stream in (self.process.stdout, self.process.stderr): stream.close()


def native(binary, directory, fixture, *extra, quiet=False):
    owner = Native(binary, directory, fixture, *extra)
    try: return owner.wait(quiet=quiet)
    finally: owner.close()


def account_dir(directory, account):
    return directory / "cache/fixtures" / hashlib.sha256(account.encode()).hexdigest()


def all_metrics(binary, directory, fixture, extra=()):
    with Client(binary, directory, extra=("--fixture-root", str(fixture.root), *extra)) as client:
        result = [metrics(client, account) for account in ACCOUNTS]
    require(client.process.returncode == 0 and not client.stderr, "metric reader child cleanup failed")
    return result


def mutate_view(directory, address, age_ms, completed_age_ms=0):
    path = account_dir(directory, address) / "index.json"
    state = json.loads(path.read_text())
    now = int(time.time() * 1000)
    views = [view for view in state["views"] if view["query"] == "" and view["labelId"] == "INBOX"]
    require(len(views) == 1, "expected one processed Inbox view")
    views[0]["lastSyncStartedAt"] = now - age_ms
    views[0]["lastSyncAt"] = now - completed_age_ms
    path.write_text(json.dumps(state) + "\n")
    require(stat.S_IMODE(path.stat().st_mode) == 0o600, "view clock edit changed private permissions")


def run_case(binary, directory, name):
    fixture = ProviderFixture(directory)
    if name == "native-first-and-quiet-coalesce":
        first = native(binary, directory, fixture)
        require(first["ok"] and not first["interrupted"] and first["slots"] == [{"slot": i, "outcome": "refreshed"} for i in (1, 2, 3)],
                "native first run did not sequentially cover3 slots")
        before = all_metrics(binary, directory, fixture)
        require(all(m["metadataEntries"] == 32 and m["fixtureSends"] == 0 for m in before), "native initial Inbox head/writes wrong")
        native(binary, directory, fixture, "--quiet", quiet=True)
        after = all_metrics(binary, directory, fixture)
        for old, new in zip(before, after):
            for key in ("fixtureCalls", "syncCalls", "syncListCalls", "syncHistoryPages", "syncMetadataGets", "syncBodyGets"):
                require(old[key] == new[key], "recent quiet native run contacted provider")
        return {"enabledSlots": 3, "firstOutcomes": [item["outcome"] for item in first["slots"]], "quietStdoutBytes": 0,
                "recentProviderCalls": 0, "mutationRequests": 0}
    if name in ("held-lease-cli-tui", "native-signal-restart"):
        seed(binary, directory, fixture, accounts=ACCOUNTS)
        fixture.stage(ACCOUNTS[0], "delta", held=True)
        owner = Native(binary, directory, fixture, "--force")
        terminal = None
        try:
            fixture.wait_entered(owner.process, pump=owner.pump)
            with Client(binary, directory, extra=fixture.options()) as reader:
                status = cached(reader, "cache.refresh-status")
                require(status == {"refreshInProgress": True}, "native lease not observable cross-process")
                require(metrics(reader)["refreshInProgress"] is True, "stats disagree with native lease")
                before = metrics(reader)
                coalesced = reader.request("mail.refresh", limit=32, label="INBOX")
                require(coalesced["coalesced"] is True and coalesced["refreshed"] is False and coalesced["refreshInProgress"] is True,
                        "concurrent CLI refresh did not coalesce with native lease")
                require("message 092" in cached(reader, "mail.read", messageId="shared-msg-092")["bodyText"], "native lease blocked cached full read")
                require(len(cached(reader, "mail.thread", threadId="shared-thread-030")["messages"]) == 3,
                        "native lease blocked cached thread")
                require(fixture.is_held(), "full reads finished only after native release")
            if name == "held-lease-cli-tui":
                terminal = Terminal(binary, directory, extra=fixture.options(), screen_type=StatusScreen,
                                    environment={"NO_COLOR": None, "COLORTERM": "truecolor"})
                terminal.until(lambda: contains_body(terminal, 96))
                status_color(terminal, "Updating elsewhere · cached mail ready", FETCH_COLOR)
                terminal.send(b"l")
                terminal.gap()
                terminal.send(b"J")
                terminal.until(lambda: contains_body(terminal, 95))
                require(fixture.is_held() and owner.process.poll() is None, "TUI awaited or cancelled other process's lease")
                terminal.finish(signal_mode=signal.SIGTERM)
                terminal.close()
                terminal = None
                with Client(binary, directory, extra=fixture.options()) as reader:
                    require(cached(reader, "cache.refresh-status")["refreshInProgress"] is True, "TUI exit released another owner's lease")
                fixture.release()
                result = owner.wait()
                require(result["slots"][0]["outcome"] == "refreshed", "native owner did not finish after marker release")
                return {"nativeVsCliCoalesced": True, "cachedFullReadAndThreadBeforeRelease": True,
                        "tuiNavigationBeforeRelease": True, "tuiExitPreservedOtherLease": True, "mutationRequests": 0}
            started = time.monotonic()
            owner.process.send_signal(signal.SIGTERM)
            stopped = owner.wait(seconds=5)
            require(stopped["interrupted"] is True and fixture.is_held(), "native signal did not cancel held job")
            with Client(binary, directory, extra=fixture.options()) as reader:
                require(cached(reader, "cache.refresh-status") == {"refreshInProgress": False}, "signal left lease active")
                require(metrics(reader)["historyId"] == before["historyId"], "interrupted job advanced checkpoint")
                require("message 092" in cached(reader, "mail.read", messageId="shared-msg-092")["bodyText"], "signal damaged cached body")
            fixture.release()
            resumed = native(binary, directory, fixture, "--force")
            require(resumed["slots"][0]["outcome"] == "refreshed", "next native owner could not take released lease")
            require(all_metrics(binary, directory, fixture)[0]["historyId"] == "1001", "next owner did not establish new checkpoint")
            return {"sigtermSeconds": round(time.monotonic() - started, 4), "heldJobCancelled": True,
                    "leaseReleased": True, "oldCheckpointPreservedUntilRestart": True, "nextOwnerRefreshed": True}
        finally:
            if terminal is not None: terminal.close()
            owner.close()
    if name == "refresh-lease-file-safety":
        seed(binary, directory, fixture)
        path = account_dir(directory, ACCOUNTS[0]) / "refresh.lock"
        original = path.read_bytes()
        require(original == b"" and stat.S_IMODE(path.stat().st_mode) == 0o600, "lease is not empty private0600")
        refused = []
        for kind in ("symlink", "public-mode", "fifo", "directory", "nonempty"):
            path.unlink()
            target = directory / "unrelated-target"
            target.write_bytes(b"synthetic unchanged target\n")
            target.chmod(0o600)
            if kind == "symlink": path.symlink_to(target)
            elif kind == "public-mode": path.write_bytes(b""); path.chmod(0o644)
            elif kind == "fifo": os.mkfifo(path, 0o600)
            elif kind == "directory": path.mkdir(mode=0o700)
            else: path.write_bytes(b"not an empty lock"); path.chmod(0o600)
            try:
                with Client(binary, directory, extra=fixture.options()) as client:
                    started = time.monotonic()
                    for cmd in ("cache.refresh-status", "mail.refresh"):
                        error = client.request(cmd, ok=False, **({"limit": 32, "auto": True} if cmd == "mail.refresh" else {}))
                        require(error["code"] == "InsecureRefreshLease", "special lease leaf was not explicitly refused")
                    elapsed = time.monotonic() - started
                    require(elapsed < 2, "special lease leaf blocked native-compatible API")
                    require(target.read_bytes() == b"synthetic unchanged target\n", "lease followed symlink target")
                    refused.append({"kind": kind, "code": "InsecureRefreshLease", "seconds": round(elapsed, 5)})
            finally:
                if path.is_dir() and not path.is_symlink(): path.rmdir()
                else: path.unlink()
                path.write_bytes(original)
                path.chmod(0o600)
        return {"leaseRefusals": refused, "targetUnchanged": True, "noBlockingSpecialOpen": True}
    if name == "age-and-persisted-policy":
        native(binary, directory, fixture)
        results = []
        for age, expected in ((149000, "fresh"), (150000, "refreshed"), (-600000, "refreshed")):
            mutate_view(directory, ACCOUNTS[0], age, completed_age_ms=10)
            before = all_metrics(binary, directory, fixture)[0]
            value = native(binary, directory, fixture)
            outcome = value["slots"][0]["outcome"]
            require(outcome == expected, "automatic freshness used completion/full300s/future clock")
            after = all_metrics(binary, directory, fixture)[0]
            require(after["syncCalls"] - before["syncCalls"] == (0 if expected == "fresh" else 1), "age boundary counter disagreed")
            results.append({"startAgeMs": age, "outcome": outcome})
        with Client(binary, directory, extra=("--fixture-root", str(fixture.root), "--metadata-limit", "48", "--disk-limit-bytes", "131072")) as client:
            client.request("mail.refresh", limit=48, label="INBOX")
            configured = metrics(client)
            require(configured["metadataLimit"] == 48 and configured["diskLimitBytes"] == 131072, "private policy not configured")
        mutate_view(directory, ACCOUNTS[0], 151000)
        native(binary, directory, fixture, "--metadata-limit", "2000", "--disk-limit-bytes", str(256 * 1024**2))
        adopted = all_metrics(binary, directory, fixture)[0]
        require(adopted["metadataLimit"] == 48 and adopted["diskLimitBytes"] == 131072,
                "automatic background ping-ponged persisted count/disk policy")
        require(adopted["metadataEntries"] <= 48 and adopted["diskBytes"] <= 131072, "adopted policy violated")
        return {"freshnessBoundaries": results, "halfIntervalMs": 150000, "persistedMetadataLimit": 48,
                "persistedDiskLimitBytes": 131072, "explicitAutomaticDefaultsDidNotGrowPolicy": True}
    if name == "automatic-read-only-gates":
        value = native(binary, directory, fixture, "--fixture-scenario", "readonly")
        require(all(item["outcome"] == "refreshed" for item in value["slots"]), "native readonly bar-style read did not work")
        with Client(binary, directory, extra=("--fixture-root", str(fixture.root))) as client:
            before = metrics(client)
            for cmd, params in (("mail.send", {"operationId": "forbidden-bg-send", "draft": {"to": ["recipient@example.org"], "subject": "Never submit", "bodyText": "Synthetic"}}),
                                ("contacts.list", {}), ("contacts.upsert", {"operationId": "forbidden-bg-contact", "contact": {"name": "Never write", "emails": ["recipient@example.org"]}}),
                                ("invitation.reply", {"messageId": "shared-msg-009", "status": "accepted", "operationId": "forbidden-bg-rsvp"})):
                error = client.request(cmd, barGrantOnly=True, ok=False, **params)
                require(error["code"] == "PermissionDenied", "bar-only background request gained non-read capability")
            for params in ({"query": "is:unread"}, {"label": "STARRED"}, {"cursor": "unrelated"}):
                require(client.request("mail.refresh", auto=True, ok=False, **params)["code"] == "InvalidAutomaticRefresh",
                        "automatic refresh accepted scoped arbitrary request")
            after = metrics(client)
            require(after["fixtureCalls"] == before["fixtureCalls"] and after["fixtureSends"] == 0,
                    "denied automatic requests reached provider")
        return {"nativeReadOnlySlots": 3, "nonReadCapabilitiesDenied": 4, "arbitraryAutomaticScopesDenied": 3,
                "providerCallsForDeniedRequests": 0, "mutationRequests": 0, "realCredentialUse": False}
    if name == "activity-arrivals-and-isolation":
        with Client(binary, directory, extra=fixture.options()) as client:
            cold = cached(client, "cache.activity")
            require(set(cold) == {"inboxArrivalCount", "generation", "lastSyncAt"}, "activity fields changed or leaked paths")
            require(cold["inboxArrivalCount"] == 0 and cold["lastSyncAt"] == 0, "existing/cold baseline was counted as new mail")
        seed(binary, directory, fixture, accounts=ACCOUNTS)
        with Client(binary, directory, extra=fixture.options()) as client:
            require(all(cached(client, "cache.activity", account)["inboxArrivalCount"] == 0 for account in ACCOUNTS),
                    "bootstrap history counted baseline mail")
        fixture.stage(ACCOUNTS[0], "delta")
        native(binary, directory, fixture, "--force")
        with Client(binary, directory, extra=fixture.options()) as client:
            activity = cached(client, "cache.activity")
            require(activity["inboxArrivalCount"] == 2, "typed added IDs were not deduplicated or labels/deletion were counted")
            require(cached(client, "mail.list", label="INBOX")["inboxArrivalCount"] == 2, "cached list activity disagreed")
            require(all(cached(client, "cache.activity", account)["inboxArrivalCount"] == 0 for account in ACCOUNTS[1:]),
                    "colliding message IDs mixed account arrival counts")
            client.request("mail.list", label="INBOX", limit=12)
            client.request("draft.create", draft={"to": ["recipient@example.org"], "subject": "Synthetic local draft", "bodyText": "Never sent."})
            client.request("mail.archive", messageId="shared-msg-092")
            require(cached(client, "cache.activity")["inboxArrivalCount"] == 2, "prefetch/draft/label writes counted as arrivals")
        native(binary, directory, fixture, "--force")
        with Client(binary, directory, extra=fixture.options()) as client:
            require(cached(client, "cache.activity")["inboxArrivalCount"] == 2, "same checkpoint counted twice")
        fixture.stage(ACCOUNTS[0], "expired")
        native(binary, directory, fixture, "--force")
        with Client(binary, directory, extra=fixture.options()) as client:
            require(cached(client, "cache.activity")["inboxArrivalCount"] == 2, "history-expiry resync guessed an arrival count")
            client.request("cache.clear")
            require(cached(client, "cache.activity")["inboxArrivalCount"] == 2, "cache clear made cumulative count decrease")
        # Simulate an old index only after every cache owner has closed.
        path = account_dir(directory, ACCOUNTS[0]) / "index.json"
        legacy = json.loads(path.read_text());legacy.pop("inboxArrivalCount")
        path.write_text(json.dumps(legacy) + "\n")
        with Client(binary, directory, extra=fixture.options()) as client:
            require(cached(client, "cache.activity")["inboxArrivalCount"] == 0, "legacy index did not baseline zero")
        return {"incomingAdds": 2, "duplicateHistoryDeduplicated": True, "accountsIsolated": 3,
                "bootstrapResyncLabelsDraftsPrefetchExcluded": True, "legacyCounterBaseline": 0}
    if name == "activity-failed-refresh":
        seed(binary, directory, fixture)
        fixture.stage(ACCOUNTS[0], "delta")
        with Client(binary, directory, scenario="offline-refresh", extra=fixture.options()) as client:
            before = cached(client, "cache.activity")
            require(client.request("mail.refresh", label="INBOX", limit=32, ok=False)["code"] == "TransientFailure", "fixture failure was not exercised")
            after = cached(client, "cache.activity")
            require(before == after and after["inboxArrivalCount"] == 0, "failed refresh advanced activity")
        native(binary, directory, fixture, "--force")
        with Client(binary, directory, extra=fixture.options()) as client:
            require(cached(client, "cache.activity")["inboxArrivalCount"] == 2, "successful retry lost failed additions")
        return {"failedRefreshCounter": 0, "successfulRetryCounter": 2}
    if name == "activity-checkpoint-replay":
        seed(binary, directory, fixture, accounts=ACCOUNTS)
        fixture.stage(ACCOUNTS[0], "delta")
        hold, entered = fixture.root / "activity-body.hold", fixture.root / "activity-body.entered"
        hold.write_text("Synthetic body phase held\n")
        source = json.loads(fixture.path(ACCOUNTS[0]).read_text())
        source["sync"]["fixtureProgress"] = {"phase": "bodies", "completed": 1,
            "fixtureHold": hold.name, "fixtureEntered": entered.name}
        fixture.path(ACCOUNTS[0]).write_text(json.dumps(source) + "\n")
        owner = Native(binary, directory, fixture, "--force")
        try:
            deadline = time.monotonic() + 10
            while not entered.exists():
                require(owner.process.poll() is None and time.monotonic() < deadline, "partial body checkpoint was not reached")
                owner.pump(.01)
            with Client(binary, directory, extra=fixture.options()) as client:
                pending = cached(client, "cache.activity")
                require(pending["inboxArrivalCount"] == 0, "metadata intermediate commit advanced arrivals")
                require(metrics(client)["historyId"] == "1000", "body hold happened after checkpoint advancement")
                ids = {message["id"] for message in cached(client, "mail.list", label="INBOX")["messages"]}
                require({"shared-msg-097", "shared-msg-098"} <= ids, "replay did not begin after committed added metadata")
                coalesced = client.request("mail.refresh", label="INBOX", limit=32)
                require(coalesced["coalesced"] and coalesced["refreshInProgress"] and coalesced["inboxArrivalCount"] == 0,
                        "lease coalescing advanced arrival count")
            owner.process.send_signal(signal.SIGTERM)
            stopped = owner.wait(seconds=5)
            require(stopped["interrupted"], "partial refresh did not cancel")
        finally:
            owner.close();hold.unlink(missing_ok=True)
        with Client(binary, directory, extra=fixture.options()) as client:
            require(cached(client, "cache.activity")["inboxArrivalCount"] == 0, "canceled partial job counted arrivals")
        fixture.stage(ACCOUNTS[0], "delta")
        native(binary, directory, fixture, "--force")
        with Client(binary, directory, extra=fixture.options()) as client:
            require(cached(client, "cache.activity")["inboxArrivalCount"] == 2 and metrics(client)["historyId"] == "1001",
                    "replaying already-cached metadata lost or duplicated arrivals")
        native(binary, directory, fixture, "--force")
        with Client(binary, directory, extra=fixture.options()) as client:
            require(cached(client, "cache.activity")["inboxArrivalCount"] == 2, "completed replay counted twice")
        return {"metadataBeforeCheckpointCounter": 0, "canceledCounter": 0, "replayedCounter": 2,
                "coalescedCounter": 0, "sameCheckpointCounter": 2}
    raise AssertionError("unknown background case")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--build-mode", type=build_mode, default="debug")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--case", choices=CASES)
    args = parser.parse_args()
    binary = args.binary.resolve()
    require(not args.output.exists(), "refusing to overwrite background evidence")
    report = {**read_build_info(binary, args.build_mode), "binarySha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "syntheticOnly": True, "systemdInvoked": False, "desktopUsed": False, "realCredentialUse": False, "cases": []}
    with tempfile.TemporaryDirectory(prefix="omagma-bg-fixture-") as temporary:
        for name in (args.case,) if args.case else CASES:
            directory = Path(temporary) / name
            directory.mkdir(mode=0o700)
            began = time.monotonic()
            item = {"name": name}
            try: item.update(run_case(binary, directory, name), passed=True)
            except Exception as error: item.update(passed=False, error=f"{type(error).__name__}: {error}")
            item["elapsedSeconds"] = round(time.monotonic() - began, 4)
            report["cases"].append(item)
            print(json.dumps(item), flush=True)
            if not item["passed"]: break
    report["passed"] = len(report["cases"]) == (1 if args.case else len(CASES)) and all(item["passed"] for item in report["cases"])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
