"""Coverage: the streets each bike ride went along, measured again from the rides' cropped tracks (gold `activity`)
and OpenStreetMap's ways (osm.lieu) whenever either changes. The rules are those of the note « Règles des segments
Streetnav » in Metanotes.

1. Tronçons (couverture.troncon), from osm.lieu alone. Of the ways a bike may ride (osm.py), three kinds are merged
   into a street, riding them riding the street (couverture.membre):
   - a bike path along a street: the parts of a cycleway, footway or path running beside a street (within SIDE_M,
     in the same direction), whole when it runs beside streets for SIDE_SHARE of its length, otherwise the parts of
     ALONG_MIN_M or more, the rest staying a way of its own;
   - the other carriageway of a dual carriageway: a one-way street running the other way beside a one-way street of
     the same name (within TWIN_M, for TWIN_SHARE of its length); of the two, the street keeps the carriageway heading
     north through east to south (azimuth under 180 degrees), so that each pair keeps exactly one;
   - a contre-allée: a service road beside a street of the same name (within TWIN_M, for TWIN_SHARE of its length),
     or beside a longer service road of the same name (one road drawn twice).
   Two streets of different names never merge. The ways left are cut at their crossroads, the nodes they share with
   another: each tronçon is a stretch of one OSM way between two crossroads. One whose end no other bike way reaches
   is an impasse.
2. Passages (couverture.passage). A point of a ride's track is along a tronçon when it lies within its reach (half
   its width, from the width tag, else its lanes, else its kind of road, plus GPS_M) or within the reach of a way
   merged into it; it is then placed along the tronçon's way. The points along a way make runs, cut when the ride
   leaves it for more than SKIP_POINTS points or turns back by more than TURN_M. In a tunnel, where the GPS loses the
   satellites, a gap is no cut as long as crossing it took a plausible time and the points missing were nowhere else;
   and a point along a way in the open air is on it, not in a tunnel beneath, but at the tunnel's mouths (within
   TUNNEL_MOUTH_M of its ends). A run's part on each tronçon is a passage, kept when it is more than a ride crossing
   the street: RUN_MIN_M long, or most of a shorter tronçon.
   A passage rides the tronçon all along (complete) when it covers DONE_SHARE of it; an impasse, where one turns
   back, of its length but the last IMPASSE_END_M (at least IMPASSE_MIN_M), on the way in: there and back is one
   passage, where a street ridden there and back is two.
3. State (couverture.troncon_etat): the metres ridden by all passages together, done when they cover the tronçon as
   one complete passage would, the number of complete passages and of rides, the first passage, when it was done and
   by which ride, the last passage. couverture.objet counts the passages of each OSM way.

Each run brings the coverage up to date: everything again when osm.lieu changed since the tronçons were cut,
otherwise only the rides added, changed or deleted since the last run (a timer runs it every 10 minutes).

  python -m streetnav_server.coverage          bring the coverage up to date
  python -m streetnav_server.coverage full     measure everything again
"""
from __future__ import annotations

import json
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from itertools import chain

from .osm import ZONE
from .registry import connect

GPS_M = 5.0                # Apple Watch Ultra 2, dual-frequency GPS
WIDTH_M = {"primary": 12, "secondary": 10, "tertiary": 8, "primary_link": 6, "secondary_link": 6,
           "tertiary_link": 6, "unclassified": 6, "residential": 6, "living_street": 6, "pedestrian": 8,
           "service": 5, "track": 4}
PATH_WIDTH_M = 3           # cycleways, footways, paths
MAX_HALF_WIDTH_M = 20.0
SIDE_M = 15.0
SIDE_SHARE = 0.8
ALONG_MIN_M = 30.0
TWIN_M = 40.0
TWIN_SHARE = 0.6
PARALLEL_SIN = 0.5         # in the same direction: within 30 degrees
OPPOSITE_COS = -0.7        # the other way: within 45 degrees
SIDE_PIECE_M = 10
STREET_PIECE_M = 20
DONE_SHARE = 0.9
IMPASSE_END_M = 20.0
IMPASSE_MIN_M = 10.0
RUN_MIN_M = 30.0
SKIP_POINTS = 10
TURN_M = 30.0
TUNNEL_GAP_S = 600
TUNNEL_SPEED_MS = 20.0
TUNNEL_MOUTH_M = 30.0
LOCK = 0x434F_5652
RIDE = "a.sport = 'cycling' AND a.track IS NOT NULL AND NOT coalesce(a.indoor, false)"
PATHS = "('cycleway', 'footway', 'path')"
MAY_MERGE = f"(cls = 'side' OR name IS NOT NULL AND (oneway <> 0 OR highway = 'service'))"

