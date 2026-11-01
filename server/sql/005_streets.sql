-- Streets ridden and not ridden yet: the OpenStreetMap ways a bike can take (streetnav_server/streets.py loads them),
-- cut into the parts within reach of a ride and the parts never ridden. Lengths and geometry in Lambert-93 (metres).

CREATE TABLE IF NOT EXISTS street (
    id       bigint PRIMARY KEY,               -- OpenStreetMap way id
    name     text,
    highway  text NOT NULL,
    geom     geometry(LineString, 2154) NOT NULL,
    length_m double precision NOT NULL
);
CREATE INDEX IF NOT EXISTS street_geom ON street USING gist (geom);

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
