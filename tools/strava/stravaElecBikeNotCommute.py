from stravalib.client import Client
from strava_config import get_client_id, get_client_secret, get_refresh_token

CLIENT_ID = get_client_id(137455)
CLIENT_SECRET = get_client_secret()
REFRESH_TOKEN = get_refresh_token()

if not CLIENT_SECRET or not REFRESH_TOKEN:
    raise RuntimeError("Missing STRAVA_CLIENT_SECRET or STRAVA_REFRESH_TOKEN in environment")

def refresh_access_token(client_id, client_secret, refresh_token):
    """ Rafraîchit le token d'accès """
    client = Client()
    refresh_response = client.refresh_access_token(
        client_id=client_id,
        client_secret=client_secret,
        refresh_token=refresh_token
    )
    return refresh_response["access_token"], refresh_response["refresh_token"]

def get_non_commute_electric_rides():
    """ Récupère les sorties en vélo électrique sans le tag 'commute' """
    access_token, new_refresh_token = refresh_access_token(CLIENT_ID, CLIENT_SECRET, REFRESH_TOKEN)

    client = Client(access_token=access_token)
    activities_list = list(client.get_activities())

    print(f"\nTotal brut d'activités récupérées : {len(activities_list)}\n")

    # Diagnostic : Affichage des types et des valeurs commute
    for i, activity in enumerate(activities_list[:800], 1):  # Affichage des 10 premières activités pour éviter une sortie trop longue
        print(f"Activité {i} : Type={activity.type}, Gear={activity.gear_id}, Date={activity.start_date}")

    # Filtrage des activités
    non_commute_electric_rides = []
    for activity in activities_list:
        # Vérification du type et du tag commute
        if activity.type == 'EBikeRide':
            if hasattr(activity, 'commute'):  # Vérifie si le champ commute est présent
                if not activity.commute:
                    non_commute_electric_rides.append(activity)
            else:
                print(f"⚠️ Activité {activity.name} ne contient pas le champ 'commute'. Ignorée.")

    # Affichage des résultats filtrés
    print("\n### Activités filtrées (EBikeRide non commute) ###\n")
    if non_commute_electric_rides:
        for activity in non_commute_electric_rides:
            day = activity.start_date_local.strftime('%A')
            hour = activity.start_date_local.strftime('%H:%M')
            print(f"Nom : {activity.name}, Type : {activity.type}, Jour : {day}, Heure : {hour}, Date complète : {activity.start_date_local}")
    else:
        print("Aucune activité 'EBikeRide' sans commute trouvée.\n")

    print(f"\nTotal : {len(non_commute_electric_rides)} sorties en vélo électrique sans 'commute'.\n")


# Lancer la récupération des sorties
get_non_commute_electric_rides()