WIDTH_SQL = (f"least(coalesce(replace(substring(tags->>'width' FROM '^\\s*([0-9]+(?:[.,][0-9]+)?)\\s*m?\\s*$'), ',', '.')::float8,"
             f" substring(tags->>'lanes' FROM '^\\s*([0-9]+)\\s*$')::float8 * 3,"
             f" CASE tags->>'highway' {' '.join(f'WHEN {k!r} THEN {v}' for k, v in WIDTH_M.items())} ELSE {PATH_WIDTH_M} END)"
             f" / 2, {MAX_HALF_WIDTH_M}) + {GPS_M}")
PAVED = ("asphalt", "concrete", "concrete:plates", "concrete:lanes", "paving_stones", "paving_stones:lanes", "sett",
         "cobblestone", "unhewn_cobblestone", "paved", "metal", "wood", "chipseal", "bricks", "brick", "granite",
         "stone", "rubber", "tartan", "acrylic", "metal_grid")
STABILISED = ("compacted", "fine_gravel")
EARTH = ("dirt", "ground", "gravel", "earth", "grass", "mud", "sand", "unpaved", "pebblestone", "woodchips", "rock",
         "grass_paver", "soil", "clay", "stepping_stones")


def sql_list(values) -> str:
    return "(" + ",".join(f"'{v}'" for v in values) + ")"


# Streets are paved unless tagged otherwise, and so are cycleways; paths and tracks are what their tags say.
SURFACE_SQL = f"""CASE WHEN tags->>'surface' IN {sql_list(PAVED)} THEN 'revetu'
                       WHEN tags->>'surface' IN {sql_list(STABILISED)} THEN 'stabilise'
                       WHEN tags->>'surface' IN {sql_list(EARTH)} THEN 'terre'
                       WHEN tags->>'tracktype' = 'grade1' THEN 'revetu'
                       WHEN tags->>'tracktype' = 'grade2' THEN 'stabilise'
                       WHEN tags->>'tracktype' IN ('grade3', 'grade4', 'grade5') THEN 'terre'
                       WHEN tags->>'highway' NOT IN ('path', 'track', 'footway', 'bridleway') THEN 'revetu'
                       ELSE 'inconnu' END"""

# The ways a bike may ride, with what the tronçons need: side (a path that may run along a street) or street, one-way
# (1 along the way, -1 against it), reach. Sidewalks marked for bikes are there to be merged into their street.
VOIE_SQL = f"""
    CREATE TEMP TABLE cov_voie ON COMMIT DROP AS
    SELECT osm_id, name, tags, tags->>'highway' AS highway, nodes, geom, ST_Length(geom) AS len,
           CASE WHEN tags->>'highway' IN {PATHS} THEN 'side' ELSE 'street' END AS cls,
           CASE WHEN tags->>'oneway' IN ('yes', '1', 'true') THEN 1 WHEN tags->>'oneway' = '-1' THEN -1 ELSE 0 END AS oneway,
           {WIDTH_SQL} AS reach, {SURFACE_SQL} AS surface, coalesce(tags->>'tunnel', 'no') NOT IN ('no', '') AS tunnel
    FROM osm.lieu
    WHERE kind = 'voie' AND osm_type = 'w' AND bike AND GeometryType(geom) = 'LINESTRING' AND ST_Length(geom) > 0
      AND (counted OR 'sidewalk' IN (coalesce(tags->>'footway', ''), coalesce(tags->>'cycleway', ''),
                                      coalesce(tags->>'path', '')))"""
# Direction of line g at its point nearest to m (radians, over about 10 metres).
DIRECTION_SQL = """
    CREATE FUNCTION pg_temp.cov_direction(g geometry, m geometry) RETURNS float8 LANGUAGE sql IMMUTABLE AS $$
        SELECT ST_Azimuth(ST_LineInterpolatePoint(g, greatest(f - d, 0)), ST_LineInterpolatePoint(g, least(f + d, 1)))
        FROM (SELECT ST_LineLocatePoint(g, m) AS f, 5 / greatest(ST_Length(g), 5) AS d) x $$"""
