#!/usr/bin/env python3
"""Synthetic HTML-reader CLI/PTY gates; require the cooperative runtime window."""
import argparse
import contextlib
import hashlib
import html as html_escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import sys
import tempfile
import threading
import time

from build_info import build_mode, read_build_info
from terminal_cache import seed, metrics
from terminal_integration import ACCOUNTS, ROOT, Client, require
from terminal_pty import Terminal
from terminal_reader import reader_rectangle, reader_rows, reader_contains
from terminal_html_screen import HtmlScreen
from terminal_measure import Sampler, process_sample, quiet, summarize, allocator_receipt
from terminal_ui import palette, theme_path, UI_FIXTURES

sys.path.insert(0, str(Path(__file__).resolve().parent / "probes"))
from html_fixture import HTML_ROOT, MANIFEST, HtmlFixture, body, body_snapshot, document, rewrite_legacy, substitute

CASES = ("html-body-provenance", "html-legacy-cache", "html-structure-style", "html-responsive-tables",
         "html-safety-flatten", "html-cached-legacy-view", "html-reader-ux", "html-large-navigation-reuse")


class HtmlFailure(Exception):
    def __init__(self, message, diagnostics):
        super().__init__(message)
        self.diagnostics = diagnostics


def screen_capture(terminal):
    if terminal is None: return {}
    runs = []
    for y, styles in enumerate(terminal.screen.styles):
        run_start = 0
        for x in range(1, len(styles) + 1):
            if x == len(styles) or styles[x] != styles[run_start]:
                runs.append([y, run_start, x, styles[run_start]])
                run_start = x
    return {"currentCells": ["".join(row) for row in terminal.screen.cells],
            "cellGrid": [row[:] for row in terminal.screen.cells],
            "currentStyleRuns": runs, "readerRectangle": reader_rectangle(terminal.screen),
            "processExitCode": terminal.process.poll(), "stage": getattr(terminal, "html_stage", "unspecified")}


def failed_view(failure, terminal, metrics_path):
    diagnostics = screen_capture(terminal)
    if terminal is not None:
        try: terminal.close()
        except Exception as cleanup_error:
            diagnostics["closeIssue"] = type(cleanup_error).__name__
    if metrics_path.exists():
        try: diagnostics["htmlMetrics"] = html_metrics(metrics_path)
        except Exception as metric_error: diagnostics["metricsIssue"] = str(metric_error)
    return HtmlFailure(str(failure), diagnostics)


def cached_literal(client, account, identity, source, text, html):
    message = client.request("mail.read", account, messageId=identity, cacheOnly=True)
    require(message["bodySource"] == source, "HTML reader provenance changed or was inferred into old stored data")
    require(message["bodyText"] == text and message["bodyHtml"] == html, "HTML reader changed the CLI's complete literal bodies")
    require(message["id"] == identity and message["threadId"] == MANIFEST["threadId"], "HTML body lost account/thread identity")
    return message


def within_reader(terminal, text):
    rectangle = reader_rectangle(terminal.screen)
    if rectangle is None: return None
    for row, visible in reader_rows(terminal.screen):
        offset = visible.find(text)
        if offset >= 0:
            # Reader strings contain grapheme cells, including continuation
            # cells. Locate the literal through the cells to preserve columns.
            for column in range(rectangle["left"], rectangle["right"]):
                if "".join(terminal.screen.cells[row][column:rectangle["right"]]).startswith(text):
                    return row, column
    return None


def collect_reader(terminal, required=(), max_steps=100):
    observed = []
    for step in range(max_steps + 1):
        observed.extend(text for _, text in reader_rows(terminal.screen))
        joined = "\n".join(observed)
        # Rejoin soft wraps of the COMPLETE requested literals, within reader
        # cells only. No sidebar, historical VT buffer or shortened token is used.
        canonical = "".join(joined.split())
        if all("".join(text.split()) in canonical for text in required): return observed
        if step == max_steps: break
        terminal.send(b"j")
        terminal.gap(.015)
    raise AssertionError("complete expected HTML content was not reachable by reader scrolling")


