import requests
import psycopg2
from shapely.geometry import shape, Point, LineString
from shapely import wkt
from psycopg2.extras import execute_values

# Paramètres de connexion PostgreSQL
conn = psycopg2.connect(
    host="localhost",          # Remplace "postgres" par "localhost"
    database="postgres",       # La base de données à laquelle tu souhaites te connecter
    user="felixchevalier",     # Ton nom d'utilisateur PostgreSQL
)

cur = conn.cursor()

# Requête Overpass pour obtenir les rues de Paris
overpass_url = "http://overpass-api.de/api/interpreter"
overpass_query = """
[out:json];
area["name"="Paris"]->.paris;
way(area.paris)["highway"];
out geom;
"""
response = requests.get(overpass_url, params={'data': overpass_query})
data = response.json()

# Préparer les données pour insertion
streets_data = []
for element in data['elements']:
    if 'tags' in element and 'name' in element['tags']:
        name = element['tags']['name']
        osm_id = element['id']
        coords = [(node['lon'], node['lat']) for node in element['geometry']]

        # Créer la géométrie de la rue
        geom = LineString(coords)
        center = geom.centroid

        # Ajouter les données préparées
        streets_data.append((name, osm_id, center.wkt, geom.wkt))

# Insérer les données dans la table PostgreSQL
insert_query = """
    INSERT INTO paris_streets (name, osm_id, center, geom)
    VALUES %s
"""
execute_values(cur, insert_query, streets_data)
conn.commit()

# Fermeture de la connexion
cur.close()
conn.close()

print("Les données des rues de Paris ont été insérées avec succès.")
