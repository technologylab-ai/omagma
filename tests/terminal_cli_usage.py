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
import shlex
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
    "calendar": ("list", "agenda", "event", "freebusy", "invitation-plan", "review", "apply", "import", "update", "cancel", "reconcile"),
    "mail": ("list", "search", "read", "thread", "attachment", "attachment-save", "open", "sync", "refresh", "recipients",
             "reply", "forward", "send", "archive", "trash", "restore", "spam", "unspam", "mark", "batch", "undo", "triage-scope", "label-state", "prefetch",
             "drafts", "compose", "labels", "identities", "open-link", "open-attachment"),
    "draft": ("list", "read", "create", "update", "preview", "open-preview", "recovery-save", "send", "queue", "discard"),
    "queue": ("list", "read", "cancel", "resume", "process", "send-now"),
    "attachment": ("import", "discard", "open"),
    "labels": ("list", "create", "rename", "delete", "color", "palette"),
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

    def run(self, arguments, stdin=b"", without_home=False, catalogue=False):
        environment = dict(self.environment)
        if without_home:
            environment.pop("HOME", None)
        result = subprocess.run([str(self.binary), *arguments], input=stdin, capture_output=True,
                                cwd=self.directory, env=environment, timeout=8, preexec_fn=no_core_dump)
        self.calls += 1
        # The complete 83-command catalogue now exceeds 256KiB; match the
        # discovery metadata's finite 512KiB bound only for full disclosure.
        # Ordinary command help and protocol diagnostics keep their old cap.
        stdout_limit = (512 if catalogue else 256) * 1024
        require(len(result.stdout) <= stdout_limit and len(result.stderr) <= 16 * 1024,
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
            require(result.returncode == 0 and not result.stderr and ("Usage: omagma " + mode).encode() in result.stdout,
                    "legacy command help loaded HOME/configuration or entered its runtime")
    for mode in ("tui", "cli", "agent", *FAMILIES):
        for flag in ("--help", "-h"):
            result = runner.run([mode, flag], without_home=True)
            require(result.returncode == 0 and not result.stderr and b"Experimental terminal mail" in result.stdout,
                    "terminal mode help required a configured account")
            if mode in ("cli", "agent"):
                require(b'"cmd":"accounts.list"' in result.stdout and b"omagma cli --help mail.read" in result.stdout,
                        "agent quickstart lost account discovery or contextual JSONL help")
            elif mode in FAMILIES:
                require(all(verb.encode() in result.stdout for verb in FAMILIES[mode]),
                        "family help omitted an available operation")
    for family, verbs in FAMILIES.items():
        for verb in verbs:
            result = runner.run([family, verb, "--config", str(runner.invalid_config), "--help"])
            require(result.returncode == 0 and not result.stderr and b"Experimental terminal mail" in result.stdout,
                    f"supported one-shot {family}/{verb} was denied or loaded configuration before help")
            require(b"Shell example" in result.stdout and b"--help-all" in result.stdout,
                    "one-shot help omitted an executable example or advanced disclosure path")
    root = runner.run(["--help"]).stdout
    require(len(root.splitlines()) <= 35 and b"omagma cli --help" in root and b"--help-all" in root,
            "root help is not a compact entry point with next steps")
    detailed = runner.run(["mail", "read", "--help"]).stdout
    require(b"--message-id" in detailed and b"messageId" in detailed and b"draft queue" not in detailed,
            "message help omitted its fields or leaked unrelated command details")
    jsonl_help = runner.run(["cli", "--help", "mail.read"], without_home=True)
    require(jsonl_help.returncode == 0 and b'"messageId"' in jsonl_help.stdout and not jsonl_help.stderr,
            "JSONL operation discovery omitted its actual request field")
    runner.usage(["cli", "--help", "fictional.missing"], "UnknownCommand", without_home=True)
    runner.usage(["cli", "--help", "mail.compose"], "UnknownCommand", without_home=True)
    runner.usage(["cli", "--help", "mail.spam"], "UnknownCommand", without_home=True)
    runner.usage(["cli", "--help", "mail.unspam"], "UnknownCommand", without_home=True)
    for verb in ("status", "check", "guide", "dismiss", "automatic"):
        result = runner.run(["updates", verb, "--help"], without_home=True)
        require(result.returncode == 0 and not result.stderr and verb.encode() in result.stdout,
                "update help entered its runtime or omitted its own operation")
    for mode in ("cache-refresh", "version", "--version", "build-info", "budget", "probe-keyring", "probe-callback", "probe-https"):
        for flag in ("--help", "-h"):
            result = runner.run([mode, flag], without_home=True)
            require(result.returncode == 0 and not result.stderr and b"omagma" in result.stdout,
                    "standalone help entered a probe, refresh or diagnostic instead of showing usage")
    for verb in ("status", "migrate"):
        result = runner.run(["credentials", verb, "--help"], without_home=True)
        require(result.returncode == 0 and not result.stderr and ("omagma credentials " + verb).encode() in result.stdout,
                "credential help omitted its own operation")
    require(b"--to STORE" not in runner.run(["credentials", "status", "--help"], without_home=True).stdout,
            "credential status help still mixes migration-only options")
    expanded = runner.run(["draft", "create", "--help-all"], without_home=True)
    require(expanded.returncode == 0 and b"bare JSON object" in expanded.stdout
            and b"$defs" in expanded.stdout and b"--metadata-limit" in expanded.stdout,
            "expanded one-shot help omitted structured file shape or common advanced flags")
    request_input = runner.run(["mail", "send", "--body-file", str(runner.directory / "missing-body"), "--help"], without_home=True)
    require(request_input.returncode == 0 and b"Shell example" in request_input.stdout and not request_input.stderr,
            "help tried to read a body file before returning")
    environment = dict(runner.environment); environment.pop("HOME", None)
    p = subprocess.Popen([str(runner.binary), "draft", "preview", "--body-stdin", "--help"],
                         cwd=runner.directory, env=environment, stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, preexec_fn=no_core_dump)
    try:
        p.wait(timeout=3)  # Keep stdin open: help must not wait for EOF.
        require(p.returncode == 0 and b"Shell example" in p.stdout.read() and not p.stderr.read(),
                "help consumed stdin or entered a draft operation")
    finally:
        if p.poll() is None: p.kill(); p.wait(timeout=3)
        p.stdin.close(); p.stdout.close(); p.stderr.close()
    literal = runner.run(["draft", "preview", "--fixtures", "--cache-dir", str(runner.directory / "literal-help"),
                          "--account", "personal@example.com", "--subject", "--help", "--body", "Hello"])
    require(literal.returncode == 0 and json.loads(literal.stdout)["ok"],
            "literal help-valued field was mistaken for an option")
    typo = runner.usage(["mail", "read", "--fictional-unknown-option"], "UnknownOption", without_home=True)
    require(b"Details: omagma mail read --help." in typo.stderr,
            "known operation usage error did not point to contextual help")
    bad_verb = runner.usage(["mail", CANARY], "UnknownCommand", without_home=True)
    require(b"Details: omagma mail --help." in bad_verb.stderr,
            "unknown operation did not point to its known family")
    common = runner.run(["cli", "--help-options"], without_home=True)
    require(common.returncode == 0 and b"--cache-messages" in common.stdout and b"--metrics-file" in common.stdout,
            "shared advanced aliases or metrics options are not discoverable")
    full = runner.run(["--help-all"], without_home=True)
    require(full.returncode == 0 and b"recipients" in full.stdout and b"draft preview" in full.stdout,
            "extended help is unavailable without configuration")


PUBLIC_JSONL = set("""
accounts.list accounts.identities
mail.list mail.search mail.sync mail.read mail.thread mail.recipients mail.refresh mail.prefetch mail.open
mail.triage-scope mail.label-state mail.reply mail.forward mail.send mail.archive mail.trash mail.restore
mail.mark mail.batch mail.undo mail.attachment mail.attachment-save
labels.list labels.palette labels.create labels.rename labels.delete labels.color
contacts.list contacts.search contacts.upsert
cache.stats cache.clear cache.activity cache.refresh-status
browser.open auth.status auth.authorize auth.revoke
draft.list draft.read draft.create draft.update draft.recovery-save draft.preview draft.open-preview
draft.discard draft.send draft.queue
draft.gmail-info draft.gmail-save draft.gmail-status draft.gmail-take-back draft.gmail-import
queue.list queue.read queue.cancel queue.resume queue.process queue.send-now
attachment.import attachment.discard attachment.open
invitation.inspect invitation.reply operation.list operation.read
reminder.list reminder.set reminder.done
calendar.list calendar.agenda calendar.event calendar.freebusy calendar.invitation-plan
calendar.review calendar.apply calendar.import calendar.update calendar.cancel calendar.reconcile
""".split())


def discovery(runner):
    result = runner.run(["cli", "--schema"], without_home=True, catalogue=True)
    require(result.returncode == 0 and not result.stderr, "schema discovery required account setup")
    catalogue = json.loads(result.stdout)
    commands = {s["properties"]["cmd"]["const"]: s for s in catalogue["oneOf"]}
    require(set(commands) == PUBLIC_JSONL and len(commands) == len(catalogue["oneOf"]),
            "JSONL catalogue omitted a public command, included an argv alias or repeated a command")
    def references(value, definitions):
        if isinstance(value, dict):
            if "$ref" in value:
                ref = value["$ref"]
                require(ref.startswith("#/$defs/") and ref[8:] in definitions,
                        "schema depends on an external or missing definition")
            if "properties" in value:
                require(all(k in value["properties"] for k in value.get("required", [])),
                        "schema requires an undocumented property")
            for child in value.values(): references(child, definitions)
        elif isinstance(value, list):
            for child in value: references(child, definitions)
    references(catalogue, catalogue["$defs"])
    for command in ("mail.read", "mail.list", "mail.send", "draft.update", "contacts.upsert", "invitation.reply",
                    "calendar.agenda", "calendar.review", "draft.gmail-save", "reminder.set"):
        result = runner.run(["cli", "--config", str(runner.invalid_config), "--schema", command], without_home=True)
        require(result.returncode == 0 and not result.stderr, "command schema loaded private configuration")
        selected = json.loads(result.stdout)
        require(selected["title"] == command and selected["properties"]["cmd"]["const"] == command,
                "selected schema changed the requested method")
        references(selected, selected.get("$defs", {}))
        human = runner.run(["cli", "--help", command], without_home=True)
        require(human.returncode == 0 and b"Complete request fields" in human.stdout and not human.stderr,
                "human command help is not self-contained")
    require("anchorMessageId" in commands["mail.list"]["properties"]
            and "beforeMessageId" in commands["mail.list"]["properties"]
            and "includeSpamTrash" in commands["mail.search"]["properties"],
            "schema omitted ordinary optional navigation/search fields")
    require("Draft" in catalogue["$defs"] and "Contact" in catalogue["$defs"]
            and "original" in catalogue["$defs"]["Draft"]["properties"],
            "schema omitted nested compose/contact/original fields")
    listing = runner.run(["cli", "--help", "commands"], without_home=True)
    require(listing.returncode == 0 and all(c.encode() in listing.stdout for c in PUBLIC_JSONL),
            "human JSONL catalogue omitted actual cmd names")
    family = runner.run(["cli", "--help", "mail"], without_home=True)
    require(family.returncode == 0 and b"mail.read" in family.stdout and b"contacts.upsert" not in family.stdout,
            "JSONL namespace help did not narrow the catalogue")
    expanded = runner.run(["cli", "--help-all"], without_home=True, catalogue=True)
    require(expanded.returncode == 0 and b"$defs" in expanded.stdout
            and all(c.encode() in expanded.stdout for c in PUBLIC_JSONL),
            "offline full reference omitted commands or shared object fields")
    # Every catalogue method reaches an actual executor branch, not UnknownCommand.
    # Missing required values remain errors; requests use a disconnected fixture only.
    frames = [{"id": str(i), "cmd": c, **({} if c == "accounts.list" else {"account": "personal@example.com"})}
              for i, c in enumerate(sorted(PUBLIC_JSONL))]
    for frame in frames:
        if frame["cmd"] == "mail.recipients": frame["cacheOnly"] = True
    frames.append({"id": "negative-control", "cmd": "fictional.not-a-command", "account": "personal@example.com"})
    result = runner.run(["cli", "--fixtures", "--cache-dir", str(runner.directory / "catalogue-fixtures")],
                        "".join(json.dumps(f) + "\n" for f in frames).encode())
    replies = [json.loads(line) for line in result.stdout.splitlines()]
    require(result.returncode == 0 and len(replies) == len(frames), "catalogue fixture dispatcher lost frames")
    unsupported = {"UnknownCommand", "UnsupportedCommand"}
    absent = {frame["cmd"]: reply["error"]["code"] for frame, reply in zip(frames[:-1], replies[:-1])
              if reply.get("error", {}).get("code") in unsupported}
    require(not absent, f"catalogue advertises a command absent from the public executor: {absent}")
    require(replies[-1].get("error", {}).get("code") in unsupported,
            "catalogue dispatcher oracle failed to detect its unknown-command control")
    runner.usage(["cli", "--schema", "mail.spam"], "UnknownCommand", without_home=True)
    runner.usage(["cli", "--help", "fictional_namespace"], "UnknownCommand", without_home=True)


def help_examples(runner):
    # Execute the help's literal JSON examples through the real fixture dispatcher.
    # Feed returned message IDs into later examples instead of inventing provider IDs.
    common = ["--fixtures", "--cache-dir", str(runner.directory / "help-example-cache")]
    quickstart = runner.run(["cli", "--help"], without_home=True).stdout.decode()
    discovery = next(line for line in quickstart.splitlines() if "printf '%s" in line)
    request = json.loads(discovery.split("'", 3)[3].split("'", 1)[0])
    result = runner.run(["cli", *common], (json.dumps(request) + "\n").encode())
    discovered = json.loads(result.stdout)
    require(discovered["ok"] and discovered["data"]["accounts"], "help's account-discovery example failed")
    account = discovered["data"]["accounts"][0]["address"]
    returned_id = None
    for family, verb in (("mail", "list"), ("mail", "read"), ("mail", "search"), ("draft", "preview")):
        text = runner.run([family, verb, "--help"], without_home=True).stdout.decode()
        example = next(json.loads(line) for line in text.splitlines() if line.startswith('{"id"'))
        example["account"] = account
        if family == "mail" and verb == "read":
            require(returned_id is not None, "help's list example returned no usable message")
            example["messageId"] = returned_id
        result = runner.run(["cli", *common], (json.dumps(example) + "\n").encode())
        response = json.loads(result.stdout)
        require(result.returncode == 0 and response["ok"] and response["id"] == example["id"],
                f"help's {family}/{verb} example is not executable")
        if family == "mail" and verb == "list":
            returned_id = response["data"]["messages"][0]["id"]
        if family == "draft":
            require("<strong>Hello</strong>" in response["data"]["bodyHtml"],
                    "help's Markdown preview example did not render")
    # Execute the printed shell syntax separately, proving one-shot discovery
    # is usable without translating its JSONL examples.
    for family, verb in (("mail", "list"), ("mail", "read"), ("mail", "search"), ("draft", "preview"),
                         ("contacts", "list"), ("labels", "palette"), ("cache", "stats")):
        text = runner.run([family, verb, "--help"], without_home=True).stdout.decode()
        shell = text.split("Shell example", 1)[1].splitlines()[1].strip()
        argv = shlex.split(shell)
        require(argv[0] == "omagma" and argv[1:3] == [family, verb], "printed shell example changed its operation")
        argv = [returned_id if v == "RETURNED_MESSAGE_ID" else v for v in argv[1:]]
        result = runner.run([*argv, *common])
        require(result.returncode == 0 and json.loads(result.stdout)["ok"],
                f"printed {family}/{verb} shell example is not executable")


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
        for name, exercise in (("guidance", guidance), ("options", options), ("help", help_paths), ("discovery", discovery), ("help-examples", help_examples),
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
