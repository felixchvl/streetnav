"""Imports a one-off Strava export into the registry.

Strava's own API is subscriber-only, so the export is read from the athlete's web session:
  activities.json   the rows of strava.com/athlete/training_activities (one per activity)
  gear.json         {"<bike or shoes id>": "<name>"}
  streams-*.json    {"<activity id>": {"time": [...], "latlng": [...], "altitude": [...], "heartrate": [...]}}
                    only for activities whose Strava version differs from the other copies (cropped)

  python -m streetnav_server.strava_import EXPORT_DIR [--dry-run]
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from datetime import datetime, timedelta

from .registry import ActivityCopy, connect, record_run, upsert

CYCLING = {"Ride", "EBikeRide", "EMountainBikeRide", "GravelRide", "MountainBikeRide", "VirtualRide",
           "Velomobile", "Handcycle"}
SPORTS = {"Run": "running", "TrailRun": "running", "VirtualRun": "running", "Walk": "walking",
          "Hike": "hiking", "Swim": "swimming", "AlpineSki": "skiing", "BackcountrySki": "skiing",
          "NordicSki": "skiing", "Snowboard": "skiing", "Workout": "training", "WeightTraining": "training",
          "Crossfit": "training", "HighIntensityIntervalTraining": "training", "Yoga": "training",
          "Pilates": "training", "Elliptical": "training", "StairStepper": "training", "Rowing": "rowing"}


def sport_of(sport_type: str) -> str:
    return "cycling" if sport_type in CYCLING else SPORTS.get(sport_type, "other")


def to_copy(row: dict, gear: dict[str, str], streams: dict | None) -> ActivityCopy:
    started = datetime.strptime(row["start_time"], "%Y-%m-%dT%H:%M:%S%z")
    elapsed = row.get("elapsed_time_raw")
    sport_type = row.get("sport_type") or "Workout"
    gear_id = row.get("bike_id") or row.get("athlete_gear_id")
    points, heart_rate = [], []
    if streams:
        t0 = int(started.timestamp())
        times = streams.get("time") or []
        latlng = streams.get("latlng") or []
        altitude = streams.get("altitude") or []
        for i, t in enumerate(times):
            if i < len(latlng) and latlng[i]:
                points.append((latlng[i][1], latlng[i][0], altitude[i] if i < len(altitude) else None, t0 + t))
        heart_rate = [(t0 + t, int(b)) for t, b in zip(times, streams.get("heartrate") or []) if b]
    bpm = [b for _, b in heart_rate]
    # Strava reports 0 m for activities without a route: that is "unknown", not a distance.
    distance = row.get("distance_raw") or None
    return ActivityCopy(
        source="strava", external_id=str(row["id"]), started_at=started, sport=sport_of(sport_type),
        ended_at=started + timedelta(seconds=elapsed) if elapsed else None,
        indoor=bool(row.get("trainer")) or sport_type.startswith("Virtual"),
        distance_m=distance, duration_s=elapsed, moving_s=row.get("moving_time_raw"),
        elevation_gain_m=row.get("elevation_gain_raw") if distance else None,
        avg_hr=sum(bpm) / len(bpm) if bpm else None, max_hr=max(bpm) if bpm else None,
        name=row.get("name"), description=row.get("description"), sport_type=sport_type,
        commute=row.get("commute"), gear=gear.get(str(gear_id)) if gear_id else None,
        points=points, heart_rate=heart_rate, raw=row)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("export_dir")
    parser.add_argument("--dry-run", action="store_true", help="report what would happen, write nothing")
    args = parser.parse_args()
    with open(os.path.join(args.export_dir, "activities.json")) as f:
        rows = json.load(f)
    with open(os.path.join(args.export_dir, "gear.json")) as f:
        gear = json.load(f)
    streams: dict[str, dict] = {}
    for path in sorted(glob.glob(os.path.join(args.export_dir, "streams-*.json"))):
        with open(path) as f:
            streams.update(json.load(f))

    counts = {"created": 0, "merged": 0, "updated": 0, "errors": 0, "skipped": 0}
    created = []
    with connect() as conn:
        for row in sorted(rows, key=lambda r: r["start_time"]):
            try:
                activity_id, outcome = upsert(conn, to_copy(row, gear, streams.get(str(row["id"]))))
                counts[outcome] += 1
                if outcome == "created":
                    created.append(f"{row['start_time']} {row.get('sport_type')} {row.get('name')!r}")
                if not args.dry_run:
                    conn.commit()
            except Exception as exc:  # one bad activity must not stop the import
                conn.rollback()
                counts["errors"] += 1
                print(f"activity {row.get('id')}: {exc}", file=sys.stderr)
        if args.dry_run:
            conn.rollback()
        else:
            record_run(conn, "strava", counts, f"export of {len(rows)} activities, {len(streams)} tracks")
            conn.commit()
    print("\n".join(["only on Strava:"] + created[:50] + ([f"... {len(created) - 50} more"] if len(created) > 50 else [])))
    print(f"{'dry run' if args.dry_run else 'done'}: {counts}")


if __name__ == "__main__":
    main()
