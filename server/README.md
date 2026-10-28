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
- `streetnav_server/strava_import.py` - one-off import of Strava's official account archive (the
  Strava API is subscriber-only), see below.
- `streetnav_server/file_import.py` - import of a folder of FIT, GPX or TCX files, such as the FIT
  files HealthFit exports from Apple Health (source `file`, below Apple Health and Strava).
- `streetnav_server/activity_files.py` - the file readers shared by both imports.
- `tests/` - `python -m unittest discover -s tests`, no database needed.
- `deploy/` - idempotent `install.sh`, systemd units, nightly `pg_dump` (03:30, 14 kept, in
  `/var/backups/streetnav`).

## Deploy / update

Copy this `server/` folder into the container and run `bash server/deploy/install.sh` as root.
Secrets are generated once in `/etc/streetnav/streetnav.env` (database URL, API token, Ride with
GPS key and auth token) and never overwritten. `install.sh` restarts PostgreSQL: do not run it
while an import is in progress.

## Strava import

1. Request the archive at `strava.com/athlete/download_my_account`, with Strava's display language
   set to English (the CSV headers and dates are parsed). The link arrives by e-mail.
2. Copy only `activities.csv` and `activities/` to the container: the rest of the archive holds
   logins, contacts and messages.
3. Run, as the `streetnav` user from `/opt/streetnav` with `/etc/streetnav/streetnav.env` loaded:
   `venv/bin/python -m streetnav_server.strava_import ARCHIVE_DIR --dry-run`, then without `--dry-run`.
   `--check-only` reads and checks the files without touching the database.

The CSV carries the hand edits (name, sport type, commute flag, gear, cropped elapsed time and
distance); the files are the original uploads, so each one is cut to the CSV's time window, which is
what a Strava crop is. `--check-web DIR` compares the result with an export read from the website
(`activities.json`, `gear.json`, `streams-*.json`): differences are listed, and a website trace
replaces an archive track that does not match it. On the 2026-10-28 archive (2,380 activities,
2,175 tracks), 154 of 157 website traces matched; the 3 others were alpine ski days. The archive
names a trail run "Run": the sport type cannot be more precise than the CSV's display name.

## Apple Health files

HealthFit exports every Apple Health workout as a FIT file to its iCloud Drive folder. Copy that
folder to the container and run `venv/bin/python -m streetnav_server.file_import DIR --dry-run`, then
without `--dry-run` (same user and environment as above). Each file is a copy; re-running only
updates them.

## State on 2026-10-28

Loaded in this order: Ride with GPS (2,490 copies), the Strava archive (2,380), HealthFit's export
(2,437 FIT files, October 2022 onwards). Result: 2,575 activities from 2019-12 to today, 2,281 with a
track. Every activity that has a Strava copy takes its data from Strava; the others from the Apple
Health files (191) or Ride with GPS (10, mostly old entries without GPS). All 2,674 Wandrer
activities match an activity. Six Strava activities were duplicates on Strava itself and share an
activity with their twin.

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
