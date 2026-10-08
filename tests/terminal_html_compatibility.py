#!/usr/bin/env python3
"""Independent Chromium recovery oracle for synthetic formatted mail.

Requires the coordinator's cooperative host test window. Uses only local fixture
drafts and an owned loopback server. Chromium has a fresh temporary profile;
received markup runs in sandboxed frames with scripts and resource loads blocked.
No mail is sent, and no user browser profile, GUI, mail cache or credentials are
used. A failing run still writes its requested receipt for before/after evidence.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import threading

from build_info import read_build_info
from terminal_integration import ACCOUNTS, Client, ROOT, require


FIXTURE_ROOT = ROOT / "tests/fixtures/terminal/html-compatibility"
NOTE_LINK = "https://note.example.test/compatibility-oracle"
NOTE_MARKER = "Independent compatibility note"
NOTE = f"# {NOTE_MARKER}\n\n**Fictional personal note** with a [note link]({NOTE_LINK})."
MAX_CASES = 64
MAX_SOURCE_BYTES = 512 * 1024
MAX_TOTAL_BYTES = 8 * 1024 * 1024
CSP = ("default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
       "img-src data:; font-src 'none'; connect-src 'none'; frame-src 'self'; "
       "base-uri 'none'; form-action 'none'; object-src 'none'")


# This code observes Chromium's completed DOM. It does not tokenize or repair
# mail markup and knows nothing about original_mail.zig's envelope scanner.
BROWSER_SCRIPT = r"""
const inputs = INPUTS;
const noteLink = NOTE_LINK_VALUE;
const noteMarker = NOTE_MARKER_VALUE;
const results = [];
const styleNames = ['color','background-color','font-family','font-size',
  'font-weight','line-height','text-align','display','visibility','opacity',
  'white-space','border-top-width','border-top-style','border-top-color',
  'padding-top','padding-right','padding-bottom','padding-left'];
const attrs = e => Object.fromEntries(Array.from(e.attributes)
  .map(a => [a.name,a.value]).sort((a,b) => a[0].localeCompare(b[0])));
const cleanText = s => s.replace(/\s+/g,' ').trim();
const isEncoding = e => e.localName === 'meta' &&
  (e.hasAttribute('charset') ||
   (e.getAttribute('http-equiv') || '').toLowerCase() === 'content-type');
const style = e => Object.fromEntries(styleNames.map(name =>
  [name,e.ownerDocument.defaultView.getComputedStyle(e).getPropertyValue(name)]));
