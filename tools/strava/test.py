from stravalib.client import Client
from strava_config import get_access_token

access_token = get_access_token()
if not access_token:
    raise RuntimeError("Missing STRAVA_ACCESS_TOKEN in environment")
client = Client(access_token=access_token)

# Récupérer les informations de l'athlète
athlete = client.get_athlete()

# Vérifier et afficher les informations sur les vélos de l'athlète
if athlete.bikes:
    for bike in athlete.bikes:
        print(f"Nom: {bike.name}, ID: {bike.id}")
else:
    print("Aucun vélo trouvé pour cet athlète.")
