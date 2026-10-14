#!/usr/bin/env python3
"""Actual native browser argv for meeting links, using a synthetic executable.

Run under the cooperative host lock. No browser, desktop, credentials, provider
requests or production profiles are used. Calendar TUI request-capture tests
separately verify the event's account is passed to this browser.open command.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from build_info import read_build_info
from terminal_integration import no_core_dump, require


def run(binary, directory):
    profiles = ("Profile 7", "Profile 12", "Profile 4")
    accounts = tuple(f"calendar-{index}@example.test" for index in range(3))
    chrome_data = directory / "existing Chrome data with spaces"
    receipts = directory / "launches"
    receipts.mkdir()
    for profile in profiles:
        (chrome_data / profile).mkdir(parents=True)
    browser = directory / "synthetic chrome"
    browser.write_text(
        f"#!{sys.executable}\n"
        "import json, os, pathlib, sys\n"
        f"root = pathlib.Path({str(receipts)!r})\n"
        "temporary = root / (str(os.getpid()) + '.pending')\n"
        "temporary.write_text(json.dumps(sys.argv[1:]))\n"
        "temporary.rename(temporary.with_suffix('.json'))\n"
    )
    browser.chmod(0o700)
    configuration = directory / "synthetic-config.json"
    configuration.write_text(json.dumps({
        "chrome": str(browser), "chromeUserData": str(chrome_data),
        "accounts": [{"address": account, "profile": profile, "enabled": True,
                      "required": True} for account, profile in zip(accounts, profiles)],
    }))
    configuration.chmod(0o600)
    environment = dict(os.environ)
    environment["HOME"] = str(directory / "home")
    for name in ("CONFIG", "CACHE", "DATA", "STATE"):
        environment[f"XDG_{name}_HOME"] = str(directory / name.lower())
    for name in ("DISPLAY", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE",
                 "DBUS_SESSION_BUS_ADDRESS"):
        environment.pop(name, None)

    def request(account, url, error=None):
        raw = {"id": "join-profile", "cmd": "browser.open", "account": account, "url": url}
        result = subprocess.run(
            [str(binary), "cli", "--config", str(configuration),
             "--cache-dir", str(directory / "cache")],
            input=json.dumps(raw).encode() + b"\n", capture_output=True,
            env=environment, cwd=directory, timeout=10, preexec_fn=no_core_dump,
        )
        require(result.returncode == 0 and not result.stderr,
                "native browser command did not exit cleanly")
        frames = result.stdout.splitlines()
        require(len(frames) == 1, "browser command emitted unexpected frames")
        reply = json.loads(frames[0])
        require(reply.get("account") == account and reply.get("id") == raw["id"],
                "browser command lost the selected account or correlation")
        require(reply.get("ok") is (error is None), "unexpected native browser outcome")
        if error:
            require(reply.get("error", {}).get("code") == error,
                    "browser refusal omitted the expected reason")
        else:
            require(reply["data"]["opened"] and not reply["data"]["fixture"],
                    "browser test silently used fixture validation instead of launch")
        return reply

    for index, (account, profile) in enumerate(zip(accounts, profiles)):
        url = f"https://meet.example.test/room-{index}?source=calendar&token=synthetic%20value#join"
        reply = request(account, url)
        require(reply["data"]["profile"] == f"--profile-directory={profile}",
                "browser result used another account's Chrome profile")
        deadline = time.monotonic() + 3
        while len(list(receipts.glob("*.json"))) <= index and time.monotonic() < deadline:
            time.sleep(.01)
        launches = [json.loads(path.read_text()) for path in receipts.glob("*.json")]
        require(len(launches) == index + 1, "fake browser did not observe exactly one native launch")
        require([f"--profile-directory={profile}", f"--user-data-dir={chrome_data}", url]
                in launches, "actual Chrome argv lost the exact profile, configured data root or URL")

    request(accounts[0], "javascript:alert(1)", error="InvalidTarget")
    (chrome_data / profiles[1]).rmdir()
    request(accounts[1], "https://meet.example.test/missing-profile", error="ProfileMissing")
    require(len(list(receipts.glob("*.json"))) == 3, "refused Join opened another profile")
    return {"accounts": 3, "actualLaunches": 3, "configuredDataRoot": True,
            "missingProfileRefused": True, "unsafeUrlRefused": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()
    with tempfile.TemporaryDirectory(prefix="omagma-calendar-join-") as temporary:
        result = run(binary, Path(temporary))
    print(json.dumps({"build": read_build_info(binary), "calendarJoinProfile": result}))


if __name__ == "__main__":
    main()
