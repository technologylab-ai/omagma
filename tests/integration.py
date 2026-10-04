#!/usr/bin/env python3
"""Behavioral daemon tests; no Google account or desktop installation is needed."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import time
import traceback
from urllib.parse import parse_qs, unquote, urlparse

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = json.loads((ROOT / "tests/fixtures/contract.json").read_text())
ACCOUNTS = [item["address"] for item in CONTRACT["accounts"]]
REQUIRED = ACCOUNTS[:2]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def proc_sample(pid):
    """Current Linux process values, separately from application allocator metrics."""
    status = {}
    for line in Path(f"/proc/{pid}/status").read_text().splitlines():
        key, _, value = line.partition(":")
        if key in {"VmRSS", "VmHWM", "Threads"}:
            status[key] = int(value.split()[0])
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    status["cpuTicks"] = int(fields[11]) + int(fields[12])
    status["monotonic"] = time.monotonic()
    return status


class Daemon:
    """A bounded JSON-lines test client which can intentionally stop draining stdout."""
    def __init__(self, binary, config=None, extra=(), dry_run_open=True, fixture_mode=True):
        self.expected_accounts = [a["address"] for a in json.loads(Path(config).read_text())["accounts"]] if config else ACCOUNTS
        argv = [str(binary), "daemon"]
        if fixture_mode:
            argv.append("--fixtures")
        if dry_run_open:
            argv.append("--dry-run-open")
        if config:
            argv += ["--config", str(config)]
        argv += list(extra)
        self.process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, bufsize=0)
        self.selector = selectors.DefaultSelector()
        for stream, name in [(self.process.stdout, "stdout"), (self.process.stderr, "stderr")]:
            os.set_blocking(stream.fileno(), False)
            self.selector.register(stream, selectors.EVENT_READ, name)
        os.set_blocking(self.process.stdin.fileno(), False)
        self.buffer = bytearray()
        self.stderr = bytearray()
        self.replies = {}
        self.snapshots = {}
        self.generations = {}
        self.id = 0
        self.frame_count = 0
        self.event_count = 0
        self.error_count = 0
        self.overflow_events = 0
        self.largest_frame = 0

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
        self.selector.close()
        for stream in [self.process.stdin, self.process.stdout, self.process.stderr]:
            if not stream.closed:
                stream.close()

    def raw(self, data, timeout=5, pump=True):
        deadline = time.monotonic() + timeout
        view = memoryview(data)
        while view:
            try:
                written = os.write(self.process.stdin.fileno(), view)
                view = view[written:]
            except BlockingIOError:
                require(time.monotonic() < deadline, "stdin stopped consuming during output backpressure")
                if pump:
                    self.pump(0.005)
                else:
                    time.sleep(0.005)

    def send(self, cmd, **fields):
        self.id += 1
        frame = {"id": self.id, "cmd": cmd, **fields}
        self.raw(json.dumps(frame, separators=(",", ":")).encode() + b"\n")
        return self.id

    def request(self, cmd, timeout=8, **fields):
        req_id = self.send(cmd, **fields)
        self.until(lambda: req_id in self.replies, timeout)
        return self.replies.pop(req_id)

    def accept(self, frame):
        require(isinstance(frame, dict), "output frame must be a JSON object")
        self.frame_count += 1
        if frame.get("ev") == "snapshot":
            self.event_count += 1
            address = frame.get("account")
            require(address in self.expected_accounts, "snapshot omitted explicit configured account")
            generation = frame.get("generation")
            require(type(generation) is int, "snapshot generation is not an integer")
            require(generation > self.generations.get(address, -1), "out-of-order/duplicate snapshot generation")
            self.generations[address] = generation
            self.snapshots[address] = frame
            validate_snapshot(frame, self.expected_accounts)
        elif frame.get("ev") == "error":
            require(frame.get("error") == "ReplyWindowExceeded", "unknown protocol error event")
            self.error_count += 1
            self.overflow_events += 1
        elif "re" in frame:
            if not frame.get("ok"):
                self.error_count += 1
            if frame["re"] is not None:
                self.replies[frame["re"]] = frame
        else:
            raise AssertionError("stdout contained neither reply nor snapshot")

    def pump(self, timeout=0.02):
        for key, _ in self.selector.select(timeout):
            try:
                block = os.read(key.fileobj.fileno(), 65536)
            except BlockingIOError:
                continue
            if not block:
                self.selector.unregister(key.fileobj)
                continue
            if key.data == "stderr":
                self.stderr.extend(block)
                self.stderr = self.stderr[-16384:]
                continue
            self.buffer.extend(block)
            while b"\n" in self.buffer:
                line, _, remaining = self.buffer.partition(b"\n")
                self.buffer = bytearray(remaining)
                self.largest_frame = max(self.largest_frame, len(line))
                require(len(line) <= CONTRACT["maxOutputBytes"], "output frame exceeded hard cap")
                require(bool(line), "empty stdout frame")
                self.accept(json.loads(line))
            require(len(self.buffer) <= CONTRACT["maxOutputBytes"], "unterminated output exceeded hard cap")

    def until(self, predicate, timeout=8):
        deadline = time.monotonic() + timeout
        while not predicate():
            require(self.process.poll() is None, f"daemon exited {self.process.returncode}; stderr={self.stderr.decode(errors='replace')}")
            require(time.monotonic() < deadline, "daemon response deadline exceeded")
            self.pump(min(0.05, max(0, deadline - time.monotonic())))

    def settle(self, timeout=8):
        deadline = time.monotonic() + timeout
        while True:
            status = self.request("status")
            require(status.get("ok"), "status failed")
            metrics = status.get("metrics", {})
            validate_metrics(metrics)
            if metrics["activeJobs"] == 0 and metrics["pendingJobs"] == 0:
                return status
            require(time.monotonic() < deadline, "refreshes never settled")
            self.pump(0.01)

    def current(self, address, after=-1):
        self.until(lambda: self.snapshots.get(address, {}).get("state") == "current"
                   and self.snapshots[address]["generation"] > after)
        return self.snapshots[address]

    def hello(self):
        reply = self.request("hello")
        require(reply.get("ok") and reply.get("version") == 1, "invalid hello/version")
        snapshots = reply.get("accounts", [])
        require({item.get("account") for item in snapshots} == set(self.expected_accounts), "hello account slots differ")
        for snapshot in snapshots:
            validate_snapshot(snapshot, self.expected_accounts)
            self.snapshots[snapshot["account"]] = snapshot
        validate_metrics(reply.get("metrics", {}))
        return reply


def validate_snapshot(snapshot, allowed_accounts=ACCOUNTS):
    require(snapshot.get("account") in allowed_accounts, "snapshot account missing")
    require(snapshot.get("state") in {"never", "loading", "current", "stale", "disconnected", "unavailable"}, "unknown state")
    require(type(snapshot.get("generation")) is int, "generation missing")
    require(type(snapshot.get("checkedAt")) is int, "checkedAt missing")
    messages = snapshot.get("messages")
    require(isinstance(messages, list) and len(messages) <= 30, "message model exceeded 30 rows")
    require(snapshot.get("unread") is None or type(snapshot["unread"]) is int, "unread count missing")
    require(type(snapshot.get("partial")) is bool, "partial missing")
    for row in messages:
        for field in ["id", "threadId", "sender", "subject", "snippet"]:
            require(isinstance(row.get(field), str), f"message field {field} missing")
        require(len(row["id"].encode()) <= 128 and len(row["threadId"].encode()) <= 128, "identifier exceeds declared cap")
        require(len(row["sender"].encode()) <= 512 and len(row["subject"].encode()) <= 512, "display field exceeds cap")
        require(len(row["snippet"].encode()) <= 1024, "snippet exceeds cap")
        require(type(row.get("receivedAt")) is int and type(row.get("unread")) is bool, "message time/unread missing")
        require(not any(ord(c) < 32 or ord(c) == 127 for c in row["sender"] + row["subject"] + row["snippet"]), "display controls were not sanitized")
    times = [row["receivedAt"] for row in messages]
    require(times == sorted(times, reverse=True), "recent snapshot is not newest first")


def validate_metrics(metrics):
    require(metrics.get("reservationBytes") == CONTRACT["reservationBytes"], "application budget missing or changed")
    require(0 <= metrics.get("retainedRows", -1) <= 90, "retained row count is unbounded")
    require(0 <= metrics.get("activeJobs", -1) <= 1, "more than one active worker")
    require(0 <= metrics.get("pendingJobs", -1) <= 3, "pending jobs exceeded account slots")
    for field in ["snapshotBytes", "httpPeakBytes", "jsonPeakBytes", "rejectedAllocations", "refreshJobs"]:
        require(type(metrics.get(field)) is int and metrics[field] >= 0, f"metric {field} missing")
    require(metrics["snapshotBytes"] <= 2 * 1024 * 1024, "snapshot storage exceeded budget")
    require(metrics["httpPeakBytes"] <= 8 * 1024 * 1024, "HTTP allocation exceeded budget")
    require(metrics["jsonPeakBytes"] <= 2 * 1024 * 1024, "JSON allocation exceeded budget")


def check_reply(reply, ok=True):
    require(reply.get("ok") is ok, f"unexpected reply: {reply}")
    return reply


def account_isolation(binary, config):
    with Daemon(binary, config) as daemon:
        daemon.hello()
        check_reply(daemon.request("refresh", account=REQUIRED[0]), False)
        check_reply(daemon.request("visibility", open=True, account=REQUIRED[0]))
        first = daemon.current(REQUIRED[0])
        check_reply(daemon.request("select", account=REQUIRED[1]))
        second = daemon.current(REQUIRED[1])
        left = {row["id"]: row for row in first["messages"]}
        right = {row["id"]: row for row in second["messages"]}
        shared = set(left) & set(right)
        require(shared, "fixtures need conflicting message IDs across required accounts")
        for message_id in shared:
            require(left[message_id]["subject"] != right[message_id]["subject"], "conflicting IDs leaked subject across accounts")
            require(left[message_id]["sender"] != right[message_id]["sender"], "conflicting IDs leaked sender across accounts")
        for snapshot in [first, second]:
            require(any(row["unread"] for row in snapshot["messages"]), "unread fixture absent")
            require(any(not row["unread"] for row in snapshot["messages"]), "already-read mail is omitted")
            require(snapshot["checkedAt"] > 0, "successful refresh has no last-check time")
        check_reply(daemon.request("select", account=ACCOUNTS[2]))
        status = daemon.settle()
        states = {item["account"]: item for item in status["accounts"]}
        require(states[ACCOUNTS[2]]["state"] == "unavailable", "optional account should be unavailable")
        require(states[REQUIRED[0]]["messages"] == first["messages"], "optional failure altered first account")
        require(states[REQUIRED[1]]["messages"] == second["messages"], "optional failure altered second account")
        require(status["selected"] == ACCOUNTS[2], "selection failed")
        for item in CONTRACT["accounts"]:
            result = check_reply(daemon.request("open", account=item["address"], kind="inbox"))
            argv = result.get("argv")
            require(isinstance(argv, list) and len(argv) == 3, "browser argv missing")
            require(argv[0] == "/usr/bin/google-chrome-stable", "unexpected browser executable")
            require(argv[1] == f"--profile-directory={item['profile']}", "wrong account Chrome profile")
            parsed = urlparse(argv[2])
            require(parsed.scheme == "https" and parsed.netloc == "mail.google.com", "untrusted browser target")
            require(parse_qs(parsed.query).get("authuser") == [item["address"]], "browser account routing missing")
        message_id = sorted(shared)[0]
        result = check_reply(daemon.request("open", account=REQUIRED[1], kind="message", message=message_id))
        require(right[message_id]["threadId"] in unquote(result["argv"][2]), "message link lost opaque thread identity")
        require(parse_qs(urlparse(result["argv"][2]).query).get("authuser") == [REQUIRED[1]], "message link used wrong account")
        require(result["argv"][1] == "--profile-directory=Profile 1", "message link used wrong profile")
        fallback = check_reply(daemon.request("open", account=REQUIRED[1], kind="message", message=message_id, fallback=True))
        require(unquote(urlparse(fallback["argv"][2]).fragment).startswith("search/rfc822msgid:"), "valid Message-ID search fallback missing")
        require("rfc822msgid%3A" in fallback["argv"][2], "Message-ID query was not URL encoded")
        check_reply(daemon.request("open", account=REQUIRED[1], kind="message", message="missing-fixture-id"), False)
        check_reply(daemon.request("open", account=REQUIRED[0], kind="message", message="x" * 129), False)
        return {"conflictingIds": len(shared), "rowsPerRequiredAccount": [len(first["messages"]), len(second["messages"])], "largestFrameBytes": daemon.largest_frame}


def overlap_and_close(binary, config):
    with Daemon(binary, config, ["--fixture-delay-ms", "250"]) as daemon:
        daemon.hello()
        check_reply(daemon.request("visibility", open=True, account=REQUIRED[0]))
        before = daemon.request("status")["metrics"]["refreshJobs"]
        ids = [daemon.send("refresh", account=REQUIRED[index % 2]) for index in range(80)]
        ids.append(daemon.send("select", account=REQUIRED[1]))
        daemon.until(lambda: all(req_id in daemon.replies for req_id in ids))
        for req_id in ids:
            check_reply(daemon.replies.pop(req_id))
        status = daemon.settle()
        started = status["metrics"]["refreshJobs"] - before
        require(started < 12, "refresh clicks appended work instead of coalescing")
        require(status["selected"] == REQUIRED[1], "overlap changed selected account")
        require(all(item["state"] == "current" for item in status["accounts"] if item["account"] in REQUIRED), "overlap did not deliver both required snapshots")
        previous = {item["account"]: item for item in status["accounts"]}
        check_reply(daemon.request("refresh", account=REQUIRED[0]))
        check_reply(daemon.request("visibility", open=False, account=REQUIRED[0]))
        closed = daemon.settle()
        closed_jobs = closed["metrics"]["refreshJobs"]
        event_count = daemon.event_count
        deadline = time.monotonic() + 0.6
        while time.monotonic() < deadline:
            daemon.pump(0.03)
        require(daemon.event_count == event_count, "closed popup published late refresh results")
        again = daemon.request("status")
        require(again["metrics"]["refreshJobs"] == closed_jobs, "closed popup scheduled mailbox work")
        check_reply(daemon.request("refresh", account=REQUIRED[0]), False)
        current = {item["account"]: item for item in again["accounts"]}
        require(current[REQUIRED[0]]["messages"] == previous[REQUIRED[0]]["messages"], "cancel discarded cached mail")
        require(current[REQUIRED[0]]["state"] == previous[REQUIRED[0]]["state"], "closing downgraded a successful account")
        require(current[REQUIRED[0]]["error"] == previous[REQUIRED[0]]["error"], "closing invented an account error")
        check_reply(daemon.request("visibility", open=True, account=REQUIRED[0]))
        daemon.until(lambda: daemon.snapshots[REQUIRED[0]]["generation"] >= current[REQUIRED[0]]["generation"]
                     and daemon.snapshots[REQUIRED[0]]["state"] != "loading")
        require(daemon.snapshots[REQUIRED[0]]["messages"] == previous[REQUIRED[0]]["messages"], "reopening lost cancelled account cache")
        check_reply(daemon.request("visibility", open=False, account=REQUIRED[0]))
        return {"burstClicks": 80, "coalescedJobs": started, "closedJobs": closed_jobs}


def cancel_before_first_fetch(binary, config):
    with Daemon(binary, config, ["--fixture-delay-ms", "250"]) as daemon:
        daemon.hello()
        check_reply(daemon.request("visibility", open=True, account=REQUIRED[0]))
        daemon.until(lambda: daemon.request("status")["metrics"]["activeJobs"] == 1)
        check_reply(daemon.request("visibility", open=False, account=REQUIRED[0]))
        status = daemon.settle()
        account = next(a for a in status["accounts"] if a["account"] == REQUIRED[0])
        require(account["state"] == "never" and account["error"] == "", "first-fetch cancellation invented failure")
        require(account["messages"] == [] and account["checkedAt"] == 0, "cancelled first fetch invented cached mail")
        check_reply(daemon.request("visibility", open=True, account=REQUIRED[0]))
        loaded = daemon.current(REQUIRED[0])
        require(loaded["error"] == "", "reopened first fetch retained cancellation error")
        return {"cancelledFirstFetchState": account["state"], "reopenedState": loaded["state"]}


def background_refresh(binary, config):
    with Daemon(binary, config, ["--fixture-auto-refresh-ms", "200", "--fixture-delay-ms", "20"]) as daemon:
        hello = daemon.hello()
        enabled = [a["account"] for a in hello["accounts"] if a["enabled"]]
        require(enabled, "background fixture has no enabled accounts")
        def ready():
            status = daemon.request("status")
            return all(a["state"] == "current" for a in status["accounts"] if a["enabled"])
        daemon.until(ready)
        before = daemon.request("status")
        events = daemon.event_count
        peak_active, peak_pending = 0, 0
        deadline = time.monotonic() + .7
        while time.monotonic() < deadline:
            status = daemon.request("status")
            peak_active = max(peak_active, status["metrics"]["activeJobs"])
            peak_pending = max(peak_pending, status["metrics"]["pendingJobs"])
            daemon.pump(.025)
        after = daemon.request("status")
        require(after["metrics"]["refreshJobs"] >= before["metrics"]["refreshJobs"] + len(enabled), "closed timer did not refresh accounts")
        require(daemon.event_count == events, "background updates emitted closed-popup snapshots")
        closed_events_added = daemon.event_count - events
        require(peak_active <= 1 and peak_pending <= 3, "background polling appended unbounded work")
        for item in after["accounts"]:
            if not item["enabled"]:
                require(item["state"] == "unavailable" and item["messages"] == [], "background polling touched disabled account")
        check_reply(daemon.request("visibility", open=True, account=enabled[-1]))
        daemon.until(lambda: bool(daemon.snapshots[enabled[-1]]["messages"]))
        require(daemon.snapshots[enabled[-1]]["checkedAt"] > 0, "reopening did not deliver background cache")
        check_reply(daemon.request("visibility", open=False, account=enabled[-1]))
        check_reply(daemon.request("disconnect", account=enabled[0]))
        disconnected = next(a for a in daemon.request("status")["accounts"] if a["account"] == enabled[0])
        deadline = time.monotonic() + .5
        while time.monotonic() < deadline:
            daemon.pump(.025)
        final = next(a for a in daemon.request("status")["accounts"] if a["account"] == enabled[0])
        require(final["state"] == "disconnected" and final["messages"] == [] and final["generation"] == disconnected["generation"], "background polling retried disconnected account")
        return {"enabledAccounts": len(enabled), "jobsAddedWhileClosed": after["metrics"]["refreshJobs"] - before["metrics"]["refreshJobs"],
                "closedSnapshotsAdded": closed_events_added, "maxActive": peak_active, "maxPending": peak_pending,
                "disconnectedAccountSkipped": True}


def background_shutdown(binary, config):
    with Daemon(binary, config, ["--fixture-auto-refresh-ms", "100", "--fixture-delay-ms", "250"]) as daemon:
        daemon.hello()
        daemon.until(lambda: daemon.request("status")["metrics"]["activeJobs"] == 1)
        started = time.monotonic()
        daemon.process.stdin.close()
        daemon.process.wait(timeout=2)
        require(daemon.process.returncode == 0, "background daemon failed during owner shutdown")
        return {"shutdownSeconds": round(time.monotonic() - started, 4), "exitCode": daemon.process.returncode}


def empty_and_failure(binary, config):
    with Daemon(binary, config, ["--fixture-empty-account", REQUIRED[0], "--fixture-fail-account", REQUIRED[1]]) as daemon:
        daemon.hello()
        check_reply(daemon.request("visibility", open=True, account=REQUIRED[0]))
        snapshot = daemon.current(REQUIRED[0])
        require(snapshot["messages"] == [] and snapshot["unread"] == 0, "empty Inbox was not a successful zero result")
        check_reply(daemon.request("select", account=REQUIRED[1]))
        status = daemon.settle()
        states = {item["account"]: item for item in status["accounts"]}
        require(states[REQUIRED[1]]["state"] != "current" and states[REQUIRED[1]]["error"], "failure was presented as current empty Inbox")
        require(states[REQUIRED[0]]["state"] == "current", "another account's failure contaminated successful account")
        return {"emptyState": snapshot["state"], "failedState": states[REQUIRED[1]]["state"]}


def failed_refresh_preserves(binary, config):
    with Daemon(binary, config, ["--fixture-fail-after", "1"]) as daemon:
        daemon.hello()
        check_reply(daemon.request("visibility", open=True, account=REQUIRED[0]))
        before = daemon.current(REQUIRED[0])
        daemon.settle()
        check_reply(daemon.request("refresh", account=REQUIRED[0]))
        status = daemon.settle()
        after = next(item for item in status["accounts"] if item["account"] == REQUIRED[0])
        require(after["state"] == "stale" and after["error"], "failed refresh must surface stale/error")
        require(after["messages"] == before["messages"], "failed refresh replaced cached mail")
        require(after["checkedAt"] == before["checkedAt"], "failed refresh advanced successful check timestamp")
        require(after["generation"] > before["generation"], "failure did not advance state generation")
        check_reply(daemon.request("select", account=REQUIRED[1]))
        daemon.current(REQUIRED[1])
        return {"cachedRowsPreserved": len(after["messages"]), "failureState": after["state"]}


def frame_recovery(binary, config):
    with Daemon(binary, config) as daemon:
        daemon.hello()
        bad = [b"not-json\n", b"[]\n", b'{"id":-1,"cmd":"hello"}\n',
               b'{"id":9007199254740992,"cmd":"hello"}\n', b'{"id":1.5,"cmd":"hello"}\n',
               b'{"id":"2","cmd":"hello"}\n', b'{"id":4,"cmd":null}\n',
               b'{"id":7,"cmd":"hello","padding":"' + b"x" * 131072 + b'"}\n',
               b'{"id":42000,"id":42001,"cmd":"hello"}\n',
               b'{"id":42002,"cmd":"hello","extra":' + b"[" * 66 + b"0" + b"]" * 66 + b"}\n"]
        before = daemon.error_count
        for frame in bad:
            daemon.raw(frame)
            check_reply(daemon.request("status"))
        require(daemon.error_count - before >= len(bad), "malformed/oversized frames were silently accepted")
        check_reply(daemon.request("unknown_command"), False)
        check_reply(daemon.request("select", account="unconfigured@example.test"), False)
        check_reply(daemon.request("hello"))
        return {"badFrames": len(bad), "errors": daemon.error_count - before, "largestFrameBytes": daemon.largest_frame}


def restart(binary, config):
    with Daemon(binary, config) as daemon:
        daemon.hello()
        daemon.request("visibility", open=True, account=REQUIRED[0])
        daemon.current(REQUIRED[0])
        daemon.process.kill()
        daemon.process.wait()
    with Daemon(binary, config) as daemon:
        reply = daemon.hello()
        required = [item for item in reply["accounts"] if item["account"] in REQUIRED]
        require(all(item["state"] == "never" and item["messages"] == [] and item["checkedAt"] == 0 for item in required), "restart retained cached mail or last-check time")
        require(reply["metrics"]["refreshJobs"] == 0, "restart began periodic refresh work")
        return {"requiredAccountsReset": len(required)}


def configuration_and_missing_profile(binary, _config):
    with tempfile.TemporaryDirectory(prefix="omagma-config-test-") as directory:
        location = Path(directory)
        config = {"chrome": "/usr/bin/google-chrome-stable", "chromeUserData": str(location / "absent-user-data"),
                  "accounts": [{"address": item["address"], "profile": item["profile"], "enabled": item["required"], "required": item["required"]} for item in CONTRACT["accounts"]]}
        path = location / "config.json"
        path.write_text(json.dumps(config))
        # An absent synthetic user-data directory guarantees Chrome cannot launch,
        # while testing the ordinary launcher path instead of the dry-run shortcut.
        with Daemon(binary, path, dry_run_open=False) as daemon:
            daemon.hello()
            missing = check_reply(daemon.request("open", account=REQUIRED[0], kind="inbox"), False)
            require("profile" in missing.get("error", "").lower(), "missing profile did not give a configuration error")
        invalid = []
        duplicate = json.loads(json.dumps(config))
        duplicate["accounts"][1]["profile"] = duplicate["accounts"][0]["profile"]
        invalid.append(duplicate)
        duplicate = json.loads(json.dumps(config))
        duplicate["accounts"][1]["address"] = duplicate["accounts"][0]["address"]
        invalid.append(duplicate)
        excessive = json.loads(json.dumps(config))
        excessive["accounts"].append({"address": "fourth@example.test", "profile": "Profile 4"})
        invalid.append(excessive)
        bad_profile = json.loads(json.dumps(config))
        bad_profile["accounts"][0]["profile"] = "../Default"
        invalid.append(bad_profile)
        for interval in [-1, 59, 86401, "300", 300.5]:
            bad_interval = json.loads(json.dumps(config))
            bad_interval["refreshIntervalSeconds"] = interval
            invalid.append(bad_interval)
        for item in invalid:
            path.write_text(json.dumps(item))
            process = subprocess.run([str(binary), "daemon", "--fixtures", "--dry-run-open", "--config", str(path)],
                                     input=b'{"id":1,"cmd":"hello"}\n', capture_output=True, timeout=3)
            require(process.returncode != 0, "invalid account/profile configuration was accepted")
        return {"invalidConfigurationsRejected": len(invalid), "missingProfileError": missing["error"]}


def configured_account_slots(binary, _config):
    with tempfile.TemporaryDirectory(prefix="omagma-slots-test-") as directory:
        path = Path(directory) / "config.json"
        address = "solo@custom.example"
        path.write_text(json.dumps({"accounts": [{"address": address, "profile": "Profile 7", "enabled": True}]}))
        with Daemon(binary, path) as daemon:
            hello = daemon.hello()
            require(len(hello["accounts"]) == 1 and hello["selected"] == address, "configured account retained example slots")
            check_reply(daemon.request("visibility", open=True, account=address))
            loaded = daemon.current(address)
            require(loaded["messages"], "configured account did not load fixture mail")
            opened = check_reply(daemon.request("open", account=address, kind="message", message=loaded["messages"][0]["id"]))
            require("--profile-directory=Profile 7" in opened["argv"], "custom account lost its configured profile")
            check_reply(daemon.request("select", account=REQUIRED[0]), False)
            require(daemon.request("status")["selected"] == address, "unknown example account changed selection")
            return {"configuredSlots": 1, "customProfileRouted": True, "exampleAddressRejected": True}


def maximum_capacity(binary, _config):
    with Daemon(binary, ROOT / "tests/fixtures/all-accounts.json", ["--fixture-rows", "30"]) as daemon:
        daemon.hello()
        check_reply(daemon.request("visibility", open=True, account=ACCOUNTS[0]))
        daemon.current(ACCOUNTS[0])
        for address in ACCOUNTS[1:]:
            check_reply(daemon.request("select", account=address))
            daemon.current(address)
        status = daemon.settle()
        require(status["metrics"]["retainedRows"] == 90, "full three-account capacity was not retained")
        for snapshot in status["accounts"]:
            require(len(snapshot["messages"]) == 30, "configured account failed 30-row capacity")
        subjects = {item["account"]: {row["id"]: row["subject"] for row in item["messages"]} for item in status["accounts"]}
        for index, address in enumerate(ACCOUNTS):
            other = ACCOUNTS[(index + 1) % len(ACCOUNTS)]
            shared = subjects[address].keys() & subjects[other].keys()
            require(shared and all(subjects[address][mid] != subjects[other][mid] for mid in shared), "full-capacity conflicting IDs leaked account data")
        return {"retainedRows": status["metrics"]["retainedRows"], "largestFrameBytes": daemon.largest_frame}


def stdout_backpressure(binary, config):
    with Daemon(binary, config, ["--fixture-delay-ms", "600"]) as daemon:
        fcntl.fcntl(daemon.process.stdout.fileno(), fcntl.F_SETPIPE_SZ, 4096)
        daemon.hello()
        check_reply(daemon.request("visibility", open=True, account=REQUIRED[0]))
        before = proc_sample(daemon.process.pid)
        # This input is deliberately written without draining stdout. It saturates
        # stdout and the bounded reply queue, then puts cancellation behind it.
        commands = []
        for _ in range(220):
            daemon.id += 1
            commands.append({"id": daemon.id, "cmd": "status"})
        daemon.id += 1
        commands.append({"id": daemon.id, "cmd": "visibility", "open": False, "account": REQUIRED[0]})
        payload = b"".join(json.dumps(item, separators=(",", ":")).encode() + b"\n" for item in commands)
        started = time.monotonic()
        daemon.raw(payload, timeout=2, pump=False)
        write_seconds = time.monotonic() - started
        time.sleep(0.8)
        blocked = proc_sample(daemon.process.pid)
        require(blocked["VmRSS"] - before["VmRSS"] <= 8192, "stdout backlog grew process memory beyond fixed queues")
        # The final reply need not survive reply-queue saturation. A fresh command
        # proves the child recovered, and cancellation's side effect must survive.
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            daemon.pump(0.01)
        status = daemon.settle()
        require(daemon.overflow_events >= 1, "reply saturation did not report dropped replies")
        check_reply(daemon.request("refresh", account=REQUIRED[0]), False)
        require(status["metrics"]["activeJobs"] == 0 and status["metrics"]["pendingJobs"] == 0, "backpressure blocked cancellation")
        require(not any(item["state"] == "current" for item in status["accounts"] if item["account"] == REQUIRED[0]), "blocked stdout let cancelled job publish")
        return {"queuedCommands": len(commands), "writeSeconds": round(write_seconds, 4), "rssDeltaKiB": blocked["VmRSS"] - before["VmRSS"], "outputFrames": daemon.frame_count, "overflowEvents": daemon.overflow_events}


CASES = {"account_isolation": account_isolation, "overlap_and_close": overlap_and_close,
         "cancel_before_first_fetch": cancel_before_first_fetch,
         "background_refresh": background_refresh, "background_shutdown": background_shutdown,
         "empty_and_failure": empty_and_failure, "frame_recovery": frame_recovery,
         "failed_refresh_preserves": failed_refresh_preserves,
         "restart": restart, "configuration_and_missing_profile": configuration_and_missing_profile,
         "configured_account_slots": configured_account_slots,
         "maximum_capacity": maximum_capacity,
         "stdout_backpressure": stdout_backpressure}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "zig-out/bin/omagma")
    parser.add_argument("--config", type=Path)
    parser.add_argument("--build-mode", choices=["Debug", "ReleaseSafe"], default="Debug")
    parser.add_argument("--case", choices=CASES)
    parser.add_argument("--output", type=Path, default=ROOT / "tests/results/integration-debug.json")
    args = parser.parse_args()
    args.binary = args.binary.resolve()
    result = {"buildMode": args.build_mode, "binary": str(args.binary),
              "sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(), "syntheticOnly": True,
              "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "checks": {}}
    for name in [args.case] if args.case else CASES:
        started = time.monotonic()
        try:
            details = CASES[name](args.binary, args.config)
            result["checks"][name] = {"passed": True, "seconds": round(time.monotonic() - started, 4), **details}
            print(f"PASS {name}", flush=True)
        except Exception as error:
            result["checks"][name] = {"passed": False, "seconds": round(time.monotonic() - started, 4), "error": str(error)}
            print(f"FAIL {name}: {error}", flush=True)
            traceback.print_exc()
    result["passed"] = all(check["passed"] for check in result["checks"].values())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
