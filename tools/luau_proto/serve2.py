import http.server,socketserver,os,sys
os.chdir(sys.argv[1])
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy","same-origin");self.send_header("Cross-Origin-Embedder-Policy","require-corp");super().end_headers()
    def log_message(self,*a):pass
H.extensions_map['.wasm']='application/wasm'
socketserver.TCPServer.allow_reuse_address=True
socketserver.TCPServer(("",8072),H).serve_forever()
