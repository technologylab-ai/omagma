#!/usr/bin/env python3
"""Portable update CLI checks; isolated private state and no network/Gmail."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve(strict=True))
    with tempfile.TemporaryDirectory(prefix="omagma-updates-") as temporary:
        root = Path(temporary)
        env = dict(os.environ, HOME=str(root), XDG_STATE_HOME=str(root / "state"),
                   XDG_CONFIG_HOME=str(root / "config"), XDG_CACHE_HOME=str(root / "cache"))

        def run(*arguments, fixtures=False, json_output=True):
            command = [binary, "updates", *arguments]
            if fixtures:
                command.append("--fixtures")
            if json_output:
                command.append("--json")
            result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=5)
            assert result.returncode == 0, (command, result.stdout, result.stderr)
            return json.loads(result.stdout) if json_output else result.stdout

        # No configured accounts or grants, and no successful release lookup.
        status = run("status")
        assert status["ok"] and status["state"]["latest"] == ""
        assert not status["available"] and not status["noticeVisible"]
        assert not (root / "state").exists(), "Reading status must not create state"
        assert "no new gmail permission" in run("guide", json_output=False).lower()
        guide = run("guide")
        assert "guide" in guide and "close" in guide["guide"].lower()

        run("automatic", "off")
        state_file = root / "state" / "omagma" / "updates.json"
        assert state_file.stat().st_mode & 0o077 == 0
        assert state_file.parent.stat().st_mode & 0o077 == 0
        assert run("status")["state"]["manualOnly"] is True
        run("automatic", "on")
        assert run("status")["state"]["manualOnly"] is False

        state = json.loads(state_file.read_text())
        state.update(latest="99.0.0", releaseUrl="https://github.com/technologylab-ai/omagma/releases/tag/v99.0.0",
                     checkedAt=int(time.time()), nextCheckAt=int(time.time()) + 86400)
        state_file.write_text(json.dumps(state))
        pending = run("status")
        if pending["installation"]["method"] != "homebrew":
            assert pending["available"] and pending["noticeVisible"]
        run("dismiss")
        dismissed = run("status")
        assert dismissed["state"]["dismissed"] == "99.0.0" and not dismissed["noticeVisible"]
        state = json.loads(state_file.read_text())
        state.update(latest="99.0.1", releaseUrl="https://github.com/technologylab-ai/omagma/releases/tag/v99.0.1")
        state_file.write_text(json.dumps(state))
        if pending["installation"]["method"] != "homebrew":
            assert run("status")["noticeVisible"], "Dismissal applies only to the exact version"

        # A manual check must honor an unexpired server retry delay without
        # attempting a network connection, even when the user presses Check again.
        state["blockedUntil"] = int(time.time()) + 3600
        state_file.write_text(json.dumps(state))
        blocked = run("check")
        assert "asked us to wait" in blocked["state"]["errorMessage"]

        # Fixture checks/changes ignore and never replace a real cache.
        state_file.write_text("intentionally malformed private state")
        for arguments in (("status",), ("check",), ("guide",), ("dismiss",), ("automatic", "off")):
            fixture = run(*arguments, fixtures=True)
            assert fixture["ok"] and fixture["installation"]["method"] == "omarchy_source"
            assert "omarchy plugin update io.github.technologylab_ai.omagma" in fixture["commands"]
            assert "source only" in fixture["commands"]
            assert state_file.read_text() == "intentionally malformed private state"

        help_result = subprocess.run([binary, "updates", "--help"], env=env,
                                     capture_output=True, text=True, timeout=5)
        assert help_result.returncode == 0 and "omagma updates" in help_result.stdout
        unknown = subprocess.run([binary, "updates", "nonsense"], env=env,
                                 capture_output=True, text=True, timeout=5)
        assert unknown.returncode != 0 and "--help" in unknown.stderr
    print("Update CLI: private cache, exact dismissal, retry delay, guides and no-account/fixture isolation passed")


if __name__ == "__main__":
    main()