function canonical(node, excluded) {
  if (excluded.has(node)) return null;
  if (node.nodeType === Node.TEXT_NODE) {
    const text = cleanText(node.nodeValue);
    return text ? ['text',text] : null;
  }
  if (node.nodeType !== Node.ELEMENT_NODE || isEncoding(node)) return null;
  const raw = ['style','script','textarea','title','xmp','plaintext'].includes(node.localName);
  const children = node.localName === 'template' ? node.content.childNodes : node.childNodes;
  return [node.namespaceURI,node.localName,attrs(node),raw ? node.textContent :
    Array.from(children).map(n => canonical(n,excluded)).filter(n => n !== null)];
}
function inspect(frame, assembled) {
  const doc = frame.contentDocument;
  if (!doc || !doc.body || !doc.head) throw new Error('frame document unavailable');
  const excluded = new Set();
  let note = null;
  if (assembled) {
    const matches = Array.from(doc.querySelectorAll('a')).filter(a => a.getAttribute('href') === noteLink);
    const link = matches.length === 1 ? matches[0] : null;
    let root = link;
    while (root && root.parentElement !== doc.body) root = root.parentElement;
    const header = root && root.nextElementSibling;
    const first = Array.from(doc.body.childNodes).find(n => n.nodeType === Node.ELEMENT_NODE ||
      (n.nodeType === Node.TEXT_NODE && cleanText(n.nodeValue)));
    const heading = root && Array.from(root.querySelectorAll('h1')).find(h => h.textContent === noteMarker);
    note = {uniqueLink:matches.length === 1, rootInBody:!!root, firstInBody:root === first,
      hasMarker:!!heading, headingColor:heading ? style(heading).color : null,
      linkColor:link ? style(link).color : null, rootStyle:root ? style(root) : null,
      headerAdjacent:!!header && header.classList.contains('omagma-original-header')};
    if (root) excluded.add(root);
    if (note.headerAdjacent) excluded.add(header);
  }
  const retained = selector => Array.from(doc.querySelectorAll(selector)).filter(e =>
    !Array.from(excluded).some(parent => parent === e || parent.contains(e)));
  const probes = retained('[id]').map(e => ({id:e.id,tag:e.localName,style:style(e)}));
  return {
    counts:{html:doc.querySelectorAll('html').length,head:doc.querySelectorAll('head').length,
      body:doc.querySelectorAll('body').length},
    compatibilityMode:doc.compatMode,
    rootAttributes:attrs(doc.documentElement), bodyAttributes:attrs(doc.body),
    head:canonical(doc.head,excluded), body:canonical(doc.body,excluded),
    tables:retained('table').map(e => canonical(e,excluded)),
    images:retained('img').map(attrs), links:retained('a').map(attrs),
    styles:retained('style').map(e => e.textContent),
    rootStyle:style(doc.documentElement), bodyStyle:style(doc.body), probes, note,
    receivedScriptExecuted:doc.defaultView.compatibilityFixtureExecuted === true
  };
}
function load(url) {
  return new Promise((resolve,reject) => {
    const frame = document.createElement('iframe');
    frame.sandbox = 'allow-same-origin';
    frame.style.cssText = 'display:block;width:960px;height:720px;border:0';
    const deadline = setTimeout(() => {frame.remove();reject(new Error('fixture frame load timed out'));},8000);
    frame.onload = () => {clearTimeout(deadline);resolve(frame);};
    frame.src = url;
    document.body.appendChild(frame);
  });
}
(async () => {
  for (const input of inputs) {
    const result = {id:input.id};
    let source, output;
    try {
      source = await load(input.source);
      result.source = inspect(source,false);
      if (input.output) {
        output = await load(input.output);
        result.output = inspect(output,true);
      }
    } catch (error) {result.browserError = String(error);}
    finally {if(source)source.remove();if(output)output.remove();}
    results.push(result);
  }
  document.getElementById('oracle-result').textContent = JSON.stringify({complete:true,results});
})().catch(error => {
  document.getElementById('oracle-result').textContent = JSON.stringify({complete:false,error:String(error),results});
});
"""


class ResultParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.collect = False
        self.parts = []

    def handle_starttag(self, tag, attrs):
        if tag == "pre" and dict(attrs).get("id") == "oracle-result":
            self.collect = True

    def handle_endtag(self, tag):
        if tag == "pre":
            self.collect = False

    def handle_data(self, data):
        if self.collect:
            self.parts.append(data)


def invoke(client, command, **params):
    """Observe success or refusal without weakening Client's transport checks."""
    client.next_id += 1
    identity = f"html-compatibility-{client.next_id}"
    client.raw(json.dumps({"id": identity, "account": ACCOUNTS[0], "cmd": command,
                           **params}, ensure_ascii=False).encode() + b"\n")
    value = client.receive()
    require(value.get("id") == identity and value.get("account") == ACCOUNTS[0],
            "compatibility response changed request identity/account")
    return value


def load_cases(manifest_path, selected=(), include_pending=False):
    manifest_path = manifest_path.resolve()
    require(manifest_path.parent == FIXTURE_ROOT.resolve(), "only repository synthetic compatibility fixtures are accepted")
    manifest = json.loads(manifest_path.read_text())
    require(manifest.get("synthetic") is True and manifest.get("networkRequired") is False,
            "compatibility manifest must declare synthetic, network-free source")
    cases = manifest["cases"]
    require(0 < len(cases) <= MAX_CASES, "compatibility case count exceeds bound")
    require(len({case["id"] for case in cases}) == len(cases), "duplicate compatibility case identity")
    wanted = set(selected)
    require(wanted <= {case["id"] for case in cases}, "requested compatibility case is absent")
    result = []
    for original_case in cases:
        if wanted and original_case["id"] not in wanted:
            continue
        if original_case["expectedOutcome"] == "pending" and not include_pending:
            continue
        case = copy.deepcopy(original_case)
        path = (manifest_path.parent / case["file"]).resolve()
        require(path.parent == manifest_path.parent and path.suffix == ".html", "fixture path leaves synthetic corpus")
        raw = path.read_bytes()
        require(len(raw) <= MAX_SOURCE_BYTES, "compatibility source exceeds byte bound")
        case["sourceBytes"] = raw
        case["sourceHtml"] = raw.decode("utf-8")
        case["sourceSha256"] = hashlib.sha256(raw).hexdigest()
        result.append(case)
    require(result, "no active compatibility cases selected")
    require(sum(len(case["sourceBytes"]) for case in result) <= MAX_TOTAL_BYTES, "compatibility corpus exceeds byte bound")
    return manifest, result