# The ways that may be merged into a street, in pieces, each with the street it runs beside (along), for a one-way
# street heading south to north-west the one-way street of the same name running the other way (twin), for a service
# road the street of the same name beside it (beside: a street, or a longer service road, a path drawn twice; not the
# next way of the same road, whose nearest point is its end).
PIECES_SQL = f"""
    WITH p AS (
        SELECT w.osm_id, w.cls, w.highway, w.name, w.oneway, w.len AS way_len, (s).path[1] AS k, (s).geom AS g
        FROM (SELECT *, ST_DumpSegments(ST_Segmentize(geom, CASE WHEN cls = 'side' THEN {SIDE_PIECE_M} ELSE {STREET_PIECE_M} END)) AS s
              FROM cov_voie WHERE {MAY_MERGE}) w),
    q AS (SELECT *, ST_LineInterpolatePoint(g, 0.5) AS mid, ST_Length(g) AS len,
                 ST_Azimuth(ST_StartPoint(g), ST_EndPoint(g)) AS az,
                 mod((ST_Azimuth(ST_StartPoint(g), ST_EndPoint(g)) + CASE WHEN oneway < 0 THEN pi() ELSE 0 END)::numeric,
                     (2 * pi())::numeric)::float8 AS heading
          FROM p WHERE ST_Length(g) > 0)
    SELECT q.osm_id, q.cls, q.len,
           CASE WHEN q.cls = 'side' THEN (
               SELECT s.osm_id FROM cov_voie s
               WHERE s.cls = 'street' AND ST_DWithin(s.geom, q.mid, {SIDE_M})
                 AND abs(sin(q.az - pg_temp.cov_direction(s.geom, q.mid))) < {PARALLEL_SIN}
               ORDER BY s.geom <-> q.mid, s.osm_id LIMIT 1) END AS along,
           CASE WHEN q.cls = 'street' AND q.oneway <> 0 AND q.heading >= pi() THEN (
               SELECT s.osm_id FROM cov_voie s
               WHERE s.osm_id <> q.osm_id AND s.cls = 'street' AND s.oneway <> 0 AND s.name = q.name
                 AND ST_DWithin(s.geom, q.mid, {TWIN_M})
                 AND cos(q.heading - pg_temp.cov_direction(s.geom, q.mid) - CASE WHEN s.oneway < 0 THEN pi() ELSE 0 END) < {OPPOSITE_COS}
               ORDER BY s.geom <-> q.mid, s.osm_id LIMIT 1) END AS twin,
           CASE WHEN q.cls = 'street' AND q.highway = 'service' THEN (
               SELECT s.osm_id FROM cov_voie s
               WHERE s.osm_id <> q.osm_id AND s.cls = 'street' AND s.name = q.name AND ST_DWithin(s.geom, q.mid, {TWIN_M})
                 AND (s.highway <> 'service' OR (s.len, s.osm_id) > (q.way_len, q.osm_id)
                                                AND ST_LineLocatePoint(s.geom, q.mid) BETWEEN 0.001 AND 0.999)
                 AND abs(sin(q.az - pg_temp.cov_direction(s.geom, q.mid))) < {PARALLEL_SIN}
               ORDER BY s.geom <-> q.mid, s.osm_id LIMIT 1) END AS beside
    FROM q ORDER BY q.osm_id, q.k"""
# A part merged into a way itself merged into a third (a bike path along the other carriageway) goes to the third,
# into the part of the middle one nearest to it.
FOLLOW_SQL = """
    UPDATE cov_member m SET ref_osm_id = (
        SELECT s.ref_osm_id FROM cov_member s JOIN cov_voie sw ON sw.osm_id = s.osm_id
        WHERE s.osm_id = m.ref_osm_id
        ORDER BY ST_Distance(ST_LineSubstring(sw.geom, s.a, s.b), ST_LineInterpolatePoint(ST_LineSubstring(mw.geom, m.a, m.b), 0.5)),
                 s.a
        LIMIT 1)
    FROM cov_voie mw WHERE mw.osm_id = m.osm_id AND m.ref_osm_id IN (SELECT osm_id FROM cov_member)"""
# What is merged into a way that is no street of its own then stays a way of its own.
ORPHANS_SQL = """
    WITH gone AS (DELETE FROM cov_member m WHERE NOT EXISTS (SELECT FROM cov_ref r WHERE r.osm_id = m.ref_osm_id)
                  RETURNING osm_id, a, b)
    INSERT INTO cov_ref SELECT osm_id, a, b FROM gone"""
# Every vertex of the bike ways, with its node and where it lies along its way (0 to 1).
NODES_SQL = """
    CREATE TEMP TABLE cov_node ON COMMIT DROP AS
    SELECT osm_id, node, sum(step) OVER (PARTITION BY osm_id ORDER BY i) / len AS f, i = 1 OR i = n AS way_end
    FROM (SELECT w.osm_id, w.len, d.path[1] AS i, w.nodes[d.path[1]] AS node, ST_NPoints(w.geom) AS n,
                 coalesce(ST_Distance(d.geom, lag(d.geom) OVER (PARTITION BY w.osm_id ORDER BY d.path[1])), 0) AS step
          FROM cov_voie w, ST_DumpPoints(w.geom) d) x;
    CREATE INDEX ON cov_node (osm_id, f);
    CREATE TEMP TABLE cov_degree ON COMMIT DROP AS
    SELECT node, sum(CASE WHEN way_end THEN 1 ELSE 2 END) AS n FROM cov_node WHERE node IS NOT NULL GROUP BY node;
    CREATE INDEX ON cov_degree (node);
    ANALYZE cov_node, cov_degree"""
