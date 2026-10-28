-- Streetnav activity registry: one row per real-world activity, whatever the number of services
-- (Apple Health, Ride with GPS, Strava...) that hold a copy of it.

CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TABLE IF NOT EXISTS activity (
    id               bigserial PRIMARY KEY,
    started_at       timestamptz NOT NULL,
    ended_at         timestamptz,
    sport            text NOT NULL,              -- cycling, running, walking, training, ...
    indoor           boolean,
    distance_m       double precision,
    duration_s       double precision,
    moving_s         double precision,
    calories         double precision,
    avg_hr           double precision,
    max_hr           double precision,
    elevation_gain_m double precision,
    -- positioned points only: x = longitude, y = latitude, z = altitude (m), m = Unix time (s)
    track            geometry(LineStringZM, 4326),
    start_point      geometry(Point, 4326),
    primary_source   text NOT NULL,              -- source whose metrics and track are kept
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS activity_started_at ON activity (started_at);
CREATE INDEX IF NOT EXISTS activity_track ON activity USING gist (track);

-- Where each activity also lives. A new copy is attached to an existing activity when it starts
-- within 90 s of it (one cannot be in two places at once), otherwise it creates a new activity.
CREATE TABLE IF NOT EXISTS activity_source (
    source       text NOT NULL CHECK (source IN ('healthkit', 'rwgps', 'strava', 'wandrer', 'file')),
    external_id  text NOT NULL,
    activity_id  bigint NOT NULL REFERENCES activity (id) ON DELETE CASCADE,
    started_at   timestamptz NOT NULL,
    device       text,
    raw          jsonb,
    fetched_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source, external_id)
);
CREATE INDEX IF NOT EXISTS activity_source_activity ON activity_source (activity_id);

-- Heart-rate stream of the primary source (Unix seconds, bpm), kept apart from the track because
-- many samples have no position.
CREATE TABLE IF NOT EXISTS activity_heart_rate (
    activity_id bigint PRIMARY KEY REFERENCES activity (id) ON DELETE CASCADE,
    t           integer[] NOT NULL,
    bpm         smallint[] NOT NULL
);

-- Last run of each importer (read by the API's /status endpoint).
CREATE TABLE IF NOT EXISTS sync_run (
    source      text PRIMARY KEY,
    finished_at timestamptz NOT NULL,
    created     integer NOT NULL,
    merged      integer NOT NULL,
    updated     integer NOT NULL,
    errors      integer NOT NULL,
    message     text
);
