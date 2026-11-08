-- Coverage (streetnav_server/coverage.py): the streets each bike ride went along, measured again from the rides'
-- cropped tracks (gold activity) and OpenStreetMap's ways (osm.lieu) whenever either changes. Everything here can be
-- computed again at will: python -m streetnav_server.coverage full. Lambert-93 (metres).
CREATE SCHEMA IF NOT EXISTS couverture;

-- The streets a bike may ride, cut at their crossroads: each tronçon is a stretch of one OSM way (its reference way)
-- between two crossroads, the bike paths along it, its other carriageway and its contre-allées being merged into it
-- (couverture.membre).
CREATE TABLE IF NOT EXISTS couverture.troncon (
    id        integer PRIMARY KEY,
    osm_id    bigint NOT NULL,                -- the OSM way it is a stretch of
    a         double precision NOT NULL,      -- where it starts and ends along that way (0 to 1)
    b         double precision NOT NULL,
    way_m     double precision NOT NULL,      -- length of the whole way
    length_m  double precision NOT NULL,
    name      text,
    highway   text NOT NULL,
    zone      text,                           -- arrondissement of Paris or commune its middle lies in (osm.lieu)
    surface   text NOT NULL CHECK (surface IN ('revetu', 'stabilise', 'terre', 'inconnu')),
    tunnel    boolean NOT NULL,
    impasse   smallint NOT NULL,              -- 0 none, 1 dead end at b, -1 dead end at a
    reach_m   double precision NOT NULL,      -- half its width, plus the GPS margin
    geom      geometry(LineString, 2154) NOT NULL
);
-- The place (square, carrefour, rond-point drawn as an area) it lies in, as its osm_type and osm_id (w123, r45).
ALTER TABLE couverture.troncon ADD COLUMN IF NOT EXISTS place text;
CREATE INDEX IF NOT EXISTS troncon_geom ON couverture.troncon USING gist (geom);
CREATE INDEX IF NOT EXISTS troncon_place ON couverture.troncon (place) WHERE place IS NOT NULL;
CREATE INDEX IF NOT EXISTS troncon_way ON couverture.troncon (osm_id, a);
COMMENT ON TABLE couverture.troncon IS
    'coverage: the streets a bike may ride cut at their crossroads, from osm.lieu (coverage.py)';

-- The OSM ways (or parts of ways) merged into another's tronçons: a bike path along a street, the other carriageway of
-- a dual carriageway, a contre-allée. Riding them rides the street.
CREATE TABLE IF NOT EXISTS couverture.membre (
    osm_id     bigint NOT NULL,
    a          double precision NOT NULL,     -- the part of that way merged (0 to 1)
    b          double precision NOT NULL,
    ref_osm_id bigint NOT NULL,               -- the way it is merged into
    ref_a      double precision NOT NULL,     -- where it lies along that way (0 to 1)
    ref_b      double precision NOT NULL,
    role       text NOT NULL CHECK (role IN ('piste', 'chaussee', 'contre_allee')),
    reach_m    double precision NOT NULL,
    geom       geometry(LineString, 2154) NOT NULL,
    PRIMARY KEY (osm_id, a)
);
CREATE INDEX IF NOT EXISTS membre_geom ON couverture.membre USING gist (geom);
COMMENT ON TABLE couverture.membre IS
    'coverage: bike paths, carriageways and contre-allées merged into a street''s tronçons (coverage.py)';

