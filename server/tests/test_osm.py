"""OpenStreetMap's places in osm.lieu: what is kept, the zones and their rings, and the changes applied as mappers edit.
The database tests need STREETNAV_TEST_DATABASE_URL (a throwaway database these tests EMPTY)."""
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from streetnav_server import osm, registry
from test_registry import URL

STAMP = "2026-11-01T00:00:00Z"


def box_ring(west, south, east, north):
    return [{"lat": south, "lon": west}, {"lat": south, "lon": east}, {"lat": north, "lon": east},
            {"lat": north, "lon": west}, {"lat": south, "lon": west}]


def limit(osm_id, level, code, west, south, east, north):
    tags = {"boundary": "administrative", "admin_level": str(level), "name": f"Zone {code}",
            ("ref" if level == 6 else "ref:INSEE"): code}
    return {"type": "relation", "id": osm_id, "version": 1, "changeset": 1, "timestamp": STAMP, "tags": tags,
            "members": [{"type": "way", "ref": osm_id * 10, "role": "outer", "geometry": box_ring(west, south, east, north)}]}


def way(osm_id, points, tags, version=1, first_node=None):
    """A way through (node id, lon, lat) points."""
    return {"type": "way", "id": osm_id, "version": version, "changeset": 1, "timestamp": STAMP, "tags": tags,
            "nodes": [n for n, _, _ in points], "geometry": [{"lon": lon, "lat": lat} for _, lon, lat in points]}


# Paris (75) from 2.30 to 2.40 in two arrondissements, the 92 to its west in two communes, one of them holding a
# commune déléguée (level 9 too, not a zone); a commune of the 77 the box also catches.
LIMITS = [
    limit(1, 6, "75", 2.30, 48.82, 2.40, 48.88), limit(2, 6, "92", 2.10, 48.82, 2.30, 48.88),
    limit(3, 8, "75056", 2.30, 48.82, 2.40, 48.88),
    limit(4, 9, "75101", 2.30, 48.82, 2.35, 48.88), limit(5, 9, "75102", 2.35, 48.82, 2.40, 48.88),
    limit(6, 8, "92001", 2.20, 48.82, 2.30, 48.88), limit(7, 8, "92002", 2.10, 48.82, 2.20, 48.88),
    limit(8, 8, "77001", 2.50, 48.82, 2.60, 48.88), limit(9, 9, "92098", 2.20, 48.82, 2.25, 48.85),
]
STREET = way(100, [(1001, 2.31, 48.85), (1002, 2.32, 48.85), (1003, 2.33, 48.85)],
             {"highway": "residential", "name": "Rue A"})
SIDEWALK = way(101, [(1011, 2.36, 48.84), (1012, 2.37, 48.84)], {"highway": "footway", "footway": "sidewalk", "name": "Rue G"})
PATH = way(102, [(1021, 2.25, 48.86), (1022, 2.26, 48.86)], {"highway": "path"})  # unnamed path: not kept
SQUARE = way(103, [(1031, 2.36, 48.86), (1032, 2.37, 48.86), (1033, 2.37, 48.87), (1034, 2.36, 48.87), (1031, 2.36, 48.86)],
             {"place": "square", "name": "Place C"})
# A square drawn crossing itself (a bow tie): no polygon GEOS can intersect, kept all the same.
BOW_TIE = way(107, [(1071, 2.36, 48.85), (1072, 2.37, 48.86), (1073, 2.37, 48.85), (1074, 2.36, 48.86), (1071, 2.36, 48.85)],
              {"highway": "pedestrian", "area": "yes", "name": "Place H"})
FAR = way(104, [(1041, 1.90, 48.85), (1042, 1.91, 48.85)], {"highway": "primary", "name": "Route D"})


def change(*blocks):
    """An osmChange document from (action, xml of its elements) blocks."""
    return ("<osmChange version=\"0.6\">" + "".join(f"<{a}>{body}</{a}>" for a, body in blocks) + "</osmChange>").encode()


def node_xml(osm_id, lon, lat, version=2):
    return f'<node id="{osm_id}" version="{version}" changeset="9" timestamp="2026-11-05T10:00:00Z" lat="{lat}" lon="{lon}"/>'


