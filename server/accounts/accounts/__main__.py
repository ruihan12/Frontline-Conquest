import json
import os
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qsl, urlsplit

from .service import ApiError, Service, bad_request
from .store import mariadb

LIMIT = 128 * 1024
REQUIRED = ("DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD", "INTERNAL_KEY", "GUEST_SECRET")


class Server(ThreadingHTTPServer):
    # Bound simultaneous Argon2 work and connections. Each request owns its database connection.
    workers = threading.BoundedSemaphore(8)

    def process_request(self, request, client_address):
        self.workers.acquire()
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.workers.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.workers.release()

    def handle_error(self, request, client_address):
        # Built-in traceback logging may include user-controlled data.
        pass


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        self.request.settimeout(10)
        super().setup()

    def log_message(self, *args):
        pass

    def send_error(self, code, message=None, explain=None):
        self.reply(code, {"error": "invalid_http", "message": "The request could not be read."})

    def reply(self, status, data):
        encoded = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)

    def body(self):
        sizes = self.headers.get_all("Content-Length", [])
        if self.headers.get("Transfer-Encoding") or len(sizes) > 1:
            raise bad_request("Supply a single content length.")
        size = sizes[0] if sizes else "0"
        if not re.fullmatch(r"[0-9]{1,16}", size):
            raise bad_request()
        if int(size) > LIMIT:
            raise ApiError(413, "too_large", "Request exceeds 128 KB.")
        if int(size) == 0:
            return {}
        try:
            raw = self.rfile.read(int(size))
            if len(raw) != int(size):
                raise ValueError()
            data = json.loads(raw.decode("utf-8"))
            if not isinstance(data, dict):
                raise ValueError()
            # Reject unpaired surrogates and non-finite JSON values before DB or password handling.
            json.dumps(data, ensure_ascii=False, allow_nan=False).encode("utf-8")
            return data
        except (ValueError, UnicodeError, RecursionError, TimeoutError):
            raise bad_request("Expected a UTF-8 JSON object.") from None

    def request_json(self):
        try:
            url = urlsplit(self.path)
            if not url.path.startswith("/api/v1/"):
                raise ApiError(404, "not_found", "Unknown endpoint.")
            query = dict(parse_qsl(url.query, max_num_fields=32))
            data = self.server.service.dispatch(self.command, url.path[7:], self.body(), query,
                                                self.headers, self.client_address[0])
            status = 200
        except ApiError as exc:
            status, data = exc.status, {"error": exc.code, "message": exc.message}
        except ValueError:
            status, data = 400, {"error": "bad_request", "message": "The request is invalid."}
        except Exception:
            status, data = 500, {"error": "server_error", "message": "The account service could not process the request."}
        self.reply(status, data)

    do_GET = do_POST = do_PUT = request_json


def main():
    missing = [key for key in REQUIRED if not os.environ.get(key)]
    if missing:
        raise SystemExit("Missing required settings: " + ", ".join(missing))
    port = os.environ["DB_PORT"]
    if not port.isascii() or not port.isdecimal() or len(port) > 5 or not 1 <= int(port) <= 65535:
        raise SystemExit("DB_PORT must be a valid TCP port.")
    store = mariadb(os.environ)
    try:
        with store.transaction() as db:
            version = db.one("SELECT version FROM schema_version")
            if not version or version["version"] != 5:
                raise ValueError()
    except Exception:
        raise SystemExit("Cannot open account database at schema version 5.") from None
    with Server(("127.0.0.1", 8071), Handler) as server:
        server.service = Service(store, os.environ["INTERNAL_KEY"], os.environ["GUEST_SECRET"])
        server.serve_forever()


if __name__ == "__main__":
    main()
