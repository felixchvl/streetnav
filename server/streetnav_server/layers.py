"""Rebuilds silver from bronze and gold from silver, without importing anything again.

  python -m streetnav_server.layers status
  python -m streetnav_server.layers rebuild-silver [--source S] [--dry-run]   re-read every version's bronze files
  python -m streetnav_server.layers rebuild-gold [--activity ID ...] [--ignore-pending] [--dry-run]

rebuild-silver keeps each version on its activity (versions are grouped once, when they arrive) and then rebuilds
the activities it touched. rebuild-gold leaves an activity alone while one of its versions has not been read from
bronze yet, unless --ignore-pending (those versions are then left out).
"""
from __future__ import annotations

import argparse
import sys
from collections import Counter

from . import bronze, gold
from .registry import connect, upsert
from .sources import parse


def status() -> None:
    with connect() as conn:
        print("bronze (files kept, by source):")
        for source, files, size, versions in conn.execute(
                """SELECT source, count(DISTINCT path), pg_size_pretty(sum(size) FILTER (WHERE first_of_path)),
                          count(DISTINCT external_id)
                   FROM (SELECT *, row_number() OVER (PARTITION BY path ORDER BY id) = 1 AS first_of_path
                         FROM raw_file WHERE path IS NOT NULL) f
                   GROUP BY source ORDER BY source"""):
            print(f"  {source:10s} {files:6d} files, {size}, {versions} versions")
        print("silver (versions, by source):")
        for source, total, parsed in conn.execute(
                """SELECT source, count(*), count(parsed_at) FROM activity_source GROUP BY source ORDER BY source"""):
            print(f"  {source:10s} {total:6d} versions, {total - parsed} not read from bronze yet")
        total, pending, auto, strava = conn.execute(
            """SELECT count(*),
                      count(*) FILTER (WHERE EXISTS (SELECT 1 FROM activity_source s
                                                     WHERE s.activity_id = a.id AND s.parsed_at IS NULL)),
                      count(*) FILTER (WHERE provenance ? 'auto_crop'),
                      count(*) FILTER (WHERE provenance ? 'strava_crop')
               FROM activity a""").fetchone()
        print(f"gold: {total} activities, {pending} waiting for a version's bronze files, "
              f"{strava} cropped on Strava, {auto} cropped automatically")


def rebuild_gold(activity_ids: list[int] | None, ignore_pending: bool, dry_run: bool) -> Counter:
    counts: Counter = Counter()
    with connect() as conn:
        if not activity_ids:
            activity_ids = [r[0] for r in conn.execute("SELECT id FROM activity ORDER BY id")]
        for i, activity_id in enumerate(activity_ids, 1):
            counts[gold.rebuild_activity(conn, activity_id, ignore_pending)] += 1
            if i % 500 == 0:
                print(f"{i}/{len(activity_ids)} {dict(counts)}", flush=True)
        conn.rollback() if dry_run else conn.commit()
    return counts


def rebuild_silver(source: str | None, dry_run: bool) -> tuple[Counter, set[int]]:
    counts: Counter = Counter()
    touched: set[int] = set()
    with connect() as conn:
        versions = conn.execute(
            """SELECT DISTINCT source, external_id FROM raw_file WHERE %(source)s::text IS NULL OR source = %(source)s
               ORDER BY source, external_id""", {"source": source}).fetchall()
        for i, (src, external_id) in enumerate(versions, 1):
            rows = bronze.current(conn, src, external_id)
            if not rows:
                counts["deleted at the source"] += 1
                continue
            try:
                copy = parse(src, external_id, bronze.load(rows))
                activity_id, outcome = upsert(conn, copy, [r["id"] for r in rows], rebuild=False)
                touched.add(activity_id)
                counts[outcome] += 1
                if not dry_run:
                    conn.commit()
            except Exception as exc:  # one unreadable version must not stop the rebuild
                conn.rollback()
                counts["errors"] += 1
                print(f"{src}:{external_id}: {exc!r}", file=sys.stderr)
            if i % 500 == 0:
                print(f"{i}/{len(versions)} {dict(counts)}", flush=True)
        if dry_run:
            conn.rollback()
    return counts, touched


def main() -> None:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    silver = commands.add_parser("rebuild-silver")
    silver.add_argument("--source")
    silver.add_argument("--dry-run", action="store_true")
    rebuild = commands.add_parser("rebuild-gold")
    rebuild.add_argument("--activity", type=int, action="append")
    rebuild.add_argument("--ignore-pending", action="store_true")
    rebuild.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if args.command == "status":
        status()
    elif args.command == "rebuild-silver":
        counts, touched = rebuild_silver(args.source, args.dry_run)
        print(f"silver{' (dry run)' if args.dry_run else ''}: {dict(sorted(counts.items()))}")
        if not args.dry_run and touched:
            print(f"gold: {dict(sorted(rebuild_gold(sorted(touched), False, False).items()))}")
    else:
        counts = rebuild_gold(args.activity, args.ignore_pending, args.dry_run)
        print(f"gold{' (dry run)' if args.dry_run else ''}: {dict(sorted(counts.items()))}")


if __name__ == "__main__":
    main()
