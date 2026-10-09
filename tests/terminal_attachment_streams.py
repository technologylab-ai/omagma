#!/usr/bin/env python3
"""Synthetic loopback checks for native attachment upload/download streaming."""
from __future__ import annotations

import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import threading


SIZE = 4 * 1024 * 1024
BLOCK = bytes((i * 31 + 7) & 255 for i in range(256)) * 128
EXPECTED = hashlib.sha256(BLOCK * (SIZE // len(BLOCK))).hexdigest()


class Server(ThreadingHTTPServer):
    daemon_threads = True
    uploads: list[dict] = []
    requests: list[str] = []


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_POST(self):
        self.server.requests.append(self.path)
        remaining = int(self.headers["Content-Length"])
        total = remaining
        digest = hashlib.sha256()
        while remaining:
            chunk = self.rfile.read(min(32768, remaining))
            if not chunk:
                self.close_connection = True
                return
            digest.update(chunk)
            remaining -= len(chunk)
        self.server.uploads.append({"size": total, "sha256": digest.hexdigest(),
                                    "authorization": self.headers.get("Authorization"),
                                    "contentType": self.headers.get("Content-Type")})
        body = b'{"id":"fixture-sent"}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.server.requests.append(self.path)
        if self.path == "/unauthorized":
            body = b'{"error":{"code":401}}'
            self.send_response(401)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:1/unfollowed")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        chunked = self.path == "/chunked"
        self.send_response(200)
        self.send_header("Transfer-Encoding" if chunked else "Content-Length",
                         "chunked" if chunked else str(SIZE))
        self.end_headers()
        try:
            for _ in range(SIZE // len(BLOCK)):
                if chunked:
                    self.wfile.write(f"{len(BLOCK):x}\r\n".encode())
                self.wfile.write(BLOCK)
                if chunked:
                    self.wfile.write(b"\r\n")
            if chunked:
                self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, required=True)
    args = parser.parse_args()
    server = Server(("127.0.0.1", 0), Handler)
    server.uploads = []
    server.requests = []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_port}"
    receipts = []

    def run(path, mode, size=SIZE):
        completed = subprocess.run([str(args.probe.resolve()), base + path, mode, str(size)],
                                   capture_output=True, text=True, timeout=40, check=True)
        assert not completed.stderr, completed.stderr
        receipt = json.loads(completed.stdout)
        assert receipt["zigVersion"] == "0.17.0", receipt
        receipts.append({"case": path + ":" + mode, **receipt})
        return receipt

    try:
        uploaded = run("/upload", "upload")
        assert uploaded["ok"] and uploaded["status"] == 200, uploaded
        assert uploaded["sourceBytes"] == SIZE and uploaded["sourceCalls"] > 1, uploaded
        assert server.uploads[-1] == {"size": SIZE, "sha256": EXPECTED,
                                      "authorization": "Bearer synthetic-omagma-bearer",
                                      "contentType": "message/rfc822"}, server.uploads[-1]
        for path in ["/download", "/chunked"]:
            downloaded = run(path, "download")
            assert downloaded["ok"] and downloaded["status"] == 200, downloaded
            assert downloaded["sinkBytes"] == SIZE and downloaded["sinkSha256"] == EXPECTED, downloaded
        unauthorized = run("/unauthorized", "download")
        assert unauthorized["ok"] and unauthorized["status"] == 401, unauthorized
        assert unauthorized["sinkBytes"] == 0, unauthorized
        redirect = run("/redirect", "download")
        assert redirect["error"] == "RedirectRejected" and redirect["sinkBytes"] == 0, redirect
        for path in ["/download", "/chunked"]:
            oversized = run(path, "download", SIZE - 1)
            assert oversized["error"] == "ResponseTooLarge", oversized
            assert oversized["sinkBytes"] <= SIZE - 1, oversized
        before = len(server.requests)
        rejected = run("/must-not-connect", "upload", 36 * 1024 * 1024 + 1)
        assert rejected["error"] == "FormTooLarge" and rejected["sourceCalls"] == 0, rejected
        assert len(server.requests) == before, server.requests
        short = run("/short", "short-upload", 1024)
        assert short["error"] == "BodySizeMismatch", short
        print(json.dumps({"syntheticOnly": True, "passed": len(receipts), "receipts": receipts}, indent=2))
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


if __name__ == "__main__":
    main()
