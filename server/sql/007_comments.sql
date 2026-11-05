-- What each table holds and which layer it belongs to, shown by psql (\dt+) and QGIS. The activities follow bronze,
-- silver and gold (003_layers.sql); OpenStreetMap's places are a reference beside them (008_osm.sql).
COMMENT ON TABLE raw_file IS
    'bronze: index of every file received, kept as is under STREETNAV_RAW_DIR (/var/lib/streetnav/raw); append only';
COMMENT ON TABLE activity_source IS
    'silver: one row per version of an activity (Apple Health, Strava, Ride with GPS, HealthFit file), read from bronze; rebuilt by python -m streetnav_server.layers rebuild-silver';
COMMENT ON TABLE activity IS
    'gold: one row per real activity, each field taken from its versions (provenance names which); rebuilt by python -m streetnav_server.layers rebuild-gold';
COMMENT ON TABLE activity_heart_rate IS
    'gold: heart rate of each activity, from the version giving its measures';
COMMENT ON TABLE sync_run IS
    'log: last run of each importer, read by GET /status';
