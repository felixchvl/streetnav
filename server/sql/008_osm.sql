-- OpenStreetMap, the one reference of the places of Paris and the inner suburbs (75, 92, 93 and 94) for Streetnav and
-- paris-rues (streetnav_server/osm.py): the ways, the squares and the administrative limits as OSM has them, kept up to
-- date as mappers edit. Lambert-93 (metres).
CREATE SCHEMA IF NOT EXISTS osm;

CREATE TABLE IF NOT EXISTS osm.lieu (
    osm_type    char(1) NOT NULL CHECK (osm_type IN ('w', 'r')),  -- way or relation
    osm_id      bigint NOT NULL,
    kind        text NOT NULL CHECK (kind IN ('voie', 'place', 'limite')),
    name        text,
    tags        jsonb NOT NULL,                  -- every tag, as OSM has it
    admin_level smallint,                        -- limits: 6 department, 8 commune, 9 arrondissement, 10 quartier
    code        text,                            -- limits: INSEE code (75, 92011, 75111...)
    ring        smallint,                        -- zones (arrondissements of Paris, communes of 92, 93, 94): 0 Paris, 1 along its edge...
    zone        text,                            -- voies and places: code of the zone their middle lies in
    bike        boolean,                         -- voies: may a bike ride it
    bike_reason text,                            -- voies: the tag that decided
    counted     boolean,                         -- voies: a way of its own, not a sidewalk or a crossing
    nodes       bigint[],                        -- ways: their nodes in order, to follow a node moved
    geom        geometry(Geometry, 2154) NOT NULL,
    version     integer NOT NULL,
    changeset   bigint,
    edited_at   timestamptz NOT NULL,            -- when this version was saved in OSM
    loaded_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (osm_type, osm_id)
);
CREATE INDEX IF NOT EXISTS lieu_geom ON osm.lieu USING gist (geom);
CREATE INDEX IF NOT EXISTS lieu_nodes ON osm.lieu USING gin (nodes);
CREATE INDEX IF NOT EXISTS lieu_kind ON osm.lieu (kind, admin_level);
CREATE INDEX IF NOT EXISTS lieu_name ON osm.lieu (name);
COMMENT ON TABLE osm.lieu IS
    'reference: the ways, squares and administrative limits of the 75, 92, 93 and 94 from OpenStreetMap, updated every few minutes (osm.py)';

-- The voies as people name them: the ways of the same name in the same zone.
CREATE OR REPLACE VIEW osm.voie AS
SELECT name, zone, count(*) AS ways, sum(ST_Length(geom)) AS length_m, ST_Collect(geom) AS geom,
       array_agg(osm_id ORDER BY osm_id) AS osm_ids
FROM osm.lieu WHERE kind = 'voie' AND name IS NOT NULL
GROUP BY name, zone;
COMMENT ON VIEW osm.voie IS 'reference: the ways of osm.lieu grouped by name and zone';

DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'qgis') THEN
        GRANT USAGE ON SCHEMA osm TO qgis;
        GRANT SELECT ON osm.lieu, osm.voie TO qgis;
    END IF;
END $$;

-- The streets ridden and the zones from the State's API Géo, until 2026-11-05: the coverage will be measured again
-- from what each ride brought, on osm.lieu.
DROP TABLE IF EXISTS street_part, ride_piece, street_run, street, zone CASCADE;
