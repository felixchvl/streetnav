-- What each table holds and which layer it belongs to, shown by psql (\dt+) and QGIS. The activities follow bronze,
-- silver and gold (003_layers.sql); the streets are a reference crossed with the rides, outside those layers.
COMMENT ON TABLE raw_file IS
    'bronze: index of every file received, kept as is under STREETNAV_RAW_DIR (/var/lib/streetnav/raw); append only';
COMMENT ON TABLE activity_source IS
    'silver: one row per version of an activity (Apple Health, Strava, Ride with GPS, HealthFit file), read from bronze; rebuilt by python -m streetnav_server.layers rebuild-silver';
COMMENT ON TABLE activity IS
    'gold: one row per real activity, each field taken from its versions (provenance names which); rebuilt by python -m streetnav_server.layers rebuild-gold';
COMMENT ON TABLE activity_heart_rate IS
    'gold: heart rate of each activity, from the version giving its measures';
COMMENT ON TABLE street IS
    'reference: OpenStreetMap ways of Paris and the 92, 93 and 94 (streets.py)';
COMMENT ON TABLE zone IS
    'reference: arrondissements of Paris and communes of the 92, 93 and 94, from the State''s API Géo (zones.py)';
COMMENT ON TABLE ride_piece IS
    'derived from gold: the bike rides'' tracks cut into short pieces for the spatial index (streets.py)';
COMMENT ON TABLE street_part IS
    'derived from gold: each street cut into parts, ridden or not (streets.py)';
COMMENT ON TABLE street_run IS
    'log: each run of the streets ridden computation';
COMMENT ON TABLE sync_run IS
    'log: last run of each importer, read by GET /status';
