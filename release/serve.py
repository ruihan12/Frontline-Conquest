# Local server for the Web build: sends the COOP/COEP headers the threaded export needs.
# Run it from the folder that holds index.html, then open http://localhost:8060
import http.server
import os
import socketserver
import threading
import webbrowser

PORT = 8060


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, ".wasm": "application/wasm", ".js": "text/javascript"}

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


os.chdir(os.path.dirname(os.path.abspath(__file__)))
socketserver.TCPServer.allow_reuse_address = True
with socketserver.ThreadingTCPServer(("", PORT), Handler) as httpd:
    print("Serving on http://localhost:%d  (Ctrl+C to stop)" % PORT)
    threading.Timer(0.8, lambda: webbrowser.open("http://localhost:%d/" % PORT)).start()
    httpd.serve_forever()
