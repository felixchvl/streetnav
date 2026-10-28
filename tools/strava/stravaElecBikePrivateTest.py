from stravalib.client import Client
import time
from strava_config import get_access_token

access_token = get_access_token()
if not access_token:
    raise RuntimeError("Missing STRAVA_ACCESS_TOKEN in environment")
client = Client(access_token=access_token)

changedCount = 0
actCount = 0

print("Début de la récupération des activités...")

for activity in client.get_activities():

    # Convertit en chaîne et nettoie les guillemets simples
    activity_type = str(activity.type).replace("root=", "").strip("'")
    print(
        f"Vérification de l'activité ID: {activity.id}, Type: {activity_type}, Commute: {activity.commute}, Private: {activity.private}")

    actCount += 1

    if activity_type == "EBikeRide":

        print("Activités lues ", actCount)

        if activity.private == False:
            client.update_activity(activity.id, private=True)
            print("Fait", activity.start_date, activity.name)
            changedCount += 1

            break

        elif activity.commute == True:
            print("C'est déjà un trajet domicile-travail")
        else:
            print("???")
    else:
        print(activity_type)

print("Mise à jour terminée.")
print(changedCount, "activités ont été modifiées.")