def way_xml(osm_id, refs, tags, version=2):
    return (f'<way id="{osm_id}" version="{version}" changeset="9" timestamp="2026-11-05T10:00:00Z">'
            + "".join(f'<nd ref="{r}"/>' for r in refs) + "".join(f'<tag k="{k}" v="{v}"/>' for k, v in tags.items())
            + "</way>")


class RulesTest(unittest.TestCase):
    def test_kinds(self):
        self.assertEqual(osm.kind_of("w", {"highway": "residential"}), "voie")
        self.assertEqual(osm.kind_of("w", {"highway": "path"}), None)
        self.assertEqual(osm.kind_of("w", {"highway": "path", "name": "Allée E"}), "voie")
        self.assertEqual(osm.kind_of("w", {"highway": "path", "bicycle": "designated"}), "voie")
        self.assertEqual(osm.kind_of("w", {"highway": "proposed", "name": "Rue F"}), None)
        self.assertEqual(osm.kind_of("w", {"highway": "pedestrian", "area": "yes"}, closed=True), "place")
        self.assertEqual(osm.kind_of("w", {"place": "square"}, closed=False), None)
        self.assertEqual(osm.kind_of("r", {"boundary": "administrative", "admin_level": "9"}), "limite")
        self.assertEqual(osm.kind_of("r", {"boundary": "administrative", "admin_level": "4"}), None)
        self.assertEqual(osm.kind_of("r", {"type": "multipolygon", "place": "square"}), "place")

    def test_bike_rules(self):
        self.assertEqual(osm.bike_access({"highway": "footway"}), (False, "highway=footway"))
        self.assertEqual(osm.bike_access({"highway": "footway", "bicycle": "yes"}), (True, "bicycle=yes"))
        self.assertEqual(osm.bike_access({"highway": "residential", "access": "private"}), (False, "access=private"))
        self.assertFalse(osm.counted({"highway": "footway", "footway": "sidewalk"}))

    def test_parse_change(self):
        parsed = osm.parse_change(change(("modify", node_xml(1, 2.3, 48.8)),
                                         ("create", way_xml(5, [1, 2], {"highway": "residential"}, version=1)),
                                         ("delete", '<way id="6" version="3" changeset="9" timestamp="2026-11-05T10:00:00Z"/>')))
        self.assertEqual(parsed["nodes"], {1: (2.3, 48.8)})
        self.assertEqual(parsed["moved"], {1})
        self.assertEqual([(w[0], w[1], w[2], w[5], w[6]) for w in parsed["ways"]],
                         [("create", 5, 1, {"highway": "residential"}, [1, 2]), ("delete", 6, 3, {}, [])])


