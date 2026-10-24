"""Unit/integration/security tests; loopback only, no paid provider calls."""
import http.client
import json
from pathlib import Path
import subprocess
import threading
import unittest
from unittest.mock import patch

from harness_dashboard_server import SnapshotStore, make_server


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.store = SnapshotStore(Path(__file__).resolve().parent.parent, 'fake-pwsh', 10)

    @patch('harness_dashboard_server.subprocess.run')
    def test_fixed_argv_and_clean_environment(self, run):
        run.return_value = subprocess.CompletedProcess([], 0, '{"schema_version":1}', '')
        self.store.collect()
        args, kwargs = run.call_args
        self.assertIsInstance(args[0], list)
        self.assertNotIn('shell', kwargs)
        self.assertEqual(kwargs['env']['GIT_OPTIONAL_LOCKS'], '0')
        self.assertNotIn('CODEX_GIT_WORKSPACE_ROOT', kwargs['env'])
        self.assertFalse(self.store.read()['connection']['stale'])

    @patch('harness_dashboard_server.subprocess.run')
    def test_failed_collection_retains_last_success_without_stderr(self, run):
        run.return_value = subprocess.CompletedProcess([], 0, '{"schema_version":1,"tasks":[]}', '')
        self.store.collect()
        run.side_effect = subprocess.CalledProcessError(1, 'fake', stderr='PRIVATE_SECRET')
        self.store.collect()
        value = self.store.read()
        self.assertEqual(value['snapshot']['tasks'], [])
        self.assertTrue(value['connection']['stale'])
        self.assertNotIn('PRIVATE_SECRET', json.dumps(value))

    @patch('harness_dashboard_server.subprocess.run')
    def test_timeout_and_bad_json_are_not_empty_success(self, run):
        for error in (subprocess.TimeoutExpired('fake', 45), ValueError('invalid')):
            run.side_effect = error
            self.store.collect()
            self.assertIsNone(self.store.read()['snapshot'])
            self.assertTrue(self.store.read()['connection']['stale'])


class HttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.store = SnapshotStore(Path(__file__).resolve().parent.parent, 'unused', 10)
        cls.server = make_server(cls.store)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def request(self, path='/', method='GET', headers=None):
        conn = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
        try:
            conn.request(method, path, headers=headers or {})
            response = conn.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            conn.close()

    def test_assets_and_snapshot(self):
        for path in ('/', '/app.js', '/style.css', '/api/snapshot'):
            status, headers, body = self.request(path)
            self.assertEqual(status, 200)
            self.assertTrue(body)
            self.assertEqual(headers['Cache-Control'], 'no-store')
            self.assertIn("frame-ancestors 'none'", headers['Content-Security-Policy'])
        self.assertEqual(self.server.server_address[0], '127.0.0.1')

    def test_host_origin_and_fetch_site_guards(self):
        for headers in ({'Host': 'evil.invalid'}, {'Origin': 'https://evil.invalid'}, {'Origin': 'null'}, {'Sec-Fetch-Site': 'cross-site'}, {'Sec-Fetch-Site': 'same-site'}):
            self.assertEqual(self.request('/api/snapshot', headers=headers)[0], 403)

    def test_no_mutation_or_cors(self):
        for method in ('POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'):
            status, headers, _ = self.request('/api/snapshot', method)
            self.assertEqual(status, 405)
            self.assertNotIn('Access-Control-Allow-Origin', headers)

    def test_no_arbitrary_paths_or_query_commands(self):
        for path in ('/../.env', '/%2e%2e/.git/config', '/state/usage/x.json', '/api/run', '//evil.invalid/path'):
            self.assertEqual(self.request(path)[0], 404)
        self.assertEqual(self.request('/api/snapshot?path=.env')[0], 400)

    def test_raw_prompt_not_served(self):
        self.assertEqual(self.request('/scripts/get_harness_dashboard.ps1')[0], 404)
        self.assertNotIn('innerHTML', (Path(__file__).resolve().parent.parent/'dashboard/app.js').read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
