import os

def find_files_with_location(input_directory, output_file):
    # Ouvre le fichier de sortie en mode écriture
    with open(output_file, 'w', encoding='utf-8') as out_file:
        # Parcourt tous les fichiers dans le répertoire spécifié
        for filename in os.listdir(input_directory):
            if filename.endswith('.md'):  # Vérifie si le fichier a l'extension '.md'
                file_path = os.path.join(input_directory, filename)
                with open(file_path, 'r', encoding='utf-8') as file:
                    lines = file.readlines()
                    # Parcourt chaque ligne pour trouver l'indicateur 'location:'
                    for line in lines:
                        if 'location:' in line.lower():
                            # Écrit le nom du fichier dans le fichier de sortie
                            out_file.write(f"{filename}\n")
                            break  # Sort de la boucle après avoir trouvé 'location'

if __name__ == "__main__":
    # Définit le répertoire d'entrée et le fichier de sortie
    input_directory = '/Users/felixchevalier/Library/Mobile Documents/iCloud~md~obsidian/Documents/Cerveau'
    output_file = '/Users/felixchevalier/Desktop/Archibike/files_with_location.txt'
    # Exécute la fonction principale
    find_files_with_location(input_directory, output_file)
