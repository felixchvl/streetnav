from stravalib.client import Client

access_token = "1b5e383dd3a78d83d653971133e2b056d21e150d"
client = Client(access_token=access_token)

# Récupérer les informations de l'athlète
athlete = client.get_athlete()

# Vérifier et afficher les informations sur les vélos de l'athlète
if athlete.bikes:
    for bike in athlete.bikes:
        print(f"Nom: {bike.name}, ID: {bike.id}")
else:
    print("Aucun vélo trouvé pour cet athlète.")
