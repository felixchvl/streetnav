# Timeline ("Trace continue")

**Goal:** one continuous, private history of everywhere I have been, with no gap between the years recorded
by Google Maps Timeline and the months recorded by [Arc Timeline](https://www.bigpaua.com/arcapp/). The project was
called *Trace continue* ("continuous trace") in my notes. Status: idea, paused. Only the code lives here: the
location data never goes into git.

## Why it belongs to Streetnav

Streetnav is about the streets I have not ridden yet, so it first needs to know where I have already been. Rides come
from Strava, Ride with GPS and Apple Health (see `server/`), but walks, trips by other means and older years only
exist in location history. Trace continue was the first attempt to gather that history in one place, before Streetnav
had its own database. Arc Timeline, the app it relies on, later also helped rebuild bike rides that the Apple Watch
had lost (see the WorkoutRescue project).

## History

| When | What happened |
|---|---|
| 2025-10-27 | First script (`timelineToQGIS.py`, now `google_timeline_to_geojson.py`): the Google Maps Timeline export, taken from the phone, becomes a GeoJSON of visited places to look at in QGIS. |
| November 2025 | Arc Timeline is recording day to day (its sample exports start then): more private, its data stays on the phone and in iCloud. |
| 2025-12-21 | Field-by-field comparison of the Google export with Arc's JSON and GPX exports. GPX is chosen (the files were named `…_CHOISI`, "chosen"): Arc's JSON needs fields Google does not have. `GmapsGeoJSON_vers_ArcGPX_CHOISI.py`, now `google_visits_to_arc_gpx.py`, writes one GPX file per month, July 2023 to October 2025, into Arc's iCloud import folder. |
| 2026-04-22 | The monthly files sit in an Arc folder named "GPX à importer (Gmaps prob)" ("GPX to import, Google Maps problem"): the import apparently never went through. The reason was not written down. |
| 2026-07 | The working folder is renamed `trace-continue` and gets a project note in Obsidian. |
| 2026-10-28 | The scripts move here, with their hard-coded paths turned into arguments. Run on the original export with the original placeholder position, they produce byte-identical monthly files. |

## Scripts

```bash
python3 google_timeline_to_geojson.py location-history.json visits.geojson
python3 google_visits_to_arc_gpx.py visits.geojson OUTPUT_DIR [--placeholder LAT,LON]
```

- `google_timeline_to_geojson.py` keeps the **visits** of the export: one point per visit with its start, end,
  duration, Google place ID, semantic type and probabilities.
- `google_visits_to_arc_gpx.py` writes those visits as waypoints in GPX files shaped like Arc's own exports, one per
  month (`YYYY-MM.gpx`). The details go into each waypoint's description. Arc's importer wanted at least one track
  per file, so each file also holds a one-point placeholder track dated 2000-01-01; `--placeholder` sets where it
  is (0,0 by default).

## Formats (fictional values)

Google Maps Timeline item, and the GeoJSON feature made from it:

```json
{"startTime": "2024-05-04T10:00:00.000+02:00", "endTime": "2024-05-04T10:45:00.000+02:00",
 "visit": {"hierarchyLevel": "0", "probability": "0.95",
           "topCandidate": {"probability": "0.90", "semanticType": "Unknown", "placeID": "ChIJ-example",
                            "placeLocation": "geo:48.858400,2.294500"}}}
```

```json
{"type": "Feature", "geometry": {"type": "Point", "coordinates": [2.2945, 48.8584]},
 "properties": {"startTime": "2024-05-04T10:00:00.000+02:00", "endTime": "2024-05-04T10:45:00.000+02:00",
                "duration_s": 2700, "placeID": "ChIJ-example", "semanticType": "Unknown",
                "topCandidate_probability": 0.9, "visit_probability": 0.95, "hierarchyLevel": "0"}}
```

Arc's JSON export describes each sample with `timelineItemId`, `movingState`, accuracies, speed and course, which
Google's visits do not have: only the time and the position match. Arc's GPX export is simpler (tracks typed
`stationary`, `walking`…, points with elevation and time), hence the choice of GPX.

## Limits

- Google's export has **places, not paths**: the trace is continuous in time, not in space.
- Whether Arc accepts waypoint-only GPX files as visits was never confirmed (see 2026-04-22).
- A later step could store these visits in the Streetnav database next to the activities, instead of in Arc.
