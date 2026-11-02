"""What the iPhone app draws and sums up: the tracks of every bike ride for the map, and the riding statistics.

GET /tracks: one GeoJSON feature per ride with a track, simplified to about 5 metres (2,273 rides: 2 MB, much less
gzipped), with an ETag so that the app only downloads them again when a ride was added or changed.
GET /streets: every street around Paris cut into ridden and not ridden parts (streets.py), for the map's two colours,
with the class of their road for the map to draw them as wide as it; 2 MB gzipped, with an ETag on the last street run.
GET /stats: totals, this year, this month, the last 30 days, records, kilometres by year and streets ridden, overall and
in each arrondissement of Paris and commune of the inner suburbs, with its ring (zones.py).
"""
from __future__ import annotations

import hashlib

from fastapi import APIRouter, Depends, Header, Response

from .registry import connect
from .streets import SHOWN_RIDDEN

# About 5 metres in Paris (degrees of longitude / latitude): below what a phone screen shows at street level.
SIMPLIFY_DEGREES = 0.00005

# The width classes of Mapbox Standard's roads (its "roads" and "road-path" layers), from OpenStreetMap's highway tag:
# 0 motorway or trunk, 1 primary, 2 secondary or tertiary, 3 street (the rest: residential, unclassified, motorway
# links…), 4 link of a primary, secondary or tertiary, 5 service, track…, 6 path, footway, cycleway, pedestrian, steps.
ROAD_CLASS = """CASE
    WHEN s.highway IN ('motorway', 'trunk') THEN 0
    WHEN s.highway = 'primary' THEN 1
    WHEN s.highway IN ('secondary', 'tertiary') THEN 2
    WHEN s.highway IN ('primary_link', 'secondary_link', 'tertiary_link') THEN 4
    WHEN s.highway IN ('service', 'services', 'rest_area', 'track', 'construction', 'bus_stop', 'elevator') THEN 5
    WHEN s.highway IN ('path', 'footway', 'cycleway', 'pedestrian', 'steps', 'bridleway') THEN 6
    ELSE 3 END"""
# Bumped whenever the street features change shape, so that the app downloads them again.
STREETS_FORMAT = 2


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
            last = conn.execute("SELECT max(finished_at) FROM street_run").fetchone()[0]
            etag = '"' + hashlib.sha256(f"streets:{last}:{STREETS_FORMAT}".encode()).hexdigest()[:16] + '"'
            if if_none_match == etag:
                return Response(status_code=304, headers={"ETag": etag})
            body = conn.execute(
                f"""SELECT json_build_object('type', 'FeatureCollection', 'features', coalesce(json_agg(
                              json_build_object('type', 'Feature',
                                                'geometry', ST_AsGeoJSON(ST_Transform(ST_Simplify(p.geom, 1.5), 4326), 5)::json,
                                                'properties', json_build_object('r', {SHOWN_RIDDEN}::int, 'k', {ROAD_CLASS}))),
                              '[]'::json))::text
                   FROM street_part p JOIN street s ON s.id = p.street_id""").fetchone()[0]
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
            streets = conn.execute(
                f"""SELECT coalesce(sum(length_m) FILTER (WHERE {SHOWN_RIDDEN}), 0) / 1000, coalesce(sum(length_m), 0) / 1000
                    FROM street_part""").fetchone()
            zones = conn.execute(
                f"""SELECT z.code, z.name, z.department, z.ring,
                           coalesce(sum(p.length_m) FILTER (WHERE {SHOWN_RIDDEN}), 0) / 1000, coalesce(sum(p.length_m), 0) / 1000
                    FROM zone z LEFT JOIN street_part p ON p.zone = z.code
                    GROUP BY z.code ORDER BY z.ring NULLS LAST, z.code""").fetchall()
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

    return api
