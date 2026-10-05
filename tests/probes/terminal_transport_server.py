#!/usr/bin/env python3
"""Independent synthetic HTTP peer for the terminal JSON wire policy."""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading

REQUEST_BODY = b'{"payload":"' + b"x" * 131058 + b'"}'
SUCCESS_BODY = b'{"ok":true,"payload":"' + b"x" * (600 * 1024) + b'"}'
BODY_LIMIT = 3 * 1024**2


class Peer(ThreadingHTTPServer):
    daemon_threads = False
    block_on_close = True

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(15)
        with self.capture_lock:
            self.connections += 1
        return connection, address


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 <= length <= BODY_LIMIT:
                self.send_error(413)
                return
            body = self.rfile.read(length)
            with self.server.capture_lock:
                if len(self.server.requests) >= 16:
                    raise AssertionError("synthetic peer request cap exceeded")
                self.server.requests.append({"method": self.command, "path": self.path,
                                             "headers": self.headers, "body": body})
            if self.path == "/hang":
                self.server.stop_event.wait(30)
                self.close_connection = True
                return
            if self.path == "/redirect":
                self.send_response(302)
                self.send_header("Location", "/forwarded")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if self.path == "/trickle":
                self.send_response(200)
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                for _ in range(100):
                    self.wfile.write(b"1\r\nx\r\n")
                    self.wfile.flush()
                    if self.server.stop_event.wait(.25):
                        break
                self.close_connection = True
                return
            oversized = self.path in {"/oversize", "/oversize-chunk"}
            chunked = self.path == "/oversize-chunk"
            size = BODY_LIMIT + 1 if oversized else len(SUCCESS_BODY)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Transfer-Encoding" if chunked else "Content-Length", "chunked" if chunked else str(size))
            self.end_headers()
            if not oversized:
                self.wfile.write(SUCCESS_BODY)
                return
            for offset in range(0, size, 8192):
                chunk = b"x" * min(8192, size - offset)
                self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n" if chunked else chunk)
            if chunked:
                self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass

    def do_GET(self):
        # A redirect followed using another method is still a forwarding defect.
        with self.server.capture_lock:
            self.server.requests.append({"method": self.command, "path": self.path,
                                         "headers": self.headers, "body": b""})
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")


@contextmanager
def server():
    peer = Peer(("127.0.0.1", 0), Handler)
    peer.capture_lock = threading.Lock()
    peer.connections, peer.requests = 0, []
    peer.stop_event = threading.Event()
    worker = threading.Thread(target=peer.serve_forever)
    worker.start()
    try:
        yield peer
    finally:
        peer.stop_event.set()
        peer.shutdown()
        peer.server_close()  # Wait for all owned handlers; socket reads have finite deadlines.
        worker.join(timeout=3)
        if worker.is_alive():
            raise AssertionError("synthetic peer thread did not stop")
