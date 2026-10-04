#!/usr/bin/env python3
"""Credential-free loopback peer for Zig transport boundary/deadline probes."""
from __future__ import annotations

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading
import time


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        try:
            self.handle_get()
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass

    def handle_get(self):
        self.server.requests.append(self.path)
        if self.path in {"/bearer", "/bearer-missing"}:
            valid = self.headers.get_all("Authorization", []) == ["Bearer synthetic-omagma-bearer"]
            self.send_response(200 if valid else 401)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"{}")
            return
        if self.path == "/bearer-redirect":
            self.send_response(302)
            self.send_header("Location", "/bearer")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/hang":
            # No response headers: exercises actual request cancellation.
            self.server.shutdown_event.wait(30)
            self.close_connection = True
            return
        if self.path == "/trickle":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for _ in range(100):
                self.wfile.write(b"1\r\nx\r\n")
                self.wfile.flush()
                if self.server.shutdown_event.wait(0.25):
                    break
            self.close_connection = True
            return
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/ok")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/largeheader":
            self.send_response(200)
            self.send_header("X-Synthetic-Large", "x" * 40000)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"{}")
            return
        if self.path == "/gzip":
            self.send_response(200)
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Content-Length", "20")
            self.end_headers()
            self.wfile.write(bytes.fromhex("1f8b080000000000020303000000000000000000"))
            return
        if self.path == "/chunk":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"2\r\n{}\r\n0\r\n\r\n")
            return
        if self.path in {"/oversize", "/oversize-chunk"}:
            body_size = 524289
            self.send_response(200)
            if self.path == "/oversize-chunk":
                self.send_header("Transfer-Encoding", "chunked")
            else:
                self.send_header("Content-Length", str(body_size))
            self.end_headers()
            for start in range(0, body_size, 4096):
                chunk = b"x" * min(4096, body_size - start)
                if self.path == "/oversize-chunk":
                    self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                else:
                    self.wfile.write(chunk)
            if self.path == "/oversize-chunk":
                self.wfile.write(b"0\r\n\r\n")
            return
        body = b"{}" if self.path == "/ok" else b'{"error":"synthetic_not_found"}'
        self.send_response(200 if self.path == "/ok" else 404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


@contextmanager
def server():
    peer = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    peer.daemon_threads = True
    peer.requests = []
    peer.shutdown_event = threading.Event()
    worker = threading.Thread(target=peer.serve_forever, daemon=True)
    worker.start()
    try:
        yield peer
    finally:
        peer.shutdown_event.set()
        peer.shutdown()
        peer.server_close()
        worker.join()


if __name__ == "__main__":
    with server() as peer:
        print(json.dumps({"origin": f"http://127.0.0.1:{peer.server_port}", "syntheticOnly": True}), flush=True)
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            pass
