"""Activity registry: merges copies of the same activity coming from several services."""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from datetime import datetime

import psycopg

SAME_ACTIVITY_SECONDS = 90
# Otherwise a copy joins the activity it overlaps the most, if that overlap covers at least this
# share of the shorter of the two (a ride cropped at the start no longer starts at the same time).
SAME_ACTIVITY_OVERLAP = 0.5
# Higher wins: its metrics and track replace those of a lower-priority source. Strava comes first
# because that is where rides were edited by hand (cropped, commute flag, bike, sport type).
SOURCE_PRIORITY = {"strava": 5, "healthkit": 4, "file": 3, "rwgps": 2, "wandrer": 0}
METRICS = ("ended_at", "sport", "indoor", "distance_m", "duration_s", "moving_s", "calories",
           "avg_hr", "max_hr", "elevation_gain_m", "name", "description", "sport_type", "commute", "gear")


def connect() -> psycopg.Connection:
    return psycopg.connect(os.environ["STREETNAV_DATABASE_URL"])


@dataclass
class ActivityCopy:
    """One service's copy of an activity."""
    source: str
    external_id: str
    started_at: datetime
    sport: str
    ended_at: datetime | None = None
    indoor: bool | None = None
    distance_m: float | None = None
    duration_s: float | None = None
    moving_s: float | None = None
    calories: float | None = None
    avg_hr: float | None = None
    max_hr: float | None = None
    elevation_gain_m: float | None = None
    name: str | None = None
    description: str | None = None
    sport_type: str | None = None
    commute: bool | None = None
    gear: str | None = None
    points: list[tuple[float, float, float, int]] = field(default_factory=list)  # lon, lat, alt, unix s
    heart_rate: list[tuple[int, int]] = field(default_factory=list)              # unix s, bpm
    device: str | None = None
    raw: dict | None = None


def track_wkt(points) -> str | None:
    pts = [p for p in points if p[0] is not None and p[1] is not None]
    if len(pts) < 2:
        return None
    return "SRID=4326;LINESTRING ZM (" + ", ".join(
        f"{lon} {lat} {alt if alt is not None else 0} {t}" for lon, lat, alt, t in pts) + ")"


