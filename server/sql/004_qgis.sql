-- Read-only access for QGIS on the home network, through the `qgis` login role (created by hand on the server,
-- password kept out of this repo). pg_hba.conf must also allow it: hostssl streetnav qgis 192.168.1.0/24 scram-sha-256.
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'qgis') THEN
        EXECUTE format('GRANT CONNECT ON DATABASE %I TO qgis', current_database());
        GRANT USAGE ON SCHEMA public TO qgis;
        GRANT SELECT ON activity, activity_heart_rate, activity_source TO qgis;
    END IF;
END $$;
