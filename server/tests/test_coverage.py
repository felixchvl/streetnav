"""Coverage: tronçons cut from osm.lieu, ways merged into streets, rides' passages and the counters. The database test
needs STREETNAV_TEST_DATABASE_URL (a throwaway database these tests EMPTY)."""
import math
import os
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from streetnav_server import coverage, osm, registry
from test_osm import LIMITS, way
from test_registry import URL

T0 = int(datetime(2026, 11, 1, 9, 0, tzinfo=timezone.utc).timestamp())
LAT_M = 1 / 111_200                                # degrees of latitude in a metre
LON_M = 1 / (111_320 * math.cos(math.radians(48.85)))

# In the 1st arrondissement of test_osm's Paris: Rue A west to east, crossed in its middle by Rue B, which ends
# north in an impasse; Rue E and Rue F from Rue A's ends to Rue B's south end; an unnamed cycleway 8 m north of Rue A,
# sharing no node with it; Boulevard D in two one-way carriageways 22 m apart.
RUE_A = way(201, [(2001, 2.31, 48.85), (2002, 2.32, 48.85), (2003, 2.33, 48.85)], {"highway": "residential", "name": "Rue A"})
RUE_B = way(202, [(2011, 2.32, 48.845), (2002, 2.32, 48.85), (2012, 2.32, 48.855)], {"highway": "residential", "name": "Rue B"})
RUE_E = way(206, [(2001, 2.31, 48.85), (2011, 2.32, 48.845)], {"highway": "residential", "name": "Rue E"})
RUE_F = way(207, [(2003, 2.33, 48.85), (2011, 2.32, 48.845)], {"highway": "residential", "name": "Rue F"})
CYCLEWAY = way(203, [(2021, 2.3105, 48.85 + 8 * LAT_M), (2022, 2.3295, 48.85 + 8 * LAT_M)], {"highway": "cycleway"})
EASTBOUND = way(204, [(2031, 2.31, 48.87), (2032, 2.33, 48.87)], {"highway": "secondary", "name": "Boulevard D", "oneway": "yes"})
WESTBOUND = way(205, [(2041, 2.33, 48.87 + 22 * LAT_M), (2042, 2.31, 48.87 + 22 * LAT_M)],
                {"highway": "secondary", "name": "Boulevard D", "oneway": "yes"})


def track(*legs, start=T0, step_m=5.0):
    """A ride through (lon, lat) points, a point every step_m metres and every second (EWKT LineStringZM)."""
    points, t = [], start
    for (x0, y0), (x1, y1) in zip(legs, legs[1:]):
        dist = math.hypot((x1 - x0) / LON_M, (y1 - y0) / LAT_M)
        n = max(1, round(dist / step_m))
        for k in range(n):
            points.append((x0 + (x1 - x0) * k / n, y0 + (y1 - y0) * k / n, t))
            t += 1
    points.append((*legs[-1], t))
    return "SRID=4326;LINESTRING ZM(" + ",".join(f"{x:.7f} {y:.7f} 35 {t}" for x, y, t in points) + ")"


