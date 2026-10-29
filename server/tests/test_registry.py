"""Registry merge and removal, against a real PostGIS database that these tests EMPTY.

Skipped unless STREETNAV_TEST_DATABASE_URL points to a throwaway database, e.g.
  STREETNAV_TEST_DATABASE_URL=postgresql://postgres@127.0.0.1:55432/streetnav_test python -m unittest discover -s tests
"""
import os
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from streetnav_server import registry
from streetnav_server.registry import ActivityCopy

URL = os.environ.get("STREETNAV_TEST_DATABASE_URL")
T0 = datetime(2026, 10, 29, 8, 0, tzinfo=timezone.utc)


def ride(source, external_id, start=T0, minutes=30, distance=10_000.0):
    t = int(start.timestamp())
    return ActivityCopy(source=source, external_id=external_id, started_at=start, sport="cycling", sport_type="Ride",
                        ended_at=start + timedelta(minutes=minutes), distance_m=distance,
                        points=[(2.35, 48.85, 35.0, t), (2.36, 48.86, 36.0, t + 60)], heart_rate=[(t, 120)])


@unittest.skipUnless(URL, "STREETNAV_TEST_DATABASE_URL not set")
class RegistryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        os.environ["STREETNAV_DATABASE_URL"] = URL
        with registry.connect() as conn:
            for sql in sorted((Path(__file__).parents[1] / "sql").glob("*.sql")):
                conn.execute(sql.read_text())

    def setUp(self):
        self.conn = registry.connect()
        self.conn.execute("TRUNCATE activity, activity_source, activity_heart_rate, sync_run RESTART IDENTITY")

    def tearDown(self):
        self.conn.rollback()
        self.conn.close()

    def activity(self, activity_id):
        return self.conn.execute("SELECT primary_source, distance_m FROM activity WHERE id = %s",
                                 (activity_id,)).fetchone()

    def test_removing_the_only_copy_deletes_the_activity(self):
        activity_id, outcome = registry.upsert(self.conn, ride("healthkit", "A"))
        self.assertEqual(outcome, "created")
        self.assertEqual(registry.remove(self.conn, "healthkit", "A"), (activity_id, "deleted"))
        self.assertIsNone(self.activity(activity_id))
        self.assertEqual(self.conn.execute("SELECT count(*) FROM activity_heart_rate").fetchone()[0], 0)
        self.assertEqual(registry.remove(self.conn, "healthkit", "A"), (None, "unknown"))

    def test_removing_a_lower_copy_keeps_the_primary(self):
        activity_id, _ = registry.upsert(self.conn, ride("strava", "1", distance=9_000.0))
        self.assertEqual(registry.upsert(self.conn, ride("healthkit", "A", start=T0 + timedelta(seconds=30)))[1],
                         "merged")
        self.assertEqual(registry.remove(self.conn, "healthkit", "A"), (activity_id, "detached"))
        self.assertEqual(self.activity(activity_id), ("strava", 9_000.0))

    def test_removing_the_primary_hands_over_to_the_best_remaining_copy(self):
        activity_id, _ = registry.upsert(self.conn, ride("rwgps", "9"))
        registry.upsert(self.conn, ride("file", "2026/ride.fit"))
        registry.upsert(self.conn, ride("healthkit", "A", distance=10_500.0))
        self.assertEqual(self.activity(activity_id), ("healthkit", 10_500.0))
        self.assertEqual(registry.remove(self.conn, "healthkit", "A"), (activity_id, "detached"))
        self.assertEqual(self.activity(activity_id)[0], "file")
        # The file copy, sent again, takes over as usual.
        registry.upsert(self.conn, ride("file", "2026/ride.fit", distance=10_400.0))
        self.assertEqual(self.activity(activity_id), ("file", 10_400.0))


if __name__ == "__main__":
    unittest.main()
