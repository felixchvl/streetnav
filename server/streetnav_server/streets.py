"""Streets ridden and not ridden yet, the layer the app colours: OpenStreetMap's bike-usable streets around Paris, each
cut into the parts a bike ride went along and the parts never ridden.

A point of a street counts as ridden when a ride's track passes within REACH_M of it. Points are sampled every STEP_M
along each street; consecutive points with the same answer make a part. A ridden part shorter than MIN_RIDDEN_SAMPLES
points is only a ride crossing the street, unless it is the whole street.

A bike path running alongside a street (within SIDE_M of a street all along) belongs to that street, as the map shows
it: it is neither drawn nor counted, and riding it rides the street (9,371 of the 9,838 bike paths on 2026-11-01).

  python -m streetnav_server.streets fetch [--bbox S,W,N,E]   download the streets from Overpass and load them
  python -m streetnav_server.streets load FILE.tsv            load streets (osm id, name, highway, EWKT)
  python -m streetnav_server.streets compute                  every street, from every ride (about a minute)
  python -m streetnav_server.streets refresh                  only around the rides added or changed since the last run
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
import time
import urllib.parse
import urllib.request

from .registry import connect

REACH_M = 12
STEP_M = 10
MIN_RIDDEN_SAMPLES = 5
SIDE_M = 20
# Paris and the inner suburbs: 96 % of the rides' distance on 2026-11-01.
DEFAULT_BBOX = (48.75, 2.15, 48.95, 2.55)
HIGHWAYS = ("primary|primary_link|secondary|secondary_link|tertiary|tertiary_link|unclassified|residential|"
            "living_street|pedestrian|cycleway")

# Bike paths whose start, quarter points, middle and end are all within SIDE_M of a street; alongside is the street
# near most of these points (then the nearest to the middle), not one crossing it.
SIDEPATHS_SQL = f"""
    UPDATE street c SET alongside = (
        SELECT r.id FROM street r, unnest(ARRAY[0, 0.25, 0.5, 0.75, 1]::float8[]) f
        WHERE r.highway <> 'cycleway' AND ST_DWithin(r.geom, ST_LineInterpolatePoint(c.geom, f), {SIDE_M})
        GROUP BY r.id ORDER BY count(*) DESC, min(ST_Distance(r.geom, ST_LineInterpolatePoint(c.geom, 0.5))) LIMIT 1)
    WHERE c.highway = 'cycleway' AND NOT EXISTS (
        SELECT 1 FROM unnest(ARRAY[0, 0.25, 0.5, 0.75, 1]::float8[]) f
        WHERE NOT EXISTS (SELECT 1 FROM street r WHERE r.highway <> 'cycleway'
                          AND ST_DWithin(r.geom, ST_LineInterpolatePoint(c.geom, f), {SIDE_M})))"""

PIECES_SQL = """
    INSERT INTO ride_piece (activity_id, geom)
    SELECT id, (ST_Dump(ST_Subdivide(ST_Simplify(ST_Transform(ST_Force2D(track), 2154), 2), 16))).geom
    FROM activity WHERE sport = 'cycling' AND track IS NOT NULL AND {where}"""

# Samples every STEP_M metres (ridden: a ride within reach, or along a bike path beside the sample: at the path's point
# q nearest to the sample, the sample being the street's point nearest to q, which a street crossing the path is not),
# gaps-and-islands into runs, short ridden runs (a ride crossing) turned back to not
# ridden, then neighbouring runs with the same answer merged again. Bike paths alongside a street get no parts.
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
        WHERE s.alongside IS NULL AND {{where}}),
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


def load(rows, conn) -> int:
    """Upserts streets from rows of (osm id, name, highway, EWKT in WGS84)."""
    with conn.cursor() as cur:
        cur.execute("CREATE TEMP TABLE osm_in (id bigint, name text, highway text, ewkt text) ON COMMIT DROP")
        with cur.copy("COPY osm_in FROM STDIN") as copy:
            for row in rows:
                copy.write_row(row)
        cur.execute(
            """INSERT INTO street (id, name, highway, geom, length_m)
               SELECT id, nullif(name, ''), highway, g, ST_Length(g)
               FROM (SELECT id, name, highway, ST_Transform(ST_GeomFromEWKT(ewkt), 2154) g FROM osm_in) t
               ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, highway = EXCLUDED.highway,
                                              geom = EXCLUDED.geom, length_m = EXCLUDED.length_m""")
        return cur.rowcount


def fetch(bbox=DEFAULT_BBOX) -> list[tuple]:
    """Bike-usable OpenStreetMap ways in the box (south, west, north, east), from the Overpass API."""
    query = (f'[out:json][timeout:300];way["highway"~"^({HIGHWAYS})$"]["area"!="yes"]["access"!~"^(private|no)$"]'
             f'["bicycle"!="no"]({",".join(map(str, bbox))});out geom tags qt;')
    request = urllib.request.Request("https://overpass-api.de/api/interpreter",
                                     data=urllib.parse.urlencode({"data": query}).encode(),
                                     headers={"User-Agent": "streetnav/1 (personal project)", "Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=600) as response:
        elements = json.load(response)["elements"]
    return [(w["id"], (w["tags"].get("name") or ""), w["tags"]["highway"],
             "SRID=4326;LINESTRING(" + ",".join(f'{p["lon"]:.7f} {p["lat"]:.7f}' for p in w["geometry"]) + ")")
            for w in elements if w["type"] == "way" and len(w.get("geometry", [])) >= 2]


def compute(conn) -> None:
    """Every street from every ride."""
    with conn.cursor() as cur:
        cur.execute("TRUNCATE ride_piece, street_part")
        cur.execute("UPDATE street SET alongside = NULL WHERE alongside IS NOT NULL")
        cur.execute(SIDEPATHS_SQL)
        cur.execute(PIECES_SQL.format(where="true"))
        cur.execute("ANALYZE ride_piece")
        cur.execute(PARTS_SQL.format(where="true"))


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
        cur.execute("""CREATE TEMP TABLE touched ON COMMIT DROP AS
                       SELECT DISTINCT s.id FROM street s JOIN ride_piece r
                         ON r.activity_id = ANY(%s) AND ST_DWithin(s.geom, r.geom, %s)
                       WHERE s.alongside IS NULL""", (changed, REACH_M + SIDE_M))
        cur.execute("DELETE FROM street_part WHERE street_id IN (SELECT id FROM touched)")
        cur.execute(PARTS_SQL.format(where="s.id IN (SELECT id FROM touched)"))
        return len(changed)


def record(conn, started: float) -> dict:
    with conn.cursor() as cur:
        cur.execute("""SELECT (SELECT count(*) FROM street WHERE alongside IS NULL), coalesce(sum(length_m), 0) / 1000,
                              coalesce(sum(length_m) FILTER (WHERE ridden), 0) / 1000 FROM street_part""")
        streets, total, ridden = cur.fetchone()
        seconds = time.monotonic() - started
        cur.execute("INSERT INTO street_run VALUES (now(), %s, %s, %s, %s)", (streets, total, ridden, seconds))
    return {"streets": streets, "total_km": round(total), "ridden_km": round(ridden), "seconds": round(seconds, 1)}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    fetch_cmd = sub.add_parser("fetch")
    fetch_cmd.add_argument("--bbox", default=",".join(map(str, DEFAULT_BBOX)), help="south,west,north,east")
    sub.add_parser("load").add_argument("file")
    sub.add_parser("compute")
    sub.add_parser("refresh")
    args = parser.parse_args(argv)

    started = time.monotonic()
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
            print(f"{load(rows, conn)} streets loaded")
            compute(conn)
        elif args.command == "compute":
            compute(conn)
        elif refresh(conn) == 0:
            return 0
        print(json.dumps(record(conn, started)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
