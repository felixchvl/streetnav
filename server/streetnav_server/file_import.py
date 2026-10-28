"""Imports a folder of activity files (FIT, GPX, TCX, maybe gzipped) into the registry, source "file".

Made for the FIT files HealthFit exports from Apple Health (every Apple Watch workout, and those other apps wrote
to Health), named "YYYY-MM-DD-HHMMSS-<workout type>-<app or device>.fit": the workout type becomes the name and the
app or device the copy's device. A copy's id is its path relative to the folder. FIT files carry a session summary
(sport, durations, distance, calories, heart rate, ascent); for GPX and TCX they are computed from the samples.

  python -m streetnav_server.file_import DIR [--dry-run | --check-only]
"""
from __future__ import annotations

import argparse
import math
import os
import re
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone

from .activity_files import read_file, utc_seconds
from .registry import ActivityCopy, connect, record_run, upsert

EXTENSIONS = (".fit", ".gpx", ".tcx", ".fit.gz", ".gpx.gz", ".tcx.gz")
HEALTHFIT_NAME = re.compile(r"^\d{4}-\d{2}-\d{2}-\d{6}-(?P<type>.+)-(?P<device>[^-]+)$")
# FIT (sport, sub_sport) -> (registry sport, Strava-style sport type); sub_sport None matches any.
FIT_SPORTS = {
    ("cycling", "e_bike_fitness"): ("cycling", "EBikeRide"), ("cycling", "e_bike_mountain"): ("cycling", "EMountainBikeRide"),
    ("e_biking", None): ("cycling", "EBikeRide"), ("cycling", "indoor_cycling"): ("cycling", "VirtualRide"),
    ("cycling", "mountain"): ("cycling", "MountainBikeRide"), ("cycling", "gravel_cycling"): ("cycling", "GravelRide"),
    ("cycling", None): ("cycling", "Ride"), ("running", "trail"): ("running", "TrailRun"),
    ("running", None): ("running", "Run"), ("walking", None): ("walking", "Walk"), ("hiking", None): ("hiking", "Hike"),
    ("swimming", None): ("swimming", "Swim"), ("training", "strength_training"): ("training", "WeightTraining"),
    ("training", None): ("training", "Workout"), ("fitness_equipment", None): ("training", "Workout"),
    ("alpine_skiing", None): ("skiing", "AlpineSki"), ("cross_country_skiing", None): ("skiing", "NordicSki"),
    ("snowboarding", None): ("skiing", "Snowboard"), ("rowing", None): ("rowing", "Rowing"),
    ("rock_climbing", None): ("other", "RockClimbing"), ("soccer", None): ("other", "Soccer"),
    ("golf", None): ("other", "Golf"),
}
INDOOR_SUB_SPORTS = {"indoor_cycling", "treadmill", "indoor_running", "indoor_walking", "indoor_rowing", "spin",
                     "virtual_activity"}


def sport_of(sport, sub_sport) -> tuple[str, str]:
    sport, sub_sport = str(sport or "generic"), str(sub_sport or "generic")
    return FIT_SPORTS.get((sport, sub_sport)) or FIT_SPORTS.get((sport, None)) or ("other", "Workout")


def metres(a: tuple, b: tuple) -> float:
    lon1, lat1, lon2, lat2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    return 6_371_000 * math.hypot((lon2 - lon1) * math.cos((lat1 + lat2) / 2), lat2 - lat1)


def to_copy(root: str, path: str) -> ActivityCopy:
    rel = os.path.relpath(path, root)
    samples, session = read_file(path)
    points = [(lon, lat, alt, t) for t, lon, lat, alt, _ in samples if lon is not None and lat is not None]
    heart_rate = [(t, int(bpm)) for t, *_, bpm in samples if bpm]
    bpm = [b for _, b in heart_rate]

    stem = os.path.basename(path)
    for ext in EXTENSIONS:
        if stem.lower().endswith(ext):
            stem = stem[: -len(ext)]
            break
    named = HEALTHFIT_NAME.match(stem)

    if session.get("start_time"):
        started = datetime.fromtimestamp(utc_seconds(session["start_time"]), timezone.utc)
    elif samples:
        started = datetime.fromtimestamp(samples[0][0], timezone.utc)
    else:
        raise ValueError("no start time (no session, no sample)")
    elapsed = session.get("total_elapsed_time") or (samples[-1][0] - samples[0][0] if len(samples) > 1 else None)
    distance = session.get("total_distance")
    if distance is None and len(points) > 1:
        distance = sum(metres(a, b) for a, b in zip(points, points[1:]))
    sport, sport_type = sport_of(session.get("sport"), session.get("sub_sport"))
    if named and "indoor" in named["type"].lower():
        indoor = True
    else:
        indoor = True if str(session.get("sub_sport")) in INDOOR_SUB_SPORTS else None

    return ActivityCopy(
        source="file", external_id=rel, started_at=started, sport=sport,
        ended_at=started + timedelta(seconds=elapsed) if elapsed else None, indoor=indoor,
        distance_m=distance or None, duration_s=elapsed, moving_s=session.get("total_timer_time"),
        calories=session.get("total_calories"),
        avg_hr=session.get("avg_heart_rate") or (sum(bpm) / len(bpm) if bpm else None),
        max_hr=session.get("max_heart_rate") or (max(bpm) if bpm else None),
        elevation_gain_m=session.get("total_ascent"),
        name=named["type"] if named else None, sport_type=sport_type,
        points=points, heart_rate=heart_rate, device=named["device"] if named else None,
        raw={"file": rel, "sport": str(session.get("sport")) if session else None,
             "sub_sport": str(session.get("sub_sport")) if session else None, "samples": len(samples)})


def find_files(root: str) -> list[str]:
    found = []
    for dirpath, _, names in os.walk(root):
        found += [os.path.join(dirpath, n) for n in names if n.lower().endswith(EXTENSIONS)]
    return sorted(found)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("folder", help="folder holding the activity files (searched recursively)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="run against the database, then roll back")
    mode.add_argument("--check-only", action="store_true", help="read the files, no database")
    args = parser.parse_args()
    files = find_files(args.folder)

    report: Counter = Counter()
    created: list[str] = []
    conn = None if args.check_only else connect()
    try:
        for path in files:
            try:
                copy = to_copy(args.folder, path)
                report["with track" if len(copy.points) >= 2 else "without track"] += 1
                if conn is None:
                    continue
                _, outcome = upsert(conn, copy)
                report[outcome] += 1
                if outcome == "created":
                    created.append(f"{copy.started_at:%Y-%m-%d %H:%M} {copy.sport_type} {copy.name!r} ({copy.device})")
                if not args.dry_run:
                    conn.commit()
            except Exception as exc:  # one bad file must not stop the import
                if conn is not None:
                    conn.rollback()
                report["errors"] += 1
                print(f"{os.path.relpath(path, args.folder)}: {exc!r}", file=sys.stderr)
        if conn is not None:
            if args.dry_run:
                conn.rollback()
            else:
                record_run(conn, "file", report, f"{len(files)} files from {os.path.basename(os.path.normpath(args.folder))}")
                conn.commit()
    finally:
        if conn is not None:
            conn.close()

    if created:
        print("\n".join(["only in the files:"] + created[:60] + ([f"... {len(created) - 60} more"] if len(created) > 60 else [])))
    label = "check only" if args.check_only else "dry run" if args.dry_run else "done"
    print(f"{label}: {len(files)} files, {dict(sorted(report.items()))}")


if __name__ == "__main__":
    main()
