"""Starter unit tests; CI must run these before building any image."""
import unittest
from app.server import route

class ApiTests(unittest.TestCase):
    def test_healthz(self):
        self.assertEqual(route('/healthz')[0], 200)
    def test_readyz_normal(self):
        self.assertEqual(route('/readyz', {'FAIL_MODE': '0'})[0], 200)
    def test_readyz_failure_mode(self):
        self.assertEqual(route('/readyz', {'FAIL_MODE': '1'})[0], 503)
    def test_info(self):
        self.assertEqual(route('/info', {'APP_NAME': 'test-app', 'APP_ENV': 'test'})[1]['app'], 'test-app')
    def test_known_item(self):
        status, data = route('/api/books?code=BK-101')
        self.assertEqual(status, 200)
        self.assertEqual(data['status'], 'available')
    def test_unknown_item(self):
        self.assertEqual(route('/api/books?code=NOT_FOUND')[0], 404)
    def test_other_url(self):
        self.assertEqual(route('/unknown')[0], 200)  # DEMO: deliberately wrong

if __name__ == '__main__':
    unittest.main()
