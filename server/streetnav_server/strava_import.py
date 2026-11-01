"""Imports Strava's official account archive into the registry.

Strava's API is subscriber-only, but any athlete can download their archive
(strava.com/athlete/download_my_account). Only two parts of it are read; the rest holds logins,
contacts and messages, so copy just these to the server:
  activities.csv   one row per activity as edited on Strava: name, sport type, commute flag, gear,
                   cropped elapsed time and distance. Column names and dates are parsed in English,
                   Strava's display language when the archive is requested.
  activities/      the files as first uploaded (FIT, GPX or TCX, maybe gzipped). Crops are not
                   applied to them, but a Strava crop is a time window, so the samples are cut to
                   [start, start + elapsed time] of the CSV row.

--check-web DIR compares the result with the export read from the website (activities.json,
gear.json, streams-*.json): metadata differences are reported, and when an archive track does not
match the website trace (Strava's current state), the website trace is kept.

Each version is kept in bronze as three parts: activities.csv (stored once, shared by every version),
its original file, and the website streams file holding its trace, if any.

  python -m streetnav_server.strava_import ARCHIVE_DIR [--check-web DIR] [--batch NAME] [--dry-run | --check-only]
"""
from __future__ import annotations

import argparse
import csv
import glob
import io
import json
import math
import os
import re
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone

from . import bronze
from .activity_files import read_bytes
from .bronze import RawPart, sha256
from .registry import ActivityCopy, connect, ingest, record_run

CYCLING = {"Ride", "EBikeRide", "EMountainBikeRide", "GravelRide", "MountainBikeRide", "VirtualRide",
           "Velomobile", "Handcycle"}
SPORTS = {"Run": "running", "TrailRun": "running", "VirtualRun": "running", "Walk": "walking",
          "Hike": "hiking", "Swim": "swimming", "AlpineSki": "skiing", "BackcountrySki": "skiing",
          "NordicSki": "skiing", "Snowboard": "skiing", "Workout": "training", "WeightTraining": "training",
          "Crossfit": "training", "HighIntensityIntervalTraining": "training", "Yoga": "training",
          "Pilates": "training", "Elliptical": "training", "StairStepper": "training", "Rowing": "rowing"}
# The CSV holds display names; most are the sport type with its spaces removed ("E-Bike Ride").
DISPLAY_TYPES = {"Football (Soccer)": "Soccer", "Rock Climb": "RockClimbing", "HIIT": "HighIntensityIntervalTraining"}
CSV_DATE = "%b %d, %Y, %I:%M:%S %p"  # UTC, e.g. "Oct 28, 2026, 9:02:30 AM"
SAME_TRACE_M = 50                    # website and archive tracks must start and end this close


def sport_of(sport_type: str) -> str:
    return "cycling" if sport_type in CYCLING else SPORTS.get(sport_type, "other")


def sport_type_of(display: str) -> str:
    return DISPLAY_TYPES.get(display) or re.sub(r"[^A-Za-z]", "", display) or "Workout"


class Row:
    """A line of activities.csv, which repeats some headers (summary value first, detailed one second)."""

    def __init__(self, header: list[str], values: list[str]):
        self.cells: dict[str, list[str]] = {}
        for name, value in zip(header, values):
            self.cells.setdefault(name, []).append(value.strip())

    def text(self, name: str, nth: int = 0) -> str | None:
        values = self.cells.get(name, [])
        return (values[nth] or None) if nth < len(values) else None

    def number(self, *names: tuple[str, int]) -> float | None:
        """First non-empty value among (name, nth) pairs."""
        for name, nth in names:
            value = self.text(name, nth)
            if value is not None:
                return float(value.replace(",", ""))
        return None

    def raw(self) -> dict[str, str]:
        out = {}
        for name, values in self.cells.items():
            for i, value in enumerate(values):
                if value:
                    out[name if i == 0 else f"{name} #{i + 1}"] = value
        return out


def parse_csv(data: bytes) -> list[Row]:
    reader = csv.reader(io.StringIO(data.decode("utf-8"), newline=""))
    header = next(reader)
    missing = {"Activity ID", "Activity Date", "Activity Type", "Elapsed Time", "Filename"} - set(header)
    if missing:
        raise SystemExit(f"activities.csv lacks {sorted(missing)}: request the archive with Strava in English")
    return [Row(header, values) for values in reader]


def read_csv(archive_dir: str) -> list[Row]:
    with open(os.path.join(archive_dir, "activities.csv"), "rb") as f:
        return parse_csv(f.read())


_parsed: dict[str, dict] = {}  # sha256 -> rows by activity id, or website streams by activity id


def _cached(part: RawPart, read) -> dict:
    if part.sha256 not in _parsed:
        if len(_parsed) >= 4:
            _parsed.clear()
        _parsed[part.sha256] = read(part.data)
    return _parsed[part.sha256]


