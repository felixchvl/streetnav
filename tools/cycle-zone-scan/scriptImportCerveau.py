import os  # Module pour interagir avec le système de fichiers
from pathlib import Path

OUTPUT_DIRECTORY = Path(__file__).resolve().parent / "outputs"
import requests  # Module pour faire des requêtes HTTP
import geojson  # Module pour manipuler des objets GeoJSON
from geojson import Feature, FeatureCollection  # Classes GeoJSON pour les features et les collections de features

def is_valid_coordinate(coord):
    try:
        float(coord)
        return True
    except ValueError:
        return False

def extract_coordinates(file_path):
    # Ouvre le fichier et lit toutes les lignes
    with open(file_path, 'r', encoding='utf-8') as file:
        lines = file.readlines()
        # Parcourt chaque ligne pour trouver l'indicateur 'location:'
        for i, line in enumerate(lines):
            if 'location:' in line.lower():
                try:
                    # Cherche les lignes suivantes pour obtenir les coordonnées
                    lat_line = lines[i + 1].strip()
                    lng_line = lines[i + 2].strip()
                    # Vérifie que les lignes contiennent des coordonnées valides
                    if is_valid_coordinate(lat_line) and is_valid_coordinate(lng_line):
                        lat = float(lat_line)
                        lng = float(lng_line)
                        print(f"Coordinates found in {file_path}: {lat}, {lng}")
                        return (lat, lng)  # Retourne les coordonnées
                    else:
                        print(f"Invalid coordinate format in {file_path}: {lat_line}, {lng_line}")
                except (IndexError, ValueError) as e:
                    # Gère les erreurs si les coordonnées ne sont pas dans le bon format
                    print(f"Error reading coordinates in {file_path}: {e}")
                    return None
        return None  # Retourne None si aucune coordonnée n'est trouvée

def fetch_polygon_from_overpass(lat, lng):
    # URL de l'API Overpass
    overpass_url = "http://overpass-api.de/api/interpreter"
    # Requête Overpass pour obtenir les polygones des bâtiments autour des coordonnées
    overpass_query = f"""
    [out:json];
    (
      way(around:50,{lat},{lng})["building"];
      relation(around:50,{lat},{lng})["building"];
    );
    out body;
    >;
    out skel qt;
    """
    # Envoie de la requête à l'API Overpass
    response = requests.post(overpass_url, data={'data': overpass_query})
    # Convertit la réponse JSON en dictionnaire Python
    data = response.json()
    return data  # Retourne les données JSON

def convert_to_geojson(data, name):
    features = []  # Liste pour stocker les features GeoJSON
    # Parcourt chaque élément dans les données de réponse
    for element in data['elements']:
        if 'geometry' in element:
            # Extrait les coordonnées de chaque point de l'élément
            coordinates = [(point['lon'], point['lat']) for point in element['geometry']]
            # Crée un polygone GeoJSON avec les coordonnées
            polygon = geojson.Polygon([coordinates])
            # Crée une feature GeoJSON avec le polygone et le nom du fichier
            feature = geojson.Feature(geometry=polygon, properties={"name": name})
            features.append(feature)  # Ajoute la feature à la liste
    return features  # Retourne la liste des features

def main(input_directory, output_file):
    all_features = []  # Liste pour stocker toutes les features GeoJSON
    # Parcourt tous les fichiers dans le répertoire spécifié
    for filename in os.listdir(input_directory):
        if filename.endswith('.md'):  # Vérifie si le fichier a l'extension '.md'
            file_path = os.path.join(input_directory, filename)
            coordinates = extract_coordinates(file_path)  # Extrait les coordonnées du fichier
            if coordinates:
                lat, lng = coordinates
                data = fetch_polygon_from_overpass(lat, lng)  # Obtient les polygones via l'API Overpass
                features = convert_to_geojson(data, filename)  # Convertit les polygones en features GeoJSON
                all_features.extend(features)  # Ajoute les features à la liste
            else:
                print(f"No coordinates found in {file_path}")  # Indique que le fichier n'a pas de coordonnées valides
    
    # Crée une FeatureCollection GeoJSON avec toutes les features
    feature_collection = FeatureCollection(all_features)
    # Sauvegarde la FeatureCollection dans un fichier
    with open(output_file, 'w', encoding='utf-8') as f:
        geojson.dump(feature_collection, f, ensure_ascii=False, indent=2)

if __name__ == "__main__":
    # Définit le répertoire d'entrée et le fichier de sortie
    input_directory = '/Users/felixchevalier/Library/Mobile Documents/iCloud~md~obsidian/Documents/Cerveau'
    OUTPUT_DIRECTORY.mkdir(exist_ok=True)
    output_file = OUTPUT_DIRECTORY / "cerveau.geojson"
    # Exécute la fonction principale
    main(input_directory, output_file)