# The crossroads: nodes two stretches of street share; each stretch is cut at those inside it. A tronçon's end is a
# dead end when it is a way's end that no other bike way reaches (merged ones included).
TRONCONS_SQL = f"""
    WITH ref_node AS (
        SELECT r.osm_id, r.a AS ra, r.b AS rb, n.node, n.f
        FROM cov_ref r JOIN cov_node n ON n.osm_id = r.osm_id AND n.f BETWEEN r.a - 1e-9 AND r.b + 1e-9
        WHERE n.node IS NOT NULL),
    crossroad AS (SELECT node FROM ref_node GROUP BY node HAVING count(*) > 1),
    cut AS (SELECT osm_id, ra, rb, f FROM ref_node WHERE node IN (SELECT node FROM crossroad) AND f > ra + 1e-9 AND f < rb - 1e-9
            UNION SELECT osm_id, a, b, a FROM cov_ref UNION SELECT osm_id, a, b, b FROM cov_ref),
    stretch AS (SELECT osm_id, f AS a, lead(f) OVER (PARTITION BY osm_id, ra, rb ORDER BY f) AS b FROM cut),
    t AS (
        SELECT s.osm_id, s.a, s.b, w.len AS way_m, w.name, w.highway, w.surface, w.tunnel, w.reach,
               ST_LineSubstring(w.geom, s.a, s.b) AS geom,
               EXISTS (SELECT FROM cov_node n JOIN cov_degree d USING (node)
                       WHERE n.osm_id = s.osm_id AND n.f BETWEEN s.a - 1e-9 AND s.a + 1e-9 AND n.way_end AND d.n = 1) AS dead_a,
               EXISTS (SELECT FROM cov_node n JOIN cov_degree d USING (node)
                       WHERE n.osm_id = s.osm_id AND n.f BETWEEN s.b - 1e-9 AND s.b + 1e-9 AND n.way_end AND d.n = 1) AS dead_b
        FROM stretch s JOIN cov_voie w ON w.osm_id = s.osm_id
        WHERE s.b IS NOT NULL AND s.b > s.a)
    INSERT INTO couverture.troncon (id, osm_id, a, b, way_m, length_m, name, highway, surface, tunnel, impasse, reach_m, geom)
    SELECT row_number() OVER (ORDER BY osm_id, a), osm_id, a, b, way_m, ST_Length(geom), name, highway, surface, tunnel,
           CASE WHEN dead_b AND NOT dead_a THEN 1 WHEN dead_a AND NOT dead_b THEN -1 ELSE 0 END, reach, geom
    FROM t WHERE GeometryType(geom) = 'LINESTRING' AND ST_Length(geom) >= 0.5"""
ZONES_SQL = f"""
    UPDATE couverture.troncon t SET zone = (
        SELECT z.code FROM osm.lieu z WHERE {ZONE.format(t='z')} AND ST_Intersects(z.geom, ST_LineInterpolatePoint(t.geom, 0.5))
        LIMIT 1)"""
MEMBERS_SQL = """
    INSERT INTO couverture.membre (osm_id, a, b, ref_osm_id, ref_a, ref_b, role, reach_m, geom)
    SELECT m.osm_id, m.a, m.b, m.ref_osm_id, least(l.ra, l.rb), greatest(l.ra, l.rb), m.role, w.reach, s.g
    FROM cov_member m JOIN cov_voie w ON w.osm_id = m.osm_id JOIN cov_voie r ON r.osm_id = m.ref_osm_id
    CROSS JOIN LATERAL (SELECT ST_LineSubstring(w.geom, m.a, m.b) AS g) s
    CROSS JOIN LATERAL (SELECT ST_LineLocatePoint(r.geom, ST_StartPoint(s.g)) AS ra,
                               ST_LineLocatePoint(r.geom, ST_EndPoint(s.g)) AS rb) l
    WHERE GeometryType(s.g) = 'LINESTRING'"""
