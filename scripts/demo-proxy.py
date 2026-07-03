#!/usr/bin/env python3
"""Static demo web + /im/* proxy to usrsvr (hi-im M6 group chat demo)."""
import http.server
import os
import socket
import sys
import urllib.error
import urllib.request

USRSVR = os.environ.get("HIIM_USRSVR_URL", "http://127.0.0.1:8081")
PORT = int(os.environ.get("DEMO_WEB_PORT", "8088"))
BIND = os.environ.get("DEMO_WEB_BIND", "127.0.0.1")
WEB_ROOT = os.path.join(os.path.dirname(__file__), "..", "demo", "web")


class ReuseHTTPServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True


class DemoHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WEB_ROOT, **kwargs)

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        if self.path.startswith("/im/"):
            self._proxy_api()
            return
        super().do_GET()

    def _proxy_api(self):
        url = USRSVR + self.path
        try:
            with urllib.request.urlopen(url, timeout=10) as resp:
                body = resp.read()
                self.send_response(resp.status)
                ctype = resp.headers.get("Content-Type", "application/json")
                self.send_header("Content-Type", ctype)
                self.end_headers()
                self.wfile.write(body)
        except urllib.error.HTTPError as e:
            body = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", e.headers.get("Content-Type", "text/plain"))
            self.end_headers()
            self.wfile.write(body)
        except urllib.error.URLError as e:
            msg = f'{{"code":1,"errmsg":"usrsvr unreachable: {e.reason}"}}'.encode()
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(msg)


if __name__ == "__main__":
    os.chdir(WEB_ROOT)
    try:
        httpd = ReuseHTTPServer((BIND, PORT), DemoHandler)
    except OSError as e:
        if e.errno in (48, 98):
            print(f"[demo-web] ERROR: port {PORT} already in use.", file=sys.stderr)
            sys.exit(1)
        raise
    gw1 = os.environ.get("HIIM_GATEWAY1_WS", "ws://127.0.0.1:28080/ws")
    gw2 = os.environ.get("HIIM_GATEWAY2_WS", "ws://127.0.0.1:28081/ws")
    with httpd:
        print(f"Serving demo/web at http://127.0.0.1:{PORT}/")
        print(f"  group chat: http://127.0.0.1:{PORT}/group.html")
        print(f"  gateway A WS: {gw1}")
        print(f"  gateway B WS: {gw2}")
        print(f"API proxy: /im/* -> {USRSVR}")
        httpd.serve_forever()
