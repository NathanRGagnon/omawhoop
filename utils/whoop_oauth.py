#!/usr/bin/env python3
# OAuth helpers for bin/omawhoop-auth: CSRF state generation and the local
# redirect-callback listener.

import json
import secrets
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs


def generate_state():
    print(secrets.token_hex(16))


def listen_for_callback(port, expected_state):
    result = {}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            qs = parse_qs(urlparse(self.path).query)
            result["code"] = qs.get("code", [""])[0]
            result["state"] = qs.get("state", [""])[0]
            result["error"] = qs.get("error_description", qs.get("error", [""]))[0]
            ok = bool(result["code"]) and result["state"] == expected_state and not result["error"]
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            msg = "WHOOP connected. You can close this tab." if ok else "WHOOP authorization failed. You can close this tab and try again."
            self.wfile.write(f"<html><body style='font-family:sans-serif'>{msg}</body></html>".encode())

    server = HTTPServer(("127.0.0.1", port), Handler)
    server.timeout = 120
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
