"""Streets ridden and not ridden: a ride along a street, a ride crossing another. Needs STREETNAV_TEST_DATABASE_URL (a
throwaway database these tests EMPTY)."""
import json
import os
import tempfile
import unittest
from datetime import timedelta
from pathlib import Path

from streetnav_server import registry, streets
from test_registry import T0, URL, workout


def street(osm_id, lon_from, lat_from, lon_to, lat_to, highway="residential"):
    return (osm_id, f"Rue {osm_id}", highway, f"SRID=4326;LINESTRING({lon_from} {lat_from},{lon_to} {lat_to})")


@unittest.skipUnless(URL, "STREETNAV_TEST_DATABASE_URL not set")
class StreetsTest(unittest.TestCase):
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
                          "street_part, street_run, street RESTART IDENTITY CASCADE")

    def tearDown(self):
        self.conn.close()
        self.raw.cleanup()

    def push(self, payload):
        registry.ingest(self.conn, payload["source"], payload["external_id"],
                        [("payload", payload["external_id"] + ".json", json.dumps(payload).encode())], "api")

    def parts(self, osm_id):
        return self.conn.execute("SELECT ridden, round(length_m) FROM street_part WHERE street_id = %s ORDER BY "
                                 "ST_LineLocatePoint((SELECT geom FROM street WHERE id = %s), ST_StartPoint(geom))",
                                 (osm_id, osm_id)).fetchall()

    def test_ridden_along_and_crossing(self):
        # A ride east along latitude 48.85, from 2.35 to 2.41 (about 4.4 km).
        self.push(workout())
        streets.load([street(1, 2.36, 48.85, 2.37, 48.85),        # under the ride: ridden
                      street(2, 2.36, 48.86, 2.37, 48.86),        # 1.1 km north: never ridden
                      street(3, 2.38, 48.845, 2.38, 48.855),      # crossed by the ride: not ridden
                      street(4, 2.40, 48.85, 2.43, 48.85)], self.conn)  # ridden on its first third only
        streets.compute(self.conn)
        self.assertEqual([r for r, _ in self.parts(1)], [True])
        self.assertEqual([r for r, _ in self.parts(2)], [False])
        self.assertEqual([r for r, _ in self.parts(3)], [False])
        self.assertEqual([r for r, _ in self.parts(4)], [True, False])

    def test_bike_path_alongside_belongs_to_its_street(self):
        # The ride goes along a bike path 15 m north of a street (out of reach of the street itself), across another
        # street, and past a bike path of its own away from any street.
        self.push(workout())
        streets.load([street(1, 2.36, 48.849865, 2.37, 48.849865),             # 15 m south of the ride
                      street(2, 2.36, 48.85, 2.37, 48.85, "cycleway"),          # under the ride, alongside 1
                      street(3, 2.365, 48.845, 2.365, 48.855),                  # crossing both: not ridden
                      street(4, 2.38, 48.85, 2.39, 48.85, "cycleway")], self.conn)  # away from streets: its own
        streets.compute(self.conn)
        self.assertEqual(self.conn.execute("SELECT id, alongside FROM street WHERE highway = 'cycleway' ORDER BY id")
                         .fetchall(), [(2, 1), (4, None)])
        self.assertEqual([r for r, _ in self.parts(1)], [True])
        self.assertEqual(self.parts(2), [])
        self.assertEqual([r for r, _ in self.parts(3)], [False])
        self.assertEqual([r for r, _ in self.parts(4)], [True])

    def test_refresh_only_near_new_rides(self):
        streets.load([street(1, 2.36, 48.85, 2.37, 48.85)], self.conn)
        streets.compute(self.conn)
        streets.record(self.conn, 0)
        self.conn.commit()  # each run and each ride in its own transaction, as on the server
        self.assertEqual([r for r, _ in self.parts(1)], [False])
        self.push(workout("B", start=T0 + timedelta(days=1)))
        self.conn.commit()
        self.assertEqual(streets.refresh(self.conn), 1)
        self.assertEqual([r for r, _ in self.parts(1)], [True])
