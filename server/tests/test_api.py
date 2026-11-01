"""What the iPhone app relies on, through the HTTP API. Needs STREETNAV_TEST_DATABASE_URL (a throwaway database these
tests EMPTY) and httpx (FastAPI's test client)."""
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

from streetnav_server import registry
from test_registry import URL, workout


@unittest.skipUnless(URL and importlib.util.find_spec("httpx"), "STREETNAV_TEST_DATABASE_URL or httpx missing")
class ApiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from fastapi.testclient import TestClient
        from streetnav_server.api import app
        os.environ.update(STREETNAV_DATABASE_URL=URL, STREETNAV_API_TOKEN="test-token")
        with registry.connect() as conn:
            for sql in sorted((Path(__file__).parents[1] / "sql").glob("*.sql")):
                conn.execute(sql.read_text())
        cls.client = TestClient(app, headers={"Authorization": "Bearer test-token"})

    def setUp(self):
        self.raw = tempfile.TemporaryDirectory()
        os.environ["STREETNAV_RAW_DIR"] = self.raw.name
        with registry.connect() as conn:
            conn.execute("TRUNCATE activity, activity_source, activity_heart_rate, sync_run, raw_file RESTART IDENTITY")

    def tearDown(self):
        self.raw.cleanup()

    def test_push_status_and_delete(self):
        body = json.dumps(workout()).encode()
        response = self.client.post("/activities", content=body, headers={"Content-Type": "application/json"})
        self.assertEqual(response.json(), {"id": 1, "outcome": "created"})
        with registry.connect() as conn:
            path = conn.execute("SELECT path FROM raw_file").fetchone()[0]
        with open(os.path.join(self.raw.name, path), "rb") as f:
            self.assertEqual(f.read(), body)
        self.assertEqual(self.client.get("/status").json()["activities"], 1)
        detail = self.client.get("/activities/1").json()
        self.assertEqual((detail["primary_source"], detail["provenance"]["distance_m"]), ("healthkit", "healthkit:A"))
        self.assertEqual(self.client.delete("/copies/healthkit/A").json(), {"id": 1, "outcome": "deleted"})
        self.assertEqual(self.client.delete("/copies/healthkit/A").json(), {"id": None, "outcome": "unknown"})

    def test_refuses_an_invalid_workout(self):
        response = self.client.post("/activities", json={"external_id": "A"})
        self.assertEqual(response.status_code, 422)
        with registry.connect() as conn:
            self.assertEqual(conn.execute("SELECT count(*) FROM raw_file").fetchone()[0], 0)


if __name__ == "__main__":
    unittest.main()

    def test_tracks_and_stats(self):
        self.client.post("/activities", content=json.dumps(workout()).encode(), headers={"Content-Type": "application/json"})
        response = self.client.get("/tracks")
        self.assertEqual(response.status_code, 200)
        collection = response.json()
        self.assertEqual(collection["type"], "FeatureCollection")
        self.assertEqual(len(collection["features"]), 1)
        self.assertEqual(collection["features"][0]["geometry"]["type"], "LineString")
        # Same rides: nothing to download again.
        again = self.client.get("/tracks", headers={"If-None-Match": response.headers["ETag"]})
        self.assertEqual(again.status_code, 304)
        stats = self.client.get("/stats").json()
        self.assertEqual(stats["total"]["rides"], 1)
        self.assertEqual(len(stats["by_year"]), 1)
        self.assertEqual(self.client.get("/stats", headers={"Authorization": ""}).status_code, 401)
