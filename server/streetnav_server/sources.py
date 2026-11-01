"""Silver readers: turn a version's bronze files into an ActivityCopy, whatever its source."""
from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field

from .bronze import RawPart
from .registry import ActivityCopy


class WorkoutIn(BaseModel):
    """A workout pushed to the API: an Apple Health workout sent by the iPhone app, or any other source."""
    source: str = "healthkit"
    external_id: str = Field(description="HKWorkout UUID for Apple Health")
    started_at: datetime
    ended_at: datetime | None = None
    sport: str
    indoor: bool | None = None
    distance_m: float | None = None
    duration_s: float | None = None
    moving_s: float | None = None
    calories: float | None = None
    avg_hr: float | None = None
    max_hr: float | None = None
    elevation_gain_m: float | None = None
    points: list[tuple[float, float, float | None, int]] = Field(
        default_factory=list, description="[longitude, latitude, altitude m, unix seconds]")
    heart_rate: list[tuple[int, int]] = Field(default_factory=list, description="[unix seconds, bpm]")
    device: str | None = None
    name: str | None = None
    sport_type: str | None = Field(default=None, description="Strava's name, e.g. Ride, Walk, WeightTraining")
    raw: dict | None = Field(default=None, description="kept as is, e.g. the workout's source app and metadata")

    def to_copy(self) -> ActivityCopy:
        return ActivityCopy(**self.model_dump(exclude={"points", "heart_rate"}),
                            points=[tuple(p) for p in self.points], heart_rate=[tuple(h) for h in self.heart_rate])


def parse_payload(external_id: str, parts: dict[str, RawPart]) -> ActivityCopy:
    return WorkoutIn.model_validate_json(parts["payload"].data).to_copy()


def parse(source: str, external_id: str, parts: dict[str, RawPart]) -> ActivityCopy:
    """The version described by its current bronze files (one per part)."""
    if source == "strava":
        from .strava_import import parse as read
    elif source == "file":
        from .file_import import parse as read
    elif source == "rwgps":
        from .rwgps_sync import parse as read
    else:  # pushed to the API (healthkit)
        read = parse_payload
    copy = read(external_id, parts)
    if (copy.source, copy.external_id) != (source, external_id):
        raise ValueError(f"bronze files of {source}:{external_id} describe {copy.source}:{copy.external_id}")
    return copy
