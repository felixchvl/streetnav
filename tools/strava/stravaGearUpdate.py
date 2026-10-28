"""Strava Gear Update Utility (version avancée)

Objectif: Mettre à jour le matériel (gear) d'un lot d'activités Strava sur une plage de dates.

Fonctionnalités principales:
    - Dry-run par défaut (aucune écriture tant que --apply pas fourni)
    - Filtre sport type (par défaut EBikeRide, ou via --sport-types)
    - Plage de dates inclusive (--start / --end)
    - Résolution automatique de l'ID du matériel via son nom ou --gear-id explicite
    - Mode only-missing: ne modifie que les activités sans gear
    - Modes diagnostics: --inspect (échantillon), --print-range (liste TOUTES les activités dans la plage)
    - Liste des matériels (--list-gear)
    - Journal CSV des modifications (toujours en apply, optionnel en dry-run via --log-dry)
    - Auto refresh sur 401 préflight (retry unique) + option --force-refresh
    - Logging source du token + préfixe pour debug
    - Option de sauvegarde des nouveaux tokens (--save-tokens tokens.json)

Dépendances:
    pip install stravalib

Exemples rapides:
    Dry-run défaut (Véligo 1 / plage par défaut):
        python stravaGearUpdate.py
    Dry-run seulement activités sans gear: 
        python stravaGearUpdate.py --only-missing
    Appliquer réellement avec ID déjà connu:
        python stravaGearUpdate.py --gear-id b15410039 --apply
    Inclure plusieurs sports:
        python stravaGearUpdate.py --sport-types EBikeRide,Ride --apply
    Lister les matériels (ne modifie rien):
        python stravaGearUpdate.py --list-gear

Sécurité:
    - Les tokens doivent venir des variables d'environnement (fichier .env local).
    - Ne pas pousser de secrets (tokens, .env, JSON de tokens) dans Git.
    - Toujours lancer un dry-run avant --apply.
"""
from __future__ import annotations
import os
import csv
import argparse
import time
import json
from urllib import request, parse
from urllib.error import HTTPError
from datetime import datetime
from typing import Optional, Dict
import sys
from strava_config import (
    get_access_token,
    get_client_id,
    get_client_secret,
    get_refresh_token,
    get_expires_at,
)

try:
    from stravalib.client import Client
except Exception as e:  # pragma: no cover
    raise SystemExit("stravalib est requis: pip install stravalib") from e

# ============================================================================
# Identifiants & valeurs par défaut (FOURNIS PAR L'UTILISATEUR)
# ============================================================================
CLIENT_ID = get_client_id(137455)  # integer pour stravalib
CLIENT_SECRET = get_client_secret()
ACCESS_TOKEN = get_access_token()
REFRESH_TOKEN = get_refresh_token()
EXPIRES_AT = get_expires_at()

DEFAULT_GEAR_NAME = os.environ.get("STRAVA_DEFAULT_GEAR_NAME", "Véligo 1")
DEFAULT_START_DATE = os.environ.get("STRAVA_DEFAULT_START_DATE", "2024-02-17")
DEFAULT_END_DATE = os.environ.get("STRAVA_DEFAULT_END_DATE", "2024-05-04")

# Pour certains warnings stravalib, définir l'ID client dans l'env
os.environ.setdefault('STRAVA_CLIENT_ID', str(CLIENT_ID))