# The state of osm.lieu the tronçons are cut from: any OpenStreetMap run that changed something changes it.
OSM_STATE_SQL = "SELECT count(*) || ':' || coalesce(max(loaded_at)::text, '') FROM osm.lieu WHERE kind = 'voie'"
# The points of a ride's track along tronçons (within their reach, or a merged way's), each placed along the
# tronçon's way (0 to 1): when several tronçons of one way reach a point, the nearest.
HITS_SQL = f"""
    WITH pts AS (
        SELECT d.path[1] AS i, ST_M(d.geom) AS t, ST_Transform(ST_Force2D(d.geom), 2154) AS g
        FROM activity a, ST_DumpPoints(a.track) d WHERE a.id = %(id)s),
    hits AS (
        SELECT p.i, p.t, t.osm_id, t.a + ST_LineLocatePoint(t.geom, p.g) * (t.b - t.a) AS f, ST_Distance(t.geom, p.g) AS d
        FROM pts p JOIN couverture.troncon t ON ST_DWithin(t.geom, p.g, {MAX_HALF_WIDTH_M + GPS_M})
        WHERE ST_Distance(t.geom, p.g) <= t.reach_m
        UNION ALL
        SELECT p.i, p.t, t.osm_id, t.a + ST_LineLocatePoint(t.geom, p.g) * (t.b - t.a), ST_Distance(m.geom, p.g)
        FROM pts p JOIN couverture.membre m ON ST_DWithin(m.geom, p.g, {MAX_HALF_WIDTH_M + GPS_M})
        -- ST_Distance, not <->: the few tronçons of that way, never a walk through the spatial index of all of them.
        CROSS JOIN LATERAL (SELECT * FROM couverture.troncon t WHERE t.osm_id = m.ref_osm_id
                            ORDER BY ST_Distance(t.geom, p.g), t.id LIMIT 1) t
        WHERE ST_Distance(m.geom, p.g) <= m.reach_m)
    SELECT DISTINCT ON (osm_id, i) osm_id, i, t, f FROM hits ORDER BY osm_id, i, d, f"""


# 1. Tronçons


def merge(cls: str, pieces: list[tuple]) -> tuple[list[tuple], list[tuple]]:
    """What becomes of one way, from its pieces in order (length, along, twin, beside): its parts merged into another
    way (a, b, ref, role) and its parts left as streets of their own (a, b), a and b from 0 to 1 along the way."""
    total = sum(p[0] for p in pieces)
    if total <= 0:
        return [], [(0.0, 1.0)]
    bounds, run = [], 0.0
    for p in pieces:
        bounds.append((run / total, (run + p[0]) / total))
        run += p[0]
    bounds[-1] = (bounds[-1][0], 1.0)

    def share(column: int) -> float:
        return sum(p[0] for p in pieces if p[column] is not None) / total

    def parts(refs: list, role: str, lo: int = 0, hi: int | None = None) -> list[tuple]:
        """Pieces lo to hi merged, each into its own street (or its neighbours' when it has none), as parts."""
        hi = len(pieces) if hi is None else hi
        filled = refs[lo:hi]
        known = next((r for r in filled if r is not None), None)
        for i, r in enumerate(filled):
            known = r if r is not None else known
            filled[i] = known
        out = []
        for i, r in enumerate(filled):
            a, b = bounds[lo + i]
            if out and out[-1][2] == r:
                out[-1] = (out[-1][0], b, r, role)
            else:
                out.append((a, b, r, role))
        return out

    if cls == "side":
        along = [p[1] for p in pieces]
        if share(1) >= SIDE_SHARE:
            return parts(along, "piste"), []
        merged, own, i = [], [], 0
        while i < len(pieces):
            j = i
            while j < len(pieces) and (along[j] is not None) == (along[i] is not None):
                j += 1
            if along[i] is not None and bounds[j - 1][1] * total - bounds[i][0] * total >= ALONG_MIN_M:
                merged += parts(along, "piste", i, j)
            elif own and abs(own[-1][1] - bounds[i][0]) < 1e-12:
                own[-1] = (own[-1][0], bounds[j - 1][1])
            else:
                own.append((bounds[i][0], bounds[j - 1][1]))
            i = j
        return merged, own
    if share(2) >= TWIN_SHARE:
        return parts([p[2] for p in pieces], "chaussee"), []
    if share(3) >= TWIN_SHARE:
        return parts([p[3] for p in pieces], "contre_allee"), []
    return [], [(0.0, 1.0)]


