"""Ride with GPS sync against a fake API. The run itself needs STREETNAV_TEST_DATABASE_URL (a database these tests
EMPTY)."""
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock

from streetnav_server import registry, rwgps_sync
from test_registry import URL

TRIP = {"id": 7, "departed_at": "2026-10-31T19:08:21+01:00", "duration": 1451, "distance": 9004.0,
        "updated_at": "2026-11-01T00:17:41Z", "activity_type": "cycling:generic", "moving_time": 1355,
        "track_points": [{"x": 2.25 + i * 0.001, "y": 48.84, "e": 35.0, "t": 1761934101 + i * 10, "h": 130}
                         for i in range(20)]}


class FakeApi:
    def __init__(self):
        self.urls = []

    def get_bytes(self, path, params=None):
        self.urls.append(path)
        if path == "/trips.json":
            return json.dumps({"trips": [{"id": 7, "updated_at": TRIP["updated_at"]}],
                               "meta": {"pagination": {"page_count": 1}}}).encode()
        return json.dumps({"trip": TRIP}).encode()


class RequestTest(unittest.TestCase):
    def test_query_string(self):
        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

            def read(self):
                return b"{}"

        with mock.patch.dict(os.environ, RWGPS_API_KEY="k", RWGPS_AUTH_TOKEN="t"), \
                mock.patch.object(rwgps_sync.request, "urlopen", return_value=Response()) as urlopen:
            self.assertEqual(rwgps_sync.get("/trips.json", {"page": 2, "page_size": 200}), {})
        self.assertEqual(urlopen.call_args[0][0].full_url, rwgps_sync.API + "/trips.json?page=2&page_size=200")


@unittest.skipUnless(URL, "STREETNAV_TEST_DATABASE_URL not set")
class SyncTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        os.environ["STREETNAV_DATABASE_URL"] = URL
        with registry.connect() as conn:
            for sql in sorted((Path(__file__).parents[1] / "sql").glob("*.sql")):
                conn.execute(sql.read_text())

    def setUp(self):
        self.raw = tempfile.TemporaryDirectory()
        os.environ["STREETNAV_RAW_DIR"] = self.raw.name
        with registry.connect() as conn:
            conn.execute("TRUNCATE activity, activity_source, activity_heart_rate, sync_run, raw_file RESTART IDENTITY")

    def tearDown(self):
        self.raw.cleanup()

    def run_sync(self, *args):
        api = FakeApi()
        with mock.patch.object(rwgps_sync, "get_bytes", api.get_bytes), mock.patch.object(rwgps_sync, "PAUSE_S", 0), \
                mock.patch.object(sys, "argv", ["rwgps_sync", *args]), redirect_stdout(StringIO()) as out:
            rwgps_sync.main()
        return api.urls, out.getvalue()

    def test_trips_are_kept_in_bronze_and_skipped_once_known(self):
        urls, _ = self.run_sync()
        self.assertEqual(urls, ["/trips.json", "/trips/7.json"])
        with registry.connect() as conn:
            self.assertEqual(conn.execute("SELECT part, name FROM raw_file").fetchall(), [("payload", "trips/7.json")])
            self.assertEqual(conn.execute("SELECT distance_m FROM activity").fetchone()[0], 9004.0)
        self.assertEqual(self.run_sync("--full")[0], ["/trips.json"])

    def test_a_full_run_fetches_trips_loaded_before_bronze(self):
        self.run_sync()
        with registry.connect() as conn:
            conn.execute("UPDATE activity_source SET parsed_at = NULL")
        self.assertEqual(self.run_sync()[0], ["/trips.json"])
        self.assertEqual(self.run_sync("--full")[0], ["/trips.json", "/trips/7.json"])

    def test_runs_never_overlap(self):
        with registry.connect() as other:
            other.execute("SELECT pg_advisory_lock(%s)", (rwgps_sync.LOCK,))
            urls, out = self.run_sync()
        self.assertEqual(urls, [])
        self.assertIn("another Ride with GPS run", out)


if __name__ == "__main__":
    unittest.main()
