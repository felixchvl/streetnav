from stravalib.client import Client
import time

access_token = "1b5e383dd3a78d83d653971133e2b056d21e150d"
client = Client(access_token=access_token)

changedCount = 0
actCount = 0

print("Début de la récupération des activités...")

for activity in client.get_activities():

    # Convertit en chaîne et nettoie les guillemets simples
    activity_type = str(activity.type).replace("root=", "").strip("'")

    print("\n")
    print(f"Vérification de l'activité ID: {activity.id}, Type: {activity_type}, Commute: {activity.commute}, Private: {activity.private}")


    if activity_type == "EBikeRide":

        if activity.private == False:

            time.sleep(10)

            client.update_activity(activity.id, private=True)
            print("Changé", activity.start_date, activity.name)
            changedCount += 1
        elif activity.private == True:
            print("C'est déjà privé")
        else:
            print("WHAT???")

    else:
        print("Autre sport")

    actCount += 1
    print("Activités lues ", actCount)

print("Mise à jour terminée.")
print(changedCount, "activités ont été modifiées.")

