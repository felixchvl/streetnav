# Streetnav server

Activity registry for Streetnav: one row per real-world activity, whatever the number of services
holding a copy of it (Apple Health, Ride with GPS, Strava...). Runs in the `streetnav` LXC
(Proxmox CT 141, Debian 13, 192.168.1.62).

## Pieces

- `sql/` - PostgreSQL 17 + PostGIS schema: `activity` (metrics, track as `LineStringZM`: lon, lat,
  altitude, Unix time), `activity_source` (each service's copy), `activity_heart_rate`, `sync_run`.
- `streetnav_server/registry.py` - merge rule: a copy starting within 90 s of an existing activity
  is attached to it; the highest-priority source (healthkit > file > rwgps > strava) provides the
  metrics and the track, lower ones only fill gaps.
- `streetnav_server/api.py` - FastAPI on port 8080. All endpoints but `/health` need
  `Authorization: Bearer <STREETNAV_API_TOKEN>`:
  - `GET /status`, `GET /activities?since&until&sport&limit`, `GET /activities/{id}` (GeoJSON track),
  - `GET /reconcile?missing_in=rwgps&since` - activities with a track and no copy on that service,
  - `POST /activities` - push a workout (the iOS app sends Apple Health workouts here).
- `streetnav_server/rwgps_sync.py` - read-only Ride with GPS import, every 10 minutes (systemd timer).
- `deploy/` - idempotent `install.sh`, systemd units, nightly `pg_dump` (03:30, 14 kept, in
  `/var/backups/streetnav`).

## Deploy / update

Copy this `server/` folder into the container and run `bash server/deploy/install.sh` as root.
Secrets are generated once in `/etc/streetnav/streetnav.env` (database URL, API token, Ride with
GPS key and auth token) and never overwritten. `install.sh` restarts PostgreSQL: do not run it
while an import is in progress.
