"""Gold rule, without a database: python -m unittest discover -s tests (from server/)."""
import unittest
from datetime import datetime, timedelta, timezone

from streetnav_server import gold
from streetnav_server.registry import ActivityCopy

T0 = datetime(2026, 10, 29, 8, 0, tzinfo=timezone.utc)
LON_PER_M = 1 / 73_300  # at Paris' latitude


def track(*legs, step=5):
    """Points every `step` s for legs of (seconds, metres per second); a 0 speed leg jitters on the spot."""
    t, lon, points = int(T0.timestamp()), 2.35, []
    for seconds, speed in legs:
        for i in range(seconds // step):
            jitter = (3 if i % 2 else -3) * LON_PER_M if speed == 0 else 0
            points.append((lon + jitter, 48.85, 35.0, t))
            lon += speed * step * LON_PER_M
            t += step
    points.append((lon, 48.85, 35.0, t))
    return points


def version(source, external_id, points=(), start=T0, seconds=None, **values):
    seconds = seconds if seconds is not None else (points[-1][3] - points[0][3] if points else 1800)
    values.setdefault("sport", "cycling")
    return ActivityCopy(source=source, external_id=external_id, started_at=start,
                        ended_at=start + timedelta(seconds=seconds), duration_s=seconds, points=list(points),
                        heart_rate=[(p[3], 120 + i % 20) for i, p in enumerate(points)], **values)


RIDE = track((1800, 6))  # 30 min at 21.6 km/h


class ComposeTest(unittest.TestCase):
    def test_measures_from_apple_health_hand_edits_from_strava(self):
        out = gold.compose([
            version("strava", "1", RIDE, start=T0 + timedelta(seconds=5), distance_m=9_900.0, calories=500.0,
                    name="Commute", commute=True, gear="Véligo 2", sport_type="EBikeRide"),
            version("rwgps", "9", RIDE, distance_m=9_800.0),
            version("healthkit", "A", RIDE, distance_m=10_000.0, calories=300.0, name="Vélo (plein air)",
                    sport_type="Ride", indoor=False),
        ])
        self.assertEqual((out["started_at"], out["distance_m"], out["calories"]), (T0, 10_000.0, 300.0))
        self.assertEqual((out["name"], out["commute"], out["gear"], out["sport_type"], out["sport"]),
                         ("Commute", True, "Véligo 2", "EBikeRide", "cycling"))
        self.assertEqual(out["primary_source"], "healthkit")
        self.assertEqual(out["provenance"]["distance_m"], "healthkit:A")
        self.assertEqual(out["provenance"]["name"], "strava:1")
        self.assertNotIn("auto_crop", out["provenance"])

    def test_fills_what_apple_health_lacks(self):
        out = gold.compose([version("healthkit", "A", RIDE, calories=None),
                            version("file", "a.fit", RIDE, calories=310.0)])
        self.assertEqual((out["calories"], out["provenance"]["calories"]), (310.0, "file:a.fit"))

    def test_strava_cropped_by_hand_provides_the_measures(self):
        cropped = [p for p in RIDE if p[3] <= RIDE[0][3] + 1200]
        out = gold.compose([version("healthkit", "A", RIDE, distance_m=10_000.0),
                            version("strava", "1", cropped, distance_m=6_500.0, name="Commute")])
        self.assertEqual((out["ended_at"], out["distance_m"]), (T0 + timedelta(seconds=1200), 6_500.0))
        self.assertEqual((out["primary_source"], out["provenance"]["strava_crop"]), ("strava", True))
        self.assertEqual(len(out["points"]), len(cropped))

    def test_strava_within_15_seconds_is_not_a_crop(self):
        nearly = [p for p in RIDE if p[3] <= RIDE[-1][3] - 10]
        out = gold.compose([version("healthkit", "A", RIDE, distance_m=10_000.0),
                            version("strava", "1", nearly, distance_m=9_950.0)])
        self.assertEqual((out["primary_source"], out["distance_m"]), ("healthkit", 10_000.0))

    def test_strava_without_track_never_wins(self):
        out = gold.compose([version("healthkit", "A", sport="training", seconds=3900, calories=400.0),
                            version("strava", "1", sport="training", seconds=3420, calories=350.0)])
        self.assertEqual((out["duration_s"], out["calories"]), (3900, 400.0))

    def test_within_a_source_the_version_agreeing_with_the_others_comes_first(self):
        # StrongLifts wrote a 20-hour workout 7 min before the real one; HealthFit exported both
        out = gold.compose([version("file", "stronglifts.fit", sport="training", start=T0 - timedelta(minutes=7),
                                    seconds=73_893),
                            version("file", "watch.fit", sport="training", seconds=3_834),
                            version("strava", "1", sport="training", start=T0 + timedelta(seconds=2), seconds=3_830)])
        self.assertEqual((out["started_at"], out["duration_s"]), (T0, 3_834))

    def test_versions_with_a_track_come_first_within_a_source(self):
        out = gold.compose([version("strava", "1", seconds=1800, sport_type="Ride"),
                            version("strava", "2", RIDE, sport_type="EBikeRide")])
        self.assertEqual((out["sport_type"], out["provenance"]["track"]), ("EBikeRide", "strava:2"))


class AutoCropTest(unittest.TestCase):
    def ride(self, points, **values):
        return gold.compose([version("healthkit", "A", points, distance_m=10_000.0, calories=300.0,
                                     elevation_gain_m=50.0, moving_s=len(points) * 5.0, **values)])

    def test_idle_end_is_cut(self):
        points = track((600, 6), (300, 0))  # 10 min riding, then 5 min standing still
        out = self.ride(points)
        self.assertEqual(out["provenance"]["auto_crop"]["head_s"], 0)
        self.assertGreater(out["provenance"]["auto_crop"]["tail_s"], 270)
        self.assertLess(out["ended_at"], T0 + timedelta(seconds=630))
        self.assertTrue(all(p[3] <= out["ended_at"].timestamp() for p in out["points"]))
        self.assertTrue(all(t <= out["ended_at"].timestamp() for t, _ in out["heart_rate"]))
        self.assertAlmostEqual(out["calories"], 300.0 * out["duration_s"] / 900, places=6)
        self.assertLess(out["distance_m"], 10_000.0)
        self.assertEqual(out["duration_s"], (out["ended_at"] - out["started_at"]).total_seconds())

    def test_idle_start_is_cut(self):
        out = self.ride(track((240, 0), (900, 6)))
        self.assertGreater(out["provenance"]["auto_crop"]["head_s"], 200)
        self.assertGreater(out["started_at"], T0 + timedelta(seconds=200))

    def test_short_idle_is_kept(self):
        out = self.ride(track((900, 6), (40, 0)))
        self.assertNotIn("auto_crop", out["provenance"])

    def test_slow_part_that_moves_on_is_kept(self):
        # 5 min walking the bike at 4 km/h: only its last 100 m, around the arrival, count as idle
        points = track((900, 6), (300, 1.1))
        out = self.ride(points)
        walked_away = points[-1][3] - 200 / 1.1  # 200 m before the end
        self.assertGreater(out["ended_at"].timestamp(), walked_away)
        self.assertLess(out["provenance"]["auto_crop"]["tail_s"], 120)

    def test_only_outdoor_rides_from_apple_health_or_ride_with_gps(self):
        points = track((600, 6), (300, 0))
        self.assertNotIn("auto_crop", self.ride(points, indoor=True)["provenance"])
        self.assertNotIn("auto_crop", self.ride(points, sport="running")["provenance"])
        out = gold.compose([version("strava", "1", points)])
        self.assertNotIn("auto_crop", out["provenance"])


if __name__ == "__main__":
    unittest.main()
