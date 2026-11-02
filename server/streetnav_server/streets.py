"""Streets ridden and not ridden yet, the layer the app colours: OpenStreetMap's ways around Paris, the bike-usable
ones cut into the parts a bike ride went along and the parts never ridden.

The street table is the one copy of OpenStreetMap for Streetnav and paris-rues (which attaches the named ways of Paris
to the city's register of voies): every street and road of the kinds in HIGHWAYS, named or not, every named way, and
every way marked open to bikes. Whether a bike may ride a way (bike_access) and whether it is a way of its own rather
than part of a street (counted: not a sidewalk, a crossing or an area) are paris-rues's rules:
- open: bicycle=yes, designated, permissive, destination or use_sidepath;
- closed: bicycle=no, dismount or private; access or vehicle closed (no, private, customers...); motor roads,
  motorways; steps, footways, pedestrian streets, bridleways; works;
- open otherwise: streets, service roads, cycleways, tracks, and paths (open to bikes in France).
Only the ways a bike may ride and that count are drawn and measured.

A point of a street counts as ridden when a ride's track passes within REACH_M of it. Points are sampled every STEP_M
along each street; consecutive points with the same answer make a part. A ridden part shorter than MIN_RIDDEN_SAMPLES
points is only a ride crossing the street, unless it is the whole street.

A bike path (or any SIDE_WAYS way) running alongside a street a bike may ride (within SIDE_M of it all along) belongs
to that street, as the map shows it: it is neither drawn nor counted, and riding it rides the street. Beside a street
closed to bikes it stays a way of its own.

A place of Paris (a place, carrefour or rond-point of the Ville's register of voies, which paris-rues keeps in the
paris_rues schema of this database) is one open area: once rides went through it along TRAVERSED_M of its ways, every
part inside it counts as ridden. Parts are cut at the place's edge (a little wider, PLACE_MARGIN_M) so that the
streets leaving it keep their own answer. Without paris-rues there are no places.

  python -m streetnav_server.streets fetch [--bbox S,W,N,E]   download the ways from Overpass, load them, compute
  python -m streetnav_server.streets fetch --out FILE.tsv     only download them, to load on another machine
  python -m streetnav_server.streets load FILE.tsv            load ways (osm id, name, highway, tags as JSON, EWKT)
  python -m streetnav_server.streets compute                  every street, from every ride (about a minute)
  python -m streetnav_server.streets refresh                  only around the rides added or changed since the last run
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from .registry import connect

REACH_M = 12
STEP_M = 10
MIN_RIDDEN_SAMPLES = 5
SIDE_M = 20
# Paris and the inner suburbs: 96 % of the rides' distance on 2026-11-01.
DEFAULT_BBOX = (48.75, 2.15, 48.95, 2.55)
# Downloaded in TILES x TILES boxes: the whole box at once takes 900 MB to read, too much for the container.
TILES = 3
MIN_WAYS = 100_000  # 120,679 on 2026-11-02: fewer is a truncated answer, not half of Paris gone
HIGHWAYS = ("primary|primary_link|secondary|secondary_link|tertiary|tertiary_link|unclassified|residential|"
            "living_street|pedestrian|cycleway")
OPEN = {"yes", "designated", "permissive", "destination", "use_sidepath"}
CLOSED = {"no", "private", "customers", "delivery", "permit", "emergency", "agricultural", "forestry"}
NO_BIKES = {"motorway", "motorway_link", "steps", "footway", "pedestrian", "bridleway", "corridor", "construction"}
NOT_WAYS = {"proposed", "abandoned", "razed", "disused", "platform"}
PARTS_OF_A_STREET = {"sidewalk", "crossing", "traffic_island"}
# Ways that run beside a street rather than being it.
SIDE_WAYS = ("cycleway", "footway", "path", "bridleway", "busway")
SIDE_ARRAY = "'{" + ",".join(SIDE_WAYS) + "}'::text[]"
# A way drawn and measured.
MEASURED = "{t}.bike AND {t}.counted"
PLACE_KINDS = ("place", "placette", "carrefour", "rond-point", "rond")
PLACE_ARRAY = "'{" + ",".join(PLACE_KINDS) + "}'::text[]"
PLACE_MARGIN_M = 3
TRAVERSED_M = 20
# A part shown as ridden: a ride went along it, or it lies in a place that rides went through.
SHOWN_RIDDEN = f"""(ridden OR place IS NOT NULL AND place IN (
                        SELECT place FROM street_part WHERE ridden AND place IS NOT NULL
                        GROUP BY place HAVING sum(length_m) >= {TRAVERSED_M}))"""

# Side ways a bike may ride whose start, quarter points, middle and end are all within SIDE_M of a street a bike may
# ride; alongside is the street near most of these points (then the nearest to the middle), not one crossing it.
STREET_BESIDE = f"{MEASURED.format(t='r')} AND r.highway <> ALL({SIDE_ARRAY})"
SIDEPATHS_SQL = f"""
    UPDATE street c SET alongside = (
        SELECT r.id FROM street r, unnest(ARRAY[0, 0.25, 0.5, 0.75, 1]::float8[]) f
        WHERE {STREET_BESIDE} AND ST_DWithin(r.geom, ST_LineInterpolatePoint(c.geom, f), {SIDE_M})
        GROUP BY r.id ORDER BY count(*) DESC, min(ST_Distance(r.geom, ST_LineInterpolatePoint(c.geom, 0.5))) LIMIT 1)
    WHERE c.highway = ANY({SIDE_ARRAY}) AND {MEASURED.format(t='c')} AND NOT EXISTS (
        SELECT 1 FROM unnest(ARRAY[0, 0.25, 0.5, 0.75, 1]::float8[]) f
        WHERE NOT EXISTS (SELECT 1 FROM street r WHERE {STREET_BESIDE}
                          AND ST_DWithin(r.geom, ST_LineInterpolatePoint(c.geom, f), {SIDE_M})))"""

PIECES_SQL = """
    INSERT INTO ride_piece (activity_id, geom)
    SELECT id, (ST_Dump(ST_Subdivide(ST_Simplify(ST_Transform(ST_Force2D(track), 2154), 2), 16))).geom
    FROM activity WHERE sport = 'cycling' AND track IS NOT NULL AND {where}"""

# Samples every STEP_M metres (ridden: a ride within reach, or along a bike path beside the sample: at the path's point
# q nearest to the sample, the sample being the street's point nearest to q, which a street crossing the path is not),
# gaps-and-islands into runs, short ridden runs (a ride crossing) turned back to not
# ridden, then neighbouring runs with the same answer merged again. Only the ways measured get parts, not the side
# ways alongside a street.
PARTS_SQL = f"""
    INSERT INTO street_part (street_id, ridden, geom, length_m)
    WITH samples AS (
        SELECT s.id, i, k.n,
               EXISTS (SELECT 1 FROM ride_piece r WHERE ST_DWithin(r.geom, p.pt, {REACH_M}))
               OR EXISTS (SELECT 1 FROM street c, LATERAL (SELECT ST_ClosestPoint(c.geom, p.pt) AS q) cq
                          WHERE c.alongside IS NOT NULL AND ST_DWithin(c.geom, p.pt, {SIDE_M})
                            AND ST_DWithin(ST_ClosestPoint(s.geom, cq.q), p.pt, {STEP_M / 2})
                            AND EXISTS (SELECT 1 FROM ride_piece r WHERE ST_DWithin(r.geom, cq.q, {REACH_M}))) AS hit
        FROM street s, LATERAL (SELECT greatest(1, ceil(s.length_m / {STEP_M}))::int AS n) k, generate_series(0, k.n) i,
             LATERAL (SELECT ST_LineInterpolatePoint(s.geom, i::float8 / k.n) AS pt) p
        WHERE {MEASURED.format(t='s')} AND s.alongside IS NULL AND {{where}}),
    runs AS (
        SELECT id, n, hit, min(i) AS a, max(i) AS b
        FROM (SELECT *, i - row_number() OVER (PARTITION BY id, hit ORDER BY i) AS g FROM samples) x
        GROUP BY id, n, hit, g),
    kept AS (
        SELECT id, n, a, b,
               hit AND (b - a + 1 >= {MIN_RIDDEN_SAMPLES} OR (a = 0 AND b = n)) AS ridden
        FROM runs),
    merged AS (
        SELECT id, n, ridden, min(a) AS a, max(b) AS b
        FROM (SELECT *, sum(changed) OVER (PARTITION BY id ORDER BY a) AS g
              FROM (SELECT *, (ridden IS DISTINCT FROM lag(ridden) OVER (PARTITION BY id ORDER BY a))::int AS changed
                    FROM kept) y) z
        GROUP BY id, n, ridden, g)
    SELECT m.id, m.ridden, part, ST_Length(part)
    FROM merged m JOIN street s ON s.id = m.id,
         LATERAL (SELECT ST_LineSubstring(s.geom, greatest(0, (m.a - 0.5) / m.n), least(1, (m.b + 0.5) / m.n)) AS part) p
    WHERE ST_Length(part) > 0"""

# Each place's footprint, a little wider, less the places of a lower id it overlaps (a part lies in one place only).
PLACE_CELLS_SQL = (
    f"""CREATE TEMP TABLE place_cell ON COMMIT DROP AS
        SELECT id, ST_Buffer(footprint, {PLACE_MARGIN_M}) AS geom FROM paris_rues.voie
        WHERE kind = ANY({PLACE_ARRAY}) AND footprint IS NOT NULL""",
    "CREATE INDEX ON place_cell USING gist (geom)",
    "ANALYZE place_cell",
    """UPDATE place_cell c SET geom = ST_Difference(c.geom, o.lower)
       FROM (SELECT c2.id, ST_Union(o2.geom) AS lower FROM place_cell c2
             JOIN place_cell o2 ON o2.id < c2.id AND ST_Intersects(o2.geom, c2.geom) GROUP BY c2.id) o
       WHERE o.id = c.id""")

# The parts across a place's edge cut there: the pieces inside carry the place.
PLACE_PARTS_SQL = """
    WITH cut AS (
        DELETE FROM street_part p WHERE {where} AND EXISTS (SELECT 1 FROM place_cell c WHERE ST_Intersects(p.geom, c.geom))
        RETURNING street_id, ridden, geom)
    INSERT INTO street_part (street_id, ridden, geom, length_m, place)
    SELECT street_id, ridden, d.geom, ST_Length(d.geom), place
    FROM (SELECT k.street_id, k.ridden, c.id AS place, ST_Intersection(k.geom, c.geom) AS g
          FROM cut k JOIN place_cell c ON ST_Intersects(k.geom, c.geom)
          UNION ALL
          SELECT k.street_id, k.ridden, NULL,
                 ST_Difference(k.geom, (SELECT ST_Union(c.geom) FROM place_cell c WHERE ST_Intersects(k.geom, c.geom)))
          FROM cut k) x,
         LATERAL ST_Dump(ST_CollectionExtract(x.g, 2)) d
    WHERE ST_Length(d.geom) > 0"""


def bike_access(tags: dict) -> tuple[bool, str]:
    """May a bike ride this way, and the tag that decided."""
    bicycle = tags.get("bicycle")
    if bicycle in OPEN:
        return True, f"bicycle={bicycle}"
    if bicycle in {"no", "dismount", "private"}:
        return False, f"bicycle={bicycle}"
    for key in ("access", "vehicle"):
        if tags.get(key) in CLOSED:
            return False, f"{key}={tags[key]}"
    if tags.get("motorroad") == "yes":
        return False, "motorroad=yes"
    return tags["highway"] not in NO_BIKES, f"highway={tags['highway']}"


def counted(tags: dict) -> bool:
    """A way of its own, not a sidewalk, a crossing or an area (a square drawn as a polygon)."""
    return tags.get("footway") not in PARTS_OF_A_STREET and tags.get("area") != "yes"


def load(rows, conn) -> int:
    """Replaces every way with rows of (osm id, name, highway, tags as JSON, EWKT in WGS84); parts go with them."""
    with conn.cursor() as cur:
        cur.execute("CREATE TEMP TABLE osm_in (id bigint, name text, highway text, tags jsonb, bike boolean, "
                    "bike_reason text, counted boolean, ewkt text) ON COMMIT DROP")
        with cur.copy("COPY osm_in FROM STDIN") as copy:
            for osm_id, name, highway, tags_json, ewkt in rows:
                tags = json.loads(tags_json)
                copy.write_row((osm_id, name, highway, tags_json, *bike_access(tags), counted(tags), ewkt))
        cur.execute("TRUNCATE street, street_part")
        cur.execute(
            """INSERT INTO street (id, name, highway, tags, bike, bike_reason, counted, geom, length_m)
               SELECT id, nullif(name, ''), highway, tags, bike, bike_reason, counted, g, ST_Length(g)
               FROM (SELECT *, ST_Transform(ST_GeomFromEWKT(ewkt), 2154) g FROM osm_in) t""")
        return cur.rowcount


def overpass(query: str) -> list[dict]:
    """The elements Overpass answers, waiting and asking again while it is busy (429, 502, 503, 504)."""
    request = urllib.request.Request(
        "https://overpass-api.de/api/interpreter", data=urllib.parse.urlencode({"data": query}).encode(),
        headers={"User-Agent": "streetnav/1 (personal project)", "Accept": "application/json"})
    for wait in (30, 60, 120, 240, None):
        try:
            with urllib.request.urlopen(request, timeout=600) as response:
                return json.load(response)["elements"]
        except urllib.error.HTTPError as error:
            if error.code not in (429, 502, 503, 504) or wait is None:
                raise
            time.sleep(wait)


def fetch(bbox=DEFAULT_BBOX) -> list[tuple]:
    """The ways in the box (south, west, north, east) from the Overpass API, as load takes them, tile by tile (a way
    across two tiles comes once)."""
    south, west, north, east = bbox
    ways = {}
    for i in range(TILES):
        for j in range(TILES):
            box = ",".join(str(round(v, 6)) for v in (south + (north - south) * i / TILES, west + (east - west) * j / TILES,
                                                      south + (north - south) * (i + 1) / TILES,
                                                      west + (east - west) * (j + 1) / TILES))
            query = (f'[out:json][timeout:300];(way["highway"~"^({HIGHWAYS})$"]({box});way["highway"]["name"]({box});'
                     f'way["highway"]["bicycle"~"^({"|".join(sorted(OPEN))})$"]({box}););out geom tags qt;')
            elements = overpass(query)
            for w in elements:
                if w["type"] == "way" and len(w.get("geometry", [])) >= 2 and w["tags"]["highway"] not in NOT_WAYS:
                    ways[w["id"]] = (w["id"], w["tags"].get("name") or "", w["tags"]["highway"],
                                     json.dumps(w["tags"], ensure_ascii=False),
                                     "SRID=4326;LINESTRING(" + ",".join(f'{p["lon"]:.7f} {p["lat"]:.7f}'
                                                                        for p in w["geometry"]) + ")")
            del elements
    if len(ways) < MIN_WAYS:
        raise SystemExit(f"only {len(ways)} ways from Overpass, a truncated answer: nothing changed")
    return list(ways.values())


def compute(conn) -> None:
    """Every street from every ride."""
    with conn.cursor() as cur:
        cur.execute("TRUNCATE ride_piece, street_part")
        cur.execute("UPDATE street SET alongside = NULL WHERE alongside IS NOT NULL")
        cur.execute(SIDEPATHS_SQL)
        cur.execute(PIECES_SQL.format(where="true"))
        cur.execute("ANALYZE ride_piece")
        cur.execute(PARTS_SQL.format(where="true"))
        places(cur, "true")


def places(cur, where: str) -> None:
    """Cuts the parts of the streets in `where` (on p.street_id) at the places' edges, when paris-rues's register of
    voies is there to read."""
    cur.execute("""SELECT has_schema_privilege(n.oid, 'USAGE') AND has_table_privilege(c.oid, 'SELECT')
                   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                   WHERE n.nspname = 'paris_rues' AND c.relname = 'voie'""")
    readable = cur.fetchone()
    if not (readable and readable[0]):
        return
    for sql in PLACE_CELLS_SQL:
        cur.execute(sql)
    cur.execute(PLACE_PARTS_SQL.format(where=where))
    cur.execute("DROP TABLE place_cell")


def refresh(conn) -> int:
    """Only the streets near the rides added or changed since the last run; returns how many rides that was."""
    with conn.cursor() as cur:
        cur.execute("SELECT max(finished_at) FROM street_run")
        since = cur.fetchone()[0]
        if since is None:
            compute(conn)
            return -1
        cur.execute("""SELECT id FROM activity
                       WHERE sport = 'cycling' AND track IS NOT NULL AND updated_at > %s""", (since,))
        changed = [r[0] for r in cur.fetchall()]
        if not changed:
            return 0
        cur.execute("DELETE FROM ride_piece WHERE activity_id = ANY(%s)", (changed,))
        cur.execute(PIECES_SQL.format(where="id = ANY(%(ids)s)"), {"ids": changed})
        # Streets within reach, and those whose bike path is.
        cur.execute(f"""CREATE TEMP TABLE touched ON COMMIT DROP AS
                        SELECT DISTINCT s.id FROM street s JOIN ride_piece r
                          ON r.activity_id = ANY(%s) AND ST_DWithin(s.geom, r.geom, %s)
                        WHERE {MEASURED.format(t='s')} AND s.alongside IS NULL""", (changed, REACH_M + SIDE_M))
        cur.execute("DELETE FROM street_part WHERE street_id IN (SELECT id FROM touched)")
        cur.execute(PARTS_SQL.format(where="s.id IN (SELECT id FROM touched)"))
        places(cur, "p.street_id IN (SELECT id FROM touched)")
        return len(changed)


def record(conn, started: float) -> dict:
    with conn.cursor() as cur:
        cur.execute(f"""SELECT (SELECT count(*) FROM street s WHERE {MEASURED.format(t='s')} AND s.alongside IS NULL),
                               coalesce(sum(length_m), 0) / 1000,
                               coalesce(sum(length_m) FILTER (WHERE {SHOWN_RIDDEN}), 0) / 1000 FROM street_part""")
        streets, total, ridden = cur.fetchone()
        seconds = time.monotonic() - started
        cur.execute("INSERT INTO street_run VALUES (now(), %s, %s, %s, %s)", (streets, total, ridden, seconds))
    return {"streets": streets, "total_km": round(total), "ridden_km": round(ridden), "seconds": round(seconds, 1)}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    fetch_cmd = sub.add_parser("fetch")
    fetch_cmd.add_argument("--bbox", default=",".join(map(str, DEFAULT_BBOX)), help="south,west,north,east")
    fetch_cmd.add_argument("--out", help="write the ways to this TSV file instead of loading them")
    sub.add_parser("load").add_argument("file")
    sub.add_parser("compute")
    sub.add_parser("refresh")
    args = parser.parse_args(argv)

    started = time.monotonic()
    if args.command == "fetch" and args.out:
        with open(args.out, "w", newline="", encoding="utf-8") as f:
            csv.writer(f, delimiter="\t", quoting=csv.QUOTE_NONE, escapechar="\\").writerows(
                fetch(tuple(float(v) for v in args.bbox.split(","))))
        return 0
    with connect() as conn:
        # One run at a time (the timer and a manual run).
        if not conn.execute("SELECT pg_try_advisory_lock(hashtext('streetnav.streets'))").fetchone()[0]:
            print("another street run is in progress", file=sys.stderr)
            return 0
        if args.command in ("fetch", "load"):
            if args.command == "fetch":
                rows = fetch(tuple(float(v) for v in args.bbox.split(",")))
            else:
                with open(args.file, newline="", encoding="utf-8") as f:
                    rows = list(csv.reader(f, delimiter="\t", quoting=csv.QUOTE_NONE, escapechar="\\"))
            print(f"{load(rows, conn)} ways loaded")
            compute(conn)
        elif args.command == "compute":
            compute(conn)
        elif refresh(conn) == 0:
            return 0
        print(json.dumps(record(conn, started)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
