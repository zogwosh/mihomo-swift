#!/usr/bin/env python3
"""Run against a real ARM64 kernel, with temporary data and loopback-only fixtures."""
import contextlib, http.server, json, os, pathlib, signal, socket, subprocess, sys, tempfile, threading, time, urllib.error, urllib.request
ROOT = pathlib.Path(__file__).resolve().parents[2]
CORE = ROOT / 'Resources/mihomo'
SUPERVISOR = pathlib.Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip()) / 'MihomoHelper'
class Local204(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(204); self.end_headers()
    def log_message(self, *_): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Local204)
threading.Thread(target=server.serve_forever, daemon=True).start()
def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0)); return s.getsockname()[1]
api_port = port()
secret = 'isolated-test-secret'
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
def api(path, method='GET', body=None, auth=True):
    req = urllib.request.Request(f'http://127.0.0.1:{api_port}{path}', method=method)
    if auth: req.add_header('Authorization', f'Bearer {secret}')
    if body is not None: req.data = json.dumps(body).encode(); req.add_header('Content-Type', 'application/json')
    with opener.open(req, timeout=7) as r:
        data = r.read(); return json.loads(data) if data else None
with tempfile.TemporaryDirectory(prefix='Mihomo-real-core-') as work:
    directory = pathlib.Path(work)
    def profile(name, member='DIRECT'):
        return {'external-controller': f'127.0.0.1:{api_port}', 'secret': secret, 'mixed-port': 0, 'mode': 'rule', 'tun': {'enable': False}, 'dns': {'enable': False}, 'profile': {'store-selected': False}, 'proxies': [], 'proxy-groups': [{'name': name, 'type': 'select', 'proxies': [member, 'REJECT']}], 'rules': [f'MATCH,{name}']}
    a = directory / 'a.yaml'; b = directory / 'b.yaml'; bad = directory / 'bad.yaml'
    a.write_text(json.dumps(profile('Route / 中文'))); b.write_text(json.dumps(profile('Second'))); bad.write_text('proxies: [')
    for f in [a,b]:
        subprocess.run([str(CORE), '-t', '-d', work, '-f', str(f)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    p = subprocess.Popen([str(CORE), '-d', work, '-f', str(a)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            try: api('/version'); break
            except Exception: time.sleep(.1)
        else: raise AssertionError('Controller did not become ready')
        try: api('/version', auth=False); raise AssertionError('Unauthenticated controller allowed')
        except urllib.error.HTTPError as e: assert e.code == 401
        api('/proxies/Route%20%2F%20%E4%B8%AD%E6%96%87', 'PUT', {'name': 'REJECT'})
        assert api('/proxies')['proxies']['Route / 中文']['now'] == 'REJECT'
        api('/configs', 'PATCH', {'mode': 'global'})
        assert api('/configs')['mode'] == 'global'
        pid = p.pid
        api('/configs?force=true', 'PUT', {'path': str(b)})
        assert p.pid == pid and p.poll() is None
        assert 'Second' in api('/proxies')['proxies'] and 'Route / 中文' not in api('/proxies')['proxies']
        try: api('/configs?force=true', 'PUT', {'path': str(bad)}); raise AssertionError('Invalid reload accepted')
        except urllib.error.HTTPError: pass
        assert p.poll() is None and 'Second' in api('/proxies')['proxies']
        api('/proxies/Second', 'PUT', {'name': 'REJECT'})
        target = f'http://127.0.0.1:{server.server_port}/generate_204'
        import urllib.parse
        result = api('/proxies/DIRECT/delay?' + urllib.parse.urlencode({'url': target, 'timeout': 1000}))
        assert isinstance(result['delay'], int)
        assert api('/proxies')['proxies']['Second']['now'] == 'REJECT'
        try: api('/proxies/REJECT/delay?' + urllib.parse.urlencode({'url': target, 'timeout': 1000})); raise AssertionError('REJECT latency succeeded')
        except urllib.error.HTTPError: pass
        assert api('/configs')['tun']['enable'] is False
        print('PASS: real kernel validation, authenticated loopback API, Unicode/slash names, hot reload without restart, rejected reload and selection-preserving latency')
    finally:
        p.terminate()
        try: p.wait(timeout=5)
        except subprocess.TimeoutExpired: p.kill(); p.wait()
    # Own dummy owner and child only. Simulates the app being force-killed.
    owner = subprocess.Popen(['/bin/sleep', '60'])
    supervisor = subprocess.Popen([str(SUPERVISOR), '--user-supervisor', str(owner.pid), str(CORE), work, str(a)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    child_pid = None
    try:
        for _ in range(40):
            r = subprocess.run(['/usr/bin/pgrep', '-P', str(supervisor.pid)], capture_output=True, text=True)
            if r.returncode == 0:
                child_pid = int(r.stdout.strip().splitlines()[0]); break
            time.sleep(.1)
        assert child_pid is not None, 'Supervised kernel missing'
        owner.kill(); owner.wait()
        supervisor.wait(timeout=5)
        try: os.kill(child_pid, 0); raise AssertionError('Kernel survived owner crash')
        except ProcessLookupError: pass
        print('PASS: forced owner termination cleans only its supervised kernel within five seconds')
    finally:
        if owner.poll() is None: owner.terminate(); owner.wait()
        if supervisor.poll() is None: supervisor.terminate(); supervisor.wait(timeout=5)
server.shutdown()
print('ALL REAL-CORE CHECKS PASSED')
