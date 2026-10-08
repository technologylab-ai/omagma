#!/usr/bin/env python3
"""Synthetic label collection CRUD, journal, cache and account isolation checks."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

from terminal_integration import ACCOUNTS, Client, FIXTURES, no_core_dump, require


def state(directory, account=ACCOUNTS[0]):
    digest = hashlib.sha256(account.encode()).hexdigest()
    return json.loads((directory / "cache" / "fixtures" / digest / "index.json").read_text())


def run(binary, directory):
    name = "Travel/Österreich 🌋"
    renamed_name = "Travel/Volcano 🌋"
    with Client(binary, directory) as client:
        rows = client.request("mail.refresh", label="INBOX", limit=32, prefetchLimit=32)["messages"]
        ids = [message["id"] for message in rows[:2]]
        require(len(ids) == 2, "fixture messages missing")
        initial = client.request("labels.list")["labels"]
        other_initial = client.request("labels.list", account=ACCOUNTS[1])["labels"]
        bodies = {id: client.request("mail.read", messageId=id)["bodyText"] for id in ids}
        original_hashes = {entry["message"]["id"]: entry["bodyHash"] for entry in state(directory)["entries"]}
        draft = client.request("draft.create", draft={"bodyText": "Private synthetic draft stays intact"})
        created = client.request("labels.create", name=name, operationId="create-travel")
        require(created["outcome"] == "applied" and created["label"]["name"] == name, "create omitted custom label receipt")
        label_id = created["labelId"]
        require(label_id == created["label"]["id"] and label_id not in {label["id"] for label in initial}, "create reused a provider identity")
        before_replay = client.request("cache.stats")["fixtureCalls"]
        require(client.request("labels.create", name=name, operationId="create-travel") == created, "create replay changed its receipt")
        require(client.request("cache.stats")["fixtureCalls"] == before_replay, "create replay dispatched another provider call")
        require(client.request("labels.create", name="Different", operationId="create-travel", ok=False)["code"] == "OperationConflict", "operation identity accepted different content")
        require(client.request("labels.create", name=name.replace("Travel", "travel"), operationId="duplicate", ok=False)["code"] == "DuplicateLabelName", "ASCII case duplicate of UTF-8 name was created")
        require(client.request("labels.create", name=name, operationId="duplicate-exact", ok=False)["code"] == "DuplicateLabelName", "exact Unicode duplicate was created")
        client.request("mail.mark", messageId=ids[0], addLabels=[name])
        client.request("mail.batch", messageIds=[ids[1]], action="mark", addLabels=[name])
        require(all(label_id in client.request("mail.read", messageId=id)["labels"] for id in ids), "assignment failed to resolve current collection")
        require(set(ids).issubset({mail["id"] for mail in client.request("mail.list", label=name)["messages"]}), "created name was absent in provider label view")
        renamed = client.request("labels.rename", labelId=label_id, name=renamed_name, operationId="rename-travel")
        require(renamed["outcome"] == "applied" and renamed["labelId"] == label_id, "rename changed stable label identity")
        require(all(label_id in client.request("mail.read", messageId=id)["labels"] for id in ids), "rename lost message memberships")
        client.restart()
        collection = client.request("labels.list")["labels"]
        require(any(label["id"] == label_id and label["name"] == renamed_name for label in collection), "restart/list resurrected old fixture collection")
        require(not any(label["name"] == name for label in collection), "old label name survived rename")
        require(client.request("mail.mark", messageId=ids[0], addLabels=[name], ok=False)["code"] == "LabelNotFound", "old name was still assignable")
        require(set(ids).issubset({mail["id"] for mail in client.request("mail.list", label=renamed_name)["messages"]}), "renamed name failed provider resolution")
        require(set(ids).issubset({mail["id"] for mail in client.request("mail.search", cacheOnly=True, query='label:"' + renamed_name + '"', limit=100)["messages"]}), "cache search retained stale label name")
        require(client.request("labels.delete", labelId=label_id, confirmName="Wrong name", operationId="bad-delete", ok=False)["code"] == "InvalidLabelConfirmation", "delete accepted stale or incorrect name")
        for operation in ("labels.rename", "labels.delete"):
            params = {"labelId": "INBOX", "operationId": "protected-" + operation, "name": "Custom", "confirmName": "INBOX"}
            require(client.request(operation, ok=False, **params)["code"] == "SystemLabelImmutable", "system collection was mutable")
        for invalid in ("", " inbox ", "bad\r\nname", "bad\x1bname", "bad\u0085name", "x" * 257):
            require(client.request("labels.create", name=invalid, operationId="invalid-" + str(len(invalid)), ok=False)["code"] in {"InvalidLabelName", "MissingField"}, "unsafe label name accepted")
        require(client.request("labels.create", name="inbox", operationId="reserved", ok=False)["code"] == "SystemLabelImmutable", "reserved name accepted")
        require(client.request("labels.create", name="Cache mutation", operationId="cached", cacheOnly=True, ok=False)["code"] == "CacheUnsupported", "cache-only path wrote collection")
        deleted = client.request("labels.delete", labelId=label_id, confirmName=renamed_name, operationId="delete-travel")
        require(deleted["outcome"] == "applied" and deleted["deleted"] and deleted["labelId"] == label_id, "delete omitted explicit receipt")
        deletion_calls = client.request("cache.stats")["fixtureCalls"]
        require(client.request("labels.delete", labelId=label_id, confirmName=renamed_name, operationId="delete-travel") == deleted, "delete replay rejected already deleted definition")
        require(client.request("cache.stats")["fixtureCalls"] == deletion_calls, "delete replay dispatched another provider call")
        client.restart()
        require(not client.request("mail.list", label=renamed_name, cacheOnly=True)["messages"], "deleted label view became unfiltered All Mail")
        client.request("mail.refresh", label="INBOX", limit=32, prefetchLimit=32)
        require(not any(label["id"] == label_id for label in client.request("labels.list")["labels"]), "refresh resurrected deleted definition")
        require(client.request("labels.list", account=ACCOUNTS[1])["labels"] == other_initial, "collection crossed account boundary")
        require(client.request("draft.read", draftId=draft["id"])["bodyText"] == "Private synthetic draft stays intact", "label deletion changed draft")
        for id in ids:
            message = client.request("mail.read", messageId=id)
            require(message["bodyText"] == bodies[id] and label_id not in message["labels"], "label delete lost email or resurrected membership")
            require("INBOX" in message["labels"], "delete removed unrelated system membership")
        current = state(directory)
        require(all(original_hashes[entry["message"]["id"]] == entry["bodyHash"] for entry in current["entries"] if entry["message"]["id"] in original_hashes), "collection writes changed immutable body hashes")
        require(all(label_id not in record["labels"] for record in current["fixtureProvider"]), "fixture provider retains deleted label")
        require(all(label_id not in item["addLabels"] + item["removeLabels"] for receipt in current["undo"] for item in receipt["items"]), "undo can resurrect deleted label")
        replay_create = client.request("labels.create", name=name, operationId="create-travel")
        require(replay_create == created and not any(label["id"] == label_id for label in client.request("labels.list")["labels"]), "old create replay resurrected deleted label")
        argv = [str(binary), "labels", "create", "--fixtures", "--fixture-root", str(FIXTURES), "--cache-dir", str(directory / "cache"), "--account", ACCOUNTS[0], "--name", "One-shot 🌋", "--operation-id", "one-shot"]
        result = subprocess.run(argv, capture_output=True, env=client.environment, cwd=directory, timeout=8, preexec_fn=no_core_dump)
        require(result.returncode == 0 and json.loads(result.stdout)["data"]["outcome"] == "applied", "one-shot labels family not wired")
        one_id = json.loads(result.stdout)["data"]["labelId"]
        base = [str(binary), "labels"]
        common = ["--fixtures", "--fixture-root", str(FIXTURES), "--cache-dir", str(directory / "cache"), "--account", ACCOUNTS[0]]
        for verb, arguments in (("rename", ["--label-id", one_id, "--name", "One-shot renamed", "--operation-id", "one-rename"]),
                                ("delete", ["--label-id", one_id, "--confirm-name", "One-shot renamed", "--operation-id", "one-delete"])):
            result = subprocess.run(base + [verb] + common + arguments, capture_output=True, env=client.environment,
                                    cwd=directory, timeout=8, preexec_fn=no_core_dump)
            receipt = json.loads(result.stdout)
            require(result.returncode == 0 and receipt["data"]["outcome"] == "applied" and receipt["data"]["labelId"] == one_id,
                    "one-shot label rename/delete flags lost target or receipt")
        result = subprocess.run(base + ["list"] + common + ["--cached"], capture_output=True, env=client.environment,
                                cwd=directory, timeout=8, preexec_fn=no_core_dump)
        require(result.returncode == 0 and not any(label["id"] == one_id for label in json.loads(result.stdout)["data"]["labels"]),
                "one-shot list did not show current cached collection")
    with Client(binary, directory / "readonly", scenario="readonly") as client:
        for command in ("labels.create", "labels.rename", "labels.delete"):
            error = client.request(command, name="Readonly cannot write", labelId="Label_demo", confirmName="Projects", operationId=command, ok=False)
            require(error["code"] == "PermissionDenied", "read-only grant wrote label collection")
        require(client.request("operation.list")["operations"] == [], "denied collection request entered mutation journal")
    with Client(binary, directory / "unknown", scenario="unknown-send") as client:
        unknown = client.request("labels.create", name="Unknown 🌋", operationId="unknown-label")
        require(unknown["outcome"] == "unknown", "unknown mutation advertised applied")
        before = client.request("cache.stats")["fixtureCalls"]
        require(client.request("labels.create", name="Unknown 🌋", operationId="new-identity") == unknown, "new ID retried unknown mutation")
        client.restart()
        require(client.request("labels.create", name="Unknown 🌋", operationId="unknown-label") == unknown, "restart lost unknown journal guard")
        require(client.request("cache.stats")["fixtureCalls"] == before, "unknown mutation dispatched again")
    print("PASS label CRUD, stable IDs, membership/body preservation, replay/unknown guards, CLI and account isolation")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="omagma-label-management-") as temporary:
        run(args.binary.resolve(), Path(temporary))


if __name__ == "__main__":
    main()
