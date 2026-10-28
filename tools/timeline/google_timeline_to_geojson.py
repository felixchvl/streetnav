#!/usr/bin/env python3
"""Turns a Google Maps Timeline export into a GeoJSON of visited places (one point per visit), e.g. for QGIS.

The input is the on-device export of Google Maps (a JSON list of timeline items). Only the visits are kept:
the export has no recorded paths between them.

  python3 google_timeline_to_geojson.py location-history.json [visits.geojson]
"""
import argparse
import json
import re
from datetime import datetime
from pathlib import Path

GEO_RE = re.compile(r"^geo:(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)$")  # "geo:lat,lon"


def parse_iso(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))  # offsets like +02:00 included
    except Exception:
        return None


def to_features(items):
    features = []
    for item in items:
        visit = item.get("visit", {})
        tc = visit.get("topCandidate", {})
        place_loc = tc.get("placeLocation")
        if not place_loc:
            continue
        m = GEO_RE.match(place_loc.strip())
        if not m:
            continue
        lat, lon = float(m.group(1)), float(m.group(2))

        start_raw = item.get("startTime")
        end_raw = item.get("endTime")
        dt_start = parse_iso(start_raw) if start_raw else None
        dt_end = parse_iso(end_raw) if end_raw else None
        duration_s = int((dt_end - dt_start).total_seconds()) if dt_start and dt_end else None

        features.append({
            "type": "Feature",
            "geometry": {"type": "Point", "coordinates": [lon, lat]},
            "properties": {
                "startTime": start_raw,
                "endTime": end_raw,
                "duration_s": duration_s,
                "placeID": tc.get("placeID"),
                "semanticType": tc.get("semanticType"),
                "topCandidate_probability": float(tc.get("probability")) if tc.get("probability") else None,
                "visit_probability": float(visit.get("probability")) if visit.get("probability") else None,
                "hierarchyLevel": visit.get("hierarchyLevel"),
            },
        })
    return features


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("timeline_json", type=Path, help="Google Maps Timeline export (JSON list)")
    parser.add_argument("output", type=Path, nargs="?", help="default: LocationHistory_visits.geojson next to the input")
    args = parser.parse_args()
    output = args.output or args.timeline_json.with_name("LocationHistory_visits.geojson")

    with args.timeline_json.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, list):
        raise SystemExit("Expected a JSON list of timeline items (Google Maps Timeline export).")

    features = to_features(data)
    with output.open("w", encoding="utf-8") as f:
        json.dump({"type": "FeatureCollection", "features": features}, f, ensure_ascii=False)
    print(f"Written: {output} | {len(features)} visits")


if __name__ == "__main__":
    main()
