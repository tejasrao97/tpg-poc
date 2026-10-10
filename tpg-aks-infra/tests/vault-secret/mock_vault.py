#!/usr/bin/env python3
"""A minimal HTTPS stand-in for the Vault API calls of scripts/vault-secret.sh.

userpass login (password "pw-ok" -> token "tok-admin"), KV v2 under tpg/
(data put/get, metadata list/delete) and sys/wrapping/wrap. The last request
body of sys/wrapping/wrap is written to WRAP_LOG, the request lines to REQ_LOG.
Usage: mock_vault.py CERT KEY PORT_FILE WRAP_LOG REQ_LOG
"""
import json, ssl, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

CERT, KEY, PORT_FILE, WRAP_LOG, REQ_LOG = sys.argv[1:6]
KV = {}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body=None):
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n).decode() if n else ""

    def handle_any(self):
        path = self.path
        with open(REQ_LOG, "a") as f:
            f.write(f"{self.command} {path} token={'yes' if self.headers.get('X-Vault-Token') else 'no'}\n")
        raw = self.body()
        if path == "/v1/auth/userpass/login/tpg-admin" and self.command == "POST":
            if json.loads(raw or "{}").get("password") == "pw-ok":
                return self.reply(200, {"auth": {"client_token": "tok-admin"}})
            return self.reply(400, {"errors": ["invalid username or password"]})
        if self.headers.get("X-Vault-Token") != "tok-admin":
            return self.reply(403, {"errors": ["permission denied"]})
        if path == "/v1/sys/wrapping/wrap" and self.command == "POST":
            if not self.headers.get("X-Vault-Wrap-TTL"):
                return self.reply(400, {"errors": ["wrap TTL required"]})
            with open(WRAP_LOG, "w") as f:
                f.write(raw)
            return self.reply(200, {"wrap_info": {"token": "hvs.wrapped-1", "ttl": 600}})
        if path.startswith("/v1/tpg/data/"):
            key = path[len("/v1/tpg/data/"):]
            if self.command == "POST":
                KV.setdefault(key, []).append(json.loads(raw)["data"])
                return self.reply(200, {"data": {"version": len(KV[key])}})
            if self.command == "GET":
                if key not in KV:
                    return self.reply(404, {"errors": []})
                return self.reply(200, {"data": {"data": KV[key][-1]}})
        if path.startswith("/v1/tpg/metadata/"):
            key = path[len("/v1/tpg/metadata/"):]
            if self.command == "LIST":
                keys = sorted(k[len(key) + 1:] for k in KV if k.startswith(key + "/"))
                return self.reply(200, {"data": {"keys": keys}}) if keys else self.reply(404, {"errors": []})
            if self.command == "DELETE":
                KV.pop(key, None)
                return self.reply(204)
        return self.reply(404, {"errors": [f"no handler for {self.command} {path}"]})

    do_GET = do_POST = do_DELETE = do_LIST = handle_any


srv = HTTPServer(("127.0.0.1", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(CERT, KEY)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
with open(PORT_FILE, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