def assemble(binary, directory, manifest, cases):
    """Use the real fixture CLI preview; do not call or reimplement the scanner."""
    resources = {value["id"]: value for value in manifest.get("resources", [])}
    results = []
    with Client(binary, directory) as client:
        for case in cases:
            result = {"id": case["id"], "expectedOutcome": case["expectedOutcome"],
                      "sourceSha256": case["sourceSha256"], "errors": []}
            snapshot = copy.deepcopy(manifest["original"])
            snapshot.update(sourceMessageId="synthetic-compatibility-" + case["id"],
                            bodyHtml=case["sourceHtml"],
                            resources=[copy.deepcopy(resources[name]) for name in case.get("realResourceIds", [])])
            draft = {"to": [{"address": "recipient@example.test"}],
                     "subject": "Fictional HTML compatibility", "bodyText": NOTE,
                     "bodyFormat": "markdown", "original": snapshot}
            reply = invoke(client, "draft.preview", draft=draft)
            accepted = reply.get("ok") is True
            result["actualOutcome"] = "accept" if accepted else reply.get("error", {}).get("code", "UnknownError")
            expectation = case["expectedOutcome"]
            if accepted:
                preview = reply["data"]
                result["outputHtml"] = preview["bodyHtml"]
                if expectation == "reject":
                    result["errors"].append("source expected refusal but preview accepted it")
                stored = client.request("draft.create", draft=draft)
                before = client.request("draft.read", draftId=stored["id"])
                require(before["original"]["bodyHtml"] == case["sourceHtml"], "draft.create changed retained source HTML")
                persisted_preview = client.request("draft.preview", draftId=stored["id"])
                after = client.request("draft.read", draftId=stored["id"])
                require(before["original"] == after["original"], "preview mutated the original snapshot")
                require(preview == persisted_preview, "inline and persisted draft previews differ")
                require(after["bodyText"] == NOTE, "original entered the editable note")
                result["originalSourceImmutable"] = True
                for literal in case.get("mustRetain", []):
                    if literal not in result["outputHtml"]:
                        result["errors"].append("required original byte span was not retained: " + literal)
                for literal in case.get("mustNotRetain", []):
                    if literal in result["outputHtml"]:
                        result["errors"].append("obsolete/conflicting source token remained: " + literal)
                if "mustEndWith" in case:
                    suffix = case["mustEndWith"].encode("utf-8")
                    require(case["sourceBytes"].endswith(suffix), "manifest suffix is not the exact original ending")
                    result["originalTailUnchanged"] = result["outputHtml"].encode("utf-8").endswith(suffix)
                    if not result["originalTailUnchanged"]:
                        result["errors"].append("unfinished original tail changed or synthetic closers were appended")
                client.request("draft.discard", draftId=stored["id"])
            elif expectation == "accept":
                result["errors"].append("expected recoverable HTML was refused: " + result["actualOutcome"])
            elif expectation == "reject" and case.get("expectedError") and result["actualOutcome"] != case["expectedError"]:
                result["errors"].append("refusal code differs from manifest")
            require(client.request("draft.list")["drafts"] == [], "preview/refusal left a partial draft")
            results.append(result)
        require(client.request("cache.stats")["fixtureSends"] == 0, "compatibility test submitted mail")
        require(client.request("operation.list")["operations"] == [], "compatibility test created a submission operation")
    return results