def cell_style(terminal, text):
    position = within_reader(terminal, text)
    require(position is not None, "expected styled text is absent from current reader cells")
    return terminal.screen.styles[position[0]][position[1]]


def reset_reader(terminal):
    terminal.send(b"k" * 100)
    terminal.gap(.15)


def html_metrics(path):
    value = json.loads(path.read_bytes())
    require(value.get("allocatorPeakBytes", 2**64) <= 64 * 1024**2 and value.get("rejectedAllocations") == 0,
            "HTML view exceeded the terminal heap or denied a bounded allocation")
    stats = value.get("html")
    keys = {"htmlDocumentBuilds", "htmlLayoutBuilds", "htmlFallbacks"}
    require(isinstance(stats, dict) and set(stats) == keys and
            all(type(v) is int and v >= 0 for v in stats.values()), "HTML parse/layout reuse metrics missing or invalid")
    return stats


def start(binary, directory, fixture, metrics_path, columns=180, rows=60, extra=()):
    theme = theme_path(directory)
    shutil.copyfile(UI_FIXTURES / "theme-colors.toml", theme)
    return Terminal(binary, directory, extra=fixture.options("--metrics-file", str(metrics_path), *extra),
                    environment={"COLORTERM": "truecolor", "NO_COLOR": None},
                    screen_type=HtmlScreen, columns=columns, rows=rows)


@contextlib.contextmanager
def resource_peer():
    class Peer(BaseHTTPRequestHandler):
        def do_GET(self):
            self.server.requests.append(self.path)
            self.send_response(200); self.end_headers(); self.wfile.write(b"synthetic")
        def log_message(self, *_): pass
    server = ThreadingHTTPServer(("127.0.0.1", 0), Peer)
    server.requests = []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server, f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=5)
        require(not thread.is_alive(), "owned synthetic resource peer did not join")


def cli_case(binary, directory, legacy):
    fixture = HtmlFixture(directory, "legacy")
    seed(binary, directory, fixture, accounts=ACCOUNTS, bodies=("shared-msg-094", "shared-msg-095", "shared-msg-096"))
    expected = rewrite_legacy(directory, ACCOUNTS) if legacy else None
    saved = body_snapshot(directory, ACCOUNTS)
    with Client(binary, directory, extra=fixture.options()) as client:
        for account in ACCOUNTS:
            before = metrics(client, account)
            if legacy:
                for identity in ("shared-msg-096", "shared-msg-095", "shared-msg-094"):
                    value = expected[(account, identity)]
                    cached_literal(client, account, identity, value["bodySource"], value["bodyText"], value["bodyHtml"])
            else:
                cached_literal(client, account, MANIFEST["htmlMessageId"], "html",
                    substitute(MANIFEST["legacyTextTemplate"], account), document("legacy", account))
                cached_literal(client, account, MANIFEST["plainPreferredMessageId"], "plain",
                    substitute(MANIFEST["plainPreferredTemplate"], account), document("legacy", account))
            thread = client.request("mail.thread", account, threadId=MANIFEST["threadId"], cacheOnly=True)["messages"]
            require(all(m["threadId"] == MANIFEST["threadId"] for m in thread), "HTML cached thread crossed account/thread routing")
            require({m["id"] for m in thread} == {"shared-msg-094", "shared-msg-095", "shared-msg-096"}, "HTML cached thread lost literal messages")
            after = metrics(client, account)
            require(after["fixtureCalls"] == before["fixtureCalls"] and after["fixtureSends"] == 0,
                    "HTML provenance inspection fetched or submitted mail")
        client.restart()
        require(body_snapshot(directory, ACCOUNTS) == saved, "HTML provenance or restart rewrote immutable cached bodies")
    return {"accountsChecked": 3, "cachedBodyDigestsPreserved": True, "providerCallsDuringReads": 0,
            "legacyMissingProvenance": legacy, "plainPreferencePreserved": True, "bodyTextConverterUnchanged": True}