def upsert(conn: psycopg.Connection, copy: ActivityCopy) -> tuple[int, str]:
    """Stores a copy; returns (activity id, 'created' | 'merged' | 'updated')."""
    with conn.cursor() as cur:
        cur.execute("SELECT activity_id FROM activity_source WHERE source = %s AND external_id = %s",
                    (copy.source, copy.external_id))
        row = cur.fetchone()
        if row:
            activity_id, outcome = row[0], "updated"
        else:
            cur.execute(
                """SELECT id FROM activity
                   WHERE started_at BETWEEN %(t)s - make_interval(secs => %(w)s) AND %(t)s + make_interval(secs => %(w)s)
                   ORDER BY abs(extract(epoch FROM started_at - %(t)s)) LIMIT 1""",
                {"t": copy.started_at, "w": SAME_ACTIVITY_SECONDS})
            row = cur.fetchone()
            if row is None and copy.ended_at is not None:
                cur.execute(
                    """SELECT id FROM activity
                       WHERE ended_at IS NOT NULL AND started_at < %(e)s AND ended_at > %(t)s
                         AND extract(epoch FROM least(ended_at, %(e)s) - greatest(started_at, %(t)s))
                             >= %(share)s * least(extract(epoch FROM ended_at - started_at),
                                                  extract(epoch FROM %(e)s - %(t)s))
                       ORDER BY least(ended_at, %(e)s) - greatest(started_at, %(t)s) DESC LIMIT 1""",
                    {"t": copy.started_at, "e": copy.ended_at, "share": SAME_ACTIVITY_OVERLAP})
                row = cur.fetchone()
            activity_id, outcome = (row[0], "merged") if row else (None, "created")

        values = {k: getattr(copy, k) for k in METRICS}
        wkt = track_wkt(copy.points)
        start = copy.points[0] if wkt else None
        if activity_id is None:
            cur.execute(
                f"""INSERT INTO activity (started_at, {', '.join(METRICS)}, track, start_point, primary_source)
                    VALUES (%(started_at)s, {', '.join('%(' + k + ')s' for k in METRICS)},
                            ST_GeomFromEWKT(%(track)s), ST_SetSRID(ST_MakePoint(%(lon)s, %(lat)s), 4326), %(source)s)
                    RETURNING id""",
                {**values, "started_at": copy.started_at, "track": wkt, "source": copy.source,
                 "lon": start[0] if start else None, "lat": start[1] if start else None})
            activity_id = cur.fetchone()[0]
            take_over = True
        else:
            cur.execute("SELECT primary_source FROM activity WHERE id = %s", (activity_id,))
            current = cur.fetchone()[0]
            take_over = SOURCE_PRIORITY[copy.source] >= SOURCE_PRIORITY[current]
            if take_over:
                # The higher-priority copy replaces metrics (keeping existing ones it lacks) and the track.
                sets = ", ".join(f"{k} = COALESCE(%({k})s, {k})" for k in METRICS)
                cur.execute(
                    f"""UPDATE activity SET {sets}, started_at = %(started_at)s, primary_source = %(source)s, updated_at = now(),
                            track = COALESCE(ST_GeomFromEWKT(%(track)s), track),
                            start_point = COALESCE(ST_SetSRID(ST_MakePoint(%(lon)s, %(lat)s), 4326), start_point)
                        WHERE id = %(id)s""",
                    {**values, "source": copy.source, "track": wkt, "id": activity_id, "started_at": copy.started_at,
                     "lon": start[0] if start else None, "lat": start[1] if start else None})
            else:
                # A lower-priority copy only fills what is missing.
                sets = ", ".join(f"{k} = COALESCE({k}, %({k})s)" for k in METRICS)
                cur.execute(
                    f"""UPDATE activity SET {sets}, updated_at = now(),
                            track = COALESCE(track, ST_GeomFromEWKT(%(track)s)),
                            start_point = COALESCE(start_point, ST_SetSRID(ST_MakePoint(%(lon)s, %(lat)s), 4326))
                        WHERE id = %(id)s""",
                    {**values, "track": wkt, "id": activity_id,
                     "lon": start[0] if start else None, "lat": start[1] if start else None})

        if copy.heart_rate:
            cur.execute("SELECT 1 FROM activity_heart_rate WHERE activity_id = %s", (activity_id,))
            if take_over or cur.fetchone() is None:
                cur.execute(
                    """INSERT INTO activity_heart_rate (activity_id, t, bpm) VALUES (%s, %s, %s)
                       ON CONFLICT (activity_id) DO UPDATE SET t = EXCLUDED.t, bpm = EXCLUDED.bpm""",
                    (activity_id, [t for t, _ in copy.heart_rate], [b for _, b in copy.heart_rate]))

        cur.execute(
            """INSERT INTO activity_source (source, external_id, activity_id, started_at, device, raw)
               VALUES (%s, %s, %s, %s, %s, %s)
               ON CONFLICT (source, external_id) DO UPDATE
               SET activity_id = EXCLUDED.activity_id, started_at = EXCLUDED.started_at,
                   device = EXCLUDED.device, raw = EXCLUDED.raw, fetched_at = now()""",
            (copy.source, copy.external_id, activity_id, copy.started_at, copy.device,
             json.dumps(copy.raw) if copy.raw is not None else None))
    return activity_id, outcome


def record_run(conn: psycopg.Connection, source: str, counts: dict[str, int], message: str = "") -> None:
    with conn.cursor() as cur:
        cur.execute(
            """INSERT INTO sync_run (source, finished_at, created, merged, updated, errors, message)
               VALUES (%s, now(), %s, %s, %s, %s, %s)
               ON CONFLICT (source) DO UPDATE SET finished_at = now(), created = EXCLUDED.created,
                   merged = EXCLUDED.merged, updated = EXCLUDED.updated, errors = EXCLUDED.errors,
                   message = EXCLUDED.message""",
            (source, counts.get("created", 0), counts.get("merged", 0), counts.get("updated", 0),
             counts.get("errors", 0), message))
