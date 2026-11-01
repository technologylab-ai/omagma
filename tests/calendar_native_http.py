#!/usr/bin/env python3
"""Independent loopback wire oracle; credentials and Google access are absent."""
import argparse
import http.server
import json
import hashlib
from pathlib import Path
import subprocess
import threading
import urllib.parse

BODY = b'{"summary":"Fixture reviewed update","sequence":5,"extendedProperties":{"private":{"omagmaOperation":"wire-fixture"}}}'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", required=True)
    args = parser.parse_args()
    received = []
    booking_status = [200]

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *unused):
            pass

        def handle_request(self):
            size = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(size)
            received.append((self.command, self.path, dict(self.headers), body))
            status = booking_status[0] if "/calendar/v3/calendars/" in self.path else int(urllib.parse.urlsplit(self.path).path.rsplit("/", 1)[-1])
            if status == 299:  # Interrupted response after accepting request bytes.
                self.close_connection = True
                return
            response = (json.dumps({"error": {"code": 400, "message": "Bad Request", "errors": [{"reason": "participantIsNeitherOrganizerNorAttendee", "message": "The owner of the calendar must either be the organizer or an attendee of an event that is imported.", "location": "organizer.email"}]}}).encode()
                        if status == 400 else b"" if status == 204 else b'{"provider":"calendar"}')
            self.send_response(status)
            if status == 302:
                self.send_header("Location", "http://127.0.0.1:1/never-follow")
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            self.wfile.write(response)

        do_GET = do_POST = do_PATCH = do_DELETE = handle_request

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_address[1]}/calendar/"

    def run(mode, status, expected):
        before = len(received)
        booking_status[0] = status
        process = subprocess.run([args.probe, base + str(status), mode], capture_output=True, text=True, timeout=20, check=True)
        result = json.loads(process.stdout)
        assert result["zigVersion"] == "0.17.0", result
        assert result["errorCode"] == expected, result
        if mode == "bad-etag":
            assert len(received) == before, received
            return result
        assert len(received) == before + 1, "Calendar request was replayed"
        method, path, headers, body = received[-1]
        headers = {key.lower(): value for key, value in headers.items()}
        assert urllib.parse.urlsplit(path).path == ("/calendar/v3/calendars/opaque-booking-calendar/events/import" if mode == "booking-import" else "/calendar/" + str(status))
        assert headers["authorization"] == "Bearer synthetic-omagma-calendar-bearer"
        assert method == {"get": "GET", "import": "POST", "booking-import": "POST", "freebusy": "POST", "patch": "PATCH", "delete": "DELETE", "create-meet": "POST"}[mode]
        assert headers.get("if-match") == ('"wire-etag-4"' if mode in ("patch", "delete") else None), headers
        if mode == "booking-import":
            assert urllib.parse.urlsplit(path).query == "", path
            event = json.loads(body)
            assert set(event) == {"iCalUID", "organizer", "summary", "description", "location", "start", "end", "sequence", "transparency", "visibility", "extendedProperties"}, event
            assert event["iCalUID"] == "12345678-1234-4234-9234-123456789abc"
            assert event["organizer"] == {"email": "self@example.test"}, "personal copy must satisfy Google's primary-owner participant rule"
            assert event["summary"] == "Fictional haircut booking"
            assert event["description"] == "Booked service. Please arrive on time.\n\nJoin: https://bookings.example.test/manage"
            assert event["location"] == "12 Example Street"
            assert event["start"] == {"dateTime": "2026-11-10T09:15:00.000Z", "timeZone": "Europe/Vienna"}
            assert event["end"] == {"dateTime": "2026-11-10T10:05:00.000Z", "timeZone": "Europe/Vienna"}
            assert type(event["sequence"]) is int and event["sequence"] == 1
            assert event["transparency"] == "opaque" and event["visibility"] == "default"
            raw = (Path(__file__).parent / "fixtures/terminal/calendar/booking-no-attendees.ics").read_bytes()
            assert event["extendedProperties"]["private"] == {"omagmaOperation": "wire-booking", "omagmaSource": hashlib.sha256(raw).hexdigest(), "omagmaOriginalOrganizer": "host@example.test", "omagmaPersonalCopy": "1"}
            assert int(headers["content-length"]) == len(body)
            if status == 400:
                assert result["providerError"] == {"status": 400, "reason": "participantIsNeitherOrganizerNorAttendee", "message": "The owner of the calendar must either be the organizer or an attendee of an event that is imported.", "location": "organizer.email"}
        elif mode == "create-meet":
            assert urllib.parse.parse_qs(urllib.parse.urlsplit(path).query) == {"sendUpdates": ["all"], "conferenceDataVersion": ["1"]}, path
            event = json.loads(body)
            assert event["id"] == "omagma012345" and "iCalUID" not in event
            assert event["start"] == {"dateTime": "2026-10-22T10:00:00.000Z", "timeZone": "UTC"}
            assert event["end"] == {"dateTime": "2026-10-22T11:00:00.000Z", "timeZone": "UTC"}
            assert event["attendees"] == [{"email": "guest@example.test", "responseStatus": "needsAction"}]
            assert event["conferenceData"] == {"createRequest": {"requestId": "wire-event-create", "conferenceSolutionKey": {"type": "hangoutsMeet"}}}
            assert event["extendedProperties"]["private"] == {"omagmaOperation": "wire-event-create", "omagmaSource": "0" * 64}
        else:
            assert body == (BODY if method in ("POST", "PATCH") else b""), body
        if body:
            assert headers["content-type"] == "application/json", headers
        return result

    try:
        for mode in ("get", "import", "freebusy", "patch"):
            run(mode, 200, "")
        deleted = run("delete", 204, "")
        assert deleted["bodyBytes"] == 0
        for status, code in ((401, "CalendarUnauthorized"), (404, "CalendarNotFound"), (412, "CalendarVersionConflict"), (429, "CalendarRateLimited"), (503, "UnknownOutcome")):
            run("patch", status, code)
        run("freebusy", 503, "CalendarUnavailable")
        run("patch", 302, "RedirectRejected")
        interrupted = subprocess.run([args.probe, base + "299", "import"], capture_output=True, text=True, timeout=20, check=True)
        interrupted_result = json.loads(interrupted.stdout)
        assert interrupted_result["errorCode"] and interrupted_result["status"] == 0, interrupted_result
        assert sum(path == "/calendar/299" for _, path, _, _ in received) == 1
        run("bad-etag", 200, "InvalidCalendarEtag")
        run("create-meet", 200, "")
        run("create-meet", 503, "UnknownOutcome")
        run("booking-import", 200, "")
        run("booking-import", 400, "CalendarRequestRejected")
        print(json.dumps({"ok": True, "wireRequests": len(received), "checks": 18, "compiler": deleted["zigVersion"], "mode": deleted["optimizeMode"]}))
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


if __name__ == "__main__":
    main()