def formatted_case(binary, directory, name):
    kind = "legacy" if name == "html-cached-legacy-view" else "document"
    fixture = HtmlFixture(directory, kind)
    seed(binary, directory, fixture, bodies=("shared-msg-094", "shared-msg-095", "shared-msg-096"))
    if kind == "legacy": rewrite_legacy(directory)
    saved = body_snapshot(directory)
    fixture.stage(ACCOUNTS[0], "baseline", held=True)
    metrics_path = directory / "html-metrics.json"
    terminal = None
    try:
        terminal = start(binary, directory, fixture, metrics_path)
        fixture.wait_entered(terminal.process, pump=terminal.pump)
        heading = "Legacy fictional brief" if kind == "legacy" else MANIFEST["heading"]
        terminal.until(lambda: within_reader(terminal, heading) is not None)
        terminal.send(b"l")  # Focus the single cached reader; do not enter a full thread.
        result = {"cachedReadBeforeRemoteRelease": True}
        if name == "html-structure-style":
            require(cell_style(terminal, heading)[2] is True, "HTML heading is not bold in current reader cells")
            require(cell_style(terminal, heading)[0] == palette(UI_FIXTURES / "theme-colors.toml", "accent"), "HTML heading omitted theme accent color")
            for text, style in MANIFEST["styles"].items():
                require(cell_style(terminal, text)[{"bold": 2, "italic": 3, "underline": 4}[style]], "HTML inline semantic style missing")
            require(cell_style(terminal, "Guide")[0] == palette(UI_FIXTURES / "theme-colors.toml", "cyan"), "safe link omitted theme link color")
            require(cell_style(terminal, "literal_code")[1] == palette(UI_FIXTURES / "theme-colors.toml", "selection"), "inline code omitted code background")
            rows = [text for _, text in reader_rows(terminal.screen)]
            for text in MANIFEST["unorderedItems"]: require(any("• " + text in row for row in rows), "unordered HTML list bullet missing")
            for index, text in enumerate(MANIFEST["orderedItems"], 1): require(any(f"{index}. " + text in row for row in rows), "ordered HTML list number missing")
            require(any("│" in row and MANIFEST["quote"] in row for row in rows), "HTML quote structural prefix missing")
            require(cell_style(terminal, MANIFEST["quote"])[3], "HTML quote italic style missing")
            for line in MANIFEST["preLines"]: require(any(line in row for row in rows), "HTML preformatted literal spacing/newline changed")
            table_lines = [next(row for row in rows if literal in row) for literal in ("Item", "Pears", "Tea")]
            dividers = [[i for i, c in enumerate(row) if c == "│"] for row in table_lines]
            require(dividers[0] == dividers[1] == dividers[2] and len(dividers[0]) >= 4, "HTML data-table cell boundaries do not align")
            for cells, row in zip(MANIFEST["table"], table_lines): require(all(cell in row for cell in cells), "HTML data table lost complete cell content")
            result.update(headingBoldAccent=True, inlineStyles=True, lists=True, quote=True, preSpacing=True, tableAligned=True)
            result.update(screen_capture(terminal))
        elif name == "html-responsive-tables":
            observations = []
            for columns, rows, layout, expanded in ((160, 40, "right", False), (82, 30, "below", False), (70, 20, "right", True)):
                terminal.resize(columns, rows)
                terminal.send(b":layout " + layout.encode() + b"\r")
                terminal.gap(.1)
                if expanded: terminal.send(b"z"); terminal.gap(.1)
                reset_reader(terminal)
                observed = collect_reader(terminal, ("Fictional document tail marker.",), max_steps=100)
                joined = "\n".join(observed)
                for cell in ("Pears", "Tea", "€3.50", "€8.00", "Qty", "Total"):
                    require(cell in joined, "responsive table omitted a header or cell instead of stacking it")
                require("café" in joined and "∴" in joined and "👋" in joined, "responsive HTML reader lost Unicode content")
                require(not any(terminal.screen.cells[y][-1] == "" for y in range(terminal.rows)), "HTML wide glyph crossed terminal edge")
                observations.append({"columns": columns, "rows": rows, "layout": layout, "expanded": expanded})
            result.update(geometries=observations, allTableCellsReachable=True, unicodePreserved=True)
        else:
            require(cell_style(terminal, heading)[2], "old unknown cached HTML did not format matching legacy text locally")
            terminal.send(b"J")
            terminal.until(lambda: within_reader(terminal, heading) is not None and not cell_style(terminal, heading)[2])
            require(not cell_style(terminal, heading)[2], "explicit plain provenance was overridden by matching HTML")
            terminal.send(b"J")
            mismatch = substitute(MANIFEST["plainMismatchTemplate"], ACCOUNTS[0]).strip()
            terminal.until(lambda: reader_contains(terminal.screen, mismatch))
            require(not reader_contains(terminal.screen, heading), "unknown mismatching fallback text was replaced by HTML")
            result.update(oldMatchingHtmlFormatted=True, explicitPlainHonored=True, mismatchingUnknownHonored=True)
        result.update(terminal.finish())
        require(body_snapshot(directory) == saved, "HTML reader rewrote its valid immutable cached bodies")
        result["htmlMetrics"] = html_metrics(metrics_path)
        result["cachedBodyDigestsPreserved"] = True
        return result
    except Exception as failure:
        wrapped = failed_view(failure, terminal, metrics_path)
        terminal = None
        raise wrapped from failure
    finally:
        fixture.release()
        if terminal is not None: terminal.close()


