#!/usr/bin/env python3
"""Synthetic loopback checks for native attachment upload/download streaming."""
from __future__ import annotations

import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import threading


SIZE = 4 * 1024 * 1024
BLOCK = bytes((i * 31 + 7) & 255 for i in range(256)) * 128
EXPECTED = hashlib.sha256(BLOCK * (SIZE // len(BLOCK))).hexdigest()
INCOMING_LIMIT = 50 * 1024 * 1024
DOWNLOAD_WIRE_LIMIT = 69_970_604
# A multiple of three and of the 256-byte pattern: each encoded chunk is a
# complete base64 group. Neither the provider oracle nor the native decoder
# materializes the complete large file or JSON response.
WIRE_BLOCK = BLOCK[:24 * 1024]
ENCODED_BLOCK = base64.urlsafe_b64encode(WIRE_BLOCK)


def digest_for_size(size):
    digest = hashlib.sha256()
    while size:
        part = BLOCK[:min(size, len(BLOCK))]
        digest.update(part)
        size -= len(part)
    return digest.hexdigest()


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
        if self.path == "/unauthorized" or (self.path == "/attachment-retry"
                                             and self.server.requests.count(self.path) == 1):
            body = b'{"error":{"code":401}}'
            self.send_response(401)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/attachment-retry":
            self.attachment(3, chunked=False)
            return
        if self.path == "/attachment-stalled":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            # Deliver enough valid data to enter the decoder, then wait for
            # peer EOF. The probe's short internal deadline must cancel and
            # join its blocked read; no long sleep simulates cancellation.
            part = b'{"data":"' + ENCODED_BLOCK
            try:
                self.wfile.write(f"{len(part):x}\r\n".encode() + part + b"\r\n")
                self.wfile.flush()
                self.connection.settimeout(3)
                if self.connection.recv(1) == b"":
                    self.server.stream_cancelled.set()
            except (BrokenPipeError, ConnectionResetError):
                self.server.stream_cancelled.set()
            except TimeoutError:
                pass
            finally:
                self.close_connection = True
            return
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:1/unfollowed")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path in ("/attachment-30", "/attachment-50", "/attachment-wrong-size"):
            size = {"/attachment-30": 30 * 1024 * 1024,
                    "/attachment-50": INCOMING_LIMIT,
                    "/attachment-wrong-size": 2}[self.path]
            self.attachment(size, chunked=self.path == "/attachment-50")
            return
        if self.path == "/wire-too-large":
            self.send_response(200)
            self.send_header("Content-Length", str(DOWNLOAD_WIRE_LIMIT + 1))
            self.end_headers()
            self.close_connection = True
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

    def attachment(self, size, *, chunked):
        prefix = b'{"data":"'
        suffix = b'","size":' + str(size).encode() + b'}'
        wire_size = len(prefix) + ((size + 2) // 3) * 4 + len(suffix)
        self.send_response(200)
        self.send_header("Transfer-Encoding" if chunked else "Content-Length",
                         "chunked" if chunked else str(wire_size))
        self.end_headers()

        def emit(part):
            if chunked:
                self.wfile.write(f"{len(part):x}\r\n".encode())
            self.wfile.write(part)
            if chunked:
                self.wfile.write(b"\r\n")

        try:
            emit(prefix)
            remaining = size
            while remaining:
                count = min(remaining, len(WIRE_BLOCK))
                emit(ENCODED_BLOCK if count == len(WIRE_BLOCK)
                     else base64.urlsafe_b64encode(WIRE_BLOCK[:count]))
                remaining -= count
            emit(suffix)
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
    server.stream_cancelled = threading.Event()
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
        assert receipt["httpPeakBytes"] <= 8 * 1024 * 1024, receipt
        assert receipt["httpRejectedAllocations"] == 0, receipt
        assert receipt["incomingLimitBytes"] == INCOMING_LIMIT, receipt
        assert receipt["downloadWireLimitBytes"] == DOWNLOAD_WIRE_LIMIT, receipt
        expected_budget = 180_000 if mode.startswith("attachment-") else 30_000
        assert expected_budget - 1_000 < receipt["jobBudgetMs"] <= expected_budget, receipt
        assert receipt["deadlineUnchanged"], receipt
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
        for path, size in [("/attachment-30", 30 * 1024 * 1024),
                           ("/attachment-50", INCOMING_LIMIT)]:
            downloaded = run(path, "attachment-download", size)
            assert downloaded["ok"] and downloaded["status"] == 200, downloaded
            assert downloaded["sinkBytes"] == size, downloaded
            assert downloaded["sinkSha256"] == digest_for_size(size), downloaded
            assert 36 * 1024 * 1024 < downloaded["responseBytes"] <= DOWNLOAD_WIRE_LIMIT, downloaded
        for size in [INCOMING_LIMIT + 1, 51 * 1024 * 1024]:
            before = len(server.requests)
            rejected = run("/must-not-connect", "attachment-download", size)
            assert rejected["error"] == "AttachmentsTooLarge" and rejected["sinkBytes"] == 0, rejected
            assert len(server.requests) == before, server.requests
        wrong_size = run("/attachment-wrong-size", "attachment-download", 3)
        assert wrong_size["error"] == "BodySizeMismatch", wrong_size
        oversized_wire = run("/wire-too-large", "attachment-download", INCOMING_LIMIT)
        assert oversized_wire["error"] == "ResponseTooLarge" and oversized_wire["sinkBytes"] == 0, oversized_wire
        before = len(server.requests)
        rejected_wire = run("/must-not-connect", "download", DOWNLOAD_WIRE_LIMIT + 1)
        assert rejected_wire["error"] == "ResponseBufferTooLarge" and rejected_wire["sinkBytes"] == 0, rejected_wire
        assert len(server.requests) == before, server.requests
        unauthorized = run("/unauthorized", "download")
        assert unauthorized["ok"] and unauthorized["status"] == 401, unauthorized
        assert unauthorized["sinkBytes"] == 0, unauthorized
        unauthorized_attachment = run("/unauthorized", "attachment-download", INCOMING_LIMIT)
        assert unauthorized_attachment["ok"] and unauthorized_attachment["status"] == 401, unauthorized_attachment
        assert unauthorized_attachment["sinkBytes"] == 0, unauthorized_attachment
        retried = run("/attachment-retry", "attachment-retry", 3)
        assert retried["ok"] and retried["status"] == 200, retried
        assert retried["sinkBytes"] == 3 and retried["sinkSha256"] == digest_for_size(3), retried
        assert server.requests.count("/attachment-retry") == 2, server.requests
        timed_out = run("/attachment-stalled", "attachment-timeout", INCOMING_LIMIT)
        assert timed_out["error"] == "Timeout", timed_out
        assert 0 < timed_out["sinkBytes"] < INCOMING_LIMIT, timed_out
        assert 200 <= timed_out["elapsedMs"] < 3_000, timed_out
        assert server.stream_cancelled.wait(timeout=2), "timed-out stream did not close its owned connection"
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