def refresh_access_token_if_needed(access_token: str, refresh_token: str, expires_at: int) -> str:
    """Retourne un access_token valide, en rafraîchissant si nécessaire.

    On rafraîchit si l'heure courante >= (expires_at - 60).
    Utilise l'endpoint officiel Strava OAuth.
    Imprime les nouveaux tokens pour que l'utilisateur puisse les réutiliser si souhaité.
    """
    now = int(time.time())
    if expires_at and now < (expires_at - 60):
        return access_token

    print("[INFO] Access token expiré ou proche d'expirer: rafraîchissement...")
    url = "https://www.strava.com/oauth/token"
    data = parse.urlencode({
        "client_id": CLIENT_ID,
        "client_secret": CLIENT_SECRET,
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
    }).encode()
    req = request.Request(url, data=data, method="POST")
    try:
        with request.urlopen(req, timeout=15) as resp:
            payload = json.loads(resp.read().decode())
    except Exception as e:
        print(f"[WARN] Échec refresh token: {e}. On continue avec l'ancien access token (peut échouer).")
        return access_token

    new_access = payload.get("access_token") or access_token
    new_refresh = payload.get("refresh_token") or refresh_token
    new_expires = payload.get("expires_at") or expires_at
    print("[INFO] Tokens rafraîchis ->")
    print(f"ACCESS_TOKEN = '{new_access}'")
    print(f"REFRESH_TOKEN = '{new_refresh}'")
    print(f"EXPIRES_AT = {new_expires}")
    # On ne réécrit pas le fichier; l'utilisateur peut copier/coller.
    return new_access


def find_target_gear_id(client: Client, gear_name_target: str, gear_name_cache: Dict[str, Optional[str]]) -> Optional[str]:
    for gid, name in gear_name_cache.items():
        if name and name.lower() == gear_name_target.lower():
            return gid
    return None