def safety_case(binary, directory):
    with resource_peer() as (peer, origin):
        fixture = HtmlFixture(directory, "safety", tracker_url=origin)
        seed(binary, directory, fixture, bodies=("shared-msg-096",))
        fixture.stage(ACCOUNTS[0], "baseline", held=True)
        terminal = None
        path = directory / "html-metrics.json"
        try:
            terminal = start(binary, directory, fixture, path)
            fixture.wait_entered(terminal.process, pump=terminal.pump)
            terminal.until(lambda: within_reader(terminal, "Fictional safe HTML") is not None)
            terminal.send(b"l")
            spec = json.loads((HTML_ROOT / "safety.json").read_text())
            observed = collect_reader(terminal, spec["visible"])
            joined = "\n".join(observed)
            canonical = "".join(joined.split())
            require(not any("".join(marker.split()) in canonical for marker in spec["hidden"]), "HTML renderer exposed a hidden/script/resource node")
            require(not any("".join(target.split()) in canonical for target in spec["unsafeTargets"]), "HTML renderer displayed unsafe navigation targets")
            require(b"\x1b]52;" not in terminal.output and b"\x1b]8;" not in terminal.output,
                    "HTML reader emitted clipboard or hyperlink terminal controls")
            require(not any(char in joined for char in ("\x1b", "\x07", "\u202e", "\u202c")), "HTML reader retained unsafe text controls/bidi")
            result = terminal.finish()
            require(peer.requests == [], "HTML reader fetched an image/frame/stylesheet resource")
            result.update(hiddenNodesExcluded=True, unsafeTargetsExcluded=True, resourcesRequested=0, htmlMetrics=html_metrics(path))
        except Exception as failure:
            wrapped = failed_view(failure, terminal, path)
            terminal = None
            raise wrapped from failure
        finally:
            fixture.release()
            if terminal is not None: terminal.close()
    layout_dir = directory / "layout-view"
    fixture = HtmlFixture(layout_dir, "layout")
    seed(binary, layout_dir, fixture, bodies=("shared-msg-096",))
    fixture.stage(ACCOUNTS[0], "baseline", held=True)
    terminal = None
    try:
        terminal = start(binary, layout_dir, fixture, layout_dir / "html-metrics.json")
        fixture.wait_entered(terminal.process, pump=terminal.pump)
        terminal.until(lambda: within_reader(terminal, "Fictional layout letter") is not None)
        terminal.send(b"l")
        seen = collect_reader(terminal, ("Left content is readable.", "Right content is readable.", "Fictional layout tail marker."))
        require(not any("┼" in row for row in seen), "presentation/nested layout table was rendered as a data grid")
        result["layoutTablesFlattened"] = True
        terminal.finish()
        return result


    except Exception as failure:
        wrapped = failed_view(failure, terminal, layout_dir / "html-metrics.json")
        terminal = None
        raise wrapped from failure
    finally:
        fixture.release()
        if terminal is not None: terminal.close()


