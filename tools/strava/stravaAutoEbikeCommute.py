"""Auto-normalise new Strava bike activities.

For each newly detected bike activity, this script enforces:
- sport type: EBikeRide
- gear: Flying Dutchman (id 17158902)
- commute: true

It keeps a local state file so only new activities are processed on next runs.
"""

from __future__ import annotations

import argparse
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable
from urllib import parse, request

from dotenv import load_dotenv
from stravalib.client import Client

from strava_config import (
    get_access_token,
    get_client_id,
    get_client_secret,
    get_expires_at,
    get_refresh_token,
)


DEFAULT_STATE_FILE = ".strava_ebike_commute_state.json"
DEFAULT_GEAR_ID = "17158902"
DEFAULT_GEAR_NAME = "Flying Dutchman"
DEFAULT_SCAN_LIMIT = 40
DEFAULT_ENV_FILE = ".env"
MAX_KNOWN_IDS = 2000
TOKEN_REFRESH_MARGIN_SECONDS = 120


def extract_sport(activity) -> str:
    raw = getattr(activity, "sport_type", None) or getattr(activity, "type", None)
    if raw is None:
        return ""
    text = str(raw)
    if "root='" in text:
        try:
            return text.split("root='", 1)[1].split("'", 1)[0]
        except Exception:
            return text
    return text


def is_bike_sport(sport: str) -> bool:
    if not sport:
        return False
    # Covers Ride, VirtualRide, MountainBikeRide, GravelRide, EBikeRide, etc.
    return sport.endswith("Ride")


def normalize_gear_id(gear_id) -> str:
    if gear_id is None:
        return ""
    text = str(gear_id)
    if text.startswith("b") and text[1:].isdigit():
        return text[1:]
    return text


def gear_candidates(target_gear_id: str) -> list[str]:
    raw = str(target_gear_id).strip()
    values = [raw]
    if raw.isdigit():
        values.append(f"b{raw}")
    elif raw.startswith("b") and raw[1:].isdigit():
        values.append(raw[1:])
    out = []
    for value in values:
        if value and value not in out:
            out.append(value)
    return out


def load_state(path: Path) -> dict:
    if not path.exists():
        return {"known_activity_ids": [], "updated_at": None}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {"known_activity_ids": [], "updated_at": None}