def update_gear(
    token: str,
    gear_name_target: str,
    start_date: datetime.date,
    end_date: datetime.date,
    dry_run: bool = True,
    max_scan: Optional[int] = None,
    progress_every: int = 100,
    log_file: str = 'gear_update_log.csv',
    write_log_in_dry: bool = False,
    explicit_gear_id: Optional[str] = None,
    sport_types: Optional[str] = None,
    inspect: bool = False,
    only_missing: bool = False,
) -> int:
    try:
        client = Client(access_token=token)
    except Exception as e:  # pragma: no cover
        print(f"[ERREUR] Impossible de créer le client Strava: {e}")
        sys.exit(2)

    target_gear_id: Optional[str] = explicit_gear_id
    gear_name_cache: Dict[str, Optional[str]] = {}
    changed = 0
    scanned = 0
    scanned_sport = 0
    scanned_in_range = 0
    candidates = 0
    skip_wrong_sport = 0
    skip_no_date = 0
    skip_out_of_range = 0
    skip_already = 0

    pending_log_rows = []

    # Pré-charger la liste des matériels (athlète) pour résolution nom->id
    try:
        athlete = client.get_athlete()
        for b in getattr(athlete, 'bikes', []) or []:
            gid = getattr(b, 'id', None); name = getattr(b, 'name', None)
            if gid: gear_name_cache[gid] = name
        for s in getattr(athlete, 'shoes', []) or []:
            gid = getattr(s, 'id', None); name = getattr(s, 'name', None)
            if gid: gear_name_cache[gid] = name
    except Exception as e_at:
        print(f"[WARN] Impossible de charger athlete/gear list: {e_at}")

    if target_gear_id is None:
        target_gear_id = find_target_gear_id(client, gear_name_target, gear_name_cache)
        if target_gear_id:
            print(f"[INFO] Matériel cible détecté: {gear_name_target} -> {target_gear_id}")

    allowed_sports = None
    if sport_types:
        allowed_sports = {s.strip().lower() for s in sport_types.split(',') if s.strip()}
        if not allowed_sports:
            allowed_sports = None

    def extract_sport(val):
        if val is None:
            return None
        s = str(val)
        if "root='" in s:
            try:
                return s.split("root='",1)[1].split("'",1)[0]
            except Exception:
                return s
        return s

    inspected = 0

    try:
        activities_iter = client.get_activities()
    except Exception as e:
        print(f"[ERREUR] get_activities() a échoué: {e}")
        sys.exit(3)

    for act in activities_iter:
        scanned += 1
        if max_scan and scanned > max_scan:
            print(f"Limite scan {max_scan} atteinte.")
            break
        raw_type = getattr(act, 'sport_type', None) or getattr(act, 'type', None)
        sport_norm = extract_sport(raw_type)
        sport_l = (sport_norm or '').lower()
        if allowed_sports:
            if sport_l not in allowed_sports:
                skip_wrong_sport += 1
                continue
        else:
            if sport_l != 'ebikeride':
                skip_wrong_sport += 1
                continue
        scanned_sport += 1
        sdt = getattr(act, 'start_date', None)
        if not sdt:
            skip_no_date += 1
            continue
        act_date = sdt.date()
        if act_date < start_date or act_date > end_date:
            if act_date < start_date:
                break  # plus ancien que la plage (ordre décroissant)
            skip_out_of_range += 1
            continue
        scanned_in_range += 1
        gid = getattr(act, 'gear_id', None)
        if inspect and inspected < 40:
            print(f"[INSPECT] id={act.id} date={act_date} sport={sport_l} gear={gid}")
            inspected += 1
        # Résolution dynamique du nom de gear si inconnu
        if gid and gid not in gear_name_cache:
            try:
                g = client.get_gear(gid)
                gear_name_cache[gid] = getattr(g, 'name', None)
            except Exception:
                gear_name_cache[gid] = None
        # Résoudre target si pas encore fait
        if target_gear_id is None:
            target_gear_id = find_target_gear_id(client, gear_name_target, gear_name_cache)
        if target_gear_id is None and gid and gear_name_cache.get(gid) and gear_name_cache[gid].lower() == gear_name_target.lower():
            target_gear_id = gid
        if target_gear_id is None:
            if scanned % progress_every == 0:
                print(f"Recherche ID gear '{gear_name_target}'… (scanned={scanned})")
            continue
        if gid == target_gear_id:
            skip_already += 1
            continue
        if only_missing and gid is not None:
            continue

        print(f"Activity {act.id} {sdt} -> {gear_name_target} ({target_gear_id}) ancien={gid}")
        candidates += 1
        pending_log_rows.append({
            'activity_id': act.id,
            'date': sdt.isoformat(),
            'old_gear_id': gid,
            'new_gear_id': target_gear_id,
            'gear_target_name': gear_name_target,
            'applied': 'no' if dry_run else 'yes'
        })
        if not dry_run:
            try:
                client.update_activity(act.id, gear_id=target_gear_id)
                changed += 1
            except Exception as e_upd:
                print(f"[WARN] Échec update {act.id}: {e_upd}")
        else:
            changed += 1

    mode = 'DRY-RUN' if dry_run else 'APPLIED'
    print(f"Terminé ({mode}) changed={changed} candidates={candidates}")
    print(f"Stats: scanned={scanned} sport_ok={scanned_sport} in_range={scanned_in_range}")
    print(f"Skips: wrong_sport={skip_wrong_sport} no_date={skip_no_date} out_of_range={skip_out_of_range} already_correct={skip_already}")
    if only_missing:
        print("Mode only-missing: activités avec gear existant ignorées.")
    if target_gear_id is None:
        print(f"[WARN] ID du matériel '{gear_name_target}' introuvable.")
        if gear_name_cache:
            print("Matériels connus:")
            for gid_, nm in gear_name_cache.items():
                print(f"  - {gid_}: {nm}")

    if pending_log_rows and (not dry_run or write_log_in_dry):
        fieldnames = ['activity_id','date','old_gear_id','new_gear_id','gear_target_name','applied']
        with open(log_file, 'w', newline='', encoding='utf-8') as f:
            w = csv.DictWriter(f, fieldnames=fieldnames)
            w.writeheader(); w.writerows(pending_log_rows)
        print(f"Log écrit -> {log_file} ({len(pending_log_rows)} lignes)")
    return changed