def browser_oracle(browser, directory, cases, assembled):
    by_id = {item["id"]: item for item in assembled}
    routes = {}
    inputs = []
    for index, case in enumerate(cases):
        source = f"/fixture/{index}/source.html"
        routes[source] = case["sourceBytes"]
        entry = {"id": case["id"], "source": source, "output": None}
        if "outputHtml" in by_id[case["id"]]:
            entry["output"] = f"/fixture/{index}/output.html"
            routes[entry["output"]] = by_id[case["id"]]["outputHtml"].encode("utf-8")
        inputs.append(entry)
    script = BROWSER_SCRIPT.replace("INPUTS", json.dumps(inputs).replace("<", "\\u003c"), 1)
    script = script.replace("NOTE_LINK_VALUE", json.dumps(NOTE_LINK), 1).replace("NOTE_MARKER_VALUE", json.dumps(NOTE_MARKER), 1)
    routes["/driver.html"] = ("<!doctype html><html><head><meta charset=utf-8><title>Synthetic compatibility oracle</title></head>"
                              "<body><pre id=oracle-result>pending</pre><script>" + script + "</script></body></html>").encode()
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            value = routes.get(self.path)
            self.send_response(200 if value is not None else 404)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Security-Policy", CSP)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(value or b"Synthetic route not found")

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    profile = directory / "chromium-profile"
    profile.mkdir(mode=0o700)
    browser_home, browser_runtime = directory / "browser-home", directory / "browser-runtime"
    browser_home.mkdir(mode=0o700)
    browser_runtime.mkdir(mode=0o700)
    env = dict(os.environ, HOME=str(browser_home), TMPDIR=str(directory), XDG_RUNTIME_DIR=str(browser_runtime))
    for name in ("DISPLAY", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS"):
        env.pop(name, None)
    for name in ("CONFIG", "CACHE", "DATA", "STATE"):
        env[f"XDG_{name}_HOME"] = str(directory / ("browser-" + name.lower()))
    argv = [str(browser), "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
            "--disable-background-networking", "--disable-component-update", "--disable-sync", "--disable-extensions",
            "--disable-client-side-phishing-detection", "--disable-breakpad", "--disable-crash-reporter",
            "--disable-features=MediaRouter,OptimizationHints", "--metrics-recording-only", "--no-proxy-server",
            "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1", "--password-store=basic", "--use-mock-keychain",
            "--mute-audio", "--hide-scrollbars", f"--user-data-dir={profile}", "--virtual-time-budget=30000",
            "--dump-dom", f"http://127.0.0.1:{server.server_port}/driver.html"]
    process = None
    try:
        process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=env, cwd=directory, start_new_session=True)
        output, error = process.communicate(timeout=60)
        require(process.returncode == 0, "headless Chromium failed: " + error.decode(errors="replace")[-2000:])
        require(len(output) <= MAX_TOTAL_BYTES, "browser diagnostic output exceeded bound")
        parser = ResultParser()
        parser.feed(output.decode("utf-8"))
        raw = "".join(parser.parts)
        require(raw and raw != "pending", "Chromium did not finish independent fixture probes: " +
                json.dumps({"requests": requests, "result": raw[:500],
                            "domPrefix": output.decode(errors="replace")[:500],
                            "stderrTail": error.decode(errors="replace")[-2500:]}))
        result = json.loads(raw)
        require(result.get("complete") is True, "browser oracle script failed: " + str(result.get("error")))
        require(len(result["results"]) == len(cases), "browser skipped a synthetic fixture")
        result["requests"] = requests
        require(set(requests) <= set(routes) | {"/favicon.ico"}, "browser requested an unexpected local resource")
        return result
    finally:
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=3)
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
        require(not thread.is_alive(), "owned fixture server did not stop")


