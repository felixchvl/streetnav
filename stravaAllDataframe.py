
"""Extraction Strava -> DataFrame

But: Récupérer toutes (ou un sous-ensemble) des activités et produire un CSV avec
Colonnes: id, start_date, distance_km, gear_id, gear_name, sport, commute

Variables d'environnement optionnelles:
    MAX_ACTIVITIES   (int, défaut 0 (illimité), >0 => limite)
    START_DATE       (YYYY-MM-DD filtre sur start_date >=)
    PROGRESS_EVERY   (int, défaut 100 logs toutes les N activités)
    WRITE_CSV        (1 pour écrire activities_full.csv)

Pré-requis scopes: read, activity:read (et activity:read_all si activités privées/détaillées).
"""

import os
import json
import traceback
from datetime import datetime, timezone

try:
    from stravalib.client import Client
    from stravalib import exc as strava_exc
except Exception:
    print("Erreur: le module 'stravalib' n'est pas installé. Installe-le avec: python -m pip install stravalib")
    raise

import requests
from urllib.parse import urlencode
from strava_config import (
    get_access_token,
    get_client_id,
    get_client_secret,
    get_refresh_token,
    get_expires_at,
)

CLIENT_ID = get_client_id(137455)
CLIENT_SECRET = get_client_secret()
ACCESS_TOKEN = get_access_token()
REFRESH_TOKEN = get_refresh_token()
EXPIRES_AT = get_expires_at()

def build_auth_url(scopes=None):
    if scopes is None:
        scopes = ["read","activity:read","activity:read_all","activity:write"]
    params = {
        "client_id": CLIENT_ID,
        "response_type": "code",
        "redirect_uri": "http://localhost/exchange_token",
        "approval_prompt": "force",
        "scope": ",".join(scopes),
    }
    return f"https://www.strava.com/oauth/authorize?{urlencode(params)}"

def refresh_access_token(client_id, client_secret, refresh_token):
    url = 'https://www.strava.com/oauth/token'
    payload = {
        'client_id': client_id,
        'client_secret': client_secret,
        'grant_type': 'refresh_token',
        'refresh_token': refresh_token,
    }
    try:
        r = requests.post(url, data=payload, timeout=10)
        r.raise_for_status()
        return r.json()
    except Exception:
        print('Échec du rafraîchissement du token:')
        traceback.print_exc()
        return None


def fetch_activities_full(token, max_items, start_date_filter=None, progress_every=100):
    client = Client(access_token=token)
    results = []
    gear_cache = {}

    def get_gear_name(gear_id):
        if not gear_id:
            return None
        if gear_id in gear_cache:
            return gear_cache[gear_id]
        try:
            gear = client.get_gear(gear_id)
            name = getattr(gear, 'name', None)
            gear_cache[gear_id] = name
            return name
        except Exception:
            gear_cache[gear_id] = None
            return None

    count = 0
    for act in client.get_activities():
        if max_items and max_items > 0 and count >= max_items:
            print(f"Limite atteinte (MAX_ACTIVITIES={max_items}), arrêt anticipé.")
            break
        start_dt = getattr(act, 'start_date', None)
        if start_date_filter and start_dt and start_dt < start_date_filter:
            # Les activités sont retournées décroissantes, si on dépasse le filtre on peut arrêter
            if start_dt.tzinfo is not None:
                # si après conversion on est plus vieux, break
                if start_dt < start_date_filter:
                    break
            else:
                if start_dt.replace(tzinfo=timezone.utc) < start_date_filter:
                    break
        distance_m = getattr(act, 'distance', None)
        if distance_m is not None:
            try:
                distance_km = float(distance_m) / 1000.0
            except Exception:
                distance_km = None
        else:
            distance_km = None
        gear_id = getattr(act, 'gear_id', None)
        gear_name = get_gear_name(gear_id)
        results.append({
            'id': getattr(act, 'id', None),
            'start_date': start_dt,
            'distance_km': round(distance_km, 3) if distance_km is not None else None,
            'gear_id': gear_id,
            'gear_name': gear_name,
            'sport': getattr(act, 'sport_type', None) or getattr(act, 'type', None),
            'commute': getattr(act, 'commute', None),
        })
        count += 1
        if progress_every and count % progress_every == 0:
            print(f"Progression: {count} activités...")
    return results




def main():
    if not ACCESS_TOKEN:
        print('Aucun STRAVA_ACCESS_TOKEN configuré.')
        return

    max_acts = int(os.environ.get('MAX_ACTIVITIES', '0'))
    start_date_str = os.environ.get('START_DATE')  # ex: 2024-01-01
    progress_every = int(os.environ.get('PROGRESS_EVERY', '100'))
    write_csv = os.environ.get('WRITE_CSV', '1') in ('1','true','yes','True')

    start_filter_dt = None
    if start_date_str:
        try:
            start_filter_dt = datetime.strptime(start_date_str, '%Y-%m-%d').replace(tzinfo=timezone.utc)
        except ValueError:
            print('START_DATE ignoré (format attendu YYYY-MM-DD)')

    print(f"Extraction activités (max={max_acts if max_acts else 'illimité'}, start_date>={start_date_str or '---'}) ...")
    try:
        rows = fetch_activities_full(ACCESS_TOKEN, max_acts, start_filter_dt, progress_every)
    except Exception as e:
        print('Erreur durant l\'extraction:')
        traceback.print_exc()
        if isinstance(e, strava_exc.AccessUnauthorized) or 'Unauthorized' in str(e):
            print('Token insuffisant: réautorise avec activity:read_all si nécessaire.')
        return

    if not rows:
        print('Aucune activité – vérifier filtre / scopes.')
        return

    print(f'Terminé: {len(rows)} activités collectées.')

    # NOTE: La mise à jour de gear a été déplacée vers stravaStats.py (voir option CLI correspondante).

    desired_columns = ['id','start_date','distance_km','gear_id','gear_name','sport','commute']

    # Tentative DataFrame
    try:
        import pandas as pd
        df = pd.DataFrame(rows)
        # Ajouter colonnes manquantes si besoin
        for col in desired_columns:
            if col not in df.columns:
                df[col] = None
        # Réordonner
        df = df[desired_columns]
        if 'start_date' in df.columns:
            df = df.sort_values('start_date', ascending=False)
        print(df.head(10))
        if write_csv:
            out_path = os.path.join(os.getcwd(), 'activities_full.csv')
            df.to_csv(out_path, index=False)
            print('CSV écrit ->', out_path)
            print('Colonnes écrites:', ', '.join(df.columns))
    except Exception:
        print('pandas non disponible, fallback CSV basique...')
        if write_csv:
            out_path = os.path.join(os.getcwd(), 'activities_full.csv')
            import csv
            fieldnames = desired_columns
            with open(out_path, 'w', newline='') as f:
                writer = csv.DictWriter(f, fieldnames=fieldnames)
                writer.writeheader()
                for r in rows:
                    writer.writerow({k: r.get(k) for k in fieldnames})
            print('CSV écrit (fallback) ->', out_path)
            print('Colonnes écrites:', ', '.join(fieldnames))
        print('Aperçu JSON (5 premières):')
        for r in rows[:5]:
            print(json.dumps(r, default=str, ensure_ascii=False))


if __name__ == '__main__':
    main()

