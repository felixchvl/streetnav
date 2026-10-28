"""Analyse simple des activités Strava exportées dans activities_full.csv

Ce script lit le fichier CSV généré par stravaAllDataframe.py et calcule :
  - Nombre total d'activités
  - Distance totale (km)
  - Distance totale commute vs non commute
  - Top 5 des matériels (gear_name) par distance
    - Distance moyenne par jour (rolling 7 jours si pandas dispo)
    - Mise à jour optionnelle du matériel (gear) pour une plage de dates EBikeRide

Utilisation:
    python stravaStats.py              # affiche un résumé
    python stravaStats.py --save       # écrit aussi un fichier stats_summary.json
    python stravaStats.py --gear       # affiche répartition détaillée par matériel
    python stravaStats.py --daily      # affiche distance par jour

Options combinables. Le script fonctionne avec ou sans pandas.

Mise à jour de matériel (gear update):
    --update-gear                 Active la routine de modification
    --gear-target "Véligo 1"       Nom exact du matériel à appliquer
    --start 2024-02-17            Date début (incluse)
    --end 2024-05-04              Date fin (incluse)
    --apply                       Applique réellement (sinon dry-run)
    --access-token XXX            Token Strava (sinon STRAVA_ACCESS_TOKEN env)

Exemple dry-run :
    python stravaStats.py --update-gear --gear-target "Véligo 1" --start 2024-02-17 --end 2024-05-04

Exemple application réelle :
    python stravaStats.py --update-gear --gear-target "Véligo 1" --start 2024-02-17 --end 2024-05-04 --apply
"""
from __future__ import annotations
import csv
import os
import json
import argparse
from collections import defaultdict, Counter
try:
    from stravalib.client import Client  # type: ignore
except Exception:
    Client = None  # Optionnel si l'utilisateur ne fait que des stats CSV

def update_gear_for_range(token, gear_name_target, start_date, end_date, dry_run=True, progress_every=20):
    if Client is None:
        print("stravalib non disponible: impossible de mettre à jour le matériel.")
        return 0
    client = Client(access_token=token)
    target_gear_id = None
    gear_name_cache = {}
    changed = 0
    scanned = 0
    for act in client.get_activities():
        scanned += 1
        act_type = getattr(act, 'sport_type', None) or getattr(act, 'type', None)
        if str(act_type).lower() != 'ebikeride':
            continue
        sdt = getattr(act, 'start_date', None)
        if not sdt:
            continue
        local_date = sdt.date()
        if local_date < start_date or local_date > end_date:
            if local_date < start_date:
                break
            continue
        gid = getattr(act, 'gear_id', None)
        if gid and gid not in gear_name_cache:
            try:
                g = client.get_gear(gid)
                gear_name_cache[gid] = getattr(g, 'name', None)
            except Exception:
                gear_name_cache[gid] = None
        if target_gear_id is None:
            for gid_cache, gname in gear_name_cache.items():
                if gname and gname.lower() == gear_name_target.lower():
                    target_gear_id = gid_cache
                    break
        if target_gear_id is None and gid and gear_name_cache.get(gid) and gear_name_cache[gid].lower() == gear_name_target.lower():
            target_gear_id = gid
        if target_gear_id is None:
            if scanned % progress_every == 0:
                print(f"Recherche de l'ID du matériel '{gear_name_target}'... activités scannées: {scanned}")
            continue
        if gid == target_gear_id:
            continue
        print(f"Activity {act.id} {sdt} -> gear '{gear_name_target}' (id={target_gear_id}) ancien={gid}")
        if not dry_run:
            try:
                client.update_activity(act.id, gear_id=target_gear_id)
                changed += 1
            except Exception as e:
                print(f"Échec mise à jour activité {act.id}: {e}")
        else:
            changed += 1
    mode = 'DRY-RUN' if dry_run else 'APPLIQUÉ'
    print(f"Terminé ({mode}) : {changed} activités concernées.")
    if target_gear_id is None:
        print(f"Attention: ID du matériel '{gear_name_target}' introuvable.")
    return changed

from pathlib import Path
from datetime import datetime

CSV_FILE = Path("activities_full.csv")


