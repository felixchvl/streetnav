"""Gold layer: the `activity` row of each real activity, computed field by field from its versions (silver).

- Measures (time window, track, heart rate, distance, durations, calories, ascent, indoor) come from Apple Health,
  the Watch's own recording: the app's copy first, then the HealthFit file, then Strava, then Ride with GPS.
- What was typed by hand (name, description, commute flag, gear, sport type) comes from Strava first.
- A ride cropped by hand on Strava: when the Strava version has a track and its time window starts or ends more than
  STRAVA_CROP_S away from Apple Health's, Strava's version provides the measures.
- Otherwise a ride's idle start and end (the Watch started before leaving or stopped after arriving) are cut: what is
  both slow and in one place, for more than AUTO_CROP_MIN_S.

Each field takes the first non-empty value in its order. Within a source (two FIT files for one session, a duplicate
on Strava), a version with a track comes first, then the one starting closest to the activity's other versions (an app
like StrongLifts sometimes writes a workout lasting hours), then the longest. `provenance` names the version behind
each field, and what the automatic crop removed.
"""
from __future__ import annotations

import math
import struct
from datetime import datetime, timezone

import psycopg
from psycopg.types.json import Jsonb

from .registry import ActivityCopy, track_wkt

MEASURE_ORDER = ("healthkit", "file", "strava", "rwgps", "wandrer")
HAND_ORDER = ("strava", "healthkit", "file", "rwgps", "wandrer")
APPLE_HEALTH = ("healthkit", "file")
MEASURES = ("indoor", "distance_m", "duration_s", "moving_s", "calories", "avg_hr", "max_hr", "elevation_gain_m")
HAND_EDITS = ("name", "description", "commute", "gear")
STRAVA_CROP_S = 15
# Automatic crop of rides, calibrated on the rides cropped by hand on Strava.
AUTO_CROP_SPORTS = {"cycling"}
AUTO_CROP_SOURCES = {"healthkit", "file", "rwgps"}
RIDING_KMH = 6            # riding: at least this average speed...
RIDING_WINDOW_S = 30      # ...over this long
SAME_PLACE_M = 100        # idle: within this distance of the first (or last) point
AUTO_CROP_MIN_S = 60      # shorter idle starts and ends are kept
GOLD_COLUMNS = ("started_at", "ended_at", "sport", "sport_type", "indoor", "distance_m", "duration_s", "moving_s",
                "calories", "avg_hr", "max_hr", "elevation_gain_m", "name", "description", "commute", "gear")


def label(v: ActivityCopy) -> str:
    return f"{v.source}:{v.external_id}"