class RulesTest(unittest.TestCase):
    def test_a_path_along_a_street_is_merged_whole_or_in_its_long_parts(self):
        along = [(10, 7, None, None)] * 9 + [(10, None, None, None)]
        self.assertEqual(coverage.merge("side", along), ([(0.0, 1.0, 7, "piste")], []))
        partly = [(10, 7, None, None)] * 4 + [(10, None, None, None)] * 4 + [(10, 8, None, None)] * 2
        self.assertEqual(coverage.merge("side", partly), ([(0.0, 0.4, 7, "piste")], [(0.4, 1.0)]))
        self.assertEqual(coverage.merge("side", [(10, None, None, None)] * 3), ([], [(0.0, 1.0)]))

    def test_the_other_carriageway_and_contre_allees_are_merged(self):
        self.assertEqual(coverage.merge("street", [(20, None, 5, None)] * 3 + [(20, None, None, None)]),
                         ([(0.0, 1.0, 5, "chaussee")], []))
        self.assertEqual(coverage.merge("street", [(20, None, None, 6)] * 2), ([(0.0, 1.0, 6, "contre_allee")], []))
        self.assertEqual(coverage.merge("street", [(20, None, 5, None)] + [(20, None, None, None)] * 2), ([], [(0.0, 1.0)]))

    def test_runs_are_cut_when_the_ride_leaves_the_way_or_turns_back(self):
        out_and_back = [(i, i, 10.0 * i) for i in range(8)] + [(8 + i, 8 + i, 60.0 - 10 * i) for i in range(7)]
        self.assertEqual([(r[0][2], r[-1][2]) for r in coverage.runs(out_and_back)], [(0.0, 70.0), (70.0, 0.0)])
        left = [(0, 0, 0.0), (1, 1, 10.0), (30, 30, 20.0), (31, 31, 30.0)]
        self.assertEqual(len(coverage.runs(left)), 2)
        # In a tunnel, no points for 40 s over 400 m: one run all the same
        tunnel = [(0, 0, 0.0), (1, 1, 10.0), (20, 41, 410.0), (21, 42, 420.0)]
        self.assertEqual(len(coverage.runs(tunnel, tunnel=True)), 1)
        self.assertEqual(len(coverage.runs(tunnel)), 2)
        # ...but not when the points in between were along a street in the open air: the ride was up there
        on_the_quay = [(0, 0, 0.0), (1, 1, 10.0), (60, 60, 410.0), (61, 61, 420.0)]
        self.assertEqual(len(coverage.runs(on_the_quay, tunnel=True, elsewhere=frozenset(range(2, 60)))), 2)

    def test_a_passage_rides_the_troncon_all_along_or_not(self):
        street = [coverage.Troncon(1, 0.0, 100.0, 0), coverage.Troncon(2, 100.0, 300.0, 0)]
        run = [(i, i, 5.0 * i) for i in range(41)]                                  # 0 to 200 m
        self.assertEqual([(p[0], p[1], p[2], p[5]) for p in coverage.passages(run, street)],
                         [(1, 0.0, 100.0, True), (2, 0.0, 100.0, False)])
        crossing = [(i, i, 95.0 + i) for i in range(11)]                            # 95 to 105 m: crossing it
        self.assertEqual(coverage.passages(crossing, street), [])
        impasse = [coverage.Troncon(3, 0.0, 67.0, 1)]                               # dead end at 67 m
        self.assertEqual(coverage.needed(67.0, 1), (0.0, 47.0))
        self.assertEqual(coverage.needed(30.0, -1), (20.0, 30.0))
        way_in = [(i, i, 5.0 * i) for i in range(10)]                               # 0 to 45 m: done
        self.assertTrue(coverage.passages(way_in, impasse)[0][5])
        self.assertFalse(coverage.passages(way_in[::-1], impasse)[0][5])            # the way back: no new passage

    def test_passages_together_can_ride_a_troncon_all_along(self):
        first = (1, 0.0, 60.0, 10, 20, False)
        second = (2, 50.0, 100.0, 30, 40, False)
        self.assertEqual(coverage.state(100.0, 0, [first, second]), (100.0, True, 0, 0, 10, 40, 2, 40))
        self.assertEqual(coverage.state(100.0, 0, [first]), (60.0, False, 0, 0, 10, None, None, 20))