-- Each time a ride went along a tronçon: one row per ride, tronçon and run (a run is the ride staying along the
-- same way, cut where it turns back). Only runs long enough to be more than a ride crossing the street.
CREATE TABLE IF NOT EXISTS couverture.passage (
    troncon_id  integer NOT NULL,
    activity_id bigint NOT NULL,
    run         integer NOT NULL,             -- the run's number along that way, in this ride
    from_m      double precision NOT NULL,    -- the part of the tronçon ridden (metres from its start a)
    to_m        double precision NOT NULL,
    entered_at  timestamptz NOT NULL,
    left_at     timestamptz NOT NULL,
    complete    boolean NOT NULL,             -- the run rode the tronçon all along (rules in coverage.py)
    PRIMARY KEY (troncon_id, activity_id, run)
);
-- A passage the ride did not measure but earned by riding through the place the tronçon lies in (run 0).
ALTER TABLE couverture.passage ADD COLUMN IF NOT EXISTS by_place boolean NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS passage_activity ON couverture.passage (activity_id);
COMMENT ON TABLE couverture.passage IS
    'coverage: each time a bike ride went along a tronçon (coverage.py)';

-- Where each tronçon stands, from all its passages.
CREATE TABLE IF NOT EXISTS couverture.troncon_etat (
    troncon_id    integer PRIMARY KEY,
    ridden_m      double precision NOT NULL,  -- metres ridden, all passages together
    done          boolean NOT NULL,           -- ridden all along, by one passage or several together
    passages      integer NOT NULL,           -- passages that rode it all along
    rides         integer NOT NULL,           -- rides with such a passage
    first_at      timestamptz,                -- first time a ride went along it
    done_at       timestamptz,                -- when it was ridden all along for the first time
    done_activity bigint,                     -- the ride that did it
    last_at       timestamptz
);
COMMENT ON TABLE couverture.troncon_etat IS
    'coverage: metres ridden, done or not, number of passages and first and last passage of each tronçon (coverage.py)';

-- The rides measured, and the version of each that was.
CREATE TABLE IF NOT EXISTS couverture.sortie (
    activity_id bigint PRIMARY KEY,
    updated_at  timestamptz NOT NULL,         -- activity.updated_at when measured
    measured_at timestamptz NOT NULL DEFAULT now(),
    passages    integer NOT NULL
);

-- What the tronçons were cut from: osm.lieu's state then (one row).
CREATE TABLE IF NOT EXISTS couverture.build (
    one        boolean PRIMARY KEY DEFAULT true CHECK (one),
    osm_state  text NOT NULL,
    built_at   timestamptz NOT NULL DEFAULT now(),
    troncons   integer NOT NULL
);

-- Passage counters of each OSM way, from its tronçons or the tronçons it is merged into: the passages of the one
-- ridden most often (riding a whole way is one passage, however many crossroads cut it), the rides that rode one of
-- them all along, the first and last passage; with its geometry, for QGIS.
DROP VIEW IF EXISTS couverture.objet;
CREATE VIEW couverture.objet AS
WITH link AS (
    SELECT t.osm_id, 'rue' AS role, t.id AS troncon_id FROM couverture.troncon t
    UNION ALL
    SELECT m.osm_id, m.role, t.id
    FROM couverture.membre m JOIN couverture.troncon t ON t.osm_id = m.ref_osm_id AND t.a < m.ref_b AND t.b > m.ref_a
)
SELECT l.osm_id, string_agg(DISTINCT l.role, ',') AS roles, w.name, w.tags->>'highway' AS highway,
       coalesce(max(e.passages), 0) AS passages,
       (SELECT count(DISTINCT p.activity_id) FROM couverture.passage p
        WHERE p.complete AND p.troncon_id = ANY(array_agg(l.troncon_id))) AS rides,
       min(e.first_at) AS first_at, max(e.last_at) AS last_at, w.geom
FROM link l
JOIN osm.lieu w ON w.osm_type = 'w' AND w.osm_id = l.osm_id
LEFT JOIN couverture.troncon_etat e ON e.troncon_id = l.troncon_id
GROUP BY l.osm_id, w.name, w.tags, w.geom;
COMMENT ON VIEW couverture.objet IS
    'coverage: number of passages and rides along each OSM way (coverage.py)';

DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'qgis') THEN
        GRANT USAGE ON SCHEMA couverture TO qgis;
        GRANT SELECT ON ALL TABLES IN SCHEMA couverture TO qgis;
    END IF;
END $$;
