"""Bronze, silver and gold against a real PostGIS database that these tests EMPTY.

Skipped unless STREETNAV_TEST_DATABASE_URL points to a throwaway database, e.g.
  STREETNAV_TEST_DATABASE_URL=postgresql://postgres@127.0.0.1:55432/streetnav_test python -m unittest discover -s tests
Bronze files go to a temporary folder.
"""
import hashlib
import json
import os
import stat
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from streetnav_server import bronze, gold, layers, registry
from streetnav_server.registry import ActivityCopy

URL = os.environ.get("STREETNAV_TEST_DATABASE_URL")
T0 = datetime(2026, 10, 29, 8, 0, tzinfo=timezone.utc)


def workout(external_id="A", start=T0, distance=10_000.0, **extra):
    """An Apple Health workout as the iPhone app sends it."""
    t = int(start.timestamp())
    return {"source": "healthkit", "external_id": external_id, "started_at": start.isoformat(),
            "ended_at": (start + timedelta(minutes=30)).isoformat(), "sport": "cycling", "sport_type": "Ride",
            "name": "Vélo (plein air)", "distance_m": distance, "duration_s": 1800.0, "calories": 300.0,
            "points": [[2.35 + i * 0.002, 48.85, 35.0, t + i * 60] for i in range(31)],
            "heart_rate": [[t + i * 60, 120 + i] for i in range(31)], "raw": {"source_app": "Apple Watch"}, **extra}


def strava(external_id="1", start=T0, distance=9_900.0):
    t = int(start.timestamp())
    return ActivityCopy(source="strava", external_id=external_id, started_at=start, sport="cycling",
                        sport_type="EBikeRide", ended_at=start + timedelta(minutes=30), distance_m=distance,
                        name="Commute", commute=True, gear="Véligo 2",
                        points=[(2.35 + i * 0.002, 48.85, 35.0, t + i * 60) for i in range(31)])


