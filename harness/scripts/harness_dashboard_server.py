"""Local, read-only Harness monitor. Standard library only; no provider calls."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
import webbrowser

ASSETS = Path(__file__).resolve().parent.parent / 'dashboard'
COLLECTOR = Path(__file__).resolve().with_name('get_harness_dashboard.ps1')


class SnapshotStore:
    def __init__(self, root, powershell, refresh):
        self.root = str(Path(root).resolve(strict=True))
        self.powershell = powershell
        self.refresh = refresh
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.snapshot = None
        self.last_success = None
        self.error = None
        self.collecting = False

    def collect(self):
        with self.lock:
            self.collecting = True
        env = os.environ.copy()
        env['CODEX_HARNESS_ROOT'] = self.root
        env.pop('CODEX_GIT_WORKSPACE_ROOT', None)
        env['GIT_OPTIONAL_LOCKS'] = '0'
        args = [self.powershell, '-NoProfile', '-NonInteractive']
        if os.name == 'nt':
            args += ['-ExecutionPolicy', 'Bypass']
        args += ['-File', str(COLLECTOR), '-Root', self.root]
        try:
            result = subprocess.run(args, cwd=self.root, env=env, capture_output=True,
                                    timeout=45, check=True, encoding='utf-8-sig',
                                    creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            value = json.loads(result.stdout)
            if not isinstance(value, dict) or value.get('schema_version') != 1:
                raise ValueError('unsupported snapshot')
            with self.lock:
                self.snapshot = value
                self.last_success = time.time()
                self.error = None
        except (OSError, ValueError, subprocess.SubprocessError):
            # Never send stderr, commands, provider output or credentials to the UI.
            with self.lock:
                self.error = '상태 수집에 실패했습니다. 실행 환경과 기록을 확인하세요.'
        finally:
            with self.lock:
                self.collecting = False

    def run(self):
        while not self.stop.is_set():
            self.collect()
            self.stop.wait(self.refresh)

    def read(self):
        with self.lock:
            age = None if self.last_success is None else max(0, time.time()-self.last_success)
            return {'schema_version': 1, 'snapshot': self.snapshot,
                    'connection': {'collecting': self.collecting, 'error': self.error,
                                   'age_seconds': age, 'refresh_seconds': self.refresh,
                                   'stale': self.error is not None or age is None or age > self.refresh+50}}


def make_server(store, port=0):
    class Handler(BaseHTTPRequestHandler):
        server_version = 'HarnessMonitor/1'

        def log_message(self, *_):
            pass

        def respond(self, status, body, content_type='application/json; charset=utf-8'):
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('Cross-Origin-Resource-Policy', 'same-origin')
            self.send_header('Content-Security-Policy', "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            expected = '127.0.0.1:' + str(self.server.server_port)
            if self.headers.get('Host') != expected:
                self.respond(403, b'{"error":"host refused"}')
                return
            if self.headers.get('Origin') not in (None, 'http://' + expected):
                self.respond(403, b'{"error":"origin refused"}')
                return
            if self.headers.get('Sec-Fetch-Site') not in (None, 'none', 'same-origin'):
                self.respond(403, b'{"error":"cross-site request refused"}')
                return
            url = urlsplit(self.path)
            if url.query or url.fragment:
                self.respond(400, b'{"error":"query parameters unsupported"}')
                return
            if url.path == '/favicon.ico':
                self.respond(204, b'', 'image/x-icon')
                return
            if url.path == '/api/snapshot':
                self.respond(200, json.dumps(store.read(), ensure_ascii=False, allow_nan=False).encode('utf-8'))
                return
            assets = {'/': ('index.html', 'text/html; charset=utf-8'),
                      '/app.js': ('app.js', 'text/javascript; charset=utf-8'),
                      '/style.css': ('style.css', 'text/css; charset=utf-8')}
            if url.path not in assets:
                self.respond(404, b'{"error":"not found"}')
                return
            name, kind = assets[url.path]
            try:
                self.respond(200, (ASSETS/name).read_bytes(), kind)
            except OSError:
                self.respond(500, b'{"error":"asset unavailable"}')

        def do_POST(self):
            self.respond(405, b'{"error":"read only"}')

        do_PUT = do_POST
        do_DELETE = do_POST
        do_PATCH = do_POST
        do_OPTIONS = do_POST

    server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
    server.daemon_threads = True
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True)
    parser.add_argument('--powershell', required=True)
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--refresh', type=int, default=10)
    parser.add_argument('--open', action='store_true')
    args = parser.parse_args()
    if not 0 <= args.port <= 65535 or not 5 <= args.refresh <= 300:
        parser.error('port must be 0..65535 and refresh 5..300 seconds')
    store = SnapshotStore(args.root, args.powershell, args.refresh)
    server = make_server(store, args.port)
    worker = threading.Thread(target=store.run, daemon=True)
    worker.start()
    address = 'http://127.0.0.1:' + str(server.server_port) + '/'
    print('Harness dashboard (read-only): ' + address, flush=True)
    print('Stop: Ctrl+C. No AI calls, task execution or approval actions.', flush=True)
    if args.open:
        webbrowser.open(address)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        store.stop.set()
        server.server_close()


if __name__ == '__main__':
    main()