@unittest.skipUnless(URL, "STREETNAV_TEST_DATABASE_URL not set")
class CoverageTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        os.environ["STREETNAV_DATABASE_URL"] = URL
        with registry.connect() as conn:
            for sql in sorted((Path(__file__).parents[1] / "sql").glob("*.sql")):
                conn.execute(sql.read_text())

    def setUp(self):
        self.state = tempfile.TemporaryDirectory()
        os.environ["STREETNAV_STATE_DIR"] = self.state.name
        self.conn = registry.connect()
        self.conn.execute("TRUNCATE osm.lieu, activity CASCADE")
        self.conn.execute("TRUNCATE couverture.troncon, couverture.membre, couverture.passage, couverture.troncon_etat, "
                          "couverture.sortie, couverture.build")
        osm.store(self.conn, LIMITS + [RUE_A, RUE_B, RUE_E, RUE_F, CYCLEWAY, EASTBOUND, WESTBOUND], check=False)
        rides = [
            # Along the cycleway, west to east, across Rue B
            track((2.3105, 48.85 + 8 * LAT_M), (2.3295, 48.85 + 8 * LAT_M)),
            # Up Rue B to 22 m from its dead end, and back down
            track((2.32, 48.845), (2.32, 48.855 - 22 * LAT_M), (2.32, 48.845), start=T0 + 3600),
            # Along Boulevard D's westbound carriageway
            track((2.3295, 48.87 + 22 * LAT_M), (2.3105, 48.87 + 22 * LAT_M), start=T0 + 7200),
        ]
        for i, ride in enumerate(rides, 1):
            self.conn.execute("""INSERT INTO activity (id, started_at, sport, track, primary_source)
                                 VALUES (%s, to_timestamp(%s), 'cycling', ST_GeomFromEWKT(%s), 'healthkit')""",
                              (i, T0 + 3600 * (i - 1), ride))
        self.conn.commit()

    def tearDown(self):
        self.conn.rollback()
        self.conn.close()
        self.state.cleanup()

    def rows(self, sql, *params):
        return self.conn.execute(sql, params).fetchall()

    def test_streets_merged_cut_and_ridden(self):
        done = coverage.update(self.conn, full=True)
        self.conn.commit()
        self.assertTrue(done["full"])
        # Rue A and Rue B cut where they cross, Boulevard D one tronçon; Rue B's north end an impasse
        self.assertEqual(self.rows("SELECT osm_id, impasse, zone FROM couverture.troncon ORDER BY osm_id, a"),
                         [(201, 0, "75101"), (201, 0, "75101"), (202, 0, "75101"), (202, 1, "75101"), (204, 0, "75101"),
                          (206, 0, "75101"), (207, 0, "75101")])
        self.assertEqual(self.rows("SELECT osm_id, ref_osm_id, role FROM couverture.membre ORDER BY osm_id"),
                         [(203, 201, "piste"), (205, 204, "chaussee")])
        # Complete passages: Rue A by its cycleway, Rue B there and back (twice its south, once into the impasse),
        # Boulevard D by its other carriageway; Rue B merely crossed by the first ride, Rue E and Rue F merely touched by the
        # second: no passage
        self.assertEqual(self.rows("""SELECT t.osm_id, e.passages, e.rides, e.done, e.done_activity FROM couverture.troncon t
                                      JOIN couverture.troncon_etat e ON e.troncon_id = t.id ORDER BY t.osm_id, t.a"""),
                         [(201, 1, 1, True, 1), (201, 1, 1, True, 1), (202, 2, 1, True, 2), (202, 1, 1, True, 2),
                          (204, 1, 1, True, 3)])
        self.assertEqual(self.rows("SELECT osm_id, roles, passages, rides FROM couverture.objet ORDER BY osm_id"),
                         [(201, "rue", 1, 1), (202, "rue", 2, 1), (203, "piste", 1, 1), (204, "rue", 1, 1),
                          (205, "chaussee", 1, 1), (206, "rue", 0, 0), (207, "rue", 0, 0)])

        # Nothing changed: nothing measured again; a ride deleted: its passages go
        self.assertEqual(coverage.update(self.conn)["rides"], 0)
        self.conn.execute("DELETE FROM activity WHERE id = 3")
        done = coverage.update(self.conn)
        self.assertEqual((done["full"], done["removed"]), (False, 1))
        self.assertEqual(self.rows("SELECT count(*) FROM couverture.troncon_etat WHERE done_activity = 3"), [(0,)])

    def test_a_ride_through_a_place_rides_all_of_it(self):
        # Place G, a square of 100 m, crossed corner to corner by Rue H and Rue I, which meet in its middle
        x, y, d = 2.35, 48.86, 100
        corner = [(x, y), (x + d * LON_M, y), (x + d * LON_M, y + d * LAT_M), (x, y + d * LAT_M)]
        middle = (2065, x + d / 2 * LON_M, y + d / 2 * LAT_M)
        place = way(208, [(2051 + k, *corner[k % 4]) for k in range(4)] + [(2051, *corner[0])],
                    {"place": "square", "name": "Place G"})
        rue_h = way(209, [(2061, *corner[0]), middle, (2062, *corner[2])], {"highway": "residential", "name": "Rue H"})
        rue_i = way(210, [(2063, *corner[1]), middle, (2064, *corner[3])], {"highway": "residential", "name": "Rue I"})
        osm.store(self.conn, LIMITS + [RUE_A, RUE_B, RUE_E, RUE_F, CYCLEWAY, EASTBOUND, WESTBOUND, place, rue_h, rue_i],
                  check=False)
        # From the south-west corner to the middle only: 70 m in the place
        self.conn.execute("""INSERT INTO activity (id, started_at, sport, track, primary_source)
                             VALUES (4, to_timestamp(%s), 'cycling', ST_GeomFromEWKT(%s), 'healthkit')""",
                          (T0 + 10800, track(corner[0], middle[1:], start=T0 + 10800)))
        coverage.update(self.conn, full=True)
        self.assertEqual(self.rows("SELECT osm_id, place FROM couverture.troncon WHERE place IS NOT NULL ORDER BY osm_id, a"),
                         [(209, "w208"), (209, "w208"), (210, "w208"), (210, "w208")])
        # All four tronçons ridden all along by that ride, by riding through the place (its corners being dead ends,
        # the ride rode out of one, which is no complete passage of it)
        self.assertEqual(self.rows("""SELECT count(*), count(*) FILTER (WHERE by_place) FROM couverture.passage
                                      WHERE activity_id = 4 AND complete"""), [(4, 4)])
        self.assertEqual(self.rows("""SELECT e.passages, e.done, e.done_activity FROM couverture.troncon t
                                      JOIN couverture.troncon_etat e ON e.troncon_id = t.id WHERE t.place IS NOT NULL"""),
                         [(1, True, 4)] * 4)
        self.assertEqual(self.rows("SELECT osm_id, passages FROM couverture.objet WHERE osm_id IN (209, 210) ORDER BY osm_id"),
                         [(209, 1), (210, 1)])
