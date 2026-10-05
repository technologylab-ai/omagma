"""Fictional HTML/provenance fixture construction, independent of native code."""
import base64
import hashlib
import json
from pathlib import Path

from terminal_cache import ProviderFixture
from terminal_integration import ACCOUNTS, ROOT, require

HTML_ROOT = ROOT / "tests/fixtures/terminal/html"
MANIFEST = json.loads((HTML_ROOT / "manifest.json").read_text())


def substitute(value, account, tracker_url="http://127.0.0.1:1"):
    return value.replace("{account}", account).replace("{trackerUrl}", tracker_url)


def document(kind, account, tracker_url="http://127.0.0.1:1"):
    if kind in ("document", "layout"):
        return substitute((HTML_ROOT / f"{kind}.html").read_text(), account, tracker_url)
    if kind == "safety":
        return substitute(json.loads((HTML_ROOT / "safety.json").read_text())["document"], account, tracker_url)
    if kind == "legacy":
        return substitute(MANIFEST["legacyHtmlTemplate"], account)
    if kind == "depth":
        return "<div>" * 129 + f"Fictional {account}: deep café 👋." + "</div>" * 129
    if kind == "large":
        prefix = f"<html><body><h1>Fictional large HTML</h1><pre>Fictional {account}: café 👋.\n".encode()
        suffix = b"\nFictional large tail marker.</pre></body></html>"
        remaining = MANIFEST["inputByteLimit"] - len(prefix) - len(suffix)
        line = b"Fictional bounded navigation line.\n"
        filler = (line * (remaining // len(line)) + b"x" * (remaining % len(line)))
        raw = prefix + filler + suffix
        require(len(raw) == 2 * 1024**2, "large HTML oracle not exactly decoded2MiB")
        return raw.decode()
    raise AssertionError("unknown fictional HTML kind")


def body(text):
    data = text.encode()
    return {"size": len(data), "data": base64.urlsafe_b64encode(data).decode().rstrip("=")}


class HtmlFixture(ProviderFixture):
    def __init__(self, directory, kind="document", tracker_url="http://127.0.0.1:1"):
        super().__init__(directory)
        self.kind = kind
        for account in ACCOUNTS:
            source = self.data[account]["baseline"]
            html = document(kind, account, tracker_url)
            for identity, plain_preferred in ((MANIFEST["htmlMessageId"], False),
                                               (MANIFEST["plainPreferredMessageId"], True)):
                message = next(m for m in source["messages"] if m["id"] == identity)
                headers = [h for h in message["payload"]["headers"]
                           if h["name"].lower() not in {"content-type", "content-transfer-encoding", "content-disposition"}]
                if plain_preferred:
                    plain = substitute(MANIFEST["plainPreferredTemplate"], account)
                    preferred_html = document("legacy", account) if kind in ("large", "depth") else html
                    message["payload"] = {"partId": "", "mimeType": "multipart/alternative", "filename": "",
                        "headers": headers + [{"name": "Content-Type", "value": "multipart/alternative; boundary=fictional-html"}],
                        "body": {"size": 0}, "parts": [
                            {"partId": "0", "mimeType": "text/plain", "filename": "",
                             "headers": [{"name": "Content-Type", "value": "text/plain; charset=utf-8"}], "body": body(plain)},
                            {"partId": "1", "mimeType": "text/html", "filename": "",
                             "headers": [{"name": "Content-Type", "value": "text/html; charset=utf-8"}], "body": body(preferred_html)}]}
                else:
                    message["payload"] = {"partId": "", "mimeType": "text/html", "filename": "",
                        "headers": headers + [{"name": "Content-Type", "value": "text/html; charset=utf-8"}], "body": body(html)}
            self.stage(account, "baseline")


def body_snapshot(directory, accounts=(ACCOUNTS[0],)):
    result = {}
    for account in accounts:
        base = Path(directory) / "cache/fixtures" / hashlib.sha256(account.encode()).hexdigest()
        for path in base.glob("mail-*.json"):
            result[(account, path.name)] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def rewrite_legacy(directory, accounts=(ACCOUNTS[0],)):
    """Create valid old-schema synthetic bodies, never alter a user's cache."""
    expectations = {}
    for account in accounts:
        base = Path(directory) / "cache/fixtures" / hashlib.sha256(account.encode()).hexdigest()
        index_path = base / "index.json"
        state = json.loads(index_path.read_bytes())
        require(state["account"] == account and state["schema"] == 1, "legacy fixture has wrong cache identity")
        for number, source in ((96, "unknown"), (95, "plain"), (94, "unknown")):
            identity = f"shared-msg-{number:03}"
            path = base / ("mail-" + hashlib.sha256(identity.encode()).hexdigest() + ".json")
            record = json.loads(path.read_bytes())
            require(record["account"] == account and record["message"]["id"] == identity,
                    "legacy fixture body has wrong account/message identity")
            message = record["message"]
            message["bodyHtml"] = document("legacy", account)
            message["bodyText"] = substitute(MANIFEST["plainMismatchTemplate"] if number == 94 else MANIFEST["legacyTextTemplate"], account)
            if source == "unknown": message.pop("bodySource", None)
            else: message["bodySource"] = source
            raw = (json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
            path.write_bytes(raw)
            path.chmod(0o600)
            entry = next(e for e in state["entries"] if e["message"]["id"] == identity)
            entry.update(bytes=len(raw), bodyHash=hashlib.sha256(raw).hexdigest())
            if source == "unknown": entry["message"].pop("bodySource", None)
            else: entry["message"]["bodySource"] = source
            expectations[(account, identity)] = {"bodySource": source, "bodyText": message["bodyText"], "bodyHtml": message["bodyHtml"]}
        index_path.write_text(json.dumps(state, ensure_ascii=False, separators=(",", ":")) + "\n")
        index_path.chmod(0o600)
    return expectations
