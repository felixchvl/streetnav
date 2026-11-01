-- Three layers, like a medallion architecture:
--   bronze  raw_file: every version as received, kept as files under STREETNAV_RAW_DIR, never modified;
--   silver  activity_source: one row per version with its own metrics, track and heart rate, rebuilt from bronze;
--   gold    activity (+ activity_heart_rate): one row per real activity, computed field by field from its versions.

-- Bronze index, append only. A version's current files are its latest row of each part since its last deletion.
CREATE TABLE IF NOT EXISTS raw_file (
    id          bigserial PRIMARY KEY,
    source      text NOT NULL,
    external_id text NOT NULL,
    part        text NOT NULL,      -- payload (JSON received), csv, file, web_stream; deleted marks a deletion
    name        text,               -- name at the source, e.g. activities/123.fit.gz
    path        text,               -- relative to the raw directory; NULL for a deletion
    sha256      text,
    size        bigint,
    digest      text,               -- what an identical resend compares: sha256 of the canonical JSON, else of the bytes
    batch       text,               -- e.g. strava-archive-2026-10-28, api, rwgps-api
    received_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS raw_file_version ON raw_file (source, external_id, id);

-- Silver: each version's own values, filled from bronze (parsed_at NULL: not read from bronze yet).
ALTER TABLE activity_source ADD COLUMN IF NOT EXISTS ended_at         timestamptz;
ALTER TABLE activity_source ADD COLUMN IF NOT EXISTS sport            text;
ALTER TABLE activity_source ADD COLUMN IF NOT EXISTS sport_type       text;
ALTER TABLE activity_source ADD COLUMN IF NOT EXISTS indoor           boolean;
ALTER TABLE activity_source ADD COLUMN IF NOT EXISTS distance_m       double precision;
ALTER TABLE activity_source ADD COLUMN IF NOT EXISTS duration_s       double precision;
ALTER TABLE activity_source ADD COLUMN IF NOT EXISTS moving_s         double precision;
ALTER TABLE activity_source ADD COLUMN IF NOT EXISTS calories         double precision;
ALTER TABLE activity_source ADD COLUMN IF NOT EXISTS avg_hr           double precision;
ALTER TABLE activity_source ADD COLUMN IF NOT EXISTS max_hr           double precision;
ALTER TABLE activity_source ADD COLUMN IF NOT EXISTS elevation_gain_m double precision;
ALTER TABLE activity_source ADD COLUMN IF NOT EXISTS name             text;
ALTER TABLE activity_source ADD COLUMN IF NOT EXISTS description      text;
ALTER TABLE activity_source ADD COLUMN IF NOT EXISTS commute          boolean;
ALTER TABLE activity_source ADD COLUMN IF NOT EXISTS gear             text;
ALTER TABLE activity_source ADD COLUMN IF NOT EXISTS track            geometry(LineStringZM, 4326);
ALTER TABLE activity_source ADD COLUMN IF NOT EXISTS hr_t             integer[];
ALTER TABLE activity_source ADD COLUMN IF NOT EXISTS hr_bpm           smallint[];
ALTER TABLE activity_source ADD COLUMN IF NOT EXISTS raw_file_ids     bigint[];
ALTER TABLE activity_source ADD COLUMN IF NOT EXISTS parsed_at        timestamptz;

-- Gold: which version gave each field ("source:external_id"), and what the automatic crop removed.
ALTER TABLE activity ADD COLUMN IF NOT EXISTS provenance jsonb;
