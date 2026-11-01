"""Bronze layer: every version as received, written once to a file and listed in the raw_file table.

Files are named by their content (raw/<source>/<sha256[:2]>/<sha256><extension>), so a file is never rewritten and
identical bytes are stored once. The index is append only: a version's current files are its latest row of each part
since its last deletion, and a deletion only adds a row.
"""
from __future__ import annotations

import hashlib
import json
import os
import tempfile
from dataclasses import dataclass
from functools import lru_cache

import psycopg

DEFAULT_RAW_DIR = "/var/lib/streetnav/raw"
EXTENSIONS = (".fit.gz", ".gpx.gz", ".tcx.gz", ".json.gz", ".fit", ".gpx", ".tcx", ".json", ".csv")
# Dry runs index files (in a transaction rolled back afterwards) without writing them.
dry_run = False


def raw_dir() -> str:
    return os.environ.get("STREETNAV_RAW_DIR", DEFAULT_RAW_DIR)


@dataclass
class RawPart:
    """One file of a version."""
    part: str
    name: str
    data: bytes
    sha256: str


def extension(name: str) -> str:
    lower = name.lower()
    return next((ext for ext in EXTENSIONS if lower.endswith(ext)), "")


@lru_cache(maxsize=8)  # a Strava archive's activities.csv is a part of every Strava version
def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


@lru_cache(maxsize=8)
def digest(data: bytes, name: str) -> str:
    """Identity of a file's content. JSON is compared once canonical: the iPhone app writes its keys in any order."""
    if extension(name) == ".json":
        try:
            return sha256(json.dumps(json.loads(data), sort_keys=True, separators=(",", ":"),
                                     ensure_ascii=False).encode())
        except ValueError:
            pass
    return sha256(data)


def write_blob(source: str, name: str, data: bytes) -> tuple[str, str]:
    """Writes the bytes unless already there; returns (path relative to the raw directory, sha256)."""
    sha = sha256(data)
    rel = os.path.join(source, sha[:2], sha + extension(name))
    path = os.path.join(raw_dir(), rel)
    if not dry_run and not os.path.exists(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".incoming-")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, 0o440)
            os.replace(tmp, path)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise
    return rel, sha


def read_blob(rel: str) -> bytes:
    with open(os.path.join(raw_dir(), rel), "rb") as f:
        return f.read()


def current(conn: psycopg.Connection, source: str, external_id: str) -> list[dict]:
    """The version's current files (one per part), or [] if it has none or was deleted last."""
    rows = conn.execute(
        """SELECT id, part, name, path, sha256, digest, received_at FROM raw_file
           WHERE source = %s AND external_id = %s ORDER BY id""", (source, external_id)).fetchall()
    parts: dict[str, dict] = {}
    for row in rows:
        if row[1] == "deleted":
            parts = {}
        else:
            parts[row[1]] = dict(zip(("id", "part", "name", "path", "sha256", "digest", "received_at"), row))
    return list(parts.values())


def store(conn: psycopg.Connection, source: str, external_id: str, part: str, name: str, data: bytes,
          batch: str | None) -> int:
    """Keeps one file of a version; returns its raw_file id. Content identical to the current file of that part
    (same digest) adds nothing."""
    content = digest(data, name)
    for row in current(conn, source, external_id):
        if row["part"] == part and row["digest"] == content:
            return row["id"]
    rel, sha = write_blob(source, name, data)
    return conn.execute(
        """INSERT INTO raw_file (source, external_id, part, name, path, sha256, size, digest, batch)
           VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s) RETURNING id""",
        (source, external_id, part, name, rel, sha, len(data), content, batch)).fetchone()[0]


def record_deletion(conn: psycopg.Connection, source: str, external_id: str, batch: str | None) -> None:
    conn.execute("INSERT INTO raw_file (source, external_id, part, batch) VALUES (%s, %s, 'deleted', %s)",
                 (source, external_id, batch))


def load(rows: list[dict], known: dict[str, bytes] | None = None) -> dict[str, RawPart]:
    """Reads a version's current files, by part. `known` maps sha256 to bytes already in memory."""
    known = known or {}
    return {r["part"]: RawPart(r["part"], r["name"], known.get(r["sha256"]) or read_blob(r["path"]), r["sha256"])
            for r in rows}