def compare_case(case, assembled, browser):
    errors = assembled["errors"]
    if browser.get("browserError"):
        errors.append(browser["browserError"])
        return
    source = browser["source"]
    for field in ("rootAttributes", "bodyAttributes"):
        if field in case and source[field] != case[field]:
            errors.append("manifest " + field + " disagrees with independent browser recovery")
    expected_mode = case.get("compatMode", case.get("compatibilityMode"))
    if expected_mode and source["compatibilityMode"] != expected_mode:
        errors.append("manifest compatibility mode disagrees with browser byte-source parsing")
    if not set(case.get("styleProbeIds", [])) <= {probe["id"] for probe in source["probes"]}:
        errors.append("manifest style probe is absent from original browser DOM")
    if "output" not in browser:
        return
    output = browser["output"]
    if output["counts"] != {"html": 1, "head": 1, "body": 1}:
        errors.append("output does not have one coherent browser document envelope")
    note = output["note"]
    for key in ("uniqueLink", "rootInBody", "firstInBody", "hasMarker", "headerAdjacent"):
        if not note[key]:
            errors.append("generated note boundary failed: " + key)
    if note["headingColor"] != "rgb(184, 74, 16)" or note["linkColor"] != "rgb(184, 74, 16)":
        errors.append("original CSS changed branded note heading/link colors")
    if source["receivedScriptExecuted"] or output["receivedScriptExecuted"]:
        errors.append("sandbox executed received fixture script")
    if case.get("browserEquivalent", True):
        for field in ("compatibilityMode", "rootAttributes", "bodyAttributes", "head", "body", "tables", "images", "links", "styles",
                      "rootStyle", "bodyStyle", "probes"):
            if source[field] != output[field]:
                errors.append("browser recovery/presentation changed original " + field)
    assembled["browserSourceMode"] = source["compatibilityMode"]
    assembled["browserOutputMode"] = output["compatibilityMode"]
    assembled["browserOriginalEquivalent"] = not any("changed original" in error for error in errors)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--browser", type=Path, default=Path(shutil.which("chromium") or "/usr/bin/chromium"))
    parser.add_argument("--manifest", type=Path, default=FIXTURE_ROOT / "manifest.json")
    parser.add_argument("--case", action="append", default=[])
    parser.add_argument("--include-pending", action="store_true", help="probe unresolved policy cases without counting them as accepted")
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    binary, browser = args.binary.resolve(), args.browser.resolve()
    manifest, cases = load_cases(args.manifest, args.case, args.include_pending)
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    browser_version = subprocess.run([str(browser), "--version"], capture_output=True, text=True, check=True, timeout=10).stdout.strip()
    base_receipt = {"suite": "terminal-html-compatibility", "synthetic": True,
                    "fixtureSends": 0, "liveProviderWrites": 0,
                    "binarySha256": digest, "browserVersion": browser_version,
                    "browserMode": "headless; fresh profile; exact UTF-8 bytes; sandboxed frames; resource loads blocked",
                    **read_build_info(binary, None)}
    with tempfile.TemporaryDirectory(prefix="omagma-html-compatibility-") as temporary:
        directory = Path(temporary)
        assembled = []
        try:
            assembled = assemble(binary, directory, manifest, cases)
            observed = browser_oracle(browser, directory, cases, assembled)
        except Exception as error:
            if args.receipt:
                args.receipt.parent.mkdir(parents=True, exist_ok=True)
                args.receipt.write_text(json.dumps({**base_receipt, "status": "error", "error": str(error),
                    "cases": [{key: value for key, value in case.items() if key != "outputHtml"}
                              for case in assembled]}, ensure_ascii=False, indent=2) + "\n")
            raise
        by_id = {value["id"]: value for value in observed["results"]}
        for case, value in zip(cases, assembled):
            compare_case(case, value, by_id[case["id"]])
            value.pop("outputHtml", None)
            value["status"] = "pending" if value["expectedOutcome"] == "pending" else "failed" if value["errors"] else "passed"
            print(f"{value['status'].upper()} {case['id']}: {value['actualOutcome']}")
            for error in value["errors"]:
                print("  " + error)
        require(hashlib.sha256(binary.read_bytes()).hexdigest() == digest, "tested binary changed during compatibility run")
        failed = [value for value in assembled if value["status"] == "failed"]
        receipt = {**base_receipt, "status": "failed" if failed else "passed",
                   "cases": assembled, "browser": observed}
        if args.receipt:
            args.receipt.parent.mkdir(parents=True, exist_ok=True)
            args.receipt.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
        require(not failed, f"{len(failed)} synthetic HTML compatibility cases failed")


if __name__ == "__main__":
    main()
