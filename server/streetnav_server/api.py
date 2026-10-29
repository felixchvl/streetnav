"""Streetnav HTTP API: read the activity registry, and let the iPhone app push (and delete) Apple Health workouts.

Every endpoint except /health needs `Authorization: Bearer <STREETNAV_API_TOKEN>`.
"""
from __future__ import annotations

import hmac
import os
from datetime import datetime

from fastapi import Depends, FastAPI, Header, HTTPException, Query
from pydantic import BaseModel, Field

from .registry import ActivityCopy, connect, remove, upsert

app = FastAPI(title="Streetnav", version="1")


def require_token(authorization: str = Header(default="")) -> None:
    expected = "Bearer " + os.environ["STREETNAV_API_TOKEN"]
    if not hmac.compare_digest(authorization.encode(), expected.encode()):
        raise HTTPException(status_code=401, detail="invalid token")


class WorkoutIn(BaseModel):
    """An Apple Health workout sent by the iPhone app (or any other source)."""
    source: str = "healthkit"
    external_id: str = Field(description="HKWorkout UUID for Apple Health")
    started_at: datetime
    ended_at: datetime | None = None
    sport: str
    indoor: bool | None = None
    distance_m: float | None = None
    duration_s: float | None = None
    moving_s: float | None = None
    calories: float | None = None
    avg_hr: float | None = None
    max_hr: float | None = None
    elevation_gain_m: float | None = None
    points: list[tuple[float, float, float | None, int]] = Field(
        default_factory=list, description="[longitude, latitude, altitude m, unix seconds]")
    heart_rate: list[tuple[int, int]] = Field(default_factory=list, description="[unix seconds, bpm]")
    device: str | None = None
    name: str | None = None
    sport_type: str | None = Field(default=None, description="Strava's name, e.g. Ride, Walk, WeightTraining")
    raw: dict | None = Field(default=None, description="kept as is, e.g. the workout's source app and metadata")


@app.get("/health")
def health() -> dict:
    with connect() as conn:
        conn.execute("SELECT 1")
    return {"ok": True}


@app.get("/status", dependencies=[Depends(require_token)])
def status() -> dict:
    with connect() as conn:
        total = conn.execute("SELECT count(*), min(started_at), max(started_at) FROM activity").fetchone()
        by_source = conn.execute("SELECT source, count(*) FROM activity_source GROUP BY source").fetchall()
        runs = conn.execute("SELECT source, finished_at, created, merged, updated, errors, message FROM sync_run").fetchall()
    return {"activities": total[0], "first": total[1], "last": total[2], "copies_by_source": dict(by_source),
            "last_runs": [dict(zip(("source", "finished_at", "created", "merged", "updated", "errors", "message"), r))
                          for r in runs]}


@app.get("/activities", dependencies=[Depends(require_token)])
def list_activities(since: datetime | None = None, until: datetime | None = None, sport: str | None = None,
                    limit: int = Query(200, le=2000)) -> list[dict]:
    with connect() as conn:
        rows = conn.execute(
            """SELECT a.id, a.started_at, a.ended_at, a.sport, a.sport_type, a.name, a.commute, a.gear,
                      a.distance_m, a.duration_s, a.calories, a.avg_hr,
                      a.elevation_gain_m, a.primary_source, a.track IS NOT NULL,
                      array_agg(s.source ORDER BY s.source)
               FROM activity a JOIN activity_source s ON s.activity_id = a.id
               WHERE (%(since)s::timestamptz IS NULL OR a.started_at >= %(since)s)
                 AND (%(until)s::timestamptz IS NULL OR a.started_at < %(until)s)
                 AND (%(sport)s::text IS NULL OR a.sport = %(sport)s)
               GROUP BY a.id ORDER BY a.started_at DESC LIMIT %(limit)s""",
            {"since": since, "until": until, "sport": sport, "limit": limit}).fetchall()
    keys = ("id", "started_at", "ended_at", "sport", "sport_type", "name", "commute", "gear",
            "distance_m", "duration_s", "calories", "avg_hr",
            "elevation_gain_m", "primary_source", "has_track", "sources")
    return [dict(zip(keys, r)) for r in rows]


@app.get("/activities/{activity_id}", dependencies=[Depends(require_token)])
def get_activity(activity_id: int) -> dict:
    with connect() as conn:
        row = conn.execute(
            """SELECT id, started_at, ended_at, sport, sport_type, name, description, commute, gear, indoor,
                      distance_m, duration_s, moving_s, calories, avg_hr,
                      max_hr, elevation_gain_m, primary_source, ST_AsGeoJSON(track)::json
               FROM activity WHERE id = %s""", (activity_id,)).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="unknown activity")
        sources = conn.execute(
            "SELECT source, external_id, device, fetched_at FROM activity_source WHERE activity_id = %s",
            (activity_id,)).fetchall()
    keys = ("id", "started_at", "ended_at", "sport", "sport_type", "name", "description", "commute", "gear", "indoor",
            "distance_m", "duration_s", "moving_s", "calories",
            "avg_hr", "max_hr", "elevation_gain_m", "primary_source", "track")
    return {**dict(zip(keys, row)),
            "sources": [dict(zip(("source", "external_id", "device", "fetched_at"), s)) for s in sources]}


@app.get("/reconcile", dependencies=[Depends(require_token)])
def reconcile(missing_in: str = "rwgps", since: datetime | None = None, with_track_only: bool = True) -> list[dict]:
    """Activities that have no copy in `missing_in` (e.g. Apple Health workouts not on Ride with GPS)."""
    with connect() as conn:
        rows = conn.execute(
            """SELECT a.id, a.started_at, a.sport, a.distance_m, array_agg(s.source ORDER BY s.source)
               FROM activity a JOIN activity_source s ON s.activity_id = a.id
               WHERE (%(since)s::timestamptz IS NULL OR a.started_at >= %(since)s)
                 AND (NOT %(track)s OR a.track IS NOT NULL)
               GROUP BY a.id
               HAVING NOT bool_or(s.source = %(missing)s)
               ORDER BY a.started_at""",
            {"since": since, "track": with_track_only, "missing": missing_in}).fetchall()
    return [dict(zip(("id", "started_at", "sport", "distance_m", "sources"), r)) for r in rows]


@app.post("/activities", dependencies=[Depends(require_token)])
def push_activity(workout: WorkoutIn) -> dict:
    copy = ActivityCopy(**workout.model_dump(exclude={"points", "heart_rate", "raw"}),
                        points=[tuple(p) for p in workout.points],
                        heart_rate=[tuple(h) for h in workout.heart_rate],
                        raw={**(workout.raw or {}), "received_at": datetime.now().isoformat()})
    with connect() as conn:
        activity_id, outcome = upsert(conn, copy)
        conn.commit()
    return {"id": activity_id, "outcome": outcome}


@app.delete("/copies/{source}/{external_id}", dependencies=[Depends(require_token)])
def delete_copy(source: str, external_id: str) -> dict:
    """A copy deleted where it came from (the iOS app reports workouts deleted in Apple Health). Deleting an unknown
    copy succeeds too, so the app can safely send a deletion again."""
    with connect() as conn:
        activity_id, outcome = remove(conn, source, external_id)
        conn.commit()
    return {"id": activity_id, "outcome": outcome}
