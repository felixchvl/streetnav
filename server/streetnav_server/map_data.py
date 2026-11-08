"""What the iPhone app draws and sums up: the tracks of every bike ride for the map, and the riding statistics.

GET /tracks: one GeoJSON feature per ride with a track, simplified to about 5 metres (2,273 rides: 2 MB, much less
gzipped), with an ETag so that the app only downloads them again when a ride was added or changed.
GET /streets: the streets ridden and not ridden, for the map's two colours: the tronçons of the coverage (coverage.py)
in the four departments, those of an OSM way in the same state drawn as one line, with the ways merged into them (bike
paths along a street, other carriageways, contre-allées) in their state. Properties: r 1 when ridden all along, k the
road class (for its width), p the complete passages.
GET /stats: totals, this year, this month, the last 30 days, records, kilometres by year, and the kilometres of streets a
bike may ride and of those ridden, overall and in each arrondissement of Paris and commune of the inner suburbs, with
its ring (the tronçons of coverage.py).
GET /zones: the outlines of those zones, simplified to about 25 m, for the app's maps of the streets ridden by zone.
GET /tracks/outside: the parts of the bike rides' tracks outside those zones, where no street is measured, for the map
to show where the rider has been there too.

POST /osm/refresh: brings osm.lieu up to date with OpenStreetMap now (osm.ask), from the button in the app's settings,
so that an edit saved in OSM shows without waiting for Sunday's full run; what the run did, or running: true while it
goes on.
"""
from __future__ import annotations

import hashlib

from fastapi import APIRouter, Depends, Header, Response

from . import osm
from .osm import DEPARTMENTS, ZONE
from .registry import connect

# About 5 metres in Paris (degrees of longitude / latitude): below what a phone screen shows at street level.
SIMPLIFY_DEGREES = 0.00005

# The width classes of Mapbox Standard's roads (its "roads" and "road-path" layers), from OpenStreetMap's highway tag:
# 0 motorway or trunk, 1 primary, 2 secondary or tertiary, 3 street (the rest: residential, unclassified, links of
# motorways…), 4 link of a primary, secondary or tertiary, 5 service, track…, 6 path, footway, cycleway, pedestrian.
ROAD_CLASS = """CASE
    WHEN highway IN ('motorway', 'trunk') THEN 0
    WHEN highway = 'primary' THEN 1
    WHEN highway IN ('secondary', 'tertiary') THEN 2
    WHEN highway IN ('primary_link', 'secondary_link', 'tertiary_link') THEN 4
    WHEN highway IN ('service', 'track') THEN 5
    WHEN highway IN ('path', 'footway', 'cycleway', 'pedestrian', 'steps', 'bridleway') THEN 6
    ELSE 3 END"""
# Bumped whenever the street features change shape, so that the app downloads them again.
STREETS_FORMAT = 4
# A merged way is ridden when the tronçons it lies along all are; its passages, the fewest of theirs.
STREETS_SQL = f"""
    WITH part AS (
        SELECT t.osm_id, t.geom, t.highway, coalesce(e.done, false) AS done, coalesce(e.passages, 0) AS passages
        FROM couverture.troncon t LEFT JOIN couverture.troncon_etat e ON e.troncon_id = t.id
        WHERE t.zone IS NOT NULL
        UNION ALL
        SELECT m.osm_id, m.geom, w.tags->>'highway', bool_and(coalesce(e.done, false)), coalesce(min(e.passages), 0)
        FROM couverture.membre m JOIN osm.lieu w ON w.osm_type = 'w' AND w.osm_id = m.osm_id
        JOIN couverture.troncon t ON t.osm_id = m.ref_osm_id AND t.a < m.ref_b AND t.b > m.ref_a AND t.zone IS NOT NULL
        LEFT JOIN couverture.troncon_etat e ON e.troncon_id = t.id
        GROUP BY m.osm_id, m.a, m.geom, w.tags->>'highway'),
    line AS (
        SELECT highway, done, passages, (ST_Dump(ST_LineMerge(ST_Collect(geom)))).geom AS geom
        FROM part GROUP BY osm_id, highway, done, passages)
    SELECT json_build_object('type', 'FeatureCollection', 'features', coalesce(json_agg(
               json_build_object('type', 'Feature',
                                 'geometry', ST_AsGeoJSON(ST_Transform(ST_Simplify(geom, 1.5), 4326), 5)::json,
                                 'properties', json_build_object('r', done::int, 'k', {ROAD_CLASS}, 'p', passages))),
               '[]'::json))::text
    FROM line"""
