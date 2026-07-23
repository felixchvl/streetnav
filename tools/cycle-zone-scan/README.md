# Cycle zone scan

Outils locaux de préparation de données, séparés de l’application iOS.

- `main.py` importe le réseau de rues depuis Overpass dans PostgreSQL/PostGIS.
- `scriptSimple.py` liste les notes Obsidian contenant une localisation.
- `scriptImportCerveau.py` fabrique un GeoJSON de bâtiments voisins depuis ces notes.

Les fichiers créés par les deux derniers scripts vont dans `outputs/`, ignoré par Git.

Dépendances Python : `requests`, `psycopg2` et `shapely` pour `main.py`; `requests` et `geojson` pour `scriptImportCerveau.py`.

Ces outils tournent localement sur le Mac. Ils peuvent toutefois interroger Overpass et lire un coffre Obsidian local/synchronisé : ils ne font pas partie de l’application iPhone et n’ont donc pas vocation à être réécrits en Swift aujourd’hui.
