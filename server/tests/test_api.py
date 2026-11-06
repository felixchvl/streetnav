"""What the iPhone app relies on, through the HTTP API. Needs STREETNAV_TEST_DATABASE_URL (a throwaway database these
tests EMPTY) and httpx (FastAPI's test client)."""
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from streetnav_server import osm, registry
from test_osm import LIMITS, SIDEWALK, STREET
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
        # The map asks for OpenStreetMap's changes in a throwaway folder, without waiting for a run no unit starts.
        self.state = tempfile.TemporaryDirectory()
        os.environ["STREETNAV_STATE_DIR"] = self.state.name
        patcher = mock.patch.multiple(osm, WAIT_S=0, _asked=None)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.state.cleanup)
        with registry.connect() as conn:
            conn.execute("TRUNCATE activity, activity_source, activity_heart_rate, sync_run, raw_file, osm.lieu RESTART IDENTITY")

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
        self.assertEqual(stats["streets"], {"ridden_km": 0, "total_km": 0})
        self.assertEqual(stats["zones"], [])
        streets = self.client.get("/streets")
        self.assertEqual(streets.json(), {"type": "FeatureCollection", "features": []})
        self.assertEqual(self.client.get("/streets", headers={"If-None-Match": streets.headers["ETag"]}).status_code, 304)
        self.assertEqual(self.client.get("/stats", headers={"Authorization": ""}).status_code, 401)

    def test_zone_outlines(self):
        with registry.connect() as conn:
            osm.store(conn, LIMITS, check=False)
        response = self.client.get("/zones")
        features = response.json()["features"]
        self.assertEqual([f["properties"]["code"] for f in features], ["75101", "75102", "92001", "92002"])
        self.assertIn(features[0]["geometry"]["type"], ("Polygon", "MultiPolygon"))
        self.assertEqual(self.client.get("/zones", headers={"If-None-Match": response.headers["ETag"]}).status_code, 304)
        # Asking for the map asked for OpenStreetMap's latest changes.
        self.assertTrue((Path(self.state.name) / osm.WANTED).exists())

    def test_tracks_outside_the_departments(self):
        # The ride runs east along latitude 48.85 from 2.35 to 2.41 (test_registry.workout); the departments end at 2.40.
        self.client.post("/activities", content=json.dumps(workout()).encode(), headers={"Content-Type": "application/json"})
        # Without the departments, nothing is outside them.
        self.assertEqual(self.client.get("/tracks/outside").json()["features"], [])
        with registry.connect() as conn:
            osm.store(conn, LIMITS, check=False)
        response = self.client.get("/tracks/outside")
        features = response.json()["features"]
        self.assertEqual(len(features), 1)
        longitudes = [point[0] for line in ([features[0]["geometry"]["coordinates"]] if features[0]["geometry"]["type"] == "LineString"
                                            else features[0]["geometry"]["coordinates"]) for point in line]
        self.assertGreaterEqual(min(longitudes), 2.40)
        self.assertEqual(features[0]["properties"], {"r": 1})
        self.assertEqual(self.client.get("/tracks/outside", headers={"If-None-Match": response.headers["ETag"]}).status_code, 304)

    def test_stats_count_the_streets_a_bike_may_ride_in_each_zone(self):
        with registry.connect() as conn:
            osm.store(conn, LIMITS + [STREET, SIDEWALK], check=False)
        stats = self.client.get("/stats").json()
        self.assertEqual([(z["code"], z["ring"], z["ridden_km"]) for z in stats["zones"]],
                         [("75101", 0, 0), ("75102", 0, 0), ("92001", 1, 0), ("92002", 2, 0)])
        self.assertAlmostEqual(stats["zones"][0]["total_km"], 1.5, delta=0.1)
        self.assertEqual(stats["streets"]["ridden_km"], 0)

if __name__ == "__main__":
    unittest.main()
