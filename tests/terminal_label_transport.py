#!/usr/bin/env python3
"""Independent loopback wire peer for label POST/PATCH/DELETE and empty 204."""
import argparse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading

from terminal_integration import no_core_dump, require

BODY = '{"name":"Fixture 🌋"}'.encode()


class Peer(ThreadingHTTPServer):
    daemon_threads = False
    block_on_close = True

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(10)
        return connection, address


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def respond(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            require(0 <= length <= 4096, "synthetic label request size exceeded")
            body = self.rfile.read(length)
            with self.server.capture_lock:
                require(len(self.server.requests) < 32, "synthetic request cap exceeded")
                self.server.requests.append({"method": self.command, "path": self.path,
                                             "headers": self.headers, "body": body})
            status = 204 if self.command == "DELETE" else 200
            result = b"" if status == 204 else '{"id":"Label_fixture","name":"Fixture 🌋","type":"user"}'.encode()
            if self.path == "/empty":
                status, result = 200, b""
            elif self.path == "/bad-json":
                status, result = 200, b"{malformed}"
            elif self.path == "/denied":
                status, result = 403, b"{}"
            elif self.path == "/unknown":
                status, result = 503, b"{}"
            elif self.path == "/redirect":
                self.send_response(302)
                self.send_header("Location", "/forwarded")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            elif self.path == "/oversize":
                self.send_response(200)
                self.send_header("Content-Length", str(3 * 1024**2 + 1))
                self.end_headers()
                self.close_connection = True
                return
            self.send_response(status)
            if status != 204:
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(result)))
            self.end_headers()
            if result:
                self.wfile.write(result)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass

    do_POST = respond
    do_PATCH = respond
    do_DELETE = respond
    do_GET = respond


@contextmanager
def server():
    peer = Peer(("127.0.0.1", 0), Handler)
    peer.capture_lock = threading.Lock()
    peer.requests = []
    worker = threading.Thread(target=peer.serve_forever)
    worker.start()
    try:
        yield peer
    finally:
        peer.shutdown()
        peer.server_close()
        worker.join(timeout=3)
        require(not worker.is_alive(), "wire peer cleanup did not join")


def run(binary, directory):
    env = dict(os.environ, HOME=str(directory))
    for key in ("DISPLAY", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS"):
        env.pop(key, None)
    with server() as peer:
        origin = f"http://127.0.0.1:{peer.server_port}"
        cases = [(method, "/ok", "") for method in ("POST", "PATCH", "DELETE")]
        cases += [("DELETE", path, error) for path, error in (("/empty", "UnknownOutcome"), ("/bad-json", "UnknownOutcome"),
                  ("/denied", "PermissionDenied"), ("/unknown", "UnknownOutcome"), ("/redirect", "UnknownOutcome"), ("/oversize", "UnknownOutcome"))]
        for method, path, expected_error in cases:
            before = len(peer.requests)
            process = subprocess.run([str(binary), "probe-label-http", method, origin + path], capture_output=True,
                                     env=env, cwd=directory, timeout=15, preexec_fn=no_core_dump)
            require(process.returncode == 0 and not process.stderr, "label transport probe failed")
            receipt = json.loads(process.stdout)
            require(receipt["errorCode"] == expected_error and receipt["ok"] == (not expected_error), "label transport boundary returned wrong outcome")
            require(len(peer.requests) == before + 1, "mutation followed redirect or retried its wire request")
            captured = peer.requests[-1]
            require(captured["method"] == method and captured["path"] == path, "actual request changed method/path")
            require(captured["headers"].get_all("Authorization", []) == ["Bearer synthetic-omagma-bearer"], "wire authorization missing or duplicated")
            require(captured["headers"].get_all("Accept-Encoding", []) == ["identity"], "wire requested compressed response")
            require(not captured["headers"].get_all("Transfer-Encoding", []), "unexpected chunked request")
            if method == "DELETE":
                require(captured["body"] == b"" and not captured["headers"].get_all("Content-Type", []), "DELETE carried a body")
            else:
                require(captured["body"] == BODY, "UTF-8 label payload changed on the wire")
                require(captured["headers"].get_all("Content-Type", []) == ["application/json"], "JSON content type missing")
                require(captured["headers"].get_all("Content-Length", []) == [str(len(BODY))], "wire content length did not match exact UTF-8 bytes")
            if not expected_error and method == "DELETE":
                require(receipt["status"] == 204 and receipt["bodyBytes"] == 0, "real empty 204 was not accepted")
        before = len(peer.requests)
        blocked = subprocess.run([str(binary), "probe-label-http", "DELETE", "http://localhost:1/labels"],
                                 capture_output=True, env=env, cwd=directory, timeout=5, preexec_fn=no_core_dump)
        require(json.loads(blocked.stdout)["errorCode"] == "InvalidHost" and len(peer.requests) == before, "loopback probe reached an unapproved destination")
    print("PASS independent label POST/PATCH/DELETE wire, UTF-8 payload, empty 204, unknown guards and redirect rejection")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="omagma-label-wire-") as temporary:
        run(args.binary.resolve(), Path(temporary))


if __name__ == "__main__":
    main()