def build(conn) -> int:
    """Cuts the tronçons again from osm.lieu (in the caller's transaction); returns how many."""
    with conn.cursor() as cur:
        cur.execute(VOIE_SQL)
        cur.execute("CREATE INDEX ON cov_voie USING gist (geom); CREATE INDEX ON cov_voie (osm_id); ANALYZE cov_voie")
        cur.execute("DROP FUNCTION IF EXISTS pg_temp.cov_direction(geometry, geometry)")
        cur.execute(DIRECTION_SQL)
        cur.execute("CREATE TEMP TABLE cov_member (osm_id bigint, a float8, b float8, ref_osm_id bigint, role text) ON COMMIT DROP")
        cur.execute("CREATE TEMP TABLE cov_ref (osm_id bigint, a float8, b float8) ON COMMIT DROP")
        cur.execute(f"INSERT INTO cov_ref SELECT osm_id, 0, 1 FROM cov_voie WHERE NOT {MAY_MERGE}")
        members, refs = [], []
        current, cls, pieces = None, None, []
        with conn.cursor(name="cov_pieces") as rows:  # read as it comes: some 600,000 pieces
            rows.execute(PIECES_SQL)
            for osm_id, kind, length, along, twin, beside in chain(rows, [(None,) * 6]):
                if osm_id != current:
                    if current is not None:
                        merged, own = merge(cls, pieces)
                        members += [(current, a, b, ref, role) for a, b, ref, role in merged]
                        refs += [(current, a, b) for a, b in own]
                    current, cls, pieces = osm_id, kind, []
                pieces.append((length, along, twin, beside))
        with cur.copy("COPY cov_member FROM STDIN") as copy:
            for r in members:
                copy.write_row(r)
        with cur.copy("COPY cov_ref FROM STDIN") as copy:
            for r in refs:
                copy.write_row(r)
        for _ in range(2):
            cur.execute(FOLLOW_SQL)
        cur.execute(ORPHANS_SQL)
        cur.execute(NODES_SQL)
        cur.execute("DELETE FROM couverture.troncon")
        cur.execute("DELETE FROM couverture.membre")
        cur.execute(TRONCONS_SQL)
        count = cur.rowcount
        cur.execute(ZONES_SQL)
        cur.execute(MEMBERS_SQL)
        # Statistics of what this transaction wrote, or the planner measures the rides against tables it thinks empty.
        cur.execute("ANALYZE couverture.troncon; ANALYZE couverture.membre")
        cur.execute(OSM_STATE_SQL)
        state = cur.fetchone()[0]
        cur.execute("""INSERT INTO couverture.build (osm_state, troncons) VALUES (%s, %s)
                       ON CONFLICT (one) DO UPDATE SET osm_state = EXCLUDED.osm_state, built_at = now(),
                                                       troncons = EXCLUDED.troncons""", (state, count))
    return count


# 2. Passages


@dataclass
class Troncon:
    id: int
    start: float        # metres along its way
    end: float
    impasse: int


def needed(length: float, impasse: int) -> tuple[float, float]:
    """The stretch of a tronçon a passage must ride, in metres from its start: all of it, or for an impasse all but
    the last IMPASSE_END_M before its dead end."""
    if impasse == 0:
        return 0.0, length
    need = max(length - IMPASSE_END_M, min(length, IMPASSE_MIN_M))
    return (0.0, need) if impasse == 1 else (length - need, length)


def overlap(lo: float, hi: float, a: float, b: float) -> float:
    return max(0.0, min(hi, b) - max(lo, a))


def runs(points: list[tuple], tunnel: bool = False, elsewhere: frozenset = frozenset()) -> list[list[tuple]]:
    """The runs of a ride along one way, from its points along it in order (index, time, metres along the way). In a
    tunnel, a gap is no cut when the points missing were lost (none of them along a way in the open air, `elsewhere`)
    and crossing it took a plausible time."""
    out: list[list[tuple]] = []
    current: list[tuple] = []
    heading, far = 0, 0  # +1 or -1 once the run moved TURN_M along the way, and its farthest point that way

    def farthest() -> int:
        return max(range(len(current)), key=lambda k: current[k][2] * heading)

    for p in points:
        if current:
            last = current[-1]
            cut = p[0] - last[0] > SKIP_POINTS
            if cut and tunnel and not any(i in elsewhere for i in range(last[0] + 1, p[0])):
                gap = p[1] - last[1]
                cut = not (0 < gap <= TUNNEL_GAP_S and abs(p[2] - last[2]) / gap <= TUNNEL_SPEED_MS)
            if cut:
                out.append(current)
                current, heading = [], 0
        if current and heading == 0 and abs(p[2] - current[0][2]) > TURN_M:
            heading = 1 if p[2] > current[0][2] else -1
            far = farthest()
        if current and heading != 0 and (current[far][2] - p[2]) * heading > TURN_M:
            # turned back: the run ends at its farthest point, the next one starts there
            out.append(current[:far + 1])
            current, heading = current[far:], -heading
            far = farthest()
        current.append(p)
        if heading != 0 and (p[2] - current[far][2]) * heading > 0:
            far = len(current) - 1
    if current:
        out.append(current)
    return out


