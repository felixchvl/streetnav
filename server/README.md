# Streetnav server

Activity registry for Streetnav: one row per real-world activity, whatever the number of services
holding a copy of it (Apple Health, Ride with GPS, Strava...). Runs in the `streetnav` LXC
(Proxmox CT 141, Debian 13, 192.168.1.62).

## Three layers

Every activity exists in several versions (Apple Health, Strava, Ride with GPS, HealthFit files). Nothing
received is lost, and the activity everyone reads is computed from all its versions:

1. **Bronze** - each version exactly as received, in files under `/var/lib/streetnav/raw`
   (`STREETNAV_RAW_DIR`): the JSON the iPhone app pushed, the trip JSON from Ride with GPS, each FIT
   file, and for Strava `activities.csv`, the original file and the website trace. Files are named by
   their sha256 and never rewritten; table `raw_file` lists them (source, external id, part, original
   name, path, sha256, size, batch, received at). A deletion adds a row, files stay. An identical resend
   adds nothing (JSON is compared with sorted keys: the app writes its keys in any order).
2. **Silver** - `activity_source`: one row per version with its own metrics, track and heart rate, read
   from its current bronze files (`parsed_at` NULL: loaded before bronze existed, not read from it yet).
   A version is attached to an activity when it arrives (start within 90 s, or overlapping at least half
   of it) and stays there: rebuilds do not regroup, so activity ids are stable.
3. **Gold** - `activity` and `activity_heart_rate`, computed field by field (`streetnav_server/gold.py`):
   - measures (time window, track, heart rate, distance, durations, calories, ascent) come from Apple
     Health, the Watch's own recording: the app's copy, then the HealthFit file, then Strava, then Ride
     with GPS;
   - hand edits (name, description, commute flag, gear, sport type) come from Strava first;
   - a ride cropped by hand on Strava (its window starts or ends more than 15 s away from Apple Health's,
     and it has a track) takes all its measures from Strava;
   - otherwise an outdoor ride's idle start and end are cut: what is both slow (under 6 km/h over 30 s)
     and in one place (within 100 m of the first or last point), when it lasts more than 60 s. Distance
     and ascent lose the cut part, heart rate is recomputed, calories are prorated by time;
   - `provenance` names the version behind each field (`source:external_id`) and what was cropped;
     `primary_source` is the source of the measures.

   An activity with a version not read from bronze yet is left as it is.

`python -m streetnav_server.layers status | rebuild-silver | rebuild-gold` rebuilds silver from bronze and
gold from silver without importing anything again (`--dry-run` to see the counts first).

## Pieces

- `sql/` - PostgreSQL 17 + PostGIS schema: `activity` (track as `LineStringZM`: lon, lat, altitude,
  Unix time), `activity_source`, `activity_heart_rate`, `raw_file`, `sync_run`.
- `streetnav_server/registry.py` - attaches each arriving version to its activity (one writer at a time,
  through a PostgreSQL advisory lock), `bronze.py`, `sources.py` (reads a version from its bronze files),
  `gold.py`, `layers.py`.
- `streetnav_server/api.py` - FastAPI on port 8080. All endpoints but `/health` need
  `Authorization: Bearer <STREETNAV_API_TOKEN>`:
  - `GET /status`, `GET /activities?since&until&sport&limit`, `GET /activities/{id}` (GeoJSON track),
  - `GET /reconcile?missing_in=rwgps&since` - activities with a track and no copy on that service,
  - `POST /activities` - push a workout (the iOS app sends Apple Health workouts here); the request body
    is kept in bronze as is,
  - `DELETE /copies/{source}/{external_id}` - forget a copy deleted at its source (a workout deleted in
    Apple Health); its activity is recomputed from the others, or deleted if none is left.
- `streetnav_server/rwgps_sync.py` - read-only Ride with GPS import, every 10 minutes (systemd timer).
  `--full` also downloads again every trip not in bronze yet; a run started during another one exits.
- `streetnav_server/strava_import.py` - one-off import of Strava's official account archive (the
  Strava API is subscriber-only), see below.
- `streetnav_server/file_import.py` - import of a folder of FIT, GPX or TCX files, such as the FIT
  files HealthFit exports from Apple Health (source `file`, below Apple Health and Strava).
- `streetnav_server/activity_files.py` - the file readers shared by both imports.
- `tests/` - `python -m unittest discover -s tests`. The database tests also need
  `STREETNAV_TEST_DATABASE_URL`, a throwaway PostGIS database they empty, and the API tests httpx;
  without them they are skipped.