def parse_args():
    p = argparse.ArgumentParser(description='Batch update matériel Strava pour une plage d\'activités.')
    p.add_argument('--gear-name', help=f"Nom du matériel cible (default: {DEFAULT_GEAR_NAME})")
    p.add_argument('--gear-id', help='ID du matériel cible (bypass résolution par nom)')
    p.add_argument('--start', help=f"Date début YYYY-MM-DD (default: {DEFAULT_START_DATE})")
    p.add_argument('--end', help=f"Date fin YYYY-MM-DD (default: {DEFAULT_END_DATE})")
    p.add_argument('--access-token', help='Access token Strava (sinon STRAVA_ACCESS_TOKEN / ACCESS_TOKEN / hardcodé)')
    p.add_argument('--apply', action='store_true', help='Appliquer les changements (sinon dry-run)')
    p.add_argument('--only-missing', action='store_true', help='Ne modifie que les activités sans gear')
    p.add_argument('--sport-types', help='Liste séparée par virgules des sport types à inclure (ex: EBikeRide,Ride)')
    p.add_argument('--inspect', action='store_true', help='Affiche un échantillon (40) pour debug')
    p.add_argument('--print-range', action='store_true', help='Liste toutes les activités dans la plage (sans mise à jour)')
    p.add_argument('--list-gear', action='store_true', help='Affiche la liste des matériels de l\'athlète puis quitte')
    p.add_argument('--max-scan', type=int, help='Nombre max d\'activités scannées')
    p.add_argument('--progress-every', type=int, default=100, help='Fréquence logs progression')
    p.add_argument('--log-file', default='gear_update_log.csv', help='Fichier log CSV')
    p.add_argument('--log-dry', action='store_true', help='Écrit aussi le log en dry-run')
    p.add_argument('--force-refresh', action='store_true', help='Force un refresh token immédiat')
    p.add_argument('--save-tokens', help='Sauvegarde les tokens rafraîchis dans ce fichier JSON')
    return p.parse_args()