def passages(run: list[tuple], troncons: list[Troncon]) -> list[tuple]:
    """A run's passages along the tronçons of its way: (tronçon, from, to, entered, left, complete), from and to in
    metres from the tronçon's start, times in Unix seconds. Into an impasse and back is one passage: the way in."""
    lo, hi = min(p[2] for p in run), max(p[2] for p in run)
    heading = 1 if run[-1][2] > run[0][2] else -1
    out = []
    for t in troncons:
        if t.end <= lo or t.start >= hi:
            continue
        length = t.end - t.start
        a, b = max(lo, t.start) - t.start, min(hi, t.end) - t.start
        n_lo, n_hi = needed(length, t.impasse)
        if b - a < min(RUN_MIN_M, DONE_SHARE * (n_hi - n_lo)):
            continue
        inside = [p[1] for p in run if t.start <= p[2] <= t.end]
        if not inside:
            inside = [min(run, key=lambda p: abs(p[2] - (t.start + t.end) / 2))[1]]
        complete = (overlap(a, b, n_lo, n_hi) >= DONE_SHARE * (n_hi - n_lo)
                    and t.impasse in (0, heading))
        out.append((t.id, a, b, min(inside), max(inside), complete))
    return out


def measure(conn, activity_id: int) -> set[int]:
    """Measures one ride's passages again; returns the tronçons it went along."""
    with conn.cursor() as cur:
        cur.execute(HITS_SQL, {"id": activity_id})
        by_way: dict[int, list[tuple]] = {}
        for osm_id, i, t, f in cur.fetchall():
            by_way.setdefault(osm_id, []).append((i, t, f))
        rows, touched = [], set()
        if by_way:
            cur.execute("""SELECT osm_id, id, a * way_m, b * way_m, impasse, tunnel, way_m FROM couverture.troncon
                           WHERE osm_id = ANY(%s) ORDER BY osm_id, a""", (list(by_way),))
            troncons: dict[int, list[Troncon]] = {}
            ways: dict[int, tuple[float, bool]] = {}
            for osm_id, tid, start, end, impasse, tunnel, way_m in cur.fetchall():
                troncons.setdefault(osm_id, []).append(Troncon(tid, start, end, impasse))
                ways[osm_id] = (way_m, tunnel)
            # A point along a way in the open air is there, not in a tunnel beneath it (but at its mouths)
            open_air = frozenset(h[0] for osm_id, hits in by_way.items() if not ways.get(osm_id, (0, True))[1]
                                 for h in hits)
            for osm_id, hits in by_way.items():
                if osm_id not in ways:
                    continue
                way_m, tunnel = ways[osm_id]
                points = [(i, t, f * way_m) for i, t, f in hits]
                if tunnel:
                    points = [p for p in points if p[0] not in open_air or min(p[2], way_m - p[2]) <= TUNNEL_MOUTH_M]
                for n, run in enumerate(runs(points, tunnel, open_air), 1):
                    for tid, a, b, entered, left, complete in passages(run, troncons[osm_id]):
                        rows.append((tid, activity_id, n, a, b, datetime.fromtimestamp(entered, timezone.utc),
                                     datetime.fromtimestamp(left, timezone.utc), complete))
                        touched.add(tid)
        cur.execute("DELETE FROM couverture.passage WHERE activity_id = %s", (activity_id,))
        with cur.copy("COPY couverture.passage (troncon_id, activity_id, run, from_m, to_m, entered_at, left_at, complete) "
                      "FROM STDIN") as copy:
            for r in rows:
                copy.write_row(r)
        cur.execute("""INSERT INTO couverture.sortie (activity_id, updated_at, passages)
                       SELECT id, updated_at, %s FROM activity WHERE id = %s
                       ON CONFLICT (activity_id) DO UPDATE SET updated_at = EXCLUDED.updated_at, measured_at = now(),
                                                               passages = EXCLUDED.passages""",
                    (len(rows), activity_id))
    return touched


# 3. State


def state(length: float, impasse: int, passages_in_time_order: list[tuple]) -> tuple:
    """A tronçon's state from its passages in the order they happened (activity, from, to, entered, left, complete):
    (metres ridden, done, complete passages, rides, first passage, done at, done by, last passage)."""
    n_lo, n_hi = needed(length, impasse)
    union: list[list[float]] = []
    done_at = done_by = None
    for activity_id, a, b, entered, left, complete in passages_in_time_order:
        merged = [a, b]
        rest = []
        for u in union:
            if u[1] < merged[0] or u[0] > merged[1]:
                rest.append(u)
            else:
                merged = [min(u[0], merged[0]), max(u[1], merged[1])]
        union = sorted(rest + [merged])
        if done_at is None and sum(overlap(u[0], u[1], n_lo, n_hi) for u in union) >= DONE_SHARE * (n_hi - n_lo):
            done_at, done_by = left, activity_id
    complete = [p for p in passages_in_time_order if p[5]]
    return (sum(u[1] - u[0] for u in union), done_at is not None, len(complete), len({p[0] for p in complete}),
            min(p[3] for p in passages_in_time_order), done_at, done_by, max(p[4] for p in passages_in_time_order))