def save_state(path: Path, known_ids: Iterable[str]) -> None:
    deduped = []
    for activity_id in known_ids:
        if activity_id and activity_id not in deduped:
            deduped.append(activity_id)
        if len(deduped) >= MAX_KNOWN_IDS:
            break
    payload = {
        "known_activity_ids": deduped,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")


def update_env_file(path: Path, updates: dict[str, str]) -> None:
    if path.exists():
        lines = path.read_text(encoding="utf-8").splitlines()
    else:
        lines = []

    pending = dict(updates)
    output = []
    for line in lines:
        if not line.strip() or line.strip().startswith("#") or "=" not in line:
            output.append(line)
            continue
        key, _value = line.split("=", 1)
        key = key.strip()
        if key in pending:
            output.append(f"{key}={pending.pop(key)}")
        else:
            output.append(line)

    for key, value in pending.items():
        output.append(f"{key}={value}")

    path.write_text("\n".join(output) + "\n", encoding="utf-8")


def ensure_valid_access_token(args) -> str:
    access_token = get_access_token()
    expires_at = get_expires_at()
    now = int(time.time())
    should_refresh = (
        args.force_refresh
        or not access_token
        or (expires_at and now >= (expires_at - TOKEN_REFRESH_MARGIN_SECONDS))
    )

    if not should_refresh:
        return access_token

    client_id = get_client_id()
    client_secret = get_client_secret()
    refresh_token = get_refresh_token()

    missing = []
    if not client_id:
        missing.append("STRAVA_CLIENT_ID")
    if not client_secret:
        missing.append("STRAVA_CLIENT_SECRET")
    if not refresh_token:
        missing.append("STRAVA_REFRESH_TOKEN")

    if missing:
        raise RuntimeError(
            "Strava token needs refresh but required env vars are missing: "
            + ", ".join(missing)
        )

    data = parse.urlencode(
        {
            "client_id": client_id,
            "client_secret": client_secret,
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
        }
    ).encode()
    req = request.Request("https://www.strava.com/oauth/token", data=data, method="POST")
    with request.urlopen(req, timeout=20) as resp:
        payload = json.loads(resp.read().decode())

    new_access = payload.get("access_token", access_token)
    new_refresh = payload.get("refresh_token", refresh_token)
    new_expires = str(payload.get("expires_at", expires_at or 0))

    os.environ["STRAVA_ACCESS_TOKEN"] = new_access
    os.environ["STRAVA_REFRESH_TOKEN"] = new_refresh
    os.environ["STRAVA_EXPIRES_AT"] = new_expires

    if args.persist_tokens:
        update_env_file(
            Path(args.env_file),
            {
                "STRAVA_ACCESS_TOKEN": new_access,
                "STRAVA_REFRESH_TOKEN": new_refresh,
                "STRAVA_EXPIRES_AT": new_expires,
            },
        )

    print("Token refreshed.")
    return new_access


def apply_update(client: Client, activity_id: int, set_sport: bool, set_commute: bool, set_gear: bool, target_gear_id: str) -> dict:
    type_keys = [None]
    if set_sport:
        # Strava/stravalib versions may expect either key.
        type_keys = ["sport_type", "type"]

    gear_values = [None]
    if set_gear:
        gear_values = gear_candidates(target_gear_id)

    last_error = None
    for type_key in type_keys:
        for gear_value in gear_values:
            payload = {}
            if set_commute:
                payload["commute"] = True
            if type_key is not None:
                payload[type_key] = "EBikeRide"
            if gear_value is not None:
                payload["gear_id"] = gear_value
            try:
                client.update_activity(activity_id, **payload)
                return payload
            except Exception as exc:  # pragma: no cover - network/API dependent
                last_error = exc

    if last_error is None:
        raise RuntimeError("No update attempt was executed")
    raise last_error


def run_once(args) -> int:
    load_dotenv(args.env_file, override=True)
    access_token = ensure_valid_access_token(args)
    if not access_token:
        raise RuntimeError("Missing STRAVA_ACCESS_TOKEN in environment")

    client = Client(access_token=access_token)
    # Provide refresh context so stravalib does not warn on each API call.
    client.refresh_token = get_refresh_token()
    client.client_id = get_client_id()
    client.client_secret = get_client_secret()
    client.token_expires = get_expires_at()
    state_path = Path(args.state_file)
    state = load_state(state_path)
    known_ids = [str(x) for x in state.get("known_activity_ids", [])]
    known_set = set(known_ids)

    activities = list(client.get_activities(limit=args.scan_limit))

    current_ids = [str(getattr(a, "id", "")) for a in activities if getattr(a, "id", None)]

    if args.bootstrap and not known_set:
        save_state(state_path, current_ids)
        print(f"Bootstrap complete: {len(current_ids)} activities registered in state ({state_path}).")
        return 0

    new_activities = [a for a in activities if str(getattr(a, "id", "")) not in known_set]
    if not new_activities:
        print("No new activities detected.")
        return 0

    # Process oldest -> newest for deterministic behavior.
    new_activities = list(reversed(new_activities))

    mark_known = []
    updated = 0
    failed = 0

    for activity in new_activities:
        activity_id = str(getattr(activity, "id", ""))
        if not activity_id:
            continue

        sport = extract_sport(activity)
        if not is_bike_sport(sport):
            print(f"Skip #{activity_id}: non-bike sport ({sport}).")
            mark_known.append(activity_id)
            continue

        current_gear = normalize_gear_id(getattr(activity, "gear_id", None))
        target_gear = normalize_gear_id(args.target_gear_id)

        need_sport = sport != "EBikeRide"
        need_commute = bool(getattr(activity, "commute", False)) is not True
        need_gear = current_gear != target_gear

        if not (need_sport or need_commute or need_gear):
            print(f"Already compliant #{activity_id} ({sport}, gear={current_gear}, commute=True).")
            mark_known.append(activity_id)
            continue

        if args.dry_run:
            print(
                f"[DRY-RUN] Would update #{activity_id}: "
                f"sport={sport}->{('EBikeRide' if need_sport else sport)} "
                f"gear={current_gear}->{target_gear} "
                f"commute={getattr(activity, 'commute', None)}->True"
            )
            continue

        try:
            payload = apply_update(
                client=client,
                activity_id=int(activity_id),
                set_sport=need_sport,
                set_commute=need_commute,
                set_gear=need_gear,
                target_gear_id=args.target_gear_id,
            )
            updated += 1
            mark_known.append(activity_id)
            print(
                f"Updated #{activity_id} -> "
                f"sport=EBikeRide, gear={args.target_gear_name}({args.target_gear_id}), commute=True | payload={payload}"
            )
        except Exception as exc:  # pragma: no cover - network/API dependent
            failed += 1
            print(f"ERROR updating #{activity_id}: {exc}")

    if not args.dry_run:
        merged = mark_known + known_ids
        save_state(state_path, merged)

    print(
        f"Done. scanned={len(activities)} new={len(new_activities)} "
        f"updated={updated} failed={failed} state={state_path}"
    )
    return 0


def parse_args():
    parser = argparse.ArgumentParser(
        description="Auto-fix new Strava bike activities to EBikeRide + Flying Dutchman + commute"
    )
    parser.add_argument("--state-file", default=DEFAULT_STATE_FILE, help="State file path")
    parser.add_argument("--env-file", default=DEFAULT_ENV_FILE, help="Path to .env file")
    parser.add_argument("--scan-limit", type=int, default=DEFAULT_SCAN_LIMIT, help="How many latest activities to scan")
    parser.add_argument("--target-gear-id", default=DEFAULT_GEAR_ID, help="Target gear id")
    parser.add_argument("--target-gear-name", default=DEFAULT_GEAR_NAME, help="Target gear name (logs only)")
    parser.add_argument("--force-refresh", action="store_true", help="Force Strava token refresh now")
    parser.add_argument(
        "--no-persist-tokens",
        dest="persist_tokens",
        action="store_false",
        help="Do not write refreshed tokens to the env file",
    )
    parser.set_defaults(persist_tokens=True)
    parser.add_argument("--dry-run", action="store_true", help="Preview changes without updating activities")
    parser.add_argument(
        "--bootstrap",
        action="store_true",
        help="First run only: register recent activities into state without applying updates",
    )
    parser.add_argument("--loop-seconds", type=int, default=0, help="If >0, run in loop every N seconds")
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    if args.loop_seconds <= 0:
        run_once(args)
        return

    while True:
        try:
            run_once(args)
        except Exception as exc:
            print(f"Loop error: {exc}")
        time.sleep(args.loop_seconds)


if __name__ == "__main__":
    main()
