"""The arrondissements of Paris and the communes of the inner suburbs, to follow the streets ridden zone by zone: each
arrondissement, Paris, the ring of communes along its edge, the ring after, and so on to the far end of the 92, 93
and 94.

Their outlines are the State's (API Géo, geo.api.gouv.fr, from IGN's Admin Express). Paris is ring 0; a commune is in
ring n when it shares a border with one of ring n - 1: the two overlap over at least TOUCH_M2 once the other is widened
by WIDEN_M, which leaves out communes that only meet at a corner. Each part of a street belongs to the zone its middle
lies in (streets.py places them after cutting them).

  python -m streetnav_server.zones fetch     download the zones, number the rings and place every part
"""
from __future__ import annotations

import json
import sys
import urllib.request

from .registry import connect

API = "https://geo.api.gouv.fr"
DEPARTMENTS = ("92", "93", "94")
WIDEN_M = 25
TOUCH_M2 = 2500

ASSIGN_SQL = """
    UPDATE street_part p SET zone = (
        SELECT z.code FROM zone z WHERE ST_Intersects(z.geom, ST_LineInterpolatePoint(p.geom, 0.5)) LIMIT 1)
    WHERE {where}"""

NEXT_RING_SQL = """
    UPDATE zone z SET ring = %(ring)s
    WHERE z.ring IS NULL AND EXISTS (
        SELECT FROM zone o WHERE o.ring = %(ring)s - 1 AND ST_DWithin(o.geom, z.geom, %(widen)s)
          AND ST_Area(ST_Intersection(ST_Buffer(o.geom, %(widen)s), z.geom)) >= %(touch)s)"""


def download() -> list[tuple[str, str, str, str]]:
    """Code, name, department and GeoJSON outline of every zone."""
    urls = [f"{API}/communes?type=arrondissement-municipal&codeDepartement=75&format=geojson&geometry=contour"
            "&fields=nom,code"]
    urls += [f"{API}/departements/{d}/communes?format=geojson&geometry=contour&fields=nom,code" for d in DEPARTMENTS]
    rows = []
    for url in urls:
        with urllib.request.urlopen(url, timeout=60) as response:
            for feature in json.load(response)["features"]:
                code = feature["properties"]["code"]
                rows.append((code, feature["properties"]["nom"], code[:2], json.dumps(feature["geometry"])))
    if sum(1 for r in rows if r[2] == "75") != 20 or len(rows) < 120:
        raise SystemExit(f"only {len(rows)} zones from API Géo: nothing changed")
    return rows


def load(rows, conn) -> dict:
    """Replaces the zones, numbers their rings and places every part; returns how many zones each ring has."""
    with conn.cursor() as cur:
        cur.execute("TRUNCATE zone")
        cur.executemany("""INSERT INTO zone (code, name, department, geom)
                           VALUES (%s, %s, %s, ST_Multi(ST_Transform(ST_SetSRID(ST_GeomFromGeoJSON(%s), 4326), 2154)))""",
                        rows)
        cur.execute("UPDATE zone SET ring = 0 WHERE department = '75'")
        ring = 1
        while True:
            cur.execute(NEXT_RING_SQL, {"ring": ring, "widen": WIDEN_M, "touch": TOUCH_M2})
            if cur.rowcount == 0:
                break
            ring += 1
        assign(cur, "true")
        cur.execute("SELECT coalesce(ring::text, 'none'), count(*) FROM zone GROUP BY ring ORDER BY ring")
        return dict(cur.fetchall())


def assign(cur, where: str) -> None:
    """Places the parts in `where` (on p) in their zone."""
    cur.execute(ASSIGN_SQL.format(where=where))


def main(argv=None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if args != ["fetch"]:
        print(__doc__, file=sys.stderr)
        return 2
    rows = download()
    with connect() as conn:
        # The parts are rewritten by the street runs too.
        conn.execute("SELECT pg_advisory_lock(hashtext('streetnav.streets'))")
        print(json.dumps({"zones": len(rows), "by_ring": load(rows, conn)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