- `deploy/` - idempotent `install.sh`, systemd units, nightly `pg_dump` (03:30, 14 kept, in
  `/var/backups/streetnav`). The dumps do not hold bronze: back up `/var/lib/streetnav/raw` apart.

## Deploy / update

Copy this `server/` folder into the container and run `bash server/deploy/install.sh` as root.
Secrets are generated once in `/etc/streetnav/streetnav.env` (database URL, API token, Ride with
GPS key and auth token) and never overwritten. `install.sh` restarts PostgreSQL: do not run it
while an import is in progress.

## Strava import

1. Request the archive at `strava.com/athlete/download_my_account`, with Strava's display language
   set to English (the CSV headers and dates are parsed). The link arrives by e-mail.
2. Copy only `activities.csv` and `activities/` to the container (plus the website export's
   `streams-*.json`, `activities.json` and `gear.json` if `--check-web` is used): the rest of the archive
   holds logins, contacts and messages. Bronze keeps what is read, so the copies can be deleted afterwards.
3. Run, as the `streetnav` user from `/opt/streetnav` with `/etc/streetnav/streetnav.env` loaded:
   `venv/bin/python -m streetnav_server.strava_import ARCHIVE_DIR --dry-run`, then without `--dry-run`.
   `--check-only` reads and checks the files without touching the database.

The CSV carries the hand edits (name, sport type, commute flag, gear, cropped elapsed time and
distance); the files are the original uploads, so each one is cut to the CSV's time window, which is
what a Strava crop is. `--check-web DIR` compares the result with an export read from the website
(`activities.json`, `gear.json`, `streams-*.json`): differences are listed, and a website trace
replaces an archive track that does not match it (bronze then keeps that streams file with the version).
On the 2026-10-28 archive (2,380 activities,
2,175 tracks), 154 of 157 website traces matched; the 3 others were alpine ski days. The archive
names a trail run "Run": the sport type cannot be more precise than the CSV's display name.

## Apple Health from the iPhone app

The iOS app reads Apple Health (read only) and sends each workout to `POST /activities` as source
`healthkit`, with its route and heart rate: the whole history on the first sync, then every workout added
or deleted, iOS waking the app in the background. Set the server address and the API token in the app,
under Integrations → Apple Santé. Its copies attach to the activities already loaded and provide their
measures. « Tout renvoyer » (Réglages › Apple Santé) sends the whole history again: identical workouts add
nothing to bronze. Until remote access is enabled, the iPhone reaches the server on the home network only
(`http://192.168.1.62:8080`).

## Apple Health files

HealthFit exports every Apple Health workout as a FIT file to its iCloud Drive folder. Copy that
folder to the container and run `venv/bin/python -m streetnav_server.file_import DIR --dry-run`, then
without `--dry-run` (same user and environment as above). Each file is a copy; re-running only
updates them, and only new or changed files reach bronze (`--batch NAME` names the import there).

## State on 2026-10-28

Loaded in this order: Ride with GPS (2,490 copies), the Strava archive (2,380), HealthFit's export
(2,437 FIT files, October 2022 onwards). Result: 2,575 activities from 2019-12 to today, 2,281 with a
track. Every activity that has a Strava copy takes its data from Strava; the others from the Apple
Health files (191) or Ride with GPS (10, mostly old entries without GPS). All 2,674 Wandrer
activities match an activity. Six Strava activities were duplicates on Strava itself and share an
activity with their twin.

## State on 2026-11-01

The three layers were deployed and bronze filled from every source: the Strava archive and website
streams, HealthFit's 2,452 FIT files, every Ride with GPS trip downloaded again, and the iPhone app's
« Tout renvoyer ». Bronze: 9,860 versions in 638 MB (Apple Health 2,524, Ride with GPS 2,504, files
2,452, Strava 2,380); the database grew to 674 MB. Gold, rebuilt from them: the same 2,598 activities
with the same ids. Of the 2,276 rides, 2,168 take their measures from Apple Health, 59 keep their
Strava crop and 548 had an idle start or end cut (21 h in all); total distance 15,364 km before,
15,347 km after. Two quirks were found on the way: macOS and tar disagree on the Unicode form of
HealthFit file names (ids are now NFC), and some Apple Health workouts hold their route twice (silver
keeps one sample per instant).

## QGIS

