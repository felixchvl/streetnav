"""Strava archive import, without a database: python -m unittest discover -s tests (from server/)."""
import csv
import os
import tempfile
import unittest
from collections import Counter
from datetime import datetime, timedelta, timezone

from streetnav_server import strava_import as si

T0 = datetime(2026, 10, 28, 9, 2, 20, tzinfo=timezone.utc)
HEADER = ["Activity ID", "Activity Date", "Activity Name", "Activity Type", "Activity Description", "Elapsed Time",
          "Distance", "Max Heart Rate", "Commute", "Activity Gear", "Filename", "Elapsed Time", "Moving Time",
          "Distance", "Elevation Gain", "Max Heart Rate", "Average Heart Rate", "Calories"]


def gpx(points):
    """points: (seconds after T0, lat, lon, bpm)."""
    trkpts = "".join(
        f'<trkpt lat="{lat}" lon="{lon}"><ele>35.0</ele>'
        f'<time>{(T0 + timedelta(seconds=s)).strftime("%Y-%m-%dT%H:%M:%SZ")}</time>'
        f'<extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>{bpm}</gpxtpx:hr></gpxtpx:TrackPointExtension>'
        f'</extensions></trkpt>' for s, lat, lon, bpm in points)
    return ('  <?xml version="1.0" encoding="UTF-8"?>\n<gpx xmlns="http://www.topografix.com/GPX/1/1" '
            'xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1"><trk><trkseg>'
            f'{trkpts}</trkseg></trk></gpx>')


class ArchiveTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.archive = self.dir.name
        os.mkdir(os.path.join(self.archive, "activities"))
        # A 50 s recording, cropped on Strava to 30 s starting 10 s in.
        self.recorded = [(s, round(48.85 + s / 10000, 6), 2.35, 100 + s) for s in range(0, 60, 10)]
        with open(os.path.join(self.archive, "activities", "1.gpx"), "w") as f:
            f.write(gpx(self.recorded))
        start = (T0 + timedelta(seconds=10)).strftime(si.CSV_DATE).replace(" 0", " ")
        rows = [["1", start, "Commute", "E-Bike Ride", "", "30", "0.11", "140", "true", "Véligo 2", "activities/1.gpx",
                 "30.0", "28.0", "111.2", "3.0", "140.0", "120.0", "12"],
                ["2", start, "Gym", "Weight Training", "", "3600", "0", "", "false", "", "", "3600.0", "3600.0",
                 "0.0", "", "150.0", "110.0", "300"]]
        with open(os.path.join(self.archive, "activities.csv"), "w", newline="", encoding="utf-8") as f:
            csv.writer(f).writerows([HEADER] + rows)
        self.rows = si.read_csv(self.archive)

    def tearDown(self):
        self.dir.cleanup()

    def copy(self, row, web=None):
        report, notes = Counter(), []
        return si.to_copy(row, self.archive, web, report, notes), report, notes

    def test_sport_types(self):
        self.assertEqual(si.sport_type_of("E-Bike Ride"), "EBikeRide")
        self.assertEqual(si.sport_type_of("Weight Training"), "WeightTraining")
        self.assertEqual(si.sport_type_of("Football (Soccer)"), "Soccer")
        self.assertEqual(si.sport_of("EBikeRide"), "cycling")

    def test_track_is_cut_to_the_strava_window(self):
        copy, _, _ = self.copy(self.rows[0])
        self.assertEqual(copy.started_at, T0 + timedelta(seconds=10))
        self.assertEqual([p[3] - int(T0.timestamp()) for p in copy.points], [10, 20, 30, 40])
        self.assertEqual(copy.points[0][:2], (2.35, 48.851))
        self.assertEqual(copy.heart_rate[0], (int(T0.timestamp()) + 10, 110))
        self.assertEqual((copy.avg_hr, copy.max_hr), (125, 140))
        self.assertEqual((copy.duration_s, copy.distance_m, copy.moving_s), (30.0, 111.2, 28.0))
        self.assertEqual((copy.sport, copy.sport_type, copy.commute, copy.gear), ("cycling", "EBikeRide", True, "Véligo 2"))
        self.assertEqual(copy.raw["Elapsed Time #2"], "30.0")

    def test_activity_without_file(self):
        copy, _, _ = self.copy(self.rows[1])
        self.assertEqual((copy.points, copy.sport, copy.distance_m, copy.avg_hr, copy.max_hr, copy.commute, copy.gear),
                         ([], "training", None, 110.0, 150.0, False, None))

    def test_tcx(self):
        tcx = ('<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"><Activities>'
               '<Activity><Lap><Track><Trackpoint><Time>2026-10-28T09:02:30Z</Time><Position><LatitudeDegrees>48.8'
               '</LatitudeDegrees><LongitudeDegrees>2.3</LongitudeDegrees></Position><AltitudeMeters>40</AltitudeMeters>'
               '<HeartRateBpm><Value>131</Value></HeartRateBpm></Trackpoint></Track></Lap></Activity></Activities>'
               '</TrainingCenterDatabase>')
        self.assertEqual(si.xml_samples(tcx.encode()), [(int(T0.timestamp()) + 10, 2.3, 48.8, 40.0, 131)])

    def test_website_check(self):
        cropped = [p for p in self.recorded if 10 <= p[0] <= 40]
        stream = {"time": [s - 10 for s, *_ in cropped], "latlng": [[lat, lon] for _, lat, lon, _ in cropped]}
        web_row = {"id": 1, "name": "Commute", "sport_type": "EBikeRide", "commute": True, "elapsed_time_raw": 30,
                   "bike_id": 7}
        copy, report, notes = self.copy(self.rows[0], ({"1": web_row}, {"7": "Véligo 2"}, {"1": stream}))
        self.assertEqual(report, Counter({"check: track matches website": 1}))
        self.assertEqual(len(copy.points), 4)

        moved = {"time": [0, 30], "latlng": [[48.86, 2.35], [48.87, 2.35]]}
        web_row = dict(web_row, commute=False)
        copy, report, notes = self.copy(self.rows[0], ({"1": web_row}, {"7": "Véligo 2"}, {"1": moved}))
        self.assertEqual(report, Counter({"check: track differs, website trace kept": 1, "check: commute differs": 1}))
        self.assertEqual([p[:2] for p in copy.points], [(2.35, 48.86), (2.35, 48.87)])
        self.assertEqual(copy.heart_rate[0][1], 110)  # the website trace had none: the archive's is kept


if __name__ == "__main__":
    unittest.main()
