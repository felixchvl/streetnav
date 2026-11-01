"""Activity registry: attaches the versions (copies) of an activity coming from several services to one activity.

Bronze (bronze.py) keeps each version's files, silver (activity_source) each version's values, gold (gold.py) the
activity computed from its versions.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from datetime import datetime

import psycopg

from . import bronze

SAME_ACTIVITY_SECONDS = 90
# Otherwise a copy joins the activity it overlaps the most, if that overlap covers at least this
# share of the shorter of the two (a ride cropped at the start no longer starts at the same time).
SAME_ACTIVITY_OVERLAP = 0.5
MATCH_LOCK = 0x5374_6E76  # PostgreSQL advisory lock serializing the attachment of versions
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


def upsert(conn: psycopg.Connection, copy: ActivityCopy, raw_file_ids: list[int] | None,
           rebuild: bool = True) -> tuple[int, str]:
    """Stores a version in silver, attaching it to its activity, then recomputes that activity (gold) unless
    `rebuild` is False. `raw_file_ids` are the bronze files it was read from (None: not read from bronze, so it does
    not count for gold yet). Returns (activity id, 'created' | 'merged' | 'updated')."""
    from . import gold
    with conn.cursor() as cur:
        # One writer at a time decides which activity a version belongs to: the app, the timer and an import
        # running together cannot create the same activity twice.
        cur.execute("SELECT pg_advisory_xact_lock(%s)", (MATCH_LOCK,))
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
            if row:
                activity_id, outcome = row[0], "merged"
            else:
                # Gold fills the rest from the version below.
                cur.execute("""INSERT INTO activity (started_at, ended_at, sport, primary_source)
                               VALUES (%s, %s, %s, %s) RETURNING id""",
                            (copy.started_at, copy.ended_at, copy.sport, copy.source))
                activity_id, outcome = cur.fetchone()[0], "created"

        cur.execute(
            f"""INSERT INTO activity_source (source, external_id, activity_id, started_at, device, raw, {', '.join(METRICS)},
                                             track, hr_t, hr_bpm, raw_file_ids, parsed_at, fetched_at)
                VALUES (%(source)s, %(external_id)s, %(activity_id)s, %(started_at)s, %(device)s, %(raw)s,
                        {', '.join('%(' + k + ')s' for k in METRICS)}, ST_GeomFromEWKT(%(track)s), %(hr_t)s,
                        %(hr_bpm)s, %(raw_file_ids)s, CASE WHEN %(parsed)s THEN now() END, now())
                ON CONFLICT (source, external_id) DO UPDATE
                SET activity_id = EXCLUDED.activity_id, started_at = EXCLUDED.started_at, device = EXCLUDED.device,
                    raw = EXCLUDED.raw, {', '.join(f'{k} = EXCLUDED.{k}' for k in METRICS)}, track = EXCLUDED.track,
                    hr_t = EXCLUDED.hr_t, hr_bpm = EXCLUDED.hr_bpm, raw_file_ids = EXCLUDED.raw_file_ids,
                    parsed_at = EXCLUDED.parsed_at, fetched_at = now()""",
            {**{k: getattr(copy, k) for k in METRICS}, "source": copy.source, "external_id": copy.external_id,
             "activity_id": activity_id, "started_at": copy.started_at, "device": copy.device,
             "raw": json.dumps(copy.raw) if copy.raw is not None else None, "track": track_wkt(copy.points),
             "hr_t": [t for t, _ in copy.heart_rate] or None, "hr_bpm": [b for _, b in copy.heart_rate] or None,
             "raw_file_ids": raw_file_ids, "parsed": raw_file_ids is not None})
    if rebuild:
        gold.rebuild_activity(conn, activity_id)
    return activity_id, outcome


def ingest(conn: psycopg.Connection, source: str, external_id: str, parts: list[tuple[str, str, bytes]],
           batch: str | None) -> tuple[int, str, ActivityCopy]:
    """Keeps a version's files in bronze, reads the version back from its current bronze files (the same way a
    rebuild would), then stores it like upsert. `parts` are (part, name at the source, bytes)."""
    from .sources import parse
    for part, name, data in parts:
        bronze.store(conn, source, external_id, part, name, data, batch)
    rows = bronze.current(conn, source, external_id)
    copy = parse(source, external_id, bronze.load(rows, {bronze.sha256(data): data for _, _, data in parts}))
    activity_id, outcome = upsert(conn, copy, [r["id"] for r in rows])
    return activity_id, outcome, copy


def remove(conn: psycopg.Connection, source: str, external_id: str, batch: str | None = "api") -> tuple[int | None, str]:
    """Forgets a version deleted where it came from; returns (activity id, 'deleted' | 'detached' | 'unknown').

    Bronze keeps its files and records the deletion. An activity left without any version is deleted; otherwise it is
    recomputed from the versions left."""
    from . import gold
    conn.execute("SELECT pg_advisory_xact_lock(%s)", (MATCH_LOCK,))
    row = conn.execute("DELETE FROM activity_source WHERE source = %s AND external_id = %s RETURNING activity_id",
                       (source, external_id)).fetchone()
    if row is None and not bronze.current(conn, source, external_id):
        return None, "unknown"
    bronze.record_deletion(conn, source, external_id, batch)
    if row is None:
        return None, "unknown"
    activity_id = row[0]
    if gold.rebuild_activity(conn, activity_id) == "empty":
        conn.execute("DELETE FROM activity WHERE id = %s", (activity_id,))
        return activity_id, "deleted"
    return activity_id, "detached"


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