def aggregate(conn, troncon_ids: set[int] | None = None) -> None:
    """Computes the state of these tronçons again (all of them by default) from their passages."""
    with conn.cursor() as cur:
        where = "" if troncon_ids is None else "WHERE p.troncon_id = ANY(%(ids)s)"
        rows, current, info, group = [], None, None, []
        with conn.cursor(name="cov_passages") as passages_read:
            passages_read.execute(f"""
                SELECT p.troncon_id, t.length_m, t.impasse, p.activity_id, p.from_m, p.to_m, p.entered_at, p.left_at,
                       p.complete
                FROM couverture.passage p JOIN couverture.troncon t ON t.id = p.troncon_id {where}
                ORDER BY p.troncon_id, p.entered_at, p.activity_id""", {"ids": list(troncon_ids or [])})
            for tid, length, impasse, *p in chain(passages_read, [(None, None, None)]):
                if tid != current:
                    if current is not None:
                        rows.append((current, *state(*info, group)))
                    current, info, group = tid, (length, impasse), []
                if tid is not None:
                    group.append(tuple(p))
        if troncon_ids is None:
            cur.execute("DELETE FROM couverture.troncon_etat")
        else:
            cur.execute("DELETE FROM couverture.troncon_etat WHERE troncon_id = ANY(%s)", (list(troncon_ids),))
        with cur.copy("COPY couverture.troncon_etat (troncon_id, ridden_m, done, passages, rides, first_at, done_at, "
                      "done_activity, last_at) FROM STDIN") as copy:
            for r in rows:
                copy.write_row(r)


def update(conn, full: bool = False) -> dict:
    """Brings the coverage up to date, in one transaction (readers see the previous coverage until it commits):
    everything again when asked or when osm.lieu changed since the tronçons were cut, otherwise only the rides added,
    changed or deleted since. Returns what it did."""
    started = time.monotonic()
    with conn.cursor() as cur:
        # The rides' query looks costly enough to be compiled with LLVM each time: some 0.25 s per ride, for nothing.
        cur.execute("SET LOCAL jit = off")
        cur.execute(OSM_STATE_SQL)
        osm_state = cur.fetchone()[0]
        cur.execute("SELECT osm_state FROM couverture.build")
        built = cur.fetchone()
        done = {"full": full or built is None or built[0] != osm_state}
        if done["full"]:
            done["troncons"] = build(conn)
            cur.execute("DELETE FROM couverture.passage")
            cur.execute("DELETE FROM couverture.sortie")
            cur.execute(f"SELECT a.id FROM activity a WHERE {RIDE} ORDER BY a.id")
            todo, gone = [r[0] for r in cur.fetchall()], []
        else:
            cur.execute(f"""SELECT a.id FROM activity a LEFT JOIN couverture.sortie s ON s.activity_id = a.id
                            WHERE {RIDE} AND (s.activity_id IS NULL OR s.updated_at <> a.updated_at) ORDER BY a.id""")
            todo = [r[0] for r in cur.fetchall()]
            cur.execute(f"""SELECT s.activity_id FROM couverture.sortie s LEFT JOIN activity a ON a.id = s.activity_id
                            WHERE a.id IS NULL OR NOT ({RIDE})""")
            gone = [r[0] for r in cur.fetchall()]
        cur.execute("SELECT DISTINCT troncon_id FROM couverture.passage WHERE activity_id = ANY(%s)", (todo + gone,))
        touched = {r[0] for r in cur.fetchall()}
        cur.execute("DELETE FROM couverture.passage WHERE activity_id = ANY(%s)", (gone,))
        cur.execute("DELETE FROM couverture.sortie WHERE activity_id = ANY(%s)", (gone,))
        for activity_id in todo:
            touched |= measure(conn, activity_id)
        aggregate(conn, None if done["full"] else touched)
        cur.execute("SELECT count(*) FROM couverture.passage")
        done.update(rides=len(todo), removed=len(gone), troncons_touched=len(touched), passages=cur.fetchone()[0],
                    seconds=round(time.monotonic() - started, 1))
    return done


def main(argv=None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if args not in ([], ["full"]):
        print(__doc__, file=sys.stderr)
        return 2
    with connect() as conn:
        if not conn.execute("SELECT pg_try_advisory_xact_lock(%s)", (LOCK,)).fetchone()[0]:
            print("another coverage run is going: skipped")
            return 0
        done = update(conn, args == ["full"])
        conn.commit()
    print(json.dumps(done))
    return 0


if __name__ == "__main__":
    sys.exit(main())