@unittest.skipUnless(URL, "STREETNAV_TEST_DATABASE_URL not set")
class LayersTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        os.environ["STREETNAV_DATABASE_URL"] = URL
        with registry.connect() as conn:
            for sql in sorted((Path(__file__).parents[1] / "sql").glob("*.sql")):
                conn.execute(sql.read_text())

    def setUp(self):
        self.raw = tempfile.TemporaryDirectory()
        os.environ["STREETNAV_RAW_DIR"] = self.raw.name
        self.conn = registry.connect()
        self.conn.execute("TRUNCATE activity, activity_source, activity_heart_rate, sync_run, raw_file RESTART IDENTITY")
        self.conn.commit()

    def tearDown(self):
        self.conn.rollback()
        self.conn.close()
        self.raw.cleanup()

    def push(self, payload, body=None):
        body = body or json.dumps(payload).encode()
        return registry.ingest(self.conn, payload["source"], payload["external_id"],
                               [("payload", payload["external_id"] + ".json", body)], "api")[:2]

    def activity(self, activity_id):
        row = self.conn.execute("SELECT primary_source, distance_m, name, provenance FROM activity WHERE id = %s",
                                (activity_id,)).fetchone()
        return dict(zip(("primary_source", "distance_m", "name", "provenance"), row)) if row else None

    def test_a_pushed_workout_is_kept_as_received(self):
        body = json.dumps(workout(), indent=2).encode()
        activity_id, outcome = self.push(workout(), body)
        self.assertEqual(outcome, "created")
        path, sha = self.conn.execute("SELECT path, sha256 FROM raw_file").fetchone()
        with open(os.path.join(self.raw.name, path), "rb") as f:
            self.assertEqual(f.read(), body)
        self.assertEqual(sha, hashlib.sha256(body).hexdigest())
        self.assertFalse(os.stat(os.path.join(self.raw.name, path)).st_mode & stat.S_IWUSR)
        parsed, points = self.conn.execute(
            "SELECT parsed_at IS NOT NULL, ST_NPoints(track) FROM activity_source").fetchone()
        self.assertEqual((parsed, points), (True, 31))
        self.assertEqual(self.activity(activity_id)["distance_m"], 10_000.0)

    def test_an_identical_resend_adds_no_file(self):
        payload = workout()
        self.push(payload)
        self.assertEqual(self.push(payload, json.dumps(payload, sort_keys=True).encode())[1], "updated")
        self.assertEqual(self.conn.execute("SELECT count(*) FROM raw_file").fetchone()[0], 1)
        activity_id, _ = self.push(workout(distance=10_100.0))
        self.assertEqual(self.conn.execute("SELECT count(*) FROM raw_file").fetchone()[0], 2)
        self.assertEqual(self.activity(activity_id)["distance_m"], 10_100.0)

    def test_measures_from_apple_health_hand_edits_from_strava(self):
        activity_id, _ = registry.upsert(self.conn, strava(start=T0 + timedelta(seconds=5)), [])
        self.assertEqual(self.activity(activity_id)["primary_source"], "strava")
        self.assertEqual(self.push(workout()), (activity_id, "merged"))
        a = self.activity(activity_id)
        self.assertEqual((a["primary_source"], a["distance_m"], a["name"]), ("healthkit", 10_000.0, "Commute"))
        self.assertEqual(a["provenance"]["name"], "strava:1")
        bpm = self.conn.execute("SELECT bpm[1] FROM activity_heart_rate WHERE activity_id = %s",
                                (activity_id,)).fetchone()[0]
        self.assertEqual(bpm, 120)

    def test_removing_the_only_version_deletes_the_activity(self):
        activity_id, _ = self.push(workout())
        self.assertEqual(registry.remove(self.conn, "healthkit", "A"), (activity_id, "deleted"))
        self.assertIsNone(self.activity(activity_id))
        self.assertEqual(self.conn.execute("SELECT count(*) FROM activity_heart_rate").fetchone()[0], 0)
        # Bronze keeps the file and records the deletion.
        self.assertEqual(self.conn.execute("SELECT array_agg(part ORDER BY id) FROM raw_file").fetchone()[0],
                         ["payload", "deleted"])
        self.assertEqual(bronze.current(self.conn, "healthkit", "A"), [])
        self.assertEqual(registry.remove(self.conn, "healthkit", "A"), (None, "unknown"))

    def test_removing_a_version_recomputes_the_activity_from_the_others(self):
        activity_id, _ = registry.upsert(self.conn, strava(), [])
        self.push(workout(start=T0 + timedelta(seconds=10)))  # within 15 s: not a Strava crop
        self.assertEqual(self.activity(activity_id)["primary_source"], "healthkit")
        self.assertEqual(registry.remove(self.conn, "healthkit", "A"), (activity_id, "detached"))
        a = self.activity(activity_id)
        self.assertEqual((a["primary_source"], a["distance_m"]), ("strava", 9_900.0))

    def test_gold_waits_for_versions_not_read_from_bronze(self):
        activity_id, _ = registry.upsert(self.conn, strava(distance=5_000.0), None)  # loaded before bronze
        self.conn.execute("UPDATE activity SET distance_m = 5000 WHERE id = %s", (activity_id,))
        self.push(workout())
        self.assertEqual(self.activity(activity_id)["distance_m"], 5_000.0)
        self.assertEqual(gold.rebuild_activity(self.conn, activity_id), "pending")
        self.assertEqual(gold.rebuild_activity(self.conn, activity_id, ignore_pending=True), "updated")
        self.assertEqual(self.activity(activity_id)["distance_m"], 10_000.0)

    def test_silver_and_gold_are_rebuilt_from_bronze(self):
        first, _ = self.push(workout())
        second, _ = self.push(workout("B", start=T0 + timedelta(hours=3), distance=4_000.0))
        self.conn.commit()
        columns = [d.name for d in self.conn.execute("SELECT * FROM activity LIMIT 0").description]
        snapshot = lambda: [r[:columns.index("updated_at")] + r[columns.index("updated_at") + 1:]
                            for r in self.conn.execute("SELECT * FROM activity ORDER BY id").fetchall()]
        before = snapshot()
        self.conn.execute("UPDATE activity_source SET distance_m = NULL, track = NULL, hr_t = NULL, hr_bpm = NULL")
        self.conn.execute("UPDATE activity SET distance_m = NULL, track = NULL")
        self.conn.commit()
        counts, touched = layers.rebuild_silver(None, dry_run=False)
        self.assertEqual((counts, touched), ({"updated": 2}, {first, second}))
        self.assertEqual(layers.rebuild_gold(None, ignore_pending=False, dry_run=False), {"updated": 2})
        self.assertEqual(snapshot(), before)
        self.assertEqual(layers.rebuild_gold(None, ignore_pending=False, dry_run=False), {"unchanged": 2})

    def test_a_route_sent_twice_is_kept_once(self):
        payload = workout()
        payload["points"] = payload["points"] + payload["points"]  # the workout holds two copies of its route
        activity_id, _ = self.push(payload)
        version, _ = gold.load_versions(self.conn, activity_id)[0]
        self.assertEqual([p[3] for p in version.points], sorted({p[3] for p in version.points}))
        self.assertEqual(len(version.points), 31)

    def test_tracks_read_back_from_silver(self):
        activity_id, _ = self.push(workout())
        version, parsed = gold.load_versions(self.conn, activity_id)[0]
        t = int(T0.timestamp())
        self.assertTrue(parsed)
        self.assertEqual(version.points[:2], [(2.35, 48.85, 35.0, t), (2.352, 48.85, 35.0, t + 60)])
        self.assertEqual(version.heart_rate[0], (t, 120))


if __name__ == "__main__":
    unittest.main()