@unittest.skipUnless(URL, "STREETNAV_TEST_DATABASE_URL not set")
class LieuTest(unittest.TestCase):
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
        self.conn.execute("TRUNCATE osm.lieu, sync_run")
        osm.store(self.conn, LIMITS + [STREET, SIDEWALK, PATH, SQUARE, BOW_TIE, FAR], check=False)
        self.conn.commit()

    def tearDown(self):
        self.conn.rollback()
        self.conn.execute("TRUNCATE osm.lieu")
        self.conn.commit()
        self.conn.close()
        self.state.cleanup()

    def rows(self, sql, *params):
        return self.conn.execute(sql, params).fetchall()

    def test_what_is_kept_and_where(self):
        self.assertEqual(self.rows("SELECT osm_type, osm_id, kind, zone FROM osm.lieu WHERE kind <> 'limite' ORDER BY osm_id"),
                         [("w", 100, "voie", "75101"), ("w", 101, "voie", "75102"), ("w", 103, "place", "75102"),
                          ("w", 107, "place", "75102")])
        self.assertEqual(self.rows("SELECT bike, counted FROM osm.lieu WHERE osm_id IN (100, 101) ORDER BY osm_id"),
                         [(True, True), (False, False)])
        self.assertEqual(self.rows("SELECT code, ring FROM osm.lieu WHERE ring IS NOT NULL ORDER BY code"),
                         [("75101", 0), ("75102", 0), ("92001", 1), ("92002", 2)])
        self.assertEqual(self.rows("SELECT code FROM osm.lieu WHERE kind = 'limite' ORDER BY code"),
                         [("75",), ("75056",), ("75101",), ("75102",), ("92",), ("92001",), ("92002",), ("92098",)])
        self.assertEqual(self.rows("SELECT ST_GeometryType(geom) FROM osm.lieu WHERE osm_id = 103"), [("ST_Polygon",)])

    def test_broken_multipolygons_make_an_area_or_none(self):
        crossing = "ST_GeomFromText('MULTILINESTRING((0 0,10 10,10 0,0 10,0 0),(2 2,3 3))', 2154)"
        valid, kind = self.rows(f"SELECT ST_IsValid(osm.area({crossing})), GeometryType(osm.area({crossing}))")[0]
        self.assertEqual((valid, kind), (True, "MULTIPOLYGON"))
        self.assertEqual(self.rows("SELECT osm.area(ST_GeomFromText('MULTILINESTRING((0 0,1 1))', 2154))"), [(None,)])

    def test_changes_applied(self):
        fetched = []

        def fetch(ids):
            fetched.extend(sorted(ids))
            return {2001: (2.335, 48.86)}

        parsed = osm.parse_change(change(
            # Rue A renamed; a new street from its last node to a node only the API knows; the sidewalk deleted; the
            # square's corner moved; a street created far away.
            ("modify", way_xml(100, [1001, 1002, 1003], {"highway": "residential", "name": "Rue B"})
             + node_xml(1033, 2.38, 48.87)),
            ("create", way_xml(105, [1003, 2001], {"highway": "residential", "name": "Rue E"}, version=1)
             + node_xml(3001, 1.80, 48.80, version=1) + node_xml(3002, 1.81, 48.80, version=1)
             + way_xml(106, [3001, 3002], {"highway": "primary"}, version=1)),
            ("delete", '<way id="101" version="2" changeset="9" timestamp="2026-11-05T10:00:00Z"/>')))
        done = osm.apply(self.conn, parsed, fetch=fetch)
        self.assertEqual((done["added"], done["changed"], done["removed"], done["moved"]), (1, 1, 1, 1))
        self.assertEqual(fetched, [2001])
        self.assertEqual(self.rows("SELECT osm_id, name, version FROM osm.lieu WHERE kind = 'voie' ORDER BY osm_id"),
                         [(100, "Rue B", 2), (105, "Rue E", 1)])
        self.assertEqual(self.rows("""SELECT round(ST_X(ST_Transform(ST_PointN(ST_ExteriorRing(geom), 3), 4326))::numeric, 2)::float8
                                      FROM osm.lieu WHERE osm_id = 103"""), [(2.38,)])
        self.assertEqual(self.rows("SELECT zone FROM osm.lieu WHERE osm_id = 105"), [("75101",)])
        # An older version comes too late: nothing changes.
        osm.apply(self.conn, osm.parse_change(change(
            ("modify", way_xml(100, [1001, 1002, 1003], {"highway": "residential", "name": "Rue A"}, version=1)))))
        self.assertEqual(self.rows("SELECT name FROM osm.lieu WHERE osm_id = 100"), [("Rue B",)])
        # A street whose tags no longer make it kept goes.
        osm.apply(self.conn, osm.parse_change(change(
            ("modify", way_xml(105, [1003, 2001], {"highway": "proposed", "name": "Rue E"})))))
        self.assertEqual(self.rows("SELECT count(*) FROM osm.lieu WHERE osm_id = 105"), [(0,)])

    def test_update_remembers_what_it_applied(self):
        listed = [{"id": 9, "created_at": "2026-11-05T10:00:00Z", "closed_at": "2026-11-05T10:01:00Z", "open": False,
                   "changes": 1, "box": [48.85, 2.31, 48.85, 2.33]}]
        body = change(("modify", way_xml(100, [1001, 1002, 1003], {"highway": "residential", "name": "Rue B"})))
        with mock.patch.object(osm, "changesets", return_value=listed), \
                mock.patch.object(osm, "request", return_value=body) as request:
            self.assertEqual(osm.update(self.conn)["changed"], 1)
            self.assertEqual(osm.update(self.conn)["changesets"], 0)
        self.assertEqual(request.call_count, 1)
        state = json.loads((Path(self.state.name) / "osm-state.json").read_text())
        self.assertEqual((state["since"], state["seen"]), ("2026-11-05T10:01:00Z", {"9": 1}))


if __name__ == "__main__":
    unittest.main()