def reader_ux_fixture(directory, variant, spec, tracker_url):
    """Populate ordinary MIME fixtures; no renderer-derived expected output."""
    fixture = HtmlFixture(directory, "document", tracker_url=tracker_url)
    expected = {}
    for account in ACCOUNTS:
        source = fixture.data[account]["baseline"]
        message = next(value for value in source["messages"] if value["id"] == MANIFEST["htmlMessageId"])
        literal = substitute(variant["bodyTemplate"], account, tracker_url)
        literal = literal.replace("{longUrlHtml}", html_escape.escape(spec["longUrl"], quote=True))
        literal = literal.replace("{longPathHtml}", html_escape.escape(spec["longPathUrl"], quote=True))
        literal = literal.replace("{longUrl}", spec["longUrl"]).replace("{longPathUrl}", spec["longPathUrl"])
        headers = [value for value in message["payload"]["headers"]
                   if value["name"].lower() not in {"content-type", "content-transfer-encoding", "content-disposition"}]
        message["payload"] = {"partId": "", "mimeType": variant["mimeType"], "filename": "",
            "headers": headers + [{"name": "Content-Type", "value": variant["mimeType"] + "; charset=utf-8"}],
            "body": body(literal)}
        fixture.stage(account, "baseline")
        expected[account] = literal
    return fixture, expected


def reader_ux_case(binary, directory):
    spec = json.loads((HTML_ROOT / "reader-ux.json").read_text())
    observations = []
    with resource_peer() as (peer, origin):
        for variant in spec["variants"]:
            owned = directory / variant["name"]
            fixture, expected = reader_ux_fixture(owned, variant, spec, origin)
            seed(binary, owned, fixture, bodies=(MANIFEST["htmlMessageId"],))
            saved = body_snapshot(owned)
            with Client(binary, owned, extra=fixture.options()) as client:
                message = client.request("mail.read", messageId=MANIFEST["htmlMessageId"], cacheOnly=True)
                if variant["mimeType"] == "text/plain":
                    require(message["bodySource"] == "plain" and message["bodyText"] == expected[ACCOUNTS[0]],
                            "HTML-looking or technical plaintext changed its authoritative bytes/provenance")
                else:
                    require(message["bodySource"] == "html" and message["bodyHtml"] == expected[ACCOUNTS[0]],
                            "marketing HTML source bytes/provenance changed while preparing its view")
            if variant.get("cliOnly"):
                observations.append({"variant": variant["name"], "plainProvenanceAndBytesPreserved": True})
                continue  # Display inference for mislabeled plaintext has no blanket policy.
            fixture.stage(ACCOUNTS[0], "baseline", held=True)
            path = owned / "html-metrics.json"
            terminal = None
            try:
                terminal = start(binary, owned, fixture, path)
                fixture.wait_entered(terminal.process, pump=terminal.pump)
                terminal.until(lambda: reader_contains(terminal.screen, variant["visible"][0]))
                terminal.send(b"l")
                visible = [substitute(value, ACCOUNTS[0]) for value in variant["visible"]]
                if variant["name"] in {"marketing-html", "plain-links-and-literals"}:
                    visible.extend((spec["longDisplay"], spec["longPathDisplay"]))
                observed = collect_reader(terminal, visible)
                joined = "\n".join(observed)
                canonical = "".join(joined.split())
                require(not any("".join(value.split()) in canonical for value in variant["absent"]),
                        "marketing view leaked raw tags, comments or CSS/filter debris")
                for value in variant["styled"]:
                    reset_reader(terminal)
                    terminal.until(lambda value=value: within_reader(terminal, value) is not None)
                    style = cell_style(terminal, value)
                    require(style[0] == palette(UI_FIXTURES / "theme-colors.toml", "cyan") and style[4],
                            "human HTML link label lost cyan/underline styling")
                if variant["name"] in {"marketing-html", "plain-links-and-literals"}:
                    reset_reader(terminal)
                    terminal.until(lambda: within_reader(terminal, "https://example.test") is not None)
                    style = cell_style(terminal, "https://example.test")
                    require(style[0] == palette(UI_FIXTURES / "theme-colors.toml", "cyan") and style[4],
                            "visible naked/plain URL lost cyan/underline styling")
                    require(spec["longUrl"] not in canonical and spec["longPathUrl"] not in canonical,
                            "long URL tracking tail still occupies the reading view")
                require(b"\x1b]8;" not in terminal.output and b"\x1b]52;" not in terminal.output,
                        "reader UX emitted mail-authored terminal controls")
                terminal.finish()
                require(body_snapshot(owned) == saved, "reader UX rewrote immutable source/body cache")
                require(peer.requests == [], "reader UX fetched an image or marketing resource")
                observations.append({"variant": variant["name"], "readableBody": True,
                    "compactStyledLinks": variant["name"] in {"marketing-html", "plain-links-and-literals"},
                    "literalSourcePreserved": True, "remoteResourcesRequested": 0})
            except Exception as failure:
                wrapped = failed_view(failure, terminal, path)
                terminal = None
                raise wrapped from failure
            finally:
                fixture.release()
                if terminal is not None: terminal.close()
    return {"variants": observations, "remoteResourcesRequested": 0,
            "longUrlSourceBytes": len(spec["longUrl"].encode()), "displayLimitBytes": spec["displayLimitBytes"]}

