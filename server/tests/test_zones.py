"""Zones: the rings around Paris and the zone of each part of a street. Needs STREETNAV_TEST_DATABASE_URL (a throwaway
database these tests EMPTY)."""
import json
import os
import tempfile
import unittest
from pathlib import Path

from streetnav_server import registry, streets, zones
from test_registry import URL, workout
from test_streets import street


def square(code, west, south, east, north):
    ring = [[west, south], [east, south], [east, north], [west, north], [west, south]]
    return (code, f"Zone {code}", code[:2], json.dumps({"type": "Polygon", "coordinates": [ring]}))


@unittest.skipUnless(URL, "STREETNAV_TEST_DATABASE_URL not set")
class ZonesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with registry.connect() as conn:
            for sql in sorted((Path(__file__).parents[1] / "sql").glob("*.sql")):
                conn.execute(sql.read_text())

    def setUp(self):
        self.raw = tempfile.TemporaryDirectory()
        os.environ["STREETNAV_RAW_DIR"] = self.raw.name
        self.conn = registry.connect()
        self.conn.execute("TRUNCATE activity, activity_source, activity_heart_rate, sync_run, raw_file, ride_piece, "
                          "street_part, street_run, street, zone RESTART IDENTITY CASCADE")

    def tearDown(self):
        self.conn.execute("TRUNCATE zone")
        self.conn.close()
        self.raw.cleanup()

    def test_rings_and_parts(self):
        # The ride runs east along latitude 48.85 from 2.35 (test_registry.workout).
        payload = workout()
        registry.ingest(self.conn, payload["source"], payload["external_id"],
                        [("payload", "A.json", json.dumps(payload).encode())], "api")
        streets.load([street(1, 2.355, 48.85, 2.365, 48.85),            # in 92001, under the ride
                      street(2, 2.385, 48.855, 2.395, 48.855),          # in 92002, away from it
                      street(3, 2.355, 48.865, 2.365, 48.865)], self.conn)  # in 93001
        streets.compute(self.conn)
        by_ring = zones.load([square("75101", 2.33, 48.84, 2.35, 48.86),    # Paris
                              square("92001", 2.35, 48.84, 2.37, 48.86),    # along Paris's east edge
                              square("92002", 2.37, 48.84, 2.40, 48.86),    # along 92001's
                              square("93001", 2.35, 48.86, 2.37, 48.87),    # meets Paris at a corner only
                              square("94001", 2.60, 48.70, 2.61, 48.71)],   # far from all
                             self.conn)
        self.assertEqual(by_ring, {"0": 1, "1": 1, "2": 2, "none": 1})
        rings = dict(self.conn.execute("SELECT code, ring FROM zone").fetchall())
        self.assertEqual((rings["92001"], rings["92002"], rings["93001"]), (1, 2, 2))
        parts = self.conn.execute("SELECT street_id, zone, bool_or(ridden) FROM street_part GROUP BY 1, 2 ORDER BY 1").fetchall()
        self.assertEqual(parts, [(1, "92001", True), (2, "92002", False), (3, "93001", False)])


if __name__ == "__main__":
    unittest.main()
