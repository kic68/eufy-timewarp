#!/usr/bin/env python3
"""Keep the isolated printer 'believing it is online' so it stays associated,
without giving it any real internet.

Two listeners:
  * HTTP on :80  -- answers the printer's internet-reachability probe (it resolves
    connectivity-check hostnames to us via dnsmasq and expects a response). Speaks
    the common shapes: generate_204, ncsi.txt, hotspot-detect.html, else 200.
  * a raw TCP sink on :8080 -- the printer's cloud TLS ports (443/8789) are
    redirected here by nftables. It accepts the connection (so the TCP handshake
    succeeds and the printer thinks the cloud is reachable) then reads and
    DISCARDS everything. It never forwards upstream, so nothing leaves the box.

Env: HTTP_PORT (default 80), SINK_PORT (default 8080), BIND (default 0.0.0.0).
"""
import http.server, socket, socketserver, threading, os, time

BIND = os.environ.get("BIND", "0.0.0.0")
HTTP_PORT = int(os.environ.get("HTTP_PORT", "80"))
SINK_PORT = int(os.environ.get("SINK_PORT", "8080"))
APPLE_OK = b"<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>\n"


def log(m):
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


class Probe(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, body=b"", ctype="text/html"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        # HEAD must not carry a body, even though the headers advertise its length.
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        p = self.path.split("?")[0]
        if p in ("/generate_204", "/gen_204"):
            self._send(204)
        elif p == "/ncsi.txt":
            self._send(200, b"Microsoft NCSI", "text/plain")
        elif p == "/connecttest.txt":
            self._send(200, b"Microsoft Connect Test", "text/plain")
        else:
            self._send(200, APPLE_OK)

    do_HEAD = do_GET

    def log_message(self, *a):
        pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def tcp_sink():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((BIND, SINK_PORT))
    s.listen(32)
    while True:
        try:
            c, _ = s.accept()
        except Exception:
            continue

        def handle(conn):
            try:
                while conn.recv(4096):
                    pass          # read and discard; never respond, never forward
            except Exception:
                pass
            finally:
                try:
                    conn.close()
                except Exception:
                    pass
        threading.Thread(target=handle, args=(c,), daemon=True).start()


log(f"keepalive: http :{HTTP_PORT}, tcp sink :{SINK_PORT} on {BIND}")
threading.Thread(target=tcp_sink, daemon=True).start()
Server((BIND, HTTP_PORT), Probe).serve_forever()
