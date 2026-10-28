# Streetnav server

Activity registry for Streetnav: one row per real-world activity, whatever the number of services
holding a copy of it (Apple Health, Ride with GPS, Strava...). Runs in the `streetnav` LXC
(Proxmox CT 141, Debian 13, 192.168.1.62).

## Pieces

- `sql/` - PostgreSQL 17 + PostGIS schema: `activity` (metrics, track as `LineStringZM`: lon, lat,
  altitude, Unix time), `activity_source` (each service's copy), `activity_heart_rate`, `sync_run`.
- `streetnav_server/registry.py` - merge rule: a copy starting within 90 s of an existing activity,
  or overlapping at least half of it, is attached to it; the highest-priority source
  (strava > healthkit > file > rwgps) provides the metrics, the hand edits (name, commute, gear,
  sport type) and the track, lower ones only fill gaps. Strava comes first because that is where
  rides were cropped and classified by hand.
- `streetnav_server/api.py` - FastAPI on port 8080. All endpoints but `/health` need
  `Authorization: Bearer <STREETNAV_API_TOKEN>`:
  - `GET /status`, `GET /activities?since&until&sport&limit`, `GET /activities/{id}` (GeoJSON track),
  - `GET /reconcile?missing_in=rwgps&since` - activities with a track and no copy on that service,
  - `POST /activities` - push a workout (the iOS app sends Apple Health workouts here).
- `streetnav_server/rwgps_sync.py` - read-only Ride with GPS import, every 10 minutes (systemd timer).
- `streetnav_server/strava_import.py` - one-off import of a Strava export read from the web session
  (the Strava API is subscriber-only): activity rows, gear names, and the tracks of the activities
  whose Strava version differs from the other copies. Run it with `--dry-run` first.
- `deploy/` - idempotent `install.sh`, systemd units, nightly `pg_dump` (03:30, 14 kept, in
  `/var/backups/streetnav`).

## Deploy / update

Copy this `server/` folder into the container and run `bash server/deploy/install.sh` as root.
Secrets are generated once in `/etc/streetnav/streetnav.env` (database URL, API token, Ride with
GPS key and auth token) and never overwritten. `install.sh` restarts PostgreSQL: do not run it
while an import is in progress.

## Remote access (not enabled yet)

The iPhone reaches the API from anywhere through the home Caddy, without a VPN:

1. `deploy/make-client-cert.sh ~/.config/streetnav/pki iphone` creates a private CA and the
   iPhone's certificate (`iphone.p12`). The folder holds private keys: never commit it.
2. Copy `ca.pem` to `/etc/caddy/streetnav-client-ca.pem` on the Caddy container, add
   `deploy/caddy-streetnav.caddy` to its sites and reload Caddy.
3. Add a DNS A record `streetnav.felixchevalier.fr` pointing to the home public IP.
4. The app imports `iphone.p12` into its own keychain (a profile installed in iOS Settings is not
   readable by apps) and answers Caddy's client-certificate challenge with it, then sends the
   bearer token as usual.

Without the certificate the TLS handshake fails, so nothing reaches FastAPI.
