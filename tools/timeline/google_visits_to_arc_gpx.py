#!/usr/bin/env python3
"""Writes the visits of a Google Maps Timeline GeoJSON (see google_timeline_to_geojson.py) as one GPX file per
month (YYYY-MM.gpx), in the GPX flavour that Arc Timeline exports, so that Arc can import them.

Each visit becomes a waypoint: time = start of the visit, name = Google's semantic type, and the rest (end, duration,
place ID, probabilities) in its description. Arc's importer wanted at least one track per file, so each file also
gets a one-point placeholder track dated 2000-01-01.

  python3 google_visits_to_arc_gpx.py visits.geojson OUTPUT_DIR [--placeholder LAT,LON]
"""
import argparse
import json
import re
from collections import defaultdict
from pathlib import Path

CREATOR = "Arc App"


def parse_iso(dt: str) -> str:
    # Google: 2023-07-29T15:00:00.000+02:00 -> 2023-07-29T15:00:00+02:00
    return re.sub(r"\.\d{1,6}", "", dt)


def escape_xml(s: str) -> str:
    return (s.replace("&", "&amp;")
             .replace("<", "&lt;")
             .replace(">", "&gt;")
             .replace('"', "&quot;")
             .replace("'", "&apos;"))


def month_key(iso: str) -> str:
    return iso[:7]  # 2023-07-29T15:00:00+02:00 -> 2023-07


def build_wpt(lat: float, lon: float, start_iso: str, props: dict) -> str:
    end = props.get("endTime")
    duration_s = props.get("duration_s")
    place_id = props.get("placeID")
    semantic = props.get("semanticType") or "Visit"
    visit_prob = props.get("visit_probability")
    top_prob = props.get("topCandidate_probability")
    hierarchy = props.get("hierarchyLevel")

    end_iso = parse_iso(end) if end else ""

    # Arc usually shows the description in the visit details: keep what is useful there.
    desc_parts = ["source=google_timeline"]
    if end_iso:
        desc_parts.append(f"end={end_iso}")
    if duration_s is not None:
        desc_parts.append(f"duration_s={duration_s}")
    if place_id:
        desc_parts.append(f"placeID={place_id}")
    if hierarchy is not None:
        desc_parts.append(f"hierarchyLevel={hierarchy}")
    if visit_prob is not None:
        desc_parts.append(f"visit_prob={visit_prob}")
    if top_prob is not None:
        desc_parts.append(f"top_prob={top_prob}")

    return f'''  <wpt lat="{lat}" lon="{lon}">
    <time>{escape_xml(start_iso)}</time>
    <name>{escape_xml(semantic)}</name>
    <desc>{escape_xml(" | ".join(desc_parts))}</desc>
  </wpt>'''


def write_gpx(out_path: Path, wpts: list[str], placeholder: tuple[float, float]) -> None:
    placeholder_trk = f"""  <trk>
    <name>google_timeline_placeholder</name>
    <type>walking</type>
    <trkseg>
      <trkpt lat="{placeholder[0]}" lon="{placeholder[1]}">
        <time>2000-01-01T00:00:00+01:00</time>
      </trkpt>
    </trkseg>
  </trk>"""

    gpx = f'''<?xml version="1.0" encoding="utf-8" standalone="no"?>
<gpx creator="{escape_xml(CREATOR)}" version="1.1"
  xmlns="http://www.topografix.com/GPX/1/1"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
{chr(10).join(wpts)}
{placeholder_trk}
</gpx>
'''
    out_path.write_text(gpx, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("geojson", type=Path, help="visits GeoJSON from google_timeline_to_geojson.py")
    parser.add_argument("output_dir", type=Path, help="where the monthly GPX files are written")
    parser.add_argument("--placeholder", default="0,0", metavar="LAT,LON",
                        help="position of the placeholder track point (default 0,0)")
    args = parser.parse_args()
    placeholder = tuple(float(v) for v in args.placeholder.split(","))

    if not args.geojson.exists():
        raise FileNotFoundError(f"Input GeoJSON not found: {args.geojson}")
    args.output_dir.mkdir(parents=True, exist_ok=True)

    data = json.loads(args.geojson.read_text(encoding="utf-8"))
    features = data.get("features", [])
    if not isinstance(features, list):
        raise ValueError("GeoJSON format unexpected: 'features' is not a list")

    buckets: dict[str, list[str]] = defaultdict(list)  # "YYYY-MM" -> waypoints
    kept = skipped = 0
    for f in features:
        geom = (f or {}).get("geometry") or {}
        coords = geom.get("coordinates") or []
        props = (f or {}).get("properties") or {}
        start = props.get("startTime")
        if geom.get("type") != "Point" or len(coords) < 2 or not start:
            skipped += 1
            continue
        lon, lat = coords[0], coords[1]
        start_iso = parse_iso(start)
        buckets[month_key(start_iso)].append(build_wpt(lat, lon, start_iso, props))
        kept += 1

    for key in sorted(buckets):
        write_gpx(args.output_dir / f"{key}.gpx", buckets[key], placeholder)

    print(f"Input: {args.geojson}")
    print(f"Output dir: {args.output_dir}")
    print(f"Waypoints kept: {kept}")
    print(f"Items skipped: {skipped}")
    print(f"Files written: {len(buckets)}")


if __name__ == "__main__":
    main()
