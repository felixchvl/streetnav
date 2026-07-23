# Streetnav

Streetnav est une application iOS locale de découverte à vélo. L’application s’appuie aujourd’hui sur des données simulées et MapKit ; les futures intégrations (Strava, Wandrer, Apple Watch et vélo) resteront derrière des services dédiés.

## Organisation

- `ios/Streetnav/App` : démarrage de l’application et composition de l’écran racine.
- `ios/Streetnav/Features` : écrans et interactions métier visibles (carte, sortie).
- `ios/Streetnav/Core` : modèles, services et données simulées, sans présentation SwiftUI.
- `ios/Streetnav/UI` : composants SwiftUI réutilisables.
- `ios/Streetnav/Development` : previews, variations d’interface, outils de mise au point et ancienne démo de référence.
- `tools` : scripts de préparation/import de données. Ils ne font pas partie de l’app iPhone.

## Règles de travail

1. Une fonctionnalité commence dans `Features`, ses données dans `Core` et ses éléments visuels réutilisables dans `UI`.
2. Les écrans de production ne lisent pas de fichiers locaux directement : ils passent par un service dans `Core/Services`.
3. Les données fictives restent dans `Core/MockData` jusqu’à ce qu’une intégration locale réelle les remplace.
4. Une étape cohérente = un commit : par exemple « ajouter le modèle d’itinéraire », puis « afficher l’itinéraire ».

## Outils locaux

Les scripts Python sont adaptés pour scanner, importer et transformer des données sur le Mac. Ils ne sont pas embarqués dans l’application. Le code Swift reste réservé à l’app iOS et à toute logique qui doit tourner sur l’iPhone.