def main():
    args = parse_args()

    gear_name = args.gear_name or DEFAULT_GEAR_NAME
    start_raw = args.start or DEFAULT_START_DATE
    end_raw = args.end or DEFAULT_END_DATE

    try:
        start_date = datetime.strptime(start_raw, '%Y-%m-%d').date()
        end_date = datetime.strptime(end_raw, '%Y-%m-%d').date()
    except ValueError:
        raise SystemExit('Dates invalides, format attendu YYYY-MM-DD')
    if end_date < start_date:
        raise SystemExit('La date de fin est avant la date de début.')

    # Déterminer la source du token
    if args.access_token:
        token_source = 'CLI'
    elif os.environ.get('STRAVA_ACCESS_TOKEN'):
        token_source = 'ENV:STRAVA_ACCESS_TOKEN'
    elif os.environ.get('ACCESS_TOKEN'):
        token_source = 'ENV:ACCESS_TOKEN'
    else:
        token_source = 'HARDCODED'

    base_token = (
        args.access_token
        or os.environ.get('STRAVA_ACCESS_TOKEN')
        or os.environ.get('ACCESS_TOKEN')
        or ACCESS_TOKEN
    )

    if args.force_refresh:
        print('[INFO] Refresh forcé (--force-refresh).')
        effective_token = refresh_access_token_if_needed('INVALID', REFRESH_TOKEN, 0)
    else:
        effective_token = refresh_access_token_if_needed(base_token, REFRESH_TOKEN, EXPIRES_AT)

    print(f"[INFO] Plage: {start_date} -> {end_date} | Gear: {gear_name} | Mode: {'APPLY' if args.apply else 'DRY-RUN'} | TokenSource={token_source} prefix={effective_token[:8]+'…'}")

    # Préflight amélioré avec retry sur 401/403
    def preflight(tok: str) -> str:
        try:
            req_pf = request.Request(
                'https://www.strava.com/api/v3/athlete',
                headers={'Authorization': f'Bearer {tok}'},
                method='GET'
            )
            with request.urlopen(req_pf, timeout=10) as r:
                if r.status != 200:
                    print(f"[ERREUR] Préflight code {r.status}")
                    if r.status in (401,403):
                        print('  -> Token invalide ou scopes insuffisants (read,activity:read_all,activity:write).')
                    raise SystemExit(3)
            return tok
        except HTTPError as he:  # type: ignore
            if he.code in (401,403):
                print(f"[WARN] Préflight {he.code}. Tentative refresh immédiat…")
                new_tok = refresh_access_token_if_needed('INVALID', REFRESH_TOKEN, 0)
                if new_tok == tok:
                    print('[WARN] Refresh n\'a pas donné de nouveau token (refresh_token périmé ?).')
                else:
                    print('[INFO] Nouveau token obtenu, retry préflight.')
                try:
                    req_pf2 = request.Request(
                        'https://www.strava.com/api/v3/athlete',
                        headers={'Authorization': f'Bearer {new_tok}'},
                        method='GET'
                    )
                    with request.urlopen(req_pf2, timeout=10) as r2:
                        if r2.status == 200:
                            print('[INFO] Préflight OK après refresh.')
                            if args.save_tokens:
                                _persist_tokens(new_tok, REFRESH_TOKEN, int(time.time())+18000, args.save_tokens)
                            return new_tok
                        else:
                            print(f"[ERREUR] Préflight après refresh code {r2.status}")
                            raise SystemExit(3)
                except Exception as e2:
                    print(f"[ERREUR] Retry préflight échec: {e2}")
                    raise SystemExit(3)
            print(f"[ERREUR] Préflight échec HTTP {he.code}: {he}")
            raise SystemExit(3)
        except Exception as e:
            print(f"[ERREUR] Préflight exception: {e}")
            raise SystemExit(3)

    def _persist_tokens(access_t: str, refresh_t: str, expires_at: int, path: str):
        data = {
            'access_token': access_t,
            'refresh_token': refresh_t,
            'expires_at': expires_at,
            'saved_at': int(time.time())
        }
        try:
            with open(path, 'w', encoding='utf-8') as f:
                json.dump(data, f, indent=2)
            print(f"[INFO] Tokens sauvegardés -> {path}")
        except Exception as e_sv:
            print(f"[WARN] Échec sauvegarde tokens: {e_sv}")

    effective_token = preflight(effective_token)

    if args.list_gear:
        try:
            cli = Client(access_token=effective_token)
            ath = cli.get_athlete()
            print('-- Bikes --')
            for b in getattr(ath,'bikes',[]) or []:
                print(f"{getattr(b,'id',None)}\t{getattr(b,'name',None)}")
            print('-- Shoes --')
            for s in getattr(ath,'shoes',[]) or []:
                print(f"{getattr(s,'id',None)}\t{getattr(s,'name',None)}")
        except Exception as e_l:
            print(f"[ERREUR] list-gear échec: {e_l}")
        return

    if args.print_range:
        try:
            cli = Client(access_token=effective_token)
            count = 0
            gear_cache = {}
            for act in cli.get_activities():
                sdt = getattr(act,'start_date',None)
                if not sdt: continue
                d = sdt.date()
                if d < start_date: break
                if d > end_date: continue
                gid = getattr(act,'gear_id',None)
                gname = None
                if gid:
                    if gid not in gear_cache:
                        try:
                            gobj = cli.get_gear(gid)
                            gear_cache[gid] = getattr(gobj,'name',None)
                        except Exception:
                            gear_cache[gid] = None
                    gname = gear_cache.get(gid)
                print(f"{getattr(act,'id',None)}\t{d}\tsport={getattr(act,'sport_type',None)}\tgear_id={gid}\tgear_name={gname}")
                count += 1
            print(f"[PRINT-RANGE] Total: {count}")
        except Exception as e_pr:
            print(f"[ERREUR] print-range: {e_pr}")
        return

    update_gear(
        token=effective_token,
        gear_name_target=gear_name,
        start_date=start_date,
        end_date=end_date,
        dry_run=not args.apply,
        max_scan=args.max_scan,
        progress_every=args.progress_every,
        log_file=args.log_file,
        write_log_in_dry=args.log_dry,
        explicit_gear_id=args.gear_id,
        sport_types=args.sport_types,
        inspect=args.inspect,
        only_missing=args.only_missing,
    )


if __name__ == '__main__':
    main()