The `qgis` login role (created by paris-rues's install, password kept out of this repo) reads Streetnav from the
home network only and over TLS: `sql/004_qgis.sql` grants it `SELECT` on `activity`, `activity_heart_rate` and
`activity_source`, and `pg_hba.conf` holds `hostssl streetnav qgis 192.168.1.0/24 scram-sha-256` (added by hand).
Since 2026-11-02 paris-rues's tables live in this database too, in the `paris_rues` schema (its own install, its own
nightly dump; `streetnav-backup` leaves that schema out). In QGIS: a
PostgreSQL connection to `192.168.1.62:5432`, database `streetnav`, SSL mode `require`. Useful layers:
`activity` (track, one line per activity; filter `sport = 'cycling'`) and `activity_source` (one track per
version, to compare them). Tracks are `LineStringZM` in EPSG:4326, both with a spatial index.

## Remote access

Enabled on 2026-11-01: the iPhone reaches the API from anywhere at `https://streetnav.felixchevalier.fr`,
through the home Caddy, without a VPN:

1. `deploy/make-client-cert.sh ~/.config/streetnav/pki iphone` creates a private CA and the
   iPhone's certificate (`iphone.p12`). The folder holds private keys: never commit it.
2. `ca.pem` is at `/etc/caddy/streetnav-client-ca.pem` on the Caddy container (LXC 110) and
   `deploy/caddy-streetnav.caddy` is its `sites/public/30-streetnav.caddy`; Let's Encrypt issues the
   server certificate (TLS-ALPN challenge).
3. A DNS A record `streetnav.felixchevalier.fr` points to the home public IP.
4. In the app, Réglages › Serveur Streetnav › « Hors de chez toi » imports `iphone.p12` into the app's own
   keychain (a profile installed in iOS Settings is not readable by apps), then « Utiliser l'adresse
   publique ». Every request answers Caddy's client-certificate challenge with it, then sends the bearer
   token as usual.

Without the certificate the TLS handshake fails, so nothing reaches FastAPI. The public address also works
from the home network.

## Map data

`GET /tracks` returns every bike ride's track as GeoJSON, simplified to about 5 metres (2,273 rides:
2.2 MB, 0.5 MB gzipped), with an ETag; `GET /stats` the riding statistics. The app caches both.

`GET /streets` returns every street around Paris cut into ridden (`r` = 1) and not ridden (`r` = 0) parts,
the two colours of the app's map, with the width class of their road in Mapbox Standard (`k`, `map_data.ROAD_CLASS`) for
the app to draw them as wide as the road (1.6 MB gzipped, ETag on the last street run and the format). `streetnav_server/streets.py`
builds them (`sql/005_streets.sql`): OpenStreetMap's ways in Paris and the inner suburbs, from Overpass every month
(`streetnav-osm.timer`, the 1st at 04:00), in 4 x 4 tiles of the box around the 75, 92, 93 and 94, each loaded as it
comes, then only the ways within their outlines kept (`zone`, below). The `street` table is the one
copy of OpenStreetMap for Streetnav and paris-rues, which reads the named ways of Paris from it and attaches them to
the city's register of voies (its role may read `street` and `activity`). A bike may ride a way or not
by paris-rues's rules (explicit `bicycle` tags first, then access, then the kind of way: footways, steps and
pedestrian streets without `bicycle=yes` are closed), and sidewalks, crossings and areas are not ways of their own;
only the ways a bike may ride are drawn and measured. A point of a street
counts as ridden when a ride passes within 12 m, sampled every 10 m, and a ridden stretch shorter than 5
samples is only a ride crossing the street. A bike path (or footway, path, busway) running alongside a street a bike
may ride (within 20 m all along) belongs to that street, as on the map: it is neither drawn nor counted, and riding it rides
the street. A place of Paris (place, carrefour or rond-point in the city's register, read from paris-rues's
`paris_rues.voie`, footprint widened by 3 m) is one open area: parts are cut at its edge, and once rides went through
it along 20 m of its ways, every part inside it is shown as ridden (`street_part.place`; `ridden` stays what the
rides measured). On 2026-11-02: 85,435 ways measured, 9,520 km, 1,440 km ridden, 1,453 km with the 344 places ridden
through. `compute` redoes everything
(about 50 s); `streetnav-streets.timer` runs
`refresh` every 15 minutes, only around the rides added or changed since the last run.

The streets ridden zone by zone (`streetnav_server/zones.py`, `sql/006_zones.sql`, in `GET /stats`): the 20
arrondissements of Paris and the 122 communes of the 92, 93 and 94 from the State's API Géo (`zones fetch`, once at
install), numbered in rings out from Paris: ring 1 is the 29 communes along its edge, and ring 6 the far end of the 93
and 94. Each part belongs to the zone its middle lies in. Since 2026-11-03 the ways cover the four departments whole; before,
a box left out about a third of the 93 and of the 94.
