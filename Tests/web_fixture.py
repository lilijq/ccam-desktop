"""Local-only browser/proxy fixture. Never resolves or contacts a remote host."""
import http.server, json, select, socket, socketserver, sys, threading, subprocess, re
from pathlib import Path
root = Path(sys.argv[1])
lock = threading.Lock()
counters = {'pages': 0, 'proxy': 0, 'hosts': []}
def persist():
    (root/'counts.json').write_text(json.dumps(counters))
page = b'''<!doctype html><html><head><meta charset="utf-8"><title>Project preview</title><style>
body{margin:0;background:#f6f7f9;color:#1b2530;font:16px -apple-system;padding:40px;line-height:1.6}h1{font-size:30px;margin:0 0 8px}p{color:#56606d}label{display:block;margin-top:28px}input{font:inherit;padding:9px 12px;border:1px solid #c9ced6;border-radius:6px;width:220px}button,a{font:inherit;padding:10px 18px;background:#263546;color:white;border:0;border-radius:6px;display:inline-block;margin:14px 8px 0 0}section{margin-top:36px;border-top:1px solid #ddd;padding-top:20px}</style></head><body><h1>Project preview</h1><p>A local page shared by you and the assistant.</p><label for="name">Project name</label><input id="name" aria-label="Project name" placeholder="Enter a name"><button id="save" onclick="document.getElementById('result').textContent='Saved: '+document.getElementById('name').value">Save</button><p id="result">Ready</p><input type="password" value="NEVER_EXPOSE_PASSWORD" aria-label="Password"><section><a href="/second">Open details</a><a href="/second" target="_blank">New tab</a><a href="file:///etc/passwd">Blocked file link</a></section><div style="height:1800px">Scroll test</div></body></html>'''
class Pages(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with lock:
            counters['pages'] += 1; persist()
        body = page if self.path != '/second' else b'<html><title>Details</title><body><h1>Details loaded</h1><a href="/">Back home</a></body></html>'
        self.send_response(200); self.send_header('Content-Type','text/html; charset=utf-8'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self,*a): pass
class Server(http.server.ThreadingHTTPServer): daemon_threads=True
pages = Server(('127.0.0.1', 0), Pages)
# A second local address is deliberately outside the allowed loopback bypass list.
addresses = re.findall(r'inet (\d+\.\d+\.\d+\.\d+)', subprocess.check_output(['/sbin/ifconfig']).decode())
canary_host = next(a for a in addresses if not a.startswith(('127.', '169.254.')))
canary = Server((canary_host, 0), Pages)
class Proxy(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(4)
        buf=b''
        while b'\r\n\r\n' not in buf and len(buf)<32768:
            chunk=self.request.recv(4096)
            if not chunk: return
            buf+=chunk
        line=buf.split(b'\r\n')[0].decode('ascii','replace')
        with lock:
            counters['proxy']+=1; counters['hosts'].append(line); persist()
        # Every target is routed to our local fixture. No DNS or outbound connect.
        with socket.create_connection(pages.server_address) as upstream:
            if line.startswith('CONNECT '):
                self.request.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
                remainder=buf.split(b'\r\n\r\n',1)[1]
                if remainder: upstream.sendall(remainder)
            else:
                from urllib.parse import urlsplit
                first,rest=buf.split(b'\r\n',1); method,url,version=first.split(b' ',2)
                path=urlsplit(url.decode()).path or '/'
                upstream.sendall(method+b' '+path.encode()+b' '+version+b'\r\n'+rest)
            while True:
                ready,_,_=select.select([self.request,upstream],[],[],4)
                if not ready: break
                for src in ready:
                    data=src.recv(65536)
                    if not data: return
                    (upstream if src is self.request else self.request).sendall(data)
class ProxyServer(socketserver.ThreadingTCPServer): daemon_threads=True; allow_reuse_address=True
proxy=ProxyServer(('127.0.0.1',0),Proxy)
for server in (pages,canary,proxy): threading.Thread(target=server.serve_forever,daemon=True).start()
with lock: persist()
(root/'ports.json').write_text(json.dumps({'page':pages.server_port,'canary':canary.server_port,'canaryHost':canary_host,'proxy':proxy.server_address[1]}))
sys.stdin.buffer.read()