# --- website export, used as a check ----------------------------------------------------------

def load_web(web_dir: str) -> tuple[dict[str, dict], dict[str, str], list[tuple[str, bytes, dict]]]:
    """Website rows and gear (checks only), and the streams files: (name, bytes, streams by activity id)."""
    with open(os.path.join(web_dir, "activities.json")) as f:
        rows = {str(r["id"]): r for r in json.load(f)}
    with open(os.path.join(web_dir, "gear.json")) as f:
        gear = json.load(f)
    streams = []
    for path in sorted(glob.glob(os.path.join(web_dir, "streams-*.json"))):
        with open(path, "rb") as f:
            data = f.read()
        streams.append((os.path.basename(path), data, json.loads(data)))
    return rows, gear, streams


def web_track(stream: dict, started: datetime) -> tuple[list, list]:
    t0 = int(started.timestamp())
    times, latlng, altitude = stream.get("time") or [], stream.get("latlng") or [], stream.get("altitude") or []
    points = [(latlng[i][1], latlng[i][0], altitude[i] if i < len(altitude) else None, t0 + t)
              for i, t in enumerate(times) if i < len(latlng) and latlng[i]]
    heart_rate = [(t0 + t, int(b)) for t, b in zip(times, stream.get("heartrate") or []) if b]
    return points, heart_rate


def metres(a: tuple, b: tuple) -> float:
    """Distance between two (lon, lat, ...) points, equirectangular (fine at track scale)."""
    lon1, lat1, lon2, lat2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    return 6_371_000 * math.hypot((lon2 - lon1) * math.cos((lat1 + lat2) / 2), lat2 - lat1)


def same_track(a: list, b: list) -> bool:
    return bool(a and b) and metres(a[0], b[0]) <= SAME_TRACE_M and metres(a[-1], b[-1]) <= SAME_TRACE_M


# --- one activity -----------------------------------------------------------------------------

def parse(external_id: str, parts: dict[str, RawPart]) -> ActivityCopy:
    """A Strava version from its bronze parts: its activities.csv row, its original file (cut to the row's time
    window, which is what a Strava crop is) and, if the website export had it, its website trace, kept when the
    archive track does not match it."""
    row = _cached(parts["csv"], lambda data: {r.text("Activity ID"): r for r in parse_csv(data)})[external_id]
    started = datetime.strptime(row.text("Activity Date"), CSV_DATE).replace(tzinfo=timezone.utc)
    elapsed = row.number(("Elapsed Time", 1), ("Elapsed Time", 0))
    sport_type = sport_type_of(row.text("Activity Type") or "")
    raw = row.raw()

    samples = read_bytes(parts["file"].name, parts["file"].data)[0] if "file" in parts else []
    if elapsed:  # Strava's crop: keep the samples of the edited time window only
        start_s = started.timestamp()
        samples = [s for s in samples if start_s - 1 <= s[0] <= start_s + elapsed + 1]
    points = [(lon, lat, alt, t) for t, lon, lat, alt, _ in samples if lon is not None and lat is not None]
    heart_rate = [(t, int(bpm)) for t, *_, bpm in samples if bpm]

    stream = _cached(parts["web_stream"], json.loads).get(external_id) if "web_stream" in parts else None
    if stream and stream.get("latlng"):
        site_points, site_hr = web_track(stream, started)
        if not same_track(points, site_points):
            points, heart_rate = site_points, site_hr or heart_rate
            raw["track_from"] = "website"

    bpm = [b for _, b in heart_rate]
    distance = row.number(("Distance", 1)) or None  # 0 m means "no route", not a distance
    return ActivityCopy(
        source="strava", external_id=external_id, started_at=started, sport=sport_of(sport_type),
        ended_at=started + timedelta(seconds=elapsed) if elapsed else None,
        indoor=True if sport_type.startswith("Virtual") else None,
        distance_m=distance, duration_s=elapsed, moving_s=row.number(("Moving Time", 0)),
        calories=row.number(("Calories", 0)),
        elevation_gain_m=row.number(("Elevation Gain", 0)) if distance else None,
        avg_hr=sum(bpm) / len(bpm) if bpm else row.number(("Average Heart Rate", 0)),
        max_hr=max(bpm) if bpm else row.number(("Max Heart Rate", 1), ("Max Heart Rate", 0)),
        name=row.text("Activity Name"), description=row.text("Activity Description"), sport_type=sport_type,
        commute=row.text("Commute") == "true" if row.text("Commute") else None, gear=row.text("Activity Gear"),
        points=points, heart_rate=heart_rate, raw=raw)


