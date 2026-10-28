"""Imports Ride with GPS trips into the registry (read-only on Ride with GPS).

  python -m streetnav_server.rwgps_sync          new trips only (stops at the first fully known page)
  python -m streetnav_server.rwgps_sync --full   every trip (first load), already known ones skipped
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from urllib import error, parse, request

from .registry import ActivityCopy, connect, record_run, upsert

API = "https://ridewithgps.com/api/v1"
PAUSE_S = 0.5  # between trip downloads, to stay gentle with their servers


def get(path: str, params: dict | None = None) -> dict:
    url = API + path + ("?" + parse.urlencode(params) if params else "")
    req = request.Request(url, headers={"x-rwgps-api-key": os.environ["RWGPS_API_KEY"],
                                        "x-rwgps-auth-token": os.environ["RWGPS_AUTH_TOKEN"],
                                        "Accept": "application/json"})
    for attempt in range(4):
        try:
            with request.urlopen(req, timeout=60) as resp:
                return json.loads(resp.read().decode())
        except error.HTTPError as exc:
            if exc.code in (429, 500, 502, 503, 504) and attempt < 3:
                time.sleep(10 * (attempt + 1))
                continue
            raise
        except error.URLError:
            if attempt < 3:
                time.sleep(10 * (attempt + 1))
                continue
            raise
    raise RuntimeError("unreachable")


def to_copy(trip: dict) -> ActivityCopy:
    category = (trip.get("activity_type") or "other:generic").split(":")[0]
    sport = {"snow": "skiing"}.get(category, category)
    points, heart_rate = [], []
    for p in trip.get("track_points") or []:
        if p.get("t") is None:
            continue
        if p.get("x") is not None and p.get("y") is not None:
            points.append((p["x"], p["y"], p.get("e"), int(p["t"])))
        if p.get("h"):
            heart_rate.append((int(p["t"]), int(p["h"])))
    started = datetime.fromisoformat(trip["departed_at"].replace("Z", "+00:00"))
    duration = trip.get("duration")
    raw = {k: v for k, v in trip.items() if k not in ("track_points", "photos", "collections")}
    return ActivityCopy(
        source="rwgps", external_id=str(trip["id"]), started_at=started, sport=sport,
        ended_at=datetime.fromtimestamp(started.timestamp() + duration, timezone.utc) if duration else None,
        indoor=bool(trip.get("stationary")) if trip.get("stationary") is not None else None,
        distance_m=trip.get("distance"), duration_s=duration, moving_s=trip.get("moving_time"),
        calories=trip.get("calories"), avg_hr=trip.get("avg_hr"), max_hr=trip.get("max_hr"),
        elevation_gain_m=trip.get("elevation_gain"), points=points, heart_rate=heart_rate,
        device=(trip.get("device") or {}).get("name") if isinstance(trip.get("device"), dict) else trip.get("device"),
        raw=raw)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--full", action="store_true", help="walk every page (first load)")
    args = parser.parse_args()
    counts = {"created": 0, "merged": 0, "updated": 0, "errors": 0, "skipped": 0}
    with connect() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT external_id, raw->>'updated_at' FROM activity_source WHERE source = 'rwgps'")
            known = dict(cur.fetchall())
        page = 1
        while True:
            data = get("/trips.json", {"page": page, "page_size": 200})
            trips = data.get("trips", [])
            fresh = [t for t in trips if known.get(str(t["id"])) != t.get("updated_at")]
            for summary in fresh:
                try:
                    detail = get(f"/trips/{summary['id']}.json")
                    activity_id, outcome = upsert(conn, to_copy(detail.get("trip", detail)))
                    conn.commit()
                    counts[outcome] += 1
                except Exception as exc:  # one bad trip must not stop the import
                    conn.rollback()
                    counts["errors"] += 1
                    print(f"trip {summary.get('id')}: {exc}", file=sys.stderr)
                time.sleep(PAUSE_S)
            counts["skipped"] += len(trips) - len(fresh)
            pages = data.get("meta", {}).get("pagination", {}).get("page_count") or 1
            print(f"page {page}/{pages}: {len(fresh)} new or changed, counts={counts}", flush=True)
            if page >= pages or (not fresh and not args.full):
                break
            page += 1
        record_run(conn, "rwgps", counts, "full" if args.full else "incremental")
        conn.commit()
    print(f"done: {counts}")


if __name__ == "__main__":
    main()
