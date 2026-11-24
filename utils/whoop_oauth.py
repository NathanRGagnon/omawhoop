#!/usr/bin/env python3
# OAuth helpers for bin/omawhoop-auth: CSRF state generation and the local
# redirect-callback listener.

import json
import secrets
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs


def generate_state():
    print(secrets.token_hex(16))


def listen_for_callback(port, expected_state):
    result = {}

    class Handler(BaseHTTPRequestHandler):
        # The server is single-threaded, so a client that connects and sends
        # nothing (a browser preconnect, a port probe) would otherwise block
        # the real redirect behind it. Drop idle connections quickly.
        timeout = 5

        def log_message(self, *args):
            pass

        def _reply(self, status, msg):
            try:
                self.send_response(status)
                self.send_header("Content-Type", "text/html")
                self.end_headers()
                self.wfile.write(f"<html><body style='font-family:sans-serif'>{msg}</body></html>".encode())
            except OSError:
                pass  # client went away mid-reply; result (if any) is already recorded

        def do_GET(self):
            qs = parse_qs(urlparse(self.path).query)
            code = qs.get("code", [""])[0]
            state = qs.get("state", [""])[0]
            error = qs.get("error_description", qs.get("error", [""]))[0]
            # Only the real redirect counts: it carries our one-time state and
            # either a code or an error. Anything else (a favicon request, a
            # port scan, another local process) must not consume the single
            # login attempt.
            if state != expected_state or not (code or error):
                self._reply(404, "Not found.")
                return
            result["code"], result["state"], result["error"] = code, state, error
            ok = bool(code) and not error
            self._reply(200, "WHOOP connected. You can close this tab." if ok
                        else "WHOOP authorization failed. You can close this tab and try again.")

    server = HTTPServer(("127.0.0.1", port), Handler)
    deadline = time.monotonic() + 120
    while not result:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        server.timeout = remaining
        server.handle_request()
    print(json.dumps(result))


def main(argv):
    if len(argv) < 1:
        print("Usage: whoop_oauth.py {state|listen <port> <expected_state>}", file=sys.stderr)
        return 1

    if argv[0] == "state" and len(argv) == 1:
        generate_state()
        return 0

    if argv[0] == "listen" and len(argv) == 3:
        listen_for_callback(int(argv[1]), argv[2])
        return 0

    print("Usage: whoop_oauth.py {state|listen <port> <expected_state>}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
