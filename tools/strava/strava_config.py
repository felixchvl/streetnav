import os
from dotenv import load_dotenv

load_dotenv()


def require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def get_client_id(default: int = 0) -> int:
    raw = os.environ.get("STRAVA_CLIENT_ID")
    if raw:
        return int(raw)
    return default


def get_client_secret(default: str = "") -> str:
    return os.environ.get("STRAVA_CLIENT_SECRET", default)


def get_access_token(default: str = "") -> str:
    return os.environ.get("STRAVA_ACCESS_TOKEN", default)


def get_refresh_token(default: str = "") -> str:
    return os.environ.get("STRAVA_REFRESH_TOKEN", default)


def get_expires_at(default: int = 0) -> int:
    raw = os.environ.get("STRAVA_EXPIRES_AT")
    if raw:
        return int(raw)
    return default