def resource_case(binary, directory, cycles, idle):
    counts = []
    measurement = None
    for name, repetitions in (("baseline", 0), ("navigation", cycles)):
        owned = directory / name
        fixture = HtmlFixture(owned, "large")
        seed(binary, owned, fixture, bodies=("shared-msg-096",))
        before = body_snapshot(owned)
        path = owned / "html-metrics.json"
        terminal = None
        try:
            terminal = start(binary, owned, fixture, path, columns=100, rows=24, extra=("--fixture-scenario", "offline-refresh"))
            terminal.html_stage = "large-visible-head"
            terminal.until(lambda: reader_contains(terminal.screen, "Fictional large HTML"), seconds=20)
            terminal.html_stage = "offline-state"
            terminal.until(lambda: "Offline cached mail" in terminal.text())
            terminal.html_stage = "end-visible-tail"
            terminal.send(b"l")
            terminal.send(b"G")
            terminal.until(lambda: reader_contains(terminal.screen, "Fictional large tail marker."))
            terminal.html_stage = "home-visible-head"
            terminal.send(b"\x1b[H")
            terminal.until(lambda: reader_contains(terminal.screen, "Fictional large HTML"))
            original = [text for _, text in reader_rows(terminal.screen)]

            def navigate():
                terminal.send(b"j")
                terminal.until(lambda: [text for _, text in reader_rows(terminal.screen)] != original)
                terminal.send(b"k")
                terminal.until(lambda: [text for _, text in reader_rows(terminal.screen)] == original)

            samples = []
            baseline = process_sample(terminal.process.pid)
            with Sampler(terminal.process.pid) as sampler:
                terminal.html_stage = "warmup-navigation"
                for _ in range(100): navigate()
                started = time.monotonic()
                terminal.html_stage = "measured-navigation"
                for index in range(repetitions):
                    navigate()
                    samples.append({"cycle": index + 1, **process_sample(terminal.process.pid)})
                    if (index + 1) % 100 == 0:
                        print(f"HTML {index+1}/{repetitions}: RSS{samples[-1]['rssKiB']}KiB PSS{samples[-1]['pssKiB']}KiB", flush=True)
                if repetitions:
                    measurement = {"warmup": 100, "completedCycles": repetitions,
                                   "soakSeconds": round(time.monotonic()-started, 4),
                                   "fixedReservationBytes": 16 * 1024**2,
                                   "rssAbsoluteLimit": None, "pssAbsoluteLimit": None}
                    terminal.gap(.25)
                    output_before = terminal.output_total
                    terminal.html_stage = "quiet-interval"
                    measurement["quiet"] = quiet(terminal.process, idle, terminal.pump)
                    require(terminal.output_total == output_before, "HTML reader redrew while quiet without input")
                    measurement["quiet"].update(inputKeysIssued=0, outputBytesAdded=0)
            terminal.html_stage = "clean-exit"
            terminal.finish()
            require(body_snapshot(owned) == before, "large HTML navigation changed cached body bytes")
            counts.append(html_metrics(path))
            if repetitions:
                measurement["allocator"] = allocator_receipt(path)
                summarize(measurement, samples, baseline, sampler)
                require(all(measurement["checks"].values()), "HTML-heavy memory/quiet acceptance gate failed")
        except Exception as failure:
            wrapped = failed_view(failure, terminal, path)
            terminal = None
            raise wrapped from failure
        finally:
            if terminal is not None: terminal.close()
    require(counts[0]["htmlDocumentBuilds"] > 0, "HTML resource gate never attempted bounded HTML formatting")
    require(counts[0] == counts[1], "navigation reparsed/relaid out the entire unchanged HTML document")
    deep_dir = directory / "deep"
    fixture = HtmlFixture(deep_dir, "depth")
    seed(binary, deep_dir, fixture, bodies=("shared-msg-096",))
    terminal = None
    try:
        path = deep_dir / "html-metrics.json"
        terminal = start(binary, deep_dir, fixture, path, extra=("--fixture-scenario", "offline-refresh"))
        terminal.until(lambda: reader_contains(terminal.screen, f"Fictional {ACCOUNTS[0]}: deep café 👋."))
        require("Plain text · HTML layout unavailable" in terminal.text(), "bounded HTML failure omitted explicit full-text fallback status")
        terminal.finish()
        require(html_metrics(path)["htmlFallbacks"] > 0, "deep HTML parser refusal was not counted")
    except Exception as failure:
        wrapped = failed_view(failure, terminal, path)
        terminal = None
        raise wrapped from failure
    finally:
        if terminal is not None: terminal.close()
    return {"decodedHtmlBytes": MANIFEST["inputByteLimit"], "navigationCycles": cycles,
            "reuseCountersUnchanged": True, "htmlMetrics": counts[1], "measurement": measurement,
            "acceptanceRun": cycles == 1000 and idle == 60,
            "completeLargeBodyTailReachable": True,
            "quietOutputBytes": 0, "deepFallbackExplicit": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--build-mode", type=build_mode, default="debug")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--case", action="append", choices=CASES)
    parser.add_argument("--resource-cycles", type=int, default=100)
    parser.add_argument("--idle-seconds", type=float, default=2)
    args = parser.parse_args()
    require(1 <= args.resource_cycles <= 1000 and 1 <= args.idle_seconds <= 60, "invalid bounded HTML resource workload")
    require(not args.output.exists(), "refusing previous HTML evidence overwrite")
    binary = args.binary.resolve()
    report = {**read_build_info(binary, args.build_mode), "binarySha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "syntheticOnly": True, "liveWrites": False, "desktopUsed": False, "cases": []}
    with tempfile.TemporaryDirectory(prefix="omagma-html-test-") as temporary:
        for name in CASES:
            if args.case and name not in args.case: continue
            started = time.monotonic()
            try:
                directory = Path(temporary) / name
                if name in CASES[:2]: data = cli_case(binary, directory, name == "html-legacy-cache")
                elif name == "html-safety-flatten": data = safety_case(binary, directory)
                elif name == "html-large-navigation-reuse": data = resource_case(binary, directory, args.resource_cycles, args.idle_seconds)
                elif name == "html-reader-ux": data = reader_ux_case(binary, directory)
                else: data = formatted_case(binary, directory, name)
                receipt = {"name": name, "passed": True, **data}
            except Exception as error:
                receipt = {"name": name, "passed": False, "error": f"{type(error).__name__}: {error}"}
                if isinstance(error, HtmlFailure): receipt["diagnostics"] = error.diagnostics
            receipt["elapsedSeconds"] = round(time.monotonic()-started, 4)
            report["cases"].append(receipt)
            print(json.dumps(receipt), flush=True)
            if not receipt["passed"]: break
    report["passed"] = bool(report["cases"]) and all(c["passed"] for c in report["cases"])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2)+"\n")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
