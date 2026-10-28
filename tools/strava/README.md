# Strava API scripts

Former `felixchvl/strava-database` repository, merged here with its history. Scripts on the official Strava API
(`stravalib`) that clean up bike activities: e-bike type, bike (gear), commute flag, privacy, plus stats and a full
export to a dataframe.

> **Out of service since 2026-07-25.** Strava now keeps its API for subscribers: every call returns
> `403 Application Status Inactive`. The scripts are kept for reference. Streetnav takes Strava data from the
> athlete's own export instead (`server/streetnav_server/strava_import.py`).

| Script | Purpose |
|---|---|
| `stravaAutoEbikeCommute.py` | scheduled job (every 10 min, launchd/cron): new bike activities → `EBikeRide`, bike `--target-gear-id`, commute; remembers what it handled in a state file |
| `stravaGearUpdate.py` | set the bike of activities in a date range (`--list-gear`, `--gear-id`, `--apply`) |
| `stravaElecBike*.py` | one-off fixes: e-bike type, commute / not commute, private |
| `stravaAllDataframe.py`, `stravaStats.py` | export every activity to a dataframe, summary stats |
| `strava_config.py` | reads the credentials from `.env` |

## Setup

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
cp .env.example .env    # Strava client id/secret and tokens; .env is ignored by git
.venv/bin/python stravaGearUpdate.py --list-gear
.venv/bin/python stravaAutoEbikeCommute.py --env-file .env \
  --state-file .strava_ebike_commute_state.json --target-gear-id <GEAR_ID>
```

Tokens, the state file and generated CSV/JSON never go into git (see `.gitignore`).
