# Minimal stand-in for the account service's internal endpoints, for the real-socket multiplayer test only.
# Tokens: "acct-N" is account N (username Player_N), "guest-X" is guest Guest_000X, anything else is invalid.
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

KEY = "testkey"
LOG = sys.argv[2] if len(sys.argv) > 2 else "/tmp/fake_accounts.log"


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if self.headers.get("X-Internal-Key") != KEY:
            return self.out(403, {"error": "forbidden"})
        if self.path.endswith("/internal/verify-session"):
            t = str(body.get("token", ""))
            if t.startswith("acct-"):
                n = int(t[5:])
                return self.out(200, {"guest": False, "account_id": n, "username": "Player_%d" % n, "elo": 1000})
            if t.startswith("guest-"):
                return self.out(200, {"guest": True, "name": "Guest_%04d" % int(t[6:])})
            return self.out(401, {"error": "invalid_session"})
        if self.path.endswith("/internal/match-result"):
            open(LOG, "a").write(json.dumps(body) + "\n")
            return self.out(200, {"changes": []})
        self.out(404, {})

    def out(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)


HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