def load_rows():
    if not CSV_FILE.exists():
        raise FileNotFoundError(f"Fichier introuvable: {CSV_FILE}")
    rows = []
    with CSV_FILE.open(newline='', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for r in reader:
            try:
                # Normalisations de base
                r['distance_km'] = float(r.get('distance_km')) if r.get('distance_km') not in (None, '', 'None') else 0.0
            except Exception:
                r['distance_km'] = 0.0
            # Parse date
            sd = r.get('start_date')
            if sd and ' ' in sd:
                # format typique: 2025-10-03 15:02:15+00:00
                try:
                    r['start_dt'] = datetime.fromisoformat(sd.replace('Z', '+00:00'))
                except Exception:
                    r['start_dt'] = None
            else:
                r['start_dt'] = None
            # Commute -> bool
            commute_val = r.get('commute')
            if isinstance(commute_val, str):
                r['commute'] = commute_val.lower() in ('true', '1', 'yes')
            rows.append(r)
    return rows


def compute_basic_stats(rows):
    total_activities = len(rows)
    total_distance = sum(r['distance_km'] for r in rows)
    commute_distance = sum(r['distance_km'] for r in rows if r.get('commute'))
    non_commute_distance = total_distance - commute_distance
    return {
        'total_activities': total_activities,
        'total_distance_km': round(total_distance, 2),
        'commute_distance_km': round(commute_distance, 2),
        'non_commute_distance_km': round(non_commute_distance, 2),
    }


def gear_stats(rows, top=5):
    per_gear = defaultdict(float)
    for r in rows:
        per_gear[r.get('gear_name') or r.get('gear_id') or 'UNKNOWN'] += r['distance_km']
    ordered = sorted(per_gear.items(), key=lambda x: x[1], reverse=True)
    return [{'gear': g, 'distance_km': round(d, 2)} for g, d in ordered[:top]]


def daily_distance(rows):
    per_day = defaultdict(float)
    for r in rows:
        if r['start_dt']:
            day = r['start_dt'].date().isoformat()
            per_day[day] += r['distance_km']
    return dict(sorted(per_day.items()))


def rolling_average(daily_map, window=7):
    # simple rolling average sans pandas
    items = list(daily_map.items())
    out = []
    for i in range(len(items)):
        subset = items[max(0, i - window + 1): i + 1]
        avg = sum(v for _, v in subset) / len(subset)
        out.append((items[i][0], round(avg, 2)))
    return out


def try_with_pandas(daily_map):
    try:
        import pandas as pd  # type: ignore
        df = pd.DataFrame([{'date': k, 'distance_km': v} for k, v in daily_map.items()])
        df['date'] = pd.to_datetime(df['date'])
        df = df.sort_values('date')
        df['rolling7_km'] = df['distance_km'].rolling(7, min_periods=1).mean().round(2)
        return df
    except Exception:
        return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--save', action='store_true', help='Sauvegarde stats_summary.json')
    parser.add_argument('--gear', action='store_true', help='Affiche top matériel (5)')
    parser.add_argument('--daily', action='store_true', help='Affiche distances par jour (+ rolling si pandas)')
    # Gear update options
    parser.add_argument('--update-gear', action='store_true', help='Active la mise à jour du matériel EBikeRide sur une plage de dates')
    parser.add_argument('--gear-target', type=str, default='Véligo 1', help='Nom du matériel cible')
    parser.add_argument('--start', type=str, help='Date début YYYY-MM-DD')
    parser.add_argument('--end', type=str, help='Date fin YYYY-MM-DD')
    parser.add_argument('--apply', action='store_true', help='Applique réellement (sinon dry-run)')
    parser.add_argument('--access-token', type=str, help='Access token Strava (sinon STRAVA_ACCESS_TOKEN env)')
    args = parser.parse_args()

    rows = load_rows()
    basics = compute_basic_stats(rows)
    gears = gear_stats(rows)

    print('=== Résumé général ===')
    for k, v in basics.items():
        print(f'- {k}: {v}')

    if args.gear:
        print('\n=== Top matériel (distance km) ===')
        for g in gears:
            print(f"{g['gear']}: {g['distance_km']} km")

    if args.daily:
        print('\n=== Distance par jour ===')
        daily_map = daily_distance(rows)
        for d, dist in daily_map.items():
            print(f'{d}: {round(dist,2)} km')
        df = try_with_pandas(daily_map)
        if df is not None:
            print('\n=== Rolling 7 jours (pandas) ===')
            print(df.tail(14))

    if args.update_gear:
        token = args.access_token or os.environ.get('STRAVA_ACCESS_TOKEN') or os.environ.get('ACCESS_TOKEN')
        if not token:
            print("Aucun token fourni (--access-token ou STRAVA_ACCESS_TOKEN). Abandon mise à jour.")
        elif not args.start or not args.end:
            print("Veuillez fournir --start et --end pour --update-gear.")
        else:
            try:
                ds = datetime.strptime(args.start, '%Y-%m-%d').date()
                de = datetime.strptime(args.end, '%Y-%m-%d').date()
            except ValueError:
                print('Dates invalides (format attendu YYYY-MM-DD).')
                ds = de = None
            if ds and de:
                print(f"Mise à jour gear EBikeRide du {ds} au {de} -> '{args.gear_target}' (dry_run={not args.apply})")
                update_gear_for_range(token, args.gear_target, ds, de, dry_run=not args.apply)

    if args.save:
        out = {
            'basics': basics,
            'gear_top5': gears,
        }
        with open('stats_summary.json', 'w', encoding='utf-8') as f:
            json.dump(out, f, ensure_ascii=False, indent=2)
        print('\nFichier stats_summary.json écrit.')


if __name__ == '__main__':
    main()