ZONES = f"osm.lieu z WHERE {ZONE.format(t='z')}"
DEPARTMENTS_SQL = f"""SELECT ST_Union(geom) FROM osm.lieu
                      WHERE kind = 'limite' AND admin_level = 6 AND code = ANY('{{{",".join(DEPARTMENTS)}}}')"""
# Metres: the zones drawn a few centimetres wide on a phone.
ZONE_SIMPLIFY_M = 25


def router(require_token) -> APIRouter:
    api = APIRouter(dependencies=[Depends(require_token)])

    @api.get("/tracks")
    def tracks(if_none_match: str | None = Header(default=None)) -> Response:
        with connect() as conn:
            count, changed = conn.execute(
                "SELECT count(*), max(updated_at) FROM activity WHERE sport = 'cycling' AND track IS NOT NULL").fetchone()
            etag = '"' + hashlib.sha256(f"{count}:{changed}:{SIMPLIFY_DEGREES}".encode()).hexdigest()[:16] + '"'
            if if_none_match == etag:
                return Response(status_code=304, headers={"ETag": etag})
            body = conn.execute(
                """SELECT json_build_object('type', 'FeatureCollection', 'features', coalesce(json_agg(
                              json_build_object('type', 'Feature', 'id', id,
                                                'geometry', ST_AsGeoJSON(ST_Simplify(ST_Force2D(track), %(tolerance)s), 5)::json,
                                                'properties', json_build_object('day', started_at::date,
                                                                                'km', round((distance_m / 1000)::numeric, 1)))
                              ORDER BY started_at), '[]'::json))::text
                   FROM activity WHERE sport = 'cycling' AND track IS NOT NULL""",
                {"tolerance": SIMPLIFY_DEGREES}).fetchone()[0]
        return Response(body, media_type="application/geo+json", headers={"ETag": etag, "Cache-Control": "no-cache"})

    @api.get("/streets")
    def streets(if_none_match: str | None = Header(default=None)) -> Response:
        with connect() as conn:
            # The coverage changes when the tronçons are cut again or a ride is measured again.
            version = conn.execute("""SELECT (SELECT max(built_at) FROM couverture.build),
                                             (SELECT count(*) || ':' || coalesce(max(measured_at)::text, '')
                                              FROM couverture.sortie)""").fetchone()
            etag = '"' + hashlib.sha256(f"streets:{version}:{STREETS_FORMAT}".encode()).hexdigest()[:16] + '"'
            if if_none_match == etag:
                return Response(status_code=304, headers={"ETag": etag})
            body = conn.execute(STREETS_SQL).fetchone()[0]
        return Response(body, media_type="application/geo+json", headers={"ETag": etag, "Cache-Control": "no-cache"})

    @api.get("/tracks/outside")
    def tracks_outside(if_none_match: str | None = Header(default=None)) -> Response:
        with connect() as conn:
            count, changed = conn.execute(
                "SELECT count(*), max(updated_at) FROM activity WHERE sport = 'cycling' AND track IS NOT NULL").fetchone()
            zones = conn.execute(f"SELECT count(*), coalesce(sum(ST_NPoints(geom)), 0) FROM {ZONES}").fetchone()
            etag = '"' + hashlib.sha256(f"outside:{count}:{changed}:{zones}:{SIMPLIFY_DEGREES}".encode()).hexdigest()[:16] + '"'
            if if_none_match == etag:
                return Response(status_code=304, headers={"ETag": etag})
            # The four departments a little wider, so that a ride along their edge stays theirs; `r` as for the
            # streets ridden.
            body = conn.execute(
                f"""WITH area AS (SELECT ST_Transform(ST_Buffer(ST_SimplifyPreserveTopology(u, 20), 15), 4326) AS g
                                FROM ({DEPARTMENTS_SQL}) d(u) WHERE u IS NOT NULL),
                        cut AS (SELECT a.id, ST_Difference(ST_Simplify(ST_Force2D(a.track), %(tolerance)s), area.g) AS d
                                FROM activity a, area
                                WHERE a.sport = 'cycling' AND a.track IS NOT NULL AND NOT ST_Within(ST_Envelope(a.track), area.g))
                   SELECT json_build_object('type', 'FeatureCollection', 'features', coalesce(json_agg(
                              json_build_object('type', 'Feature', 'id', id, 'geometry', ST_AsGeoJSON(d, 5)::json,
                                                'properties', json_build_object('r', 1)) ORDER BY id)
                              FILTER (WHERE NOT ST_IsEmpty(d)), '[]'::json))::text
                   FROM cut""", {"tolerance": SIMPLIFY_DEGREES}).fetchone()[0]
        return Response(body, media_type="application/geo+json", headers={"ETag": etag, "Cache-Control": "no-cache"})

    @api.get("/zones")
    def zone_shapes(if_none_match: str | None = Header(default=None)) -> Response:
        with connect() as conn:
            zones, points = conn.execute(f"SELECT count(*), coalesce(sum(ST_NPoints(geom)), 0) FROM {ZONES}").fetchone()
            etag = '"' + hashlib.sha256(f"zones:{zones}:{points}:{ZONE_SIMPLIFY_M}".encode()).hexdigest()[:16] + '"'
            if if_none_match == etag:
                return Response(status_code=304, headers={"ETag": etag})
            body = conn.execute(
                f"""SELECT json_build_object('type', 'FeatureCollection', 'features', coalesce(json_agg(
                           json_build_object('type', 'Feature',
                                             'geometry', ST_AsGeoJSON(ST_Transform(ST_SimplifyPreserveTopology(geom, %s), 4326), 5)::json,
                                             'properties', json_build_object('code', code)) ORDER BY code), '[]'::json))::text
                    FROM {ZONES}""", (ZONE_SIMPLIFY_M,)).fetchone()[0]
        return Response(body, media_type="application/geo+json", headers={"ETag": etag, "Cache-Control": "no-cache"})

    @api.get("/stats")
    def stats() -> dict:
        with connect() as conn:
            def totals(where: str) -> dict:
                rides, km, hours, climb = conn.execute(
                    f"""SELECT count(*), coalesce(sum(distance_m), 0) / 1000, coalesce(sum(coalesce(moving_s, duration_s)), 0) / 3600,
                               coalesce(sum(elevation_gain_m), 0)
                        FROM activity WHERE sport = 'cycling' AND {where}""").fetchone()
                return {"rides": rides, "km": round(km, 1), "hours": round(hours, 1), "climb_m": round(climb)}

            longest = conn.execute(
                """SELECT started_at::date, round((distance_m / 1000)::numeric, 1) FROM activity
                   WHERE sport = 'cycling' AND distance_m IS NOT NULL ORDER BY distance_m DESC LIMIT 1""").fetchone()
            last = conn.execute("SELECT max(started_at) FROM activity WHERE sport = 'cycling'").fetchone()[0]
            # The tronçons of each zone and the metres ridden along them (coverage.py).
            lengths = {zone: (ridden, total) for zone, ridden, total in conn.execute(
                """SELECT t.zone, coalesce(sum(e.ridden_m), 0) / 1000, sum(t.length_m) / 1000
                   FROM couverture.troncon t LEFT JOIN couverture.troncon_etat e ON e.troncon_id = t.id
                   WHERE t.zone IS NOT NULL GROUP BY t.zone""").fetchall()}
            zones = [(code, name, code[:2], ring, *lengths.get(code, (0, 0))) for code, name, ring in conn.execute(
                f"SELECT z.code, z.name, z.ring FROM {ZONES} ORDER BY z.ring NULLS LAST, z.code").fetchall()]
            streets = (sum(r for r, _ in lengths.values()), sum(t for _, t in lengths.values()))
            by_year = conn.execute(
                """SELECT extract(year FROM started_at)::int, count(*), round((sum(distance_m) / 1000)::numeric)
                   FROM activity WHERE sport = 'cycling' GROUP BY 1 ORDER BY 1""").fetchall()
            return {
                "total": totals("true"),
                "this_year": totals("started_at >= date_trunc('year', now())"),
                "this_month": totals("started_at >= date_trunc('month', now())"),
                "last_30_days": totals("started_at >= now() - interval '30 days'"),
                "longest": {"day": longest[0], "km": float(longest[1])} if longest else None,
                "last_ride": last,
                "by_year": [{"year": y, "rides": n, "km": float(km or 0)} for y, n, km in by_year],
                "streets": {"ridden_km": round(streets[0], 1), "total_km": round(streets[1], 1)},
                "zones": [{"code": code, "name": name, "department": department, "ring": ring,
                           "ridden_km": round(ridden, 1), "total_km": round(total, 1)}
                          for code, name, department, ring, ridden, total in zones],
            }

    @api.post("/osm/refresh")
    def osm_refresh() -> dict:
        done = osm.ask()
        return {"running": True} if done is None else {"running": False, **done}

    return api
