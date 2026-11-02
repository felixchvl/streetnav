-- The arrondissements of Paris and the communes of the inner suburbs (92, 93, 94), as the State's API Géo draws them
-- (streetnav_server/zones.py), for the streets ridden zone by zone: ring 0 is Paris, ring 1 the communes along its
-- edge, ring 2 those along ring 1's, and so on to the far end of the three departments.
CREATE TABLE IF NOT EXISTS zone (
    code       text PRIMARY KEY,          -- INSEE code: 75101 to 75120 for the arrondissements
    name       text NOT NULL,
    department text NOT NULL,             -- 75, 92, 93 or 94
    ring       smallint,                  -- NULL for a commune cut off from the others (none in 2026)
    geom       geometry(MultiPolygon, 2154) NOT NULL
);
CREATE INDEX IF NOT EXISTS zone_geom ON zone USING gist (geom);

-- The zone the middle of a part lies in; NULL outside them (zones.py).
ALTER TABLE street_part ADD COLUMN IF NOT EXISTS zone text;
