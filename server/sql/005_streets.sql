-- Streets ridden and not ridden yet: the OpenStreetMap ways around Paris (streetnav_server/streets.py loads them, and
-- paris-rues reads the named ways of Paris from here), the ones a bike may ride cut into the parts within reach of a
-- ride and the parts never ridden. Lengths and geometry in Lambert-93 (metres).

CREATE TABLE IF NOT EXISTS street (
    id       bigint PRIMARY KEY,               -- OpenStreetMap way id
    name     text,
    highway  text NOT NULL,
    geom     geometry(LineString, 2154) NOT NULL,
    length_m double precision NOT NULL
);
CREATE INDEX IF NOT EXISTS street_geom ON street USING gist (geom);
-- The way's tags, whether a bike may ride it and the tag that decided, whether it is a way of its own rather than a
-- sidewalk, a crossing or an area (rules in streets.py). The defaults only held the ways loaded before 2026-11-02.
ALTER TABLE street ADD COLUMN IF NOT EXISTS tags jsonb NOT NULL DEFAULT '{}';
ALTER TABLE street ADD COLUMN IF NOT EXISTS bike boolean NOT NULL DEFAULT true;
ALTER TABLE street ADD COLUMN IF NOT EXISTS bike_reason text NOT NULL DEFAULT '';
ALTER TABLE street ADD COLUMN IF NOT EXISTS counted boolean NOT NULL DEFAULT true;
-- The street a bike path runs alongside (streets.SIDE_M): that path is neither drawn nor counted, riding it rides the
-- street. NULL for every other way.
ALTER TABLE street ADD COLUMN IF NOT EXISTS alongside bigint;

-- Short pieces of the bike rides' tracks, so that the spatial index finds the few near a point.
CREATE TABLE IF NOT EXISTS ride_piece (
    activity_id bigint NOT NULL REFERENCES activity (id) ON DELETE CASCADE,
    geom        geometry(LineString, 2154) NOT NULL
);
CREATE INDEX IF NOT EXISTS ride_piece_geom ON ride_piece USING gist (geom);
CREATE INDEX IF NOT EXISTS ride_piece_activity ON ride_piece (activity_id);

-- Each street cut into runs: ridden (within reach of a ride) or not.
CREATE TABLE IF NOT EXISTS street_part (
    street_id bigint NOT NULL REFERENCES street (id) ON DELETE CASCADE,
    ridden    boolean NOT NULL,
    geom      geometry(LineString, 2154) NOT NULL,
    length_m  double precision NOT NULL
);
CREATE INDEX IF NOT EXISTS street_part_street ON street_part (street_id);
CREATE INDEX IF NOT EXISTS street_part_geom ON street_part USING gist (geom);

CREATE TABLE IF NOT EXISTS street_run (
    finished_at timestamptz NOT NULL,
    streets     integer NOT NULL,
    total_km    double precision NOT NULL,
    ridden_km   double precision NOT NULL,
    seconds     double precision NOT NULL
);
