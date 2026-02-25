# strava-database (VPS-ready)

Projet migré d'un poste local vers VPS.

## Setup VPS

```bash
cd /home/ubuntu/strava-database
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

Renseigner ensuite les variables Strava dans `.env`.

## Exemples

```bash
python test.py
python stravaAllDataframe.py
python stravaGearUpdate.py --list-gear
```

## Git

Le dossier a été initialisé en repo local sur le VPS. Ajoute ton remote puis pousse:

```bash
git remote add origin <url>
git push -u origin main
```