def ranked(versions: list[ActivityCopy], order: tuple[str, ...]) -> list[ActivityCopy]:
    rank = {source: i for i, source in enumerate(order)}
    starts = sorted(v.started_at.timestamp() for v in versions)
    median = (starts[(len(starts) - 1) // 2] + starts[len(starts) // 2]) / 2
    return sorted(versions, key=lambda v: (
        rank.get(v.source, len(order)), len(v.points) < 2, round(abs(v.started_at.timestamp() - median)),
        -(v.ended_at - v.started_at).total_seconds() if v.ended_at else 0, v.external_id))


def strava_crop(versions: list[ActivityCopy]) -> ActivityCopy | None:
    """The Strava version, if it was cropped by hand: its window differs from Apple Health's."""
    health = next((v for v in ranked(versions, MEASURE_ORDER) if v.source in APPLE_HEALTH and v.ended_at), None)
    strava = next((v for v in ranked(versions, HAND_ORDER)
                   if v.source == "strava" and len(v.points) >= 2 and v.ended_at), None)
    if health is None or strava is None:
        return None
    gap = max(abs((strava.started_at - health.started_at).total_seconds()),
              abs((strava.ended_at - health.ended_at).total_seconds()))
    return strava if gap > STRAVA_CROP_S else None


def metres(a: tuple, b: tuple) -> float:
    """Distance between two (lon, lat, ...) points, equirectangular (fine at track scale)."""
    lon1, lat1, lon2, lat2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    return 6_371_000 * math.hypot((lon2 - lon1) * math.cos((lat1 + lat2) / 2), lat2 - lat1)


def riding_bounds(points: list[tuple]) -> tuple[int | None, int | None]:
    """First and last moments of riding: RIDING_KMH or more on average over RIDING_WINDOW_S."""
    cumulative = [0.0]
    for a, b in zip(points, points[1:]):
        cumulative.append(cumulative[-1] + metres(a, b))
    first = last = None
    j = 0
    for i, point in enumerate(points):
        while j < len(points) and points[j][3] < point[3] + RIDING_WINDOW_S:
            j += 1
        if j >= len(points):
            break
        seconds = points[j][3] - point[3]
        if seconds > 0 and (cumulative[j] - cumulative[i]) / seconds * 3.6 >= RIDING_KMH:
            first = point[3] if first is None else first
            last = points[j][3]
    return first, last


def auto_crop(points: list[tuple], start_s: float, end_s: float) -> tuple[float, float] | None:
    """The (start, end) a ride is cut to, or None: idle means slow and in one place."""
    first, last = riding_bounds(points)
    if first is None:
        return None
    k = 0
    while k < len(points) - 1 and metres(points[k + 1], points[0]) <= SAME_PLACE_M:
        k += 1
    head_end = min(first, points[k][3])
    k = len(points) - 1
    while k > 0 and metres(points[k - 1], points[-1]) <= SAME_PLACE_M:
        k -= 1
    tail_start = max(last, points[k][3])
    start = head_end if head_end - start_s > AUTO_CROP_MIN_S else start_s
    end = tail_start if end_s - tail_start > AUTO_CROP_MIN_S else end_s
    if (start, end) == (start_s, end_s) or end <= start or sum(start <= p[3] <= end for p in points) < 2:
        return None
    return start, end


def apply_crop(out: dict, start: float, end: float) -> dict:
    """Cuts the gold values to [start, end]: track and heart rate cut, the rest recomputed or scaled."""
    old_start, old_end = out["started_at"].timestamp(), out["ended_at"].timestamp()
    points = out["points"]
    removed = [(a, b) for a, b in zip(points, points[1:]) if b[3] <= start or a[3] >= end]
    removed_m = sum(metres(a, b) for a, b in removed)
    removed_gain = sum(max(0.0, b[2] - a[2]) for a, b in removed if a[2] is not None and b[2] is not None)
    removed_s = (start - old_start) + (old_end - end)
    kept = [p for p in points if start <= p[3] <= end]
    duration = end - start

    out = dict(out, points=kept, started_at=datetime.fromtimestamp(start, timezone.utc),
               ended_at=datetime.fromtimestamp(end, timezone.utc), duration_s=duration)
    if out["distance_m"] is not None:
        out["distance_m"] = max(0.0, out["distance_m"] - removed_m)
    if out["elevation_gain_m"] is not None:
        out["elevation_gain_m"] = max(0.0, out["elevation_gain_m"] - removed_gain)
    if out["moving_s"] is not None:
        out["moving_s"] = min(duration, max(0.0, out["moving_s"] - removed_s))
    if out["calories"] is not None and old_end > old_start:
        out["calories"] = out["calories"] * duration / (old_end - old_start)  # no per-minute calories: prorated
    heart_rate = [(t, bpm) for t, bpm in out["heart_rate"] if start <= t <= end]
    if heart_rate:
        out["avg_hr"] = sum(b for _, b in heart_rate) / len(heart_rate)
        out["max_hr"] = max(b for _, b in heart_rate)
    out["heart_rate"] = heart_rate
    out["provenance"] = dict(out["provenance"], auto_crop={"head_s": round(start - old_start),
                                                          "tail_s": round(old_end - end)})
    return out


def compose(versions: list[ActivityCopy]) -> dict:
    """Gold values of an activity from its versions (at least one)."""
    measures = ranked(versions, MEASURE_ORDER)
    cropped = strava_crop(versions)
    if cropped is not None:
        measures = [cropped] + [v for v in measures if v is not cropped]
    hand = ranked(versions, HAND_ORDER)

    def first(order, field, present=lambda value: value is not None):
        return next(((getattr(v, field), v) for v in order if present(getattr(v, field))), (None, None))

    lead = measures[0]
    out, provenance = {"started_at": lead.started_at}, {"started_at": label(lead)}
    ended_at, by = (lead.ended_at, lead) if lead.ended_at else first(measures, "ended_at")
    out["ended_at"] = ended_at
    for field, (value, v) in [("ended_at", (ended_at, by))] + [(f, first(measures, f)) for f in MEASURES] + \
            [(f, first(hand, f)) for f in HAND_EDITS]:
        out[field] = value
        if v is not None:
            provenance[field] = label(v)
    out["points"], track_by = first(measures, "points", lambda points: len(points) >= 2)
    out["points"] = out["points"] or []
    out["heart_rate"], hr_by = first(measures, "heart_rate", bool)
    out["heart_rate"] = out["heart_rate"] or []
    sport_type, sport_by = first(hand, "sport_type")
    out["sport_type"], out["sport"] = sport_type, (sport_by or hand[0]).sport
    provenance["sport_type"] = provenance["sport"] = label(sport_by or hand[0])
    for field, v in (("track", track_by), ("heart_rate", hr_by)):
        if v is not None:
            provenance[field] = label(v)
    if cropped is not None:
        provenance["strava_crop"] = True
    out["primary_source"] = (track_by or lead).source
    out["provenance"] = provenance

    if (cropped is None and out["sport"] in AUTO_CROP_SPORTS and out["indoor"] is not True
            and not (out["sport_type"] or "").startswith("Virtual") and track_by is not None
            and track_by.source in AUTO_CROP_SOURCES and out["ended_at"] is not None):
        window = auto_crop(out["points"], out["started_at"].timestamp(), out["ended_at"].timestamp())
        if window:
            out = apply_crop(out, *window)
    return out


# --- database ---------------------------------------------------------------------------------

SILVER_FIELDS = ("source", "external_id", "started_at", "ended_at", "sport", "sport_type", "indoor", "distance_m",
                 "duration_s", "moving_s", "calories", "avg_hr", "max_hr", "elevation_gain_m", "name", "description",
                 "commute", "gear", "device")


def wkb_points(wkb: bytes | None) -> list[tuple]:
    """(lon, lat, alt, unix s) of a LineStringZM in ISO WKB."""
    if not wkb:
        return []
    wkb = bytes(wkb)
    order = "<" if wkb[0] == 1 else ">"
    n = struct.unpack_from(order + "I", wkb, 5)[0]
    return [(x, y, z, int(m)) for x, y, z, m in struct.iter_unpack(order + "4d", wkb[9:9 + 32 * n])]


def load_versions(conn: psycopg.Connection, activity_id: int) -> list[tuple[ActivityCopy, bool]]:
    """(version, read from bronze) of each version of an activity."""
    rows = conn.execute(
        f"""SELECT {', '.join(SILVER_FIELDS)}, ST_AsBinary(track), hr_t, hr_bpm, parsed_at IS NOT NULL
            FROM activity_source WHERE activity_id = %s""", (activity_id,)).fetchall()
    out = []
    for row in rows:
        values = dict(zip(SILVER_FIELDS, row))
        track, hr_t, hr_bpm, parsed = row[len(SILVER_FIELDS):]
        out.append((ActivityCopy(**values, points=wkb_points(track),
                                 heart_rate=list(zip(hr_t or [], hr_bpm or []))), parsed))
    return out


def rebuild_activity(conn: psycopg.Connection, activity_id: int, ignore_pending: bool = False) -> str:
    """Recomputes an activity; returns 'updated', 'unchanged', 'pending' (a version not read from bronze yet, so
    the activity is left as it is) or 'empty' (no version)."""
    loaded = load_versions(conn, activity_id)
    versions = [v for v, parsed in loaded if parsed]
    if not loaded:
        return "empty"
    if not versions or (len(versions) < len(loaded) and not ignore_pending):
        return "pending"
    out = compose(versions)
    start = out["points"][0] if len(out["points"]) >= 2 else None
    values = {k: out[k] for k in GOLD_COLUMNS}
    values.update(id=activity_id, track=track_wkt(out["points"]), lon=start[0] if start else None,
                  lat=start[1] if start else None, primary_source=out["primary_source"],
                  provenance=Jsonb(out["provenance"]))
    columns = GOLD_COLUMNS + ("track", "start_point", "primary_source", "provenance")
    typed = {"started_at": "timestamptz", "ended_at": "timestamptz", "indoor": "boolean", "commute": "boolean",
             "sport": "text", "sport_type": "text", "name": "text", "description": "text", "gear": "text"}
    selects = [f"%({k})s::{typed.get(k, 'double precision')} AS {k}" for k in GOLD_COLUMNS] + [
        "ST_GeomFromEWKT(%(track)s::text) AS track",
        "ST_SetSRID(ST_MakePoint(%(lon)s::double precision, %(lat)s::double precision), 4326) AS start_point",
        "%(primary_source)s::text AS primary_source", "%(provenance)s::jsonb AS provenance"]
    updated = conn.execute(
        f"""WITH new AS (SELECT {', '.join(selects)})
            UPDATE activity a SET ({', '.join(columns)}) = (SELECT {', '.join('new.' + c for c in columns)}),
                                  updated_at = now()
            FROM new
            WHERE a.id = %(id)s AND ({', '.join('a.' + c for c in columns)})
                                    IS DISTINCT FROM ({', '.join('new.' + c for c in columns)})
            RETURNING a.id""", values).fetchone() is not None

    if out["heart_rate"]:
        changed = conn.execute(
            """INSERT INTO activity_heart_rate (activity_id, t, bpm) VALUES (%s, %s, %s)
               ON CONFLICT (activity_id) DO UPDATE SET t = EXCLUDED.t, bpm = EXCLUDED.bpm
               WHERE (activity_heart_rate.t, activity_heart_rate.bpm) IS DISTINCT FROM (EXCLUDED.t, EXCLUDED.bpm)""",
            (activity_id, [t for t, _ in out["heart_rate"]], [b for _, b in out["heart_rate"]])).rowcount
    else:
        changed = conn.execute("DELETE FROM activity_heart_rate WHERE activity_id = %s", (activity_id,)).rowcount
    return "updated" if updated or changed else "unchanged"
