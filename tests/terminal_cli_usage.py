#!/usr/bin/env python3
"""Portable CLI usage regressions with isolated fictional state and no desktop.

Run under the cooperative host lease. Unknown argv/help/version paths use no
configured account. Protocol checks explicitly use disconnected fixtures; no
credentials, browser, keyring or live provider operation is requested.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import traceback

from build_info import build_mode, read_build_info
from terminal_integration import no_core_dump, require


HINT = b"Try omagma --help for available commands and options."
CANARY = "fictional-private-argument-canary"
LEGACY_MODES = ("daemon", "auth", "status")
FAMILIES = {
    "mail": ("list", "search", "read", "thread", "attachment", "open", "sync", "refresh", "recipients",
             "reply", "forward", "send", "archive", "trash", "restore", "mark", "batch", "undo", "prefetch",
             "drafts", "compose", "labels", "identities", "open-link", "open-attachment"),
    "draft": ("list", "read", "create", "update", "preview", "recovery-save", "send", "discard"),
    "contacts": ("list", "search", "upsert"),
    "invitations": ("inspect", "reply"),
    "cache": ("stats", "clear", "activity", "refresh-status"),
    "operation": ("list", "read"),
    "terminal-auth": ("status", "authorize", "revoke"),
}
VALUE_FLAGS = (
    "--config", "--metrics-file", "--grant-file", "--client-file", "--capabilities",
    "--fixture-root", "--fixture-scenario", "--cache-dir", "--ui-file", "--editor-mode",
    "--metadata-limit", "--cache-messages", "--prefetch-bodies", "--disk-limit-bytes", "--cache-bytes",
    "--account", "--action", "--undo-token", "--url", "--path", "--message-ids", "--message-id", "--id",
    "--before-message-id", "--after-message-id", "--boundary-received-at", "--format", "--from",
    "--limit", "--cursor", "--query", "--label", "--thread-id", "--draft-id", "--attachment-id",
    "--operation-id", "--status", "--to", "--cc", "--bcc", "--subject", "--body", "--attach-file",
    "--body-file", "--draft-file", "--contact-file", "--expected-etag", "--add-label", "--remove-label",
)


class Runner:
    def __init__(self, binary, directory):
        self.binary, self.directory = binary, directory
        self.environment = dict(os.environ)
        for key, name in (("HOME", "home"), ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache"),
                          ("XDG_DATA_HOME", "data"), ("XDG_STATE_HOME", "state"), ("XDG_RUNTIME_DIR", "runtime")):
            path = directory / name
            path.mkdir(mode=0o700)
            self.environment[key] = str(path)
        for key in ("DISPLAY", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS"):
            self.environment.pop(key, None)
        self.invalid_config = directory / "malformed-private-config.json"
        self.invalid_config.write_text("not a configured account or valid JSON\n")
        self.invalid_config.chmod(0o600)
        self.calls = 0

    def run(self, arguments, stdin=b"", without_home=False):
        environment = dict(self.environment)
        if without_home:
            environment.pop("HOME", None)
        result = subprocess.run([str(self.binary), *arguments], input=stdin, capture_output=True,
                                cwd=self.directory, env=environment, timeout=8, preexec_fn=no_core_dump)
        self.calls += 1
        require(len(result.stdout) <= 256 * 1024 and len(result.stderr) <= 16 * 1024,
                "CLI usage output exceeded its finite diagnostic bound")
        require(b"\x1b" not in result.stdout + result.stderr and b"\x00" not in result.stdout + result.stderr,
                "CLI usage output emitted raw terminal controls")
        require(CANARY.encode() not in result.stdout + result.stderr, "CLI diagnostic echoed raw private argv")
        return result

    def usage(self, arguments, error, **options):
        result = self.run(arguments, **options)
        require(result.returncode != 0 and result.stdout == b"", "argv usage error wrote protocol output or exited successfully")
        require(error.encode() in result.stderr, f"CLI usage error was not classified as {error}")
        require(result.stderr.count(HINT) == 1, "CLI usage error omitted or repeated the fixed help hint")
        return result


def guidance(runner):
    runner.usage(["nonsense"], "UnknownMode")
    runner.usage(["nonsense"], "UnknownMode", without_home=True)
    runner.usage(["--fictional-unknown-option"], "UnknownMode")
    for family in FAMILIES:
        runner.usage([family], "CommandRequired")
        runner.usage([family, CANARY], "UnknownCommand")
        runner.usage([family, CANARY, "--config", str(runner.invalid_config)], "UnknownCommand")
        runner.usage([family, CANARY, "--body-file", str(runner.directory / "absent-body")], "UnknownCommand")
        runner.usage([family, CANARY], "UnknownCommand", without_home=True)
    require(not list((runner.directory / "cache").iterdir()), "unknown command initialized an account cache")


def options(runner):
    for mode in ("tui", "cli", "agent"):
        runner.usage([mode, "--fictional-unknown-option"], "UnknownOption")
        runner.usage([mode, "--fictional-unknown-option", CANARY], "UnknownOption")
        runner.usage([mode, "--fictional-unknown-option"], "UnknownOption", without_home=True)
    for mode in LEGACY_MODES:
        runner.usage([mode, "--fictional-unknown-option"], "UnknownOption", without_home=True)
        runner.usage([mode, "--fictional-unknown-option", CANARY], "UnknownOption", without_home=True)
        runner.usage([mode, "--config"], "ConfigRequired", without_home=True)
        runner.usage([mode, "--account"], "AccountRequired", without_home=True)
    runner.usage(["mail", "list", "--fictional-unknown-option"], "UnknownOption")
    runner.usage(["mail", "list", "--fictional-unknown-option", CANARY], "UnknownOption")
    runner.usage(["mail", "list", CANARY], "UnknownOption")
    runner.usage(["mail", "list", "--config", str(runner.invalid_config), "--fictional-unknown-option"], "UnknownOption")
    for flag in VALUE_FLAGS:
        runner.usage(["mail", "list", flag], "ValueRequired")
    require(not list((runner.directory / "cache").iterdir()), "unknown/missing option initialized an account cache")


def help_paths(runner):
    for arguments in ([], ["--help"], ["help"], ["-h"]):
        result = runner.run(arguments, without_home=True)
        require(result.returncode == 0 and not result.stderr and b"omagma" in result.stdout,
                "top-level help required configuration or wrote an error")
    for mode in LEGACY_MODES:
        for flag in ("--help", "-h"):
            result = runner.run([mode, "--config", str(runner.invalid_config), flag], without_home=True)
            require(result.returncode == 0 and not result.stderr and b"Experimental terminal mail" in result.stdout,
                    "legacy command help loaded HOME/configuration or entered its runtime")
    for mode in ("tui", "cli", "agent", *FAMILIES):
        for flag in ("--help", "-h"):
            result = runner.run([mode, flag], without_home=True)
            require(result.returncode == 0 and not result.stderr and b"Experimental terminal mail" in result.stdout,
                    "terminal mode help required a configured account")
            lines = result.stdout.splitlines()
            require(any(b"omagma mail " in line and b"recipients" in line for line in lines)
                    and any(b"omagma draft " in line and b"preview" in line for line in lines),
                    "terminal help command listing omitted recipients or draft preview")
    for family, verbs in FAMILIES.items():
        for verb in verbs:
            result = runner.run([family, verb, "--config", str(runner.invalid_config), "--help"])
            require(result.returncode == 0 and not result.stderr and b"Experimental terminal mail" in result.stdout,
                    f"supported one-shot {family}/{verb} was denied or loaded configuration before help")


def protocol(runner):
    fixture_cache = runner.directory / "fixture-cache"
    common = ["--fixtures", "--cache-dir", str(fixture_cache)]
    failed = runner.run(["mail", "read", *common])
    reply = json.loads(failed.stdout)
    require(failed.returncode != 0 and reply.get("version") == 1 and reply.get("ok") is False
            and reply.get("error", {}).get("code") == "MissingField", "valid one-shot command lost its JSON error contract")
    require(HINT not in failed.stderr, "ordinary one-shot command error received an unrelated argv help hint")
    preview = runner.run(["draft", "preview", *common, "--account", "personal@example.com",
                          "--body", "**Hello**", "--format", "markdown"])
    reply = json.loads(preview.stdout)
    require(preview.returncode == 0 and not preview.stderr and reply.get("ok") is True
            and reply["data"]["bodyFormat"] == "markdown" and reply["data"]["bodyText"] == "**Hello**"
            and "<strong>Hello</strong>" in reply["data"]["bodyHtml"], "draft.preview was denied or lost Markdown source/rendered output")
    drafts = runner.run(["mail", "drafts", *common, "--account", "personal@example.com"])
    require(drafts.returncode == 0 and not drafts.stderr and json.loads(drafts.stdout)["data"]["drafts"] == [],
            "mail drafts alias was denied or preview saved an unsolicited draft")
    requests = (b"invalid JSON\n" + json.dumps({"id": "unknown", "cmd": "fictional.unknown",
                "account": "personal@example.com"}).encode() + b"\n" +
                json.dumps({"id": "accounts", "cmd": "accounts.list"}).encode() + b"\n")
    frames = runner.run(["cli", *common], stdin=requests)
    replies = [json.loads(line) for line in frames.stdout.splitlines()]
    require(frames.returncode == 0 and not frames.stderr and len(replies) == 3,
            "JSONL frame error broke framing or stopped the following request")
    require(replies[0]["error"]["code"] == "InvalidRequest" and replies[1]["error"]["code"] == "UnsupportedCommand"
            and replies[1]["id"] == "unknown" and replies[2]["ok"] is True and replies[2]["id"] == "accounts",
            "JSONL command errors changed to argv usage errors")
    require(all(reply.get("version") == 1 for reply in replies) and HINT not in frames.stdout,
            "JSONL stdout contains human usage diagnostics")
    missing_config = runner.run(["mail", "list", "--config", str(runner.directory / "absent-config.json")])
    require(missing_config.returncode != 0 and not missing_config.stdout and HINT not in missing_config.stderr,
            "known operational configuration failure received an unrelated argv hint")


def version(runner, expected):
    results = [runner.run([verb], without_home=True) for verb in ("version", "--version")]
    require(all(result.returncode == 0 and not result.stderr for result in results), "version alias needed configured accounts")
    require(results[0].stdout == results[1].stdout == f"omagma {expected}\n".encode(),
            "version and --version disagreed with the binary-reported application version")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--build-mode", type=build_mode)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    info = read_build_info(binary, args.build_mode)
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    receipt = {"schemaVersion": 1, "suite": "terminal-cli-usage", "synthetic": True,
               "liveProviderWrites": 0, "binarySha256": digest, **info, "cases": []}

    def save():
        if args.receipt:
            args.receipt.parent.mkdir(parents=True, exist_ok=True)
            args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")

    with tempfile.TemporaryDirectory(prefix="omagma-cli-usage-") as temporary:
        runner = Runner(binary, Path(temporary))
        for name, exercise in (("guidance", guidance), ("options", options), ("help", help_paths),
                               ("protocol", protocol), ("version", lambda runner: version(runner, info["appVersion"]))):
            try:
                exercise(runner)
            except Exception:
                receipt["cases"].append({"name": name, "status": "failed", "traceback": traceback.format_exc()})
                save()
                raise
            receipt["cases"].append({"name": name, "status": "passed"})
            save()
            print(f"PASS CLI usage {name}: isolated argv/help/protocol contract")
        receipt["subprocessCalls"] = runner.calls
    require(hashlib.sha256(binary.read_bytes()).hexdigest() == digest, "tested binary changed during usage checks")
    receipt["binaryUnchanged"] = True
    save()


if __name__ == "__main__":
    main()
