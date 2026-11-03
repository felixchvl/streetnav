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


def street(osm_id, lon_from, lat_from, lon_to, lat_to, highway="residential", **tags):
    tags = {"highway": highway, "name": f"Rue {osm_id}", **tags}
    return (osm_id, tags["name"], highway, json.dumps(tags),
            f"SRID=4326;LINESTRING({lon_from} {lat_from},{lon_to} {lat_to})")


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
                          "street_part, street_run, street, zone RESTART IDENTITY CASCADE")

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

    def test_only_the_ways_a_bike_may_ride_are_measured(self):
        self.push(workout())
        streets.load([street(1, 2.36, 48.85, 2.37, 48.85, "pedestrian"),                   # closed to bikes
                      street(2, 2.37, 48.85, 2.38, 48.85, "pedestrian", bicycle="yes"),    # opened by its tag
                      street(3, 2.38, 48.85, 2.39, 48.85, footway="sidewalk"),             # part of a street
                      street(4, 2.39, 48.85, 2.40, 48.85, access="private"),               # closed
                      street(5, 2.36, 48.87, 2.37, 48.87, "path")], self.conn)             # open in France
        streets.compute(self.conn)
        self.assertEqual(self.conn.execute("SELECT id, bike, bike_reason, counted FROM street ORDER BY id").fetchall(),
                         [(1, False, "highway=pedestrian", True), (2, True, "bicycle=yes", True),
                          (3, True, "highway=residential", False), (4, False, "access=private", True),
                          (5, True, "highway=path", True)])
        self.assertEqual([r for r, _ in self.parts(2)], [True])
        self.assertEqual([r for r, _ in self.parts(5)], [False])
        self.assertEqual([self.parts(i) for i in (1, 3, 4)], [[], [], []])

    def test_bike_path_beside_a_street_closed_to_bikes_is_its_own(self):
        self.push(workout())
        streets.load([street(1, 2.36, 48.849865, 2.37, 48.849865, "primary", bicycle="no"),
                      street(2, 2.36, 48.85, 2.37, 48.85, "cycleway")], self.conn)
        streets.compute(self.conn)
        self.assertEqual(self.conn.execute("SELECT alongside FROM street WHERE id = 2").fetchone(), (None,))
        self.assertEqual([r for r, _ in self.parts(2)], [True])
        self.assertEqual(self.parts(1), [])

    def test_a_place_ridden_through_counts_as_ridden_all_over(self):
        # paris-rues's register of voies, only what streets.places reads (rolled back with the test).
        self.conn.execute("""CREATE SCHEMA paris_rues;
                             CREATE TABLE paris_rues.voie (id integer, kind text, footprint geometry(MultiPolygon, 2154))""")
        for voie_id, kind, south in ((1, "place", 48.8496), (2, "place", 48.8596), (3, "rue", 48.8696)):
            self.conn.execute("INSERT INTO paris_rues.voie VALUES (%s, %s, ST_Multi(ST_Transform(ST_MakeEnvelope("
                              "2.3743, %s, 2.3757, %s, 4326), 2154)))", (voie_id, kind, south, south + 0.0008))
        self.push(workout())  # along latitude 48.85, through place 1
        streets.load([street(1, 2.37, 48.85, 2.38, 48.85),           # under the ride, across place 1
                      street(2, 2.3746, 48.8503, 2.3754, 48.8503),   # in place 1, 33 m from the ride
                      street(3, 2.3753, 48.849, 2.3753, 48.852),     # across place 1 and beyond, crossed by the ride
                      street(4, 2.3746, 48.86, 2.3754, 48.86),       # in place 2, never ridden through
                      street(5, 2.3746, 48.87, 2.3754, 48.87)], self.conn)  # in a street's footprint, not a place's
        streets.compute(self.conn)

        def shown(osm_id):
            return [r for r, in self.conn.execute(
                f"SELECT {streets.SHOWN_RIDDEN} FROM street_part WHERE street_id = %s ORDER BY "
                "ST_LineLocatePoint((SELECT geom FROM street WHERE id = %s), ST_StartPoint(geom))", (osm_id, osm_id))]
        self.assertEqual(shown(1), [True, True, True])
        self.assertEqual([r for r, _ in self.parts(2)], [False])
        self.assertEqual(shown(2), [True])
        self.assertEqual(shown(3), [False, True, False])
        self.assertEqual(shown(4), [False])
        self.assertEqual(shown(5), [False])
        self.assertEqual(self.conn.execute("SELECT DISTINCT place FROM street_part WHERE street_id IN (2, 4, 5) "
                                           "ORDER BY 1").fetchall(), [(1,), (2,), (None,)])

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
