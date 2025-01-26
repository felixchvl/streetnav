from stravalib.client import Client
import time
from datetime import datetime

access_token = "71335ce7d61ecfea20adae5258f2b84d09c06de6"
client = Client(access_token=access_token)

changedCount = 0
actCount = 0

print("Début de la récupération des activités...")

# Date limite pour la comparaison
date_limite = datetime.fromisoformat("2024-08-23T00:00:00+00:00")

for activity in client.get_activities():

    # Convertit en chaîne et nettoie les guillemets simples
    activity_type = str(activity.type).replace("root=", "").strip("'")

    print("\n")
    print(f"Vérification de l'activité ID: {activity.id}, Type: {activity_type}, Bike: {activity.gear_id}")

    # Vérifie si l'activité est après la date limite
    if activity.start_date >= date_limite:
        print(f"Activité après la date limite : {activity.id}, {activity.start_date}")

        if activity_type == "EBikeRide":
            if activity.gear_id is None:
                time.sleep(5)  # Pause pour respecter la limite de débit de l'API
                client.update_activity(activity.id, gear_id=14097273)
                print("Changé", activity.start_date, activity.name)
                changedCount += 1
            else:
                print("Déjà le cas")
        else:
            print("Autre sport")
    else:
        print("Activité avant la date limite")

    actCount += 1
    print("Activités lues ", actCount)

print("Mise à jour terminée.")
print(changedCount, "activités ont été modifiées.")
