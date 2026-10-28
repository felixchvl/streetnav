"""Reads activity files (FIT, GPX or TCX, maybe gzipped).

Samples are (unix s, lon, lat, altitude, bpm) tuples, position and heart rate being None when absent. FIT files
also give their session summary (sport, durations, distance, calories, heart rate, ascent).
"""
from __future__ import annotations

import gzip
import io
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

SEMICIRCLE_DEG = 180 / 2**31  # FIT positions are in semicircles


def utc_seconds(t: datetime) -> int:
    return int((t if t.tzinfo else t.replace(tzinfo=timezone.utc)).timestamp())


def _tolerate_undeclared_dev_fields() -> None:
    """Some FIT files (HealthFit exports of autumn 2024) use developer fields they never declare, which fitparse
    rejects: read those fields as raw bytes instead (nothing streetnav uses lives there). Others (spring 2023)
    declare a field's base type without its endian bit (15 for uint64, 0x8F): accept those numbers too."""
    from fitparse import base, records
    if getattr(base, "_undeclared_dev_fields_ok", False):
        return
    for type_id, base_type in list(records.BASE_TYPES.items()):
        records.BASE_TYPES.setdefault(type_id & 0x1F, base_type)
    declared = records.get_dev_type

    def get_dev_type(dev_data_index, field_def_num):
        try:
            return declared(dev_data_index, field_def_num)
        except Exception:
            return records.DevField(dev_data_index=dev_data_index, def_num=field_def_num,
                                    type=records.BASE_TYPES[0x0D], name=f"undeclared_dev_field_{field_def_num}",
                                    units=None, native_field_num=None)

    base.get_dev_type = get_dev_type
    base._undeclared_dev_fields_ok = True


def fit_read(data: bytes) -> tuple[list[tuple], dict]:
    import fitparse  # only FIT files need it
    _tolerate_undeclared_dev_fields()
    samples, session = [], {}
    for message in fitparse.FitFile(io.BytesIO(data)).get_messages(["record", "session"]):
        v = message.get_values()
        if message.name == "session":
            session = session or v  # multisport files: the first session describes the start
            continue
        if v.get("timestamp") is None:
            continue
        lat, lon = v.get("position_lat"), v.get("position_long")
        has_pos = lat is not None and lon is not None
        alt = v.get("enhanced_altitude") if v.get("enhanced_altitude") is not None else v.get("altitude")
        samples.append((utc_seconds(v["timestamp"]), lon * SEMICIRCLE_DEG if has_pos else None,
                        lat * SEMICIRCLE_DEG if has_pos else None, alt, v.get("heart_rate")))
    return samples, session


def xml_samples(data: bytes) -> list[tuple]:
    """GPX <trkpt> and TCX <Trackpoint> elements."""
    local = lambda tag: tag.rsplit("}", 1)[-1]
    out = []
    for _, el in ET.iterparse(io.BytesIO(data.lstrip())):
        tag = local(el.tag)
        if tag not in ("trkpt", "Trackpoint"):
            continue
        t = alt = bpm = None
        lat, lon = (float(el.get("lat")), float(el.get("lon"))) if tag == "trkpt" else (None, None)
        for child in el.iter():
            name, text = local(child.tag), (child.text or "").strip()
            if name in ("time", "Time") and text:
                t = utc_seconds(datetime.fromisoformat(text.replace("Z", "+00:00")))
            elif name in ("ele", "AltitudeMeters") and text:
                alt = float(text)
            elif name == "LatitudeDegrees" and text:
                lat = float(text)
            elif name == "LongitudeDegrees" and text:
                lon = float(text)
            elif name == "hr" and text:
                bpm = int(float(text))
            elif name == "HeartRateBpm":
                bpm = next((int(float(v.text)) for v in child if (v.text or "").strip()), bpm)
        if t is not None:
            out.append((t, lon, lat, alt, bpm))
        el.clear()
    return out


def read_file(path: str) -> tuple[list[tuple], dict]:
    """(samples, FIT session summary or {})."""
    with open(path, "rb") as f:
        data = f.read()
    if path.endswith(".gz"):
        data, path = gzip.decompress(data), path[:-3]
    if path.lower().endswith(".fit"):
        return fit_read(data)
    if path.lower().endswith((".gpx", ".tcx")):
        return xml_samples(data), {}
    return [], {}  # e.g. JSON strength sets: no track