def check(row: Row, copy: ActivityCopy, web: tuple, report: Counter, notes: list[str]) -> None:
    """Compares a version with the website export."""
    web_rows, web_gear, web_streams = web
    activity_id = row.text("Activity ID")
    w = web_rows.get(activity_id)
    if w is None:
        report["check: not in website export"] += 1
    else:
        gear_id = str(w.get("bike_id") or w.get("athlete_gear_id") or "")
        checks = [("name", row.text("Activity Name") or "", w.get("name") or ""),
                  ("sport type", copy.sport_type, w.get("sport_type")),
                  ("commute", row.text("Commute") == "true", bool(w.get("commute"))),
                  ("elapsed time", round(copy.duration_s or 0), w.get("elapsed_time_raw") or 0)]
        if not gear_id or gear_id in web_gear:  # the website export only names bikes, not shoes
            checks.append(("gear", row.text("Activity Gear"), web_gear.get(gear_id)))
        for field, archive_value, web_value in checks:
            if archive_value != web_value:
                report[f"check: {field} differs"] += 1
                notes.append(f"{activity_id} {field}: archive {archive_value!r}, website {web_value!r}")
    if any((streams.get(activity_id) or {}).get("latlng") for _, _, streams in web_streams):
        if copy.raw.get("track_from") == "website":
            report["check: track differs, website trace kept"] += 1
            notes.append(f"{activity_id} track: website trace kept ({len(copy.points)} points)")
        else:
            report["check: track matches website"] += 1


def version_parts(row: Row, archive_dir: str, csv_data: bytes, web: tuple | None) -> list[tuple[str, str, bytes]]:
    """(part, name, bytes) of a row's version, as kept in bronze."""
    parts = [("csv", "activities.csv", csv_data)]
    if row.text("Filename"):
        with open(os.path.join(archive_dir, row.text("Filename")), "rb") as f:
            parts.append(("file", row.text("Filename"), f.read()))
    for name, data, streams in (web[2] if web else []):
        if (streams.get(row.text("Activity ID")) or {}).get("latlng"):
            parts.append(("web_stream", name, data))
            break
    return parts


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive_dir", help="folder holding activities.csv and activities/")
    parser.add_argument("--check-web", metavar="DIR", help="website export to compare with")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="run against the database, then roll back")
    mode.add_argument("--check-only", action="store_true", help="read and check the files, no database")
    parser.add_argument("--batch", help="name of this import in the bronze index (default: strava-<folder name>)")
    args = parser.parse_args()
    bronze.dry_run = args.dry_run  # a dry run writes no bronze file
    with open(os.path.join(args.archive_dir, "activities.csv"), "rb") as f:
        csv_data = f.read()
    rows = sorted(parse_csv(csv_data), key=lambda r: datetime.strptime(r.text("Activity Date"), CSV_DATE))
    web = load_web(args.check_web) if args.check_web else None
    batch = args.batch or "strava-" + os.path.basename(os.path.normpath(args.archive_dir))

    report: Counter = Counter()
    notes: list[str] = []
    created: list[str] = []
    conn = None if args.check_only else connect()
    try:
        for row in rows:
            try:
                activity_id = row.text("Activity ID")
                parts = version_parts(row, args.archive_dir, csv_data, web)
                if conn is None:
                    copy = parse(activity_id, {p: RawPart(p, name, data, sha256(data)) for p, name, data in parts})
                else:
                    _, outcome, copy = ingest(conn, "strava", activity_id, parts, batch)
                    report[outcome] += 1
                report["with track" if len(copy.points) >= 2 else "without track"] += 1
                if web:
                    check(row, copy, web, report, notes)
                if conn is None:
                    continue
                if outcome == "created":
                    created.append(f"{copy.started_at:%Y-%m-%d %H:%M} {copy.sport_type} {copy.name!r}")
                if not args.dry_run:
                    conn.commit()
            except Exception as exc:  # one bad activity must not stop the import
                if conn is not None:
                    conn.rollback()
                report["errors"] += 1
                print(f"activity {row.text('Activity ID')}: {exc!r}", file=sys.stderr)
        if conn is not None:
            if args.dry_run:
                conn.rollback()
            else:
                record_run(conn, "strava", report,
                           f"archive of {len(rows)} activities, {report['with track']} tracks"
                           + (f", {report['check: track differs, website trace kept']} website traces kept" if web else ""))
                conn.commit()
    finally:
        if conn is not None:
            conn.close()

    if created:
        print("\n".join(["only on Strava:"] + created[:50] + ([f"... {len(created) - 50} more"] if len(created) > 50 else [])))
    if notes:
        print("\n".join(["website check:"] + notes[:40] + ([f"... {len(notes) - 40} more"] if len(notes) > 40 else [])))
    label = "check only" if args.check_only else "dry run" if args.dry_run else "done"
    print(f"{label}: {dict(sorted(report.items()))}")


if __name__ == "__main__":
    main()
