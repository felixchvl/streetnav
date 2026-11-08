"""OpenStreetMap as the one reference of the places of Paris and the inner suburbs (75, 92, 93 and 94), in osm.lieu: the
ways (kind voie: streets, roads, paths), the squares drawn as areas (place) and the administrative limits (limite:
departments, communes, the arrondissements of Paris and its quartiers), each with its tags as OSM has them: the one
copy of OSM in this database.

What is kept: every way of the kinds in HIGHWAYS (paths and tracks included), named or not, every named way and every
way marked open to bikes (voie); place=square and the highway areas (place); boundary=administrative relations of
LIMIT_LEVELS (limite). Only what lies in the four departments stays. Whether a bike may ride a voie (bike), after
Wandrer's rules (the note « Règles des segments Streetnav » in Metanotes), and whether it is a way of its own rather
than part of a street (counted: not a sidewalk, a crossing or a traffic island):
- open: bicycle=yes, designated, permissive, official, mtb or destination, bicycle:designated, bicycle=no with a
  bicycle:conditional;
- closed: bicycle=no, dismount, private or use_sidepath (the bike path beside it is the way); access or vehicle closed
  (no, private, customers, military...); motor roads, indoor ways; motorways, trunk roads, bus ways, steps, footways,
  bridleways, works; service roads tagged as parking aisles, driveways, emergency accesses...;
- open otherwise: streets, pedestrian streets (bikes at walking pace), service roads (alleys among them), tunnels,
  cycleways, tracks, and paths (open to bikes in France).
The members of bicycle route relations, which Wandrer keeps, are not looked at: in the four departments, only some
3 km of them are not open already (2026-11-08).

The zones are the arrondissements of Paris and the communes of the 92, 93 and 94. Paris is ring 0; a commune is in ring
n when it shares a border with one of ring n - 1: the two overlap over at least TOUCH_M2 once the other is widened by
WIDEN_M, which leaves out communes that only meet at a corner. Each voie and place carries the zone its middle lies in.

One pipeline, run in full every week and in between on demand. In full (every Sunday, and the first time, osm.lieu
empty), it downloads everything from Overpass again (about 15 minutes). On demand, from the button in the app's
settings (POST /osm/refresh: the API asks for a run, ask, and waits for it a little), it brings osm.lieu up to date
in a few seconds: the OSM API lists the changesets in the box closed since the last run and the ones still open, and
each one's changes are applied, a newer version only replacing an older one. A way takes its nodes' positions from the
change, from the ways already known or from the API; a node moved alone moves the ways it belongs to. A relation is
read again from Overpass when it changed, or when one of its member ways did (a limit or a square whose outline was
redrawn); when Overpass is behind the changes, it is read again at the next run.

  python -m streetnav_server.osm         bring osm.lieu up to date (everything, the first time)
  python -m streetnav_server.osm full    download everything again
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .registry import connect

BBOX = (48.68, 2.14, 49.02, 2.62)  # south, west, north, east: the four departments and a little more
DEPARTMENTS = ("75", "92", "93", "94")
LIMIT_LEVELS = ("6", "8", "9", "10")
# Downloaded in TILES x TILES boxes, each stored as it comes: the whole box at once is too much for the container.
TILES = 4
MIN_VOIES = 100_000  # 128,269 ways in the streets of 2026-11-03: fewer is a truncated answer, not half of Paris gone
OVERPASS = "https://overpass-api.de/api/interpreter"
API = "https://api.openstreetmap.org/api/0.6"
USER_AGENT = "streetnav/1 (personal project)"
LOCK = 0x4F53_4D4C
# A changeset whose box is wider than this (degrees) is an edit far and wide: its ways are only looked at when they are
# known already or have a node in the box.
LOCAL_DEGREES = 1.0
NODES_PER_REQUEST = 300
IDS_PER_QUERY = 5000
RETRIES = 10
# On demand: the API writes this file in the state folder, and streetnav-osm.path starts streetnav-osm.service.
WANTED = "osm-wanted"
WAIT_S = 30.0  # how long the app's button waits for the run

HIGHWAYS = ("primary|primary_link|secondary|secondary_link|tertiary|tertiary_link|unclassified|residential|"
            "living_street|pedestrian|cycleway|path|track")
# Wandrer's rules (wandrer.earth/filters, read on 2026-11-08), but for named alleys and tunnels, kept, and access=no,
# closed: the note « Règles des segments Streetnav » in Metanotes.
OPEN = {"yes", "designated", "permissive", "official", "mtb", "MTB", "destination"}
CLOSED = {"no", "private", "customers", "delivery", "permit", "emergency", "agricultural", "forestry", "military"}
NO_BIKES = {"motorway", "motorway_link", "trunk", "trunk_link", "busway", "bus_guideway", "steps", "footway",
            "bridleway", "corridor", "construction", "raceway", "escape", "elevator", "services", "rest_area",
            "bus_stop", "platform", "via_ferrata", "no"}
# Service roads: kept when named, but parking aisles, driveways, emergency accesses... (alleys are streets).
SERVICES_KEPT = {"alley"}
NOT_WAYS = {"proposed", "abandoned", "razed", "disused", "platform"}
PARTS_OF_A_STREET = {"sidewalk", "crossing", "traffic_island"}
PATHS = {"cycleway", "footway", "path"}
WIDEN_M = 25
TOUCH_M2 = 2500

# The zones: the arrondissements of Paris and the communes of the 92, 93 and 94. Level 9 also holds the communes
# déléguées of merged communes (Saint-Denis and Pierrefitte-sur-Seine since 2025), which are not zones.
ARRONDISSEMENT = "({t}.admin_level = 9 AND left({t}.code, 3) = '751')"
ZONE = f"({{t}}.kind = 'limite' AND ({ARRONDISSEMENT} OR {{t}}.admin_level = 8 AND left({{t}}.code, 2) <> '75'))"
MIDDLE = "CASE WHEN ST_Dimension({g}) = 1 THEN ST_LineInterpolatePoint({g}, 0.5) ELSE ST_Centroid(ST_Boundary({g})) END"
ASSIGN_SQL = f"""
    UPDATE osm.lieu l SET zone = (SELECT z.code FROM osm.lieu z
                                  WHERE {ZONE.format(t='z')} AND ST_Intersects(z.geom, {MIDDLE.format(g='l.geom')}) LIMIT 1)
    WHERE l.kind <> 'limite' AND {{where}}"""
NEXT_RING_SQL = f"""
    UPDATE osm.lieu z SET ring = %(ring)s
    WHERE {ZONE.format(t='z')} AND z.ring IS NULL AND EXISTS (
        SELECT FROM osm.lieu o WHERE o.ring = %(ring)s - 1 AND ST_DWithin(o.geom, z.geom, %(widen)s)
          AND ST_Area(ST_Intersection(ST_Buffer(o.geom, %(widen)s), z.geom)) >= %(touch)s)"""
# The four departments, which everything kept must touch (no row before they are loaded: then everything is kept).
AREA_SQL = f"""CREATE TEMP TABLE IF NOT EXISTS osm_area AS
               SELECT g FROM (SELECT ST_Union(geom) AS g FROM osm.lieu
                              WHERE kind = 'limite' AND admin_level = 6 AND code = ANY('{{{",".join(DEPARTMENTS)}}}')) u
               WHERE g IS NOT NULL"""

STAGE_SQL = """CREATE TEMP TABLE osm_in (osm_type char(1), osm_id bigint, kind text, name text, tags jsonb,
               admin_level smallint, code text, bike boolean, bike_reason text, counted boolean, nodes bigint[],
               ewkt text, version integer, changeset bigint, edited_at timestamptz) ON COMMIT DROP"""
# Ways come as their line (or ring), relations as their member ways, made into an area here.
GEOM = """CASE WHEN osm_type = 'r' THEN osm.area(ST_Transform(ST_GeomFromEWKT(ewkt), 2154))
               ELSE ST_Transform(ST_GeomFromEWKT(ewkt), 2154) END"""
# What is tested against the departments: a surface by its outline, a square drawn crossing itself being no polygon
# GEOS can intersect.
EDGE = "CASE WHEN ST_Dimension({g}) = 2 THEN ST_Boundary({g}) ELSE {g} END"
COLUMNS = ("osm_type, osm_id, kind, name, tags, admin_level, code, bike, bike_reason, counted, nodes, geom, version, "
           "changeset, edited_at")
UPSERT_SQL = f"""
    INSERT INTO osm.lieu ({COLUMNS})
    SELECT osm_type, osm_id, kind, name, tags, admin_level, code, bike, bike_reason, counted, nodes, g, version,
           changeset, edited_at
    FROM (SELECT DISTINCT ON (osm_type, osm_id) *, {GEOM} AS g FROM osm_in {{where}}
          ORDER BY osm_type, osm_id, version DESC) i
    WHERE g IS NOT NULL AND NOT ST_IsEmpty(g)
      AND (kind = 'limite' OR NOT EXISTS (SELECT FROM osm_area)
           OR EXISTS (SELECT FROM osm_area WHERE ST_Intersects({EDGE.format(g='i.g')}, osm_area.g)))
    ON CONFLICT (osm_type, osm_id) DO UPDATE SET
        kind = EXCLUDED.kind, name = EXCLUDED.name, tags = EXCLUDED.tags, admin_level = EXCLUDED.admin_level,
        code = EXCLUDED.code, bike = EXCLUDED.bike, bike_reason = EXCLUDED.bike_reason, counted = EXCLUDED.counted,
        nodes = EXCLUDED.nodes, geom = EXCLUDED.geom, version = EXCLUDED.version, changeset = EXCLUDED.changeset,
        edited_at = EXCLUDED.edited_at, loaded_at = now()
    WHERE osm.lieu.version <= EXCLUDED.version
    RETURNING osm_type, osm_id, (xmax = 0) AS added"""
# A newer version that left the four departments, or whose geometry could not be made, goes.
LEFT_SQL = f"""
    DELETE FROM osm.lieu l USING osm_in i
    WHERE l.osm_type = i.osm_type AND l.osm_id = i.osm_id AND l.version <= i.version AND l.kind <> 'limite'
      AND EXISTS (SELECT FROM osm_area)
      AND NOT EXISTS (SELECT FROM osm_area
                      WHERE ST_Intersects({EDGE.format(g="ST_Transform(ST_GeomFromEWKT(i.ewkt), 2154)")}, osm_area.g))"""
# The positions of nodes the ways known already go through (WGS84).
KNOWN_NODES_SQL = """
    SELECT u.n, ST_X(p), ST_Y(p)
    FROM (SELECT nodes, ST_Transform(CASE WHEN ST_Dimension(geom) = 2 THEN ST_ExteriorRing(geom) ELSE geom END, 4326) AS line
          FROM osm.lieu WHERE osm_type = 'w' AND nodes && %(ids)s::bigint[]) w,
         unnest(w.nodes) WITH ORDINALITY u(n, i), LATERAL ST_PointN(w.line, u.i::int) p
    WHERE u.n = ANY(%(ids)s::bigint[])"""
# Ways through nodes that moved, drawn again point by point.
MOVE_SQL = """
    WITH moved(id, lon, lat) AS (SELECT * FROM unnest(%(ids)s::bigint[], %(lons)s::float8[], %(lats)s::float8[])),
    pts AS (
        SELECT l.osm_id, u.i,
               coalesce(ST_Transform(ST_SetSRID(ST_MakePoint(m.lon, m.lat), 4326), 2154), ST_PointN(w.line, u.i::int)) AS p
        FROM osm.lieu l
        CROSS JOIN LATERAL (SELECT CASE WHEN ST_Dimension(l.geom) = 2 THEN ST_ExteriorRing(l.geom) ELSE l.geom END AS line) w
        CROSS JOIN LATERAL unnest(l.nodes) WITH ORDINALITY u(n, i)
        LEFT JOIN moved m ON m.id = u.n
        WHERE l.osm_type = 'w' AND l.nodes && %(ids)s::bigint[] AND NOT l.osm_id = ANY(%(skip)s::bigint[])),
    lines AS (SELECT osm_id, ST_MakeLine(p ORDER BY i) AS line FROM pts GROUP BY osm_id)
    UPDATE osm.lieu l SET geom = CASE WHEN ST_Dimension(l.geom) = 2 THEN ST_MakePolygon(lines.line) ELSE lines.line END,
                          loaded_at = now()
    FROM lines WHERE l.osm_type = 'w' AND l.osm_id = lines.osm_id
    RETURNING l.osm_id"""


def bike_access(tags: dict) -> tuple[bool, str]:
    """May a bike ride this way, and the tag that decided."""
    bicycle = tags.get("bicycle")
    if bicycle in OPEN:
        return True, f"bicycle={bicycle}"
    if tags.get("bicycle:designated", "no") != "no":
        return True, "bicycle:designated"
    if bicycle == "no" and "bicycle:conditional" in tags:
        return True, "bicycle:conditional"
    if bicycle in {"no", "dismount", "private", "use_sidepath"}:
        return False, f"bicycle={bicycle}"
    for key in ("access", "vehicle"):
        if tags.get(key) in CLOSED:
            return False, f"{key}={tags[key]}"
    for key in ("motorroad", "indoor"):
        if tags.get(key) == "yes":
            return False, f"{key}=yes"
    if tags["highway"] == "service" and tags.get("service", "alley") not in SERVICES_KEPT:
        return False, f"service={tags['service']}"
    return tags["highway"] not in NO_BIKES, f"highway={tags['highway']}"


def counted(tags: dict) -> bool:
    """A way of its own, not a sidewalk, a crossing or a traffic island (a bike path along the sidewalk becomes part of
    its street, coverage.py)."""
    keys = ("footway", "cycleway", "path") if tags.get("highway") in PATHS else ("footway",)
    return not any(tags.get(key) in PARTS_OF_A_STREET for key in keys)


def is_place(tags: dict) -> bool:
    return tags.get("place") == "square" or ("highway" in tags and tags.get("area") == "yes")


def kind_of(osm_type: str, tags: dict, closed: bool = False) -> str | None:
    """voie, place, limite, or None for what osm.lieu does not keep."""
    if osm_type == "r":
        if tags.get("boundary") == "administrative" and tags.get("admin_level") in LIMIT_LEVELS:
            return "limite"
        if tags.get("type") == "multipolygon" and (tags.get("place") == "square" or "highway" in tags):
            return "place"
        return None
    if is_place(tags):
        return "place" if closed else None
    highway = tags.get("highway")
    if highway and highway not in NOT_WAYS and (
            re.fullmatch(HIGHWAYS, highway) or "name" in tags or tags.get("bicycle") in OPEN):
        return "voie"
    return None


def limit_code(tags: dict) -> str | None:
    return tags.get("ref") if tags.get("admin_level") == "6" else tags.get("ref:INSEE")


def wanted_limit(tags: dict) -> bool:
    """The limits of the four departments and what lies in them (the box also catches their neighbours); quartiers,
    without an INSEE code, are kept by where they lie (store)."""
    code = limit_code(tags) or ""
    level = tags.get("admin_level")
    return code in DEPARTMENTS if level == "6" else code[:2] in DEPARTMENTS if level in ("8", "9") else True


def ewkt_line(points, polygon_ring: bool = False) -> str:
    coords = ",".join(f"{lon:.7f} {lat:.7f}" for lon, lat in points)
    return f"SRID=4326;POLYGON(({coords}))" if polygon_ring else f"SRID=4326;LINESTRING({coords})"


def row(osm_type: str, osm_id: int, tags: dict, nodes, ewkt: str, version: int, changeset, edited_at, kind: str):
    """A row of osm_in."""
    bike, reason, own = (*bike_access(tags), counted(tags)) if kind == "voie" else (None, None, None)
    level = int(tags["admin_level"]) if kind == "limite" else None
    code = limit_code(tags) if kind == "limite" else None
    return (osm_type, osm_id, kind, tags.get("name"), json.dumps(tags, ensure_ascii=False), level, code, bike, reason,
            own, nodes, ewkt, version, changeset, edited_at)


def element_row(e: dict):
    """The osm_in row of an Overpass element (out geom meta), or None."""
    tags = e.get("tags", {})
    if e["type"] == "way":
        nodes, geometry = e.get("nodes", []), e.get("geometry", [])
        if len(geometry) < 2 or len(geometry) != len(nodes) or any(p is None for p in geometry):
            return None
        closed = len(nodes) >= 4 and nodes[0] == nodes[-1]
        kind = kind_of("w", tags, closed)
        if kind is None:
            return None
        points = [(p["lon"], p["lat"]) for p in geometry]
        return row("w", e["id"], tags, nodes, ewkt_line(points, kind == "place"), e["version"], e.get("changeset"),
                   e["timestamp"], kind)
    if e["type"] == "relation":
        kind = kind_of("r", tags)
        if kind is None or kind == "limite" and not wanted_limit(tags):
            return None
        lines = [m["geometry"] for m in e.get("members", [])
                 if m["type"] == "way" and m.get("role") in ("outer", "inner", "") and len(m.get("geometry") or []) >= 2]
        lines = [[(p["lon"], p["lat"]) for p in line if p] for line in lines]
        lines = [line for line in lines if len(line) >= 2]
        if not lines:
            return None
        ewkt = "SRID=4326;MULTILINESTRING(" + ",".join(
            "(" + ",".join(f"{lon:.7f} {lat:.7f}" for lon, lat in line) + ")" for line in lines) + ")"
        return row("r", e["id"], tags, None, ewkt, e["version"], e.get("changeset"), e["timestamp"], kind)
    return None


def stage(cur, rows) -> int:
    """Copies rows into osm_in (created if needed); returns how many."""
    cur.execute("SELECT to_regclass('pg_temp.osm_in')")
    if cur.fetchone()[0] is None:
        cur.execute(STAGE_SQL)
    count = 0
    with cur.copy("COPY osm_in FROM STDIN") as copy:
        for r in rows:
            copy.write_row(r)
            count += 1
    return count


def number_rings(cur) -> None:
    cur.execute(f"""UPDATE osm.lieu z SET ring = CASE WHEN {ARRONDISSEMENT.format(t='z')} THEN 0 END
                    WHERE {ZONE.format(t='z')} OR ring IS NOT NULL""")
    ring = 1
    while True:
        cur.execute(NEXT_RING_SQL, {"ring": ring, "widen": WIDEN_M, "touch": TOUCH_M2})
        if cur.rowcount == 0:
            break
        ring += 1


def store(conn, elements, check: bool = True) -> dict:
    """Replaces osm.lieu with the Overpass elements (limits first, then the rest, as they come); only what lies in the
    four departments stays. `check`: refuse an answer too small to be all of it."""
    with conn.cursor() as cur:
        cur.execute("DROP TABLE IF EXISTS osm_in")
        stage(cur, (r for r in map(element_row, elements) if r))
        cur.execute(f"""SELECT count(*) FILTER (WHERE kind = 'voie'), count(*) FILTER (WHERE {ARRONDISSEMENT.format(t='osm_in')}),
                              count(*) FILTER (WHERE kind = 'limite' AND admin_level = 6) FROM osm_in""")
        voies, arrondissements, departments = cur.fetchone()
        if check and (voies < MIN_VOIES or arrondissements != 20 or departments != len(DEPARTMENTS)):
            raise SystemExit(f"only {voies} voies, {arrondissements} arrondissements and {departments} departments "
                             "from Overpass: nothing changed")
        cur.execute("TRUNCATE osm.lieu")
        cur.execute("DROP TABLE IF EXISTS osm_area")
        cur.execute(AREA_SQL)
        cur.execute(UPSERT_SQL.format(where="WHERE kind = 'limite'"))
        cur.execute("DROP TABLE osm_area")
        cur.execute(AREA_SQL)
        cur.execute(UPSERT_SQL.format(where="WHERE kind <> 'limite'"))
        # The limits outside the departments that the box caught (a quartier of a neighbour has no INSEE code).
        cur.execute("""DELETE FROM osm.lieu l WHERE kind = 'limite' AND admin_level > 6
                         AND NOT EXISTS (SELECT FROM osm_area WHERE ST_Intersects(osm_area.g, ST_PointOnSurface(l.geom)))""")
        number_rings(cur)
        cur.execute(ASSIGN_SQL.format(where="true"))
        cur.execute("DROP TABLE osm_area")
        cur.execute("SELECT kind, count(*) FROM osm.lieu GROUP BY kind ORDER BY kind")
        return dict(cur.fetchall())


def request(url: str, data: bytes | None = None, accept: str = "application/json"):
    req = urllib.request.Request(url, data=data, headers={"User-Agent": USER_AGENT, "Accept": accept})
    for wait in (30, 60, 120, 240, None):
        try:
            with urllib.request.urlopen(req, timeout=600) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            if error.code not in (429, 502, 503, 504) or wait is None:
                raise
            time.sleep(wait)


def overpass_answer(query: str) -> dict:
    """Overpass's answer (its elements, and in osm3s the time of the OSM data it holds), waiting and asking again while
    it is busy."""
    return json.loads(request(OVERPASS, urllib.parse.urlencode({"data": query}).encode()))


def overpass(query: str) -> list[dict]:
    return overpass_answer(query)["elements"]


def boxes(bbox=BBOX):
    south, west, north, east = bbox
    for i in range(TILES):
        for j in range(TILES):
            yield ",".join(str(round(v, 6)) for v in (
                south + (north - south) * i / TILES, west + (east - west) * j / TILES,
                south + (north - south) * (i + 1) / TILES, west + (east - west) * (j + 1) / TILES))


def download(bbox=BBOX):
    """Every element osm.lieu keeps in the box, limits first, tile by tile (an element across two tiles comes twice)."""
    box = ",".join(str(v) for v in bbox)
    levels = "|".join(LIMIT_LEVELS)
    yield from overpass(f'[out:json][timeout:600];relation["boundary"="administrative"]["admin_level"~"^({levels})$"]'
                        f'({box});out geom meta;')
    opened = "|".join(sorted(OPEN))
    for tile in boxes(bbox):
        elements = overpass(
            f'[out:json][timeout:300];(way["highway"~"^({HIGHWAYS})$"]({tile});way["highway"]["name"]({tile});'
            f'way["highway"]["bicycle"~"^({opened})$"]({tile});way["place"="square"]({tile});'
            f'way["highway"]["area"="yes"]({tile});relation["type"="multipolygon"]["place"="square"]({tile});'
            f'relation["type"="multipolygon"]["highway"]({tile}););out geom meta qt;')
        yield from elements
        del elements


# Changes


def state_path() -> Path:
    return Path(os.environ.get("STREETNAV_STATE_DIR", "/var/lib/streetnav")) / "osm-state.json"


def read_state() -> dict:
    try:
        return json.loads(state_path().read_text())
    except FileNotFoundError:
        return {}


def write_state(state: dict) -> None:
    path = state_path()
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=1, sort_keys=True))
    tmp.replace(path)


def changesets(since: str | None, bbox=BBOX) -> list[dict]:
    """The changesets touching the box closed after `since`, and the ones open now."""
    south, west, north, east = bbox
    base = f"{API}/changesets?bbox={west},{south},{east},{north}"
    found = parse_changesets(request(f"{base}&open=true", accept="application/xml"))
    if since:
        until = None
        while True:
            window = since if until is None else f"{since},{until}"
            batch = parse_changesets(request(f"{base}&closed=true&time={urllib.parse.quote(window)}",
                                             accept="application/xml"))
            found += batch
            if len(batch) < 100:
                break
            until = min(c["created_at"] for c in batch)
    unique = {c["id"]: c for c in found}
    return sorted(unique.values(), key=lambda c: (c["created_at"], c["id"]))


def parse_changesets(xml: bytes) -> list[dict]:
    out = []
    for c in ET.fromstring(xml).iter("changeset"):
        box = [c.get(k) for k in ("min_lat", "min_lon", "max_lat", "max_lon")]
        out.append({"id": int(c.get("id")), "created_at": c.get("created_at"), "closed_at": c.get("closed_at"),
                    "open": c.get("open") == "true", "changes": int(c.get("changes_count", 0)),
                    "box": [float(v) for v in box] if all(box) else None})
    return out


def parse_change(xml: bytes) -> dict:
    """An osmChange document: positions of the nodes it carries, the nodes modified, its ways and relations as
    (action, id, version, changeset, timestamp, tags, node refs), and the time of its newest element."""
    nodes, moved, ways, relations, newest = {}, set(), [], [], ""
    for block in ET.fromstring(xml):
        action = block.tag
        for e in block:
            tags = {t.get("k"): t.get("v") for t in e.findall("tag")}
            meta = (action, int(e.get("id")), int(e.get("version")), int(e.get("changeset") or 0), e.get("timestamp"))
            newest = max(newest, meta[4] or "")
            if e.tag == "node":
                if action != "delete" and e.get("lat") is not None:
                    nodes[meta[1]] = (float(e.get("lon")), float(e.get("lat")))
                    if action == "modify":
                        moved.add(meta[1])
            elif e.tag == "way":
                ways.append((*meta, tags, [int(nd.get("ref")) for nd in e.findall("nd")]))
            elif e.tag == "relation":
                relations.append((*meta, tags))
    return {"nodes": nodes, "moved": moved, "ways": ways, "relations": relations, "newest": newest}


def fetch_nodes(ids) -> dict:
    """Current positions of nodes from the OSM API."""
    found, ids = {}, sorted(ids)
    for i in range(0, len(ids), NODES_PER_REQUEST):
        chunk = ids[i:i + NODES_PER_REQUEST]
        try:
            xml = request(f"{API}/nodes?nodes={','.join(map(str, chunk))}", accept="application/xml")
        except urllib.error.HTTPError:
            continue
        for n in ET.fromstring(xml).iter("node"):
            if n.get("lat") is not None:
                found[int(n.get("id"))] = (float(n.get("lon")), float(n.get("lat")))
    return found


def in_box(position, bbox=BBOX) -> bool:
    south, west, north, east = bbox
    lon, lat = position
    return south <= lat <= north and west <= lon <= east


def apply(conn, change: dict, local: bool = True, fetch=fetch_nodes) -> dict:
    """Applies a parsed osmChange to osm.lieu; returns what it did. `local`: the changeset stays around the box, so a
    way of a kind kept that is new here is worth asking the API for its nodes."""
    done = {"added": 0, "changed": 0, "removed": 0, "moved": 0, "relations": []}
    # What may have redrawn a relation: ways changed (and still there) and nodes moved, around the box. Whether a
    # relation osm.lieu keeps has them as members is asked of Overpass once the run's changesets are applied.
    done["ways"] = [w[1] for w in change["ways"] if w[0] != "delete" and (local or any(
        in_box(change["nodes"][n]) for n in w[6] if n in change["nodes"]))]
    done["nodes"] = [n for n in change["moved"] if in_box(change["nodes"][n])]
    with conn.cursor() as cur:
        cur.execute(AREA_SQL)
        positions = dict(change["nodes"])
        ways = change["ways"]
        cur.execute("SELECT osm_id FROM osm.lieu WHERE osm_type = 'w' AND osm_id = ANY(%s::bigint[])", ([w[1] for w in ways],))
        known = {r[0] for r in cur.fetchall()}
        gone, kept = [], []
        for action, osm_id, version, changeset, stamp, tags, refs in ways:
            closed = len(refs) >= 4 and refs[0] == refs[-1]
            kind = None if action == "delete" else kind_of("w", tags, closed)
            if kind is None:
                if osm_id in known:
                    gone.append((osm_id, version))
                continue
            if osm_id not in known and not local and not any(in_box(positions[n]) for n in refs if n in positions):
                continue
            kept.append((osm_id, version, changeset, stamp, tags, refs, kind))
        missing = {n for w in kept for n in w[5]} - positions.keys()
        if missing:
            cur.execute(KNOWN_NODES_SQL, {"ids": sorted(missing)})
            positions.update({n: (x, y) for n, x, y in cur.fetchall()})
            missing -= positions.keys()
        if missing:
            positions.update(fetch(missing))
        rows = []
        for osm_id, version, changeset, stamp, tags, refs, kind in kept:
            if any(n not in positions for n in refs) or len(refs) < 2:
                continue
            rows.append(row("w", osm_id, tags, refs, ewkt_line([positions[n] for n in refs], kind == "place"),
                            version, changeset, stamp, kind))
        cur.execute("DROP TABLE IF EXISTS osm_in")
        stage(cur, rows)
        cur.execute(LEFT_SQL)
        done["removed"] += cur.rowcount
        cur.execute(UPSERT_SQL.format(where=""))
        upserted = cur.fetchall()
        done["added"] += sum(1 for _, _, added in upserted if added)
        done["changed"] += sum(1 for _, _, added in upserted if not added)
        for osm_id, version in gone:
            cur.execute("DELETE FROM osm.lieu WHERE osm_type = 'w' AND osm_id = %s AND version <= %s", (osm_id, version))
            done["removed"] += cur.rowcount
        touched = [w[0] for w in kept]
        moved = sorted(change["moved"])
        if moved:
            cur.execute(MOVE_SQL, {"ids": moved, "lons": [change["nodes"][n][0] for n in moved],
                                   "lats": [change["nodes"][n][1] for n in moved], "skip": touched})
            shifted = [r[0] for r in cur.fetchall()]
            done["moved"] = len(shifted)
            touched += shifted
        cur.execute(ASSIGN_SQL.format(where="l.osm_type = 'w' AND l.osm_id = ANY(%(ids)s::bigint[])"), {"ids": touched})
        # Relations: read again from Overpass when one osm.lieu keeps (or kept) is in the change.
        cur.execute("SELECT osm_id FROM osm.lieu WHERE osm_type = 'r' AND osm_id = ANY(%s::bigint[])",
                    ([r[1] for r in change["relations"]],))
        known_relations = {r[0] for r in cur.fetchall()}
        for action, osm_id, version, changeset, stamp, tags in change["relations"]:
            if osm_id in known_relations or action != "delete" and kind_of("r", tags):
                done["relations"].append(osm_id)
    return done


def parent_relations(ways, nodes) -> set[int]:
    """The relations having one of these ways, or a way through one of these nodes, as a member (Overpass), asked
    IDS_PER_QUERY at a time: a run long after the last brings many."""
    found, ways, nodes = set(), sorted(ways), sorted(nodes)
    for i in range(0, max(len(ways), len(nodes)), IDS_PER_QUERY):
        parts = ""
        if nodes[i:i + IDS_PER_QUERY]:
            parts += f"node(id:{','.join(map(str, nodes[i:i + IDS_PER_QUERY]))});way(bn);"
        if ways[i:i + IDS_PER_QUERY]:
            parts += f"way(id:{','.join(map(str, ways[i:i + IDS_PER_QUERY]))});"
        found |= {e["id"] for e in overpass(f"[out:json][timeout:300];({parts});rel(bw);out ids;")
                  if e["type"] == "relation"}
    return found


def refresh_relations(conn, ids) -> str:
    """Reads relations again from Overpass and replaces them, or removes them when gone or no longer kept. Returns the
    time of the OSM data Overpass answered from."""
    answer = overpass_answer(f"[out:json][timeout:300];relation(id:{','.join(map(str, ids))});out geom meta;")
    elements = answer["elements"]
    with conn.cursor() as cur:
        cur.execute(AREA_SQL)
        cur.execute("DROP TABLE IF EXISTS osm_in")
        stage(cur, (r for r in map(element_row, elements) if r))
        cur.execute(UPSERT_SQL.format(where=""))
        cur.execute("""DELETE FROM osm.lieu l WHERE osm_type = 'r' AND osm_id = ANY(%s::bigint[])
                         AND NOT EXISTS (SELECT FROM osm_in i WHERE i.osm_type = 'r' AND i.osm_id = l.osm_id)""",
                    (list(ids),))
        cur.execute("SELECT coalesce(bool_or(kind = 'limite'), false) FROM osm_in")
        if cur.fetchone()[0]:
            number_rings(cur)
            cur.execute(ASSIGN_SQL.format(where="true"))
            cur.execute("DROP TABLE osm_area")
    return answer.get("osm3s", {}).get("timestamp_osm_base", "")


def update(conn, bbox=BBOX, members=parent_relations) -> dict:
    """Applies the changesets since the last run; returns what it did. A changeset that fails is tried again at the
    next runs, up to RETRIES times; so is a relation Overpass answered for from data older than the changes."""
    with conn.cursor() as cur:
        cur.execute("SELECT max(edited_at) FROM osm.lieu")
        newest_kept = cur.fetchone()[0]
    state = read_state()
    since = state.get("since") or (newest_kept - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
    seen = {int(k): v for k, v in state.get("seen", {}).items()}
    retry = {int(k): v for k, v in state.get("retry", {}).items()}
    pending = state.get("relations", {})
    total = {"changesets": 0, "added": 0, "changed": 0, "removed": 0, "moved": 0, "relations": 0, "errors": 0}
    listed = changesets(since, bbox)
    todo = [c for c in listed if seen.get(c["id"]) != c["changes"]]
    todo += [{"id": i, "changes": None, "box": None} for i in retry if i not in {c["id"] for c in todo}]
    relations, next_seen, next_retry = set(pending.get("ids", [])), {c["id"]: c["changes"] for c in listed}, {}
    ways, nodes, newest = set(pending.get("ways", [])), set(pending.get("nodes", [])), pending.get("newest", "")
    for c in todo:
        try:
            change = parse_change(request(f"{API}/changeset/{c['id']}/download", accept="application/xml"))
            box = c["box"]
            done = apply(conn, change, box is None or (box[2] - box[0] <= LOCAL_DEGREES and box[3] - box[1] <= LOCAL_DEGREES))
            conn.commit()
        except Exception as error:  # noqa: BLE001 - one changeset must not stop the others
            conn.rollback()
            print(f"changeset {c['id']}: {error}", file=sys.stderr)
            total["errors"] += 1
            next_seen.pop(c["id"], None)
            if retry.get(c["id"], 0) + 1 < RETRIES:
                next_retry[c["id"]] = retry.get(c["id"], 0) + 1
            continue
        relations.update(done.pop("relations"))
        ways.update(done.pop("ways"))
        nodes.update(done.pop("nodes"))
        newest = max(newest, change["newest"])
        total["changesets"] += 1
        for k, v in done.items():
            total[k] += v
    next_pending = {}
    try:
        if ways or nodes:
            parents = sorted(members(ways, nodes))
            with conn.cursor() as cur:
                cur.execute("SELECT osm_id FROM osm.lieu WHERE osm_type = 'r' AND osm_id = ANY(%s::bigint[])", (parents,))
                relations.update(r[0] for r in cur.fetchall())
        if relations:
            base = refresh_relations(conn, sorted(relations))
            conn.commit()
            total["relations"] = len(relations)
            if base < newest:
                next_pending = {"ids": sorted(relations), "newest": newest}
    except Exception as error:  # noqa: BLE001 - Overpass down: the relations wait for the next run
        conn.rollback()
        print(f"relations: {error}", file=sys.stderr)
        total["errors"] += 1
        next_pending = {"ids": sorted(relations), "ways": sorted(ways), "nodes": sorted(nodes), "newest": newest}
    closed = [c["closed_at"] for c in listed if not c["open"] and c["closed_at"]]
    write_state({"since": max([since, *closed]), "seen": next_seen, "retry": next_retry, "relations": next_pending})
    return total


def sync(conn, full: bool = False) -> dict:
    """Brings osm.lieu up to date: everything from Overpass in full or while it is empty, the changes since the last run
    otherwise."""
    if full or conn.execute("SELECT NOT EXISTS (SELECT FROM osm.lieu)").fetchone()[0]:
        done = store(conn, download())
        conn.commit()
        write_state({})
        return done
    return update(conn)


def ask(wait: float | None = None) -> dict | None:
    """Asks for a run on demand (streetnav-osm.path starts streetnav-osm.service) and waits for it up to WAIT_S: what it
    did, or None while it goes on (a full run going, Overpass slow)."""
    with connect() as conn:
        conn.autocommit = True
        last = "SELECT finished_at, message FROM sync_run WHERE source = 'osm'"
        before = conn.execute(last).fetchone()
        state_path().with_name(WANTED).write_text(datetime.now(timezone.utc).isoformat() + "\n")
        deadline = time.monotonic() + (WAIT_S if wait is None else wait)
        while time.monotonic() < deadline:
            time.sleep(0.5)
            run = conn.execute(last).fetchone()
            if run != before:
                return json.loads(run[1] or "{}")
    return None


def record(conn, started: float, done: dict) -> None:
    conn.execute("""INSERT INTO sync_run (source, finished_at, created, merged, updated, errors, message)
                    VALUES ('osm', now(), %s, 0, %s, %s, %s)
                    ON CONFLICT (source) DO UPDATE SET finished_at = now(), created = EXCLUDED.created,
                        merged = 0, updated = EXCLUDED.updated, errors = EXCLUDED.errors, message = EXCLUDED.message""",
                 (done.get("added", 0), done.get("changed", 0) + done.get("moved", 0), done.get("errors", 0),
                  json.dumps({**done, "seconds": round(time.monotonic() - started, 1)})))


def main(argv=None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if args not in ([], ["full"]):
        print(__doc__, file=sys.stderr)
        return 2
    full = args == ["full"]
    started = time.monotonic()
    with connect() as conn:
        if full:  # the week's run waits for a run on demand rather than being skipped until next week
            conn.execute("SELECT pg_advisory_lock(%s)", (LOCK,))
        elif not conn.execute("SELECT pg_try_advisory_lock(%s)", (LOCK,)).fetchone()[0]:
            print("another OpenStreetMap run is going: skipped")
            return 0
        done = sync(conn, full)
        record(conn, started, done)
        conn.commit()
    print(json.dumps(done))
    return 0


if __name__ == "__main__":
    sys.exit(main())
